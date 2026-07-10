#Requires -Version 5.1
<#
.SYNOPSIS
    Shared plumbing for the Purview configuration snapshot toolkit (internal module).
    Houses the connect logic, the per-area collection wrapper and its status
    vocabulary, stable-key ordering, and the canonical snapshot serializers.
.NOTES
    Internal structure only (DECISIONS.md batch 2, Task 1): no manifest, no publish.
    Read-only: the only tenant-touching commands issued here are the Connect-* session
    setup calls. Collection happens in caller-supplied scriptblocks, so cmdlet
    resolution (and test mocking) follows the calling script's session, not this
    module's scope.

    Status vocabulary (D9):
        Success | Empty | AccessDenied | CmdletNotAvailable | Failed | NotAttempted
#>

$script:SnapshotSchemaVersion = '1.0-draft'   # frozen at the sandbox checkpoint (Task 5)
$script:SnapshotToolName      = 'purview-discovery-toolkit'
$script:SnapshotToolVersion   = '2.0.0-dev'

# PowerShell remoting/transport artifacts stripped from collected objects before
# serialization: they describe the session, not tenant configuration.
$script:TransportNoiseProperties = @('PSComputerName', 'RunspaceId', 'PSShowComputerName')

# Volatile-field register (D9): paths a diff of two snapshots must ignore because they
# change run-to-run without any configuration change. Reasons are documented in
# docs/SNAPSHOT-SCHEMA.md; the register is embedded in every snapshot for
# self-description.
$script:VolatileFieldRegister = @(
    'provenance',
    'areas[].durationMs',
    'areas[].count',
    'areas[].error',
    'areas[].objects[].DistributionStatus',
    'areas[].objects[].DistributionResults',
    'areas[].objects[].LastStatusUpdateTime',
    'areas[diffExcluded=true]'
)

function Get-SnapshotSchemaVersion { $script:SnapshotSchemaVersion }
function Get-SnapshotToolVersion   { $script:SnapshotToolVersion }
function Get-SnapshotVolatileFieldRegister { ,@($script:VolatileFieldRegister) }

function Get-SafeName([string]$n) {
    if ([string]::IsNullOrWhiteSpace($n)) { 'unnamed' } else { ($n -replace '[\\/:*?"<>|]', '_').Trim() }
}

function Connect-PurviewSnapshotSession {
    <# Connects to Security & Compliance PowerShell (IPPS) and Exchange Online.
       -ReuseExistingSession skips everything, including the module import, so an
       already-connected session (or an offline test session) is left untouched. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [switch]$ReuseExistingSession
    )
    if ($ReuseExistingSession) { return }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Write-Host "Connecting to Security & Compliance PowerShell (sign in as $UserPrincipalName)..." -ForegroundColor Yellow
    Connect-IPPSSession -UserPrincipalName $UserPrincipalName
    Write-Host "Connecting to Exchange Online (sign in as $UserPrincipalName)..." -ForegroundColor Yellow
    Connect-ExchangeOnline -UserPrincipalName $UserPrincipalName -ShowBanner:$false
}

function Resolve-SnapshotFailureStatus {
    <# Maps an exception to the D9 failure statuses: CommandNotFound ->
       CmdletNotAvailable; authorization signals (type or message text, anywhere in
       the inner-exception chain) -> AccessDenied; anything else -> Failed. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Exception)
    if ($Exception -is [System.Management.Automation.CommandNotFoundException]) { return 'CmdletNotAvailable' }
    $e = $Exception
    while ($null -ne $e) {
        if ($e -is [System.UnauthorizedAccessException] -or $e -is [System.Security.SecurityException]) { return 'AccessDenied' }
        $text = "$($e.GetType().FullName) $($e.Message)"
        if ($text -match '(?i)access[\s-]*(is[\s-]+)?denied|unauthori[sz]ed|forbidden|\(401\)|\(403\)|insufficient\s+(permission|privilege|access|right)|not\s+authorized|permission\s+denied|role\s+(assignment|required)|\bRBAC\b') {
            return 'AccessDenied'
        }
        $e = $e.InnerException
    }
    'Failed'
}

function Get-SnapshotStableKey {
    <# Stable identifier used to order objects deterministically (D9): Guid+Name
       composite where a Guid exists, then Name, then Identity, then a SHA-256 of the
       object's compact JSON. Documented in docs/SNAPSHOT-SCHEMA.md. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Object)
    $p = $Object.PSObject.Properties
    $guid     = if ($p['Guid'])     { "$($Object.Guid)" }     else { '' }
    $name     = if ($p['Name'])     { "$($Object.Name)" }     else { '' }
    $identity = if ($p['Identity']) { "$($Object.Identity)" } else { '' }
    if ($guid)     { return "guid:$guid|name:$name" }
    if ($name)     { return "name:$name" }
    if ($identity) { return "id:$identity" }
    $json = ConvertTo-Json -InputObject $Object -Depth 12 -Compress -WarningAction SilentlyContinue
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = (@($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($json))) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
    "hash:$hash"
}

