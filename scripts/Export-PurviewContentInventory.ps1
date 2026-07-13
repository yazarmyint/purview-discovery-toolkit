#Requires -Version 5.1
<#
.SYNOPSIS
    Content Explorer baseline: item counts per SIT / sensitivity label / retention label.
    Requires the "Content Explorer List Viewer" (counts/list) or "Content Explorer Content
    Viewer" role - NEITHER is granted by the Compliance Administrator role group, so assign
    one explicitly. Run against the tenant under assessment.
    In -Detailed mode the output includes file names, UPNs, and site URLs - treat as confidential.
.PARAMETER TagType
    Canonical Export-ContentExplorerData TagType values: SensitiveInformationType, Sensitivity,
    Retention, TrainableClassifier.
.PARAMETER Detailed
    File-level export (uses paging). Slower; output may include file names / UPNs / site URLs
    - treat as confidential. Omit for fast aggregate counts (falls back to paged counting if
    the -Aggregate preview isn't available in the tenant).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$OutputRoot = "C:\PurviewDiscovery",
    [ValidateSet('SensitiveInformationType','Sensitivity','Retention','TrainableClassifier')]
    [string]$TagType = 'SensitiveInformationType',
    [string[]]$Tags,            # leave empty to auto-discover from the tenant
    [switch]$Detailed,
    [switch]$ReuseExistingSession
)
$ErrorActionPreference = 'Stop'
Import-Module ExchangeOnlineManagement -ErrorAction Stop
function Connect-Ipps { Connect-IPPSSession -UserPrincipalName $UserPrincipalName -WarningAction SilentlyContinue | Out-Null }
if (-not $ReuseExistingSession) { Connect-Ipps }

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $OutputRoot "ContentInventory-$stamp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Auto-discover tags if none supplied (TagType values must be canonical)
if (-not $Tags) {
    switch ($TagType) {
        'SensitiveInformationType' { $Tags = (Get-DlpSensitiveInformationType | Where-Object Publisher -ne 'Microsoft Corporation').Name }
        'Sensitivity'              { $Tags = (Get-Label).DisplayName }
        'Retention'                { $Tags = (Get-ComplianceTag).Name }
        'TrainableClassifier'      { Write-Warning "Trainable classifiers can't be auto-enumerated; pass -Tags explicitly."; return }
    }
    if (-not $Tags) { Write-Warning "No tags found for $TagType; pass -Tags explicitly (e.g. to inventory built-in SITs by name)."; return }
}

# Probe -Aggregate availability. It's a preview feature absent in some tenants; if the user
# didn't ask for -Detailed and aggregate isn't available, fall back to paged counting.
$useAggregate = -not $Detailed
if ($useAggregate) {
    try { $null = Export-ContentExplorerData -TagType $TagType -TagName $Tags[0] -Aggregate -ErrorAction Stop }
    catch {
        Write-Warning "-Aggregate not available in this tenant ($($_.Exception.Message)). Falling back to paged counting."
        $useAggregate = $false
    }
}

# Detailed/paged retrieval with token-expiry resume. The session token expires after ~1 hour;
# on failure we reconnect and resume from the last page cookie.
function Get-PagedRecords([string]$tagType,[string]$tag) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $cookie = $null
    do {
        try {
            $page = Export-ContentExplorerData -TagType $tagType -TagName $tag -PageSize 1000 -PageCookie $cookie
        } catch {
            Write-Warning "  page failed ($($_.Exception.Message)); reconnecting and resuming from last cookie..."
            Connect-Ipps
            $page = Export-ContentExplorerData -TagType $tagType -TagName $tag -PageSize 1000 -PageCookie $cookie
        }
        $head = $page | Select-Object -First 1                       # element 0 = summary object
        if (@($page).Count -gt 1) { $page[1..($page.Count-1)] | ForEach-Object { $rows.Add($_) } }
        $cookie = $head.PageCookie
        $more = ("$($head.MorePagesAvailable)".Trim() -eq 'True')    # explicit; [bool]"False" would be $true
    } while ($more -and $cookie)
    ,$rows
}

$summary = [System.Collections.Generic.List[object]]::new()
foreach ($tag in $Tags) {
    Write-Host "Inventorying [$TagType] $tag ..." -ForegroundColor Yellow
    try {
        if ($useAggregate) {
            $r = Export-ContentExplorerData -TagType $TagType -TagName $tag -Aggregate
            $total = ($r | Select-Object -First 1).TotalCount
            $summary.Add([pscustomobject]@{ TagType=$TagType; Tag=$tag; TotalCount=$total; Mode='Aggregate' })
        } else {
            $rows = Get-PagedRecords $TagType $tag
            if ($Detailed) {
                $rows | ConvertTo-Json -Depth 8 |
                    Out-File (Join-Path $outDir ("Detail_$(($tag -replace '[\\/:*?""<>|]','_')).json")) -Encoding utf8
            }
            $summary.Add([pscustomobject]@{ TagType=$TagType; Tag=$tag; TotalCount=$rows.Count; Mode=$(if($Detailed){'Detailed'}else{'PagedCount'}) })
        }
    } catch { Write-Warning "  $tag failed: $($_.Exception.Message)" }
}
$summary | Sort-Object TotalCount -Descending | Export-Csv (Join-Path $outDir '_ContentInventorySummary.csv') -NoTypeInformation -Encoding utf8
$summary | Sort-Object TotalCount -Descending | Format-Table -AutoSize
Write-Host "Saved: $outDir" -ForegroundColor Cyan