function ConvertTo-SnapshotObjects {
    <# Normalizes a collected object set for the snapshot: drops nulls, strips
       remoting noise properties, and sorts by stable key (ordinal, with the object's
       compact JSON as tiebreaker so duplicate keys still order deterministically). #>
    [CmdletBinding()]
    param([object[]]$Objects = @())
    $clean = [System.Collections.Generic.List[object]]::new()
    foreach ($o in @($Objects)) {
        if ($null -eq $o) { continue }
        $noise = @($o.PSObject.Properties | Where-Object { $_.Name -in $script:TransportNoiseProperties })
        if (@($noise).Count -gt 0) {
            $copy = [ordered]@{}
            foreach ($pr in $o.PSObject.Properties) {
                if ($pr.Name -notin $script:TransportNoiseProperties) { $copy[$pr.Name] = $pr.Value }
            }
            $clean.Add([pscustomobject]$copy)
        } else {
            $clean.Add($o)
        }
    }
    if ($clean.Count -le 1) { return ,@($clean.ToArray()) }
    # In-place List sort with an ordinal Comparison delegate. (Array.Sort(keys, items)
    # is unusable here: PowerShell passes the items array as a converted copy, so the
    # caller's array never reorders.)
    $decorated = [System.Collections.Generic.List[object]]::new()
    foreach ($o in $clean) {
        $tiebreak = ConvertTo-Json -InputObject $o -Depth 12 -Compress -WarningAction SilentlyContinue
        $decorated.Add([pscustomobject]@{ K = (Get-SnapshotStableKey -Object $o) + "`n" + $tiebreak; O = $o })
    }
    $decorated.Sort([System.Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.K, $y.K) })
    $sorted = New-Object 'object[]' $decorated.Count
    for ($i = 0; $i -lt $decorated.Count; $i++) { $sorted[$i] = $decorated[$i].O }
    ,$sorted
}

function Get-SnapshotArea {
    <# The Export-Artifact successor: runs a caller-supplied collect scriptblock and
       returns a per-area envelope carrying the durable outcome. Every attempted area
       yields an envelope; nothing is silent (D9).

       -Process optionally post-processes the collected objects INSIDE the same
       try/catch (so sidecar-writing failures classify into the area status). It
       receives the raw objects and returns @{ Objects; Sidecars; Notes }. Notes
       surface in the envelope's error field without failing the area. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Area,
        [string[]]$Cmdlet = @(),
        [scriptblock]$Collect,
        [scriptblock]$Process,
        [switch]$DiffExcluded,
        [switch]$Skip,
        [string]$SkipReason = 'Skipped by parameter'
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'Failed'; $err = $null; $objects = @(); $sidecars = @()
    if ($Skip) {
        $status = 'NotAttempted'
        $err = $SkipReason
    } elseif ($null -eq $Collect) {
        throw "Get-SnapshotArea '$Area': -Collect is required unless -Skip is set."
    } else {
        try {
            $raw = @(@(& $Collect) | Where-Object { $null -ne $_ })
            $notes = @()
            if ($Process) {
                $r = & $Process $raw
                $objects  = @(@($r.Objects)  | Where-Object { $null -ne $_ })
                $sidecars = @(@($r.Sidecars) | Where-Object { $null -ne $_ })
                $notes    = @(@($r.Notes)    | Where-Object { $_ })
            } else {
                $objects = $raw
            }
            $objects = ConvertTo-SnapshotObjects -Objects $objects
            $status = if (@($objects).Count -gt 0) { 'Success' } else { 'Empty' }
            if (@($notes).Count -gt 0) { $err = (@($notes) -join '; ') }
        } catch {
            $status = Resolve-SnapshotFailureStatus -Exception $_.Exception
            $err = $_.Exception.Message
            $objects = @(); $sidecars = @()
        }
    }
    $sw.Stop()
    [pscustomobject][ordered]@{
        area         = $Area
        cmdlets      = @($Cmdlet)
        status       = $status
        count        = @($objects).Count
        error        = $err
        durationMs   = [long]$sw.ElapsedMilliseconds
        diffExcluded = [bool]$DiffExcluded
        sidecars     = @($sidecars)
        objects      = @($objects)
    }
}
