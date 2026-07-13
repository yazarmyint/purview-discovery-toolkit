#Requires -Version 5.1
<#
.SYNOPSIS
    Point-in-time Microsoft Purview configuration snapshot. Enumerates Information
    Protection, Classification, DLP, Data Lifecycle / Records and Audit configuration
    read-only and writes ONE schema-versioned snapshot.json (the source of truth),
    plus sidecar files for large XML/ZIP artifacts and a _manifest.csv status view.
.NOTES
    Connects to BOTH Security & Compliance PowerShell (IPPS) and Exchange Online (EXO).
    Read-only: issues only Get-* / Export-* cmdlets.

    Every area records a durable status - Success | Empty | AccessDenied |
    CmdletNotAvailable | Failed | NotAttempted (DECISIONS.md D9) - so an absent
    cmdlet, a permissions gap or a failure is never silent. Snapshot shape,
    stable-key ordering and the volatile-field register are documented in
    docs/SNAPSHOT-SCHEMA.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceUpn,
    [string]$OutputRoot = "C:\PurviewDiscovery",
    [switch]$IncludePurviewConfigZip,
    [switch]$ReuseExistingSession
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PurviewSnapshot.psm1') -Force

# --- Run scaffold (UTC stamps; D9) ------------------------------------------
$startedUtc = (Get-Date).ToUniversalTime()
$runDir = Join-Path $OutputRoot ("SourceDiscovery-" + $startedUtc.ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
Start-Transcript -Path (Join-Path $runDir '_transcript.log') -Force | Out-Null
$script:Areas = [System.Collections.Generic.List[object]]::new()
$script:RunCompleted = $false
$script:SidecarRoot = Join-Path $runDir 'sidecars'
Write-Host "Output: $runDir" -ForegroundColor Cyan

# Writes one sidecar file and returns its snapshot reference (relative path with
# forward slashes). Called from -Process blocks, so a write failure classifies into
# that area's status instead of dying silently.
function Write-SidecarFile([string]$AreaName, [string]$FileName, [string]$Content) {
    $dir = Join-Path $script:SidecarRoot $AreaName
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir $FileName), $Content, (New-Object System.Text.UTF8Encoding $false))
    "sidecars/$AreaName/$FileName"
}

# Registers an envelope and prints its one-line outcome.
function Trace-Area($Envelope) {
    $script:Areas.Add($Envelope)
    $color = switch ($Envelope.status) {
        'Success'      { 'Green' }
        'Empty'        { 'DarkGray' }
        'NotAttempted' { 'DarkGray' }
        default        { 'Yellow' }
    }
    $suffix = if ($Envelope.error) { " ($($Envelope.error))" } else { '' }
    Write-Host "[$($Envelope.status)] $($Envelope.area): $($Envelope.count)$suffix" -ForegroundColor $color
}

# Everything below runs inside try/finally: on ANY terminating error the snapshot
# (areas collected so far, outcome Aborted), the manifest view and the transcript
# are still produced (finally block at EOF).
try {

Connect-PurviewSnapshotSession -UserPrincipalName $SourceUpn -ReuseExistingSession:$ReuseExistingSession

# === Information Protection ==================================================
Trace-Area (Get-SnapshotArea -Area 'InformationProtection.SensitivityLabels' -Cmdlet 'Get-Label' -Collect { Get-Label })
Trace-Area (Get-SnapshotArea -Area 'InformationProtection.LabelPolicies' -Cmdlet 'Get-LabelPolicy' -Collect { Get-LabelPolicy })
Trace-Area (Get-SnapshotArea -Area 'InformationProtection.AutoLabelPolicies' -Cmdlet 'Get-AutoSensitivityLabelPolicy' -Collect { Get-AutoSensitivityLabelPolicy })
Trace-Area (Get-SnapshotArea -Area 'InformationProtection.AutoLabelRules' -Cmdlet 'Get-AutoSensitivityLabelRule' `
    -StableKeyProperty @('Guid', 'ParentPolicyName', 'Name') -Collect { Get-AutoSensitivityLabelRule })

# === Classification ==========================================================
Trace-Area (Get-SnapshotArea -Area 'Classification.SensitiveInformationTypes' -Cmdlet 'Get-DlpSensitiveInformationType' -Collect { Get-DlpSensitiveInformationType })

# SIT rule packages: the serialized rule collection (the regex/keyword logic) goes to
# XML sidecars; the envelope keeps light descriptors. Per-item extraction failures are
# noted without failing the area.
Trace-Area (Get-SnapshotArea -Area 'Classification.SitRulePackages' -Cmdlet 'Get-DlpSensitiveInformationTypeRulePackage' `
    -Collect { Get-DlpSensitiveInformationTypeRulePackage } `
    -Process {
        param($packages)
        $objects  = [System.Collections.Generic.List[object]]::new()
        $sidecars = [System.Collections.Generic.List[object]]::new()
        $notes    = [System.Collections.Generic.List[string]]::new()
        foreach ($p in @($packages)) {
            $id = if ($p.PSObject.Properties['Identity'] -and "$($p.Identity)" -ne '') { "$($p.Identity)" }
                  elseif ($p.PSObject.Properties['Name']) { "$($p.Name)" } else { 'rulepack' }
            $file = (Get-SafeName $id) + '.xml'
            $rel = $null
            try {
                $xml = [System.Text.Encoding]::Unicode.GetString($p.SerializedClassificationRuleCollection)
                $rel = Write-SidecarFile 'Classification.SitRulePackages' $file $xml
                $sidecars.Add([pscustomobject][ordered]@{ name = $file; path = $rel; diffExcluded = $false })
            } catch { $notes.Add(($id + ': ' + $_.Exception.Message)) }
            $desc = [ordered]@{ Name = $id; SidecarPath = $rel }
            foreach ($n in @('RulePackId', 'Publisher', 'Version')) {
                if ($p.PSObject.Properties[$n]) { $desc[$n] = "$($p.$n)" }
            }
            $objects.Add([pscustomobject]$desc)
        }
        @{ Objects = $objects.ToArray(); Sidecars = $sidecars.ToArray(); Notes = $notes.ToArray() }
    })

# EDM schemas: schema XML to sidecars, light descriptors in the envelope.
Trace-Area (Get-SnapshotArea -Area 'Classification.EdmSchemas' -Cmdlet 'Get-DlpEdmSchema' `
    -Collect { Get-DlpEdmSchema } `
    -Process {
        param($schemas)
        $objects  = [System.Collections.Generic.List[object]]::new()
        $sidecars = [System.Collections.Generic.List[object]]::new()
        $notes    = [System.Collections.Generic.List[string]]::new()
        foreach ($s in @($schemas)) {
            $id = "$($s.Identity)"
            $file = (Get-SafeName $id) + '.xml'
            $rel = $null
            try {
                $detail = Get-DlpEdmSchema -Identity $s.Identity
                $rel = Write-SidecarFile 'Classification.EdmSchemas' $file "$($detail.EdmSchemaXML)"
                $sidecars.Add([pscustomobject][ordered]@{ name = $file; path = $rel; diffExcluded = $false })
            } catch { $notes.Add(($id + ': ' + $_.Exception.Message)) }
            $objects.Add([pscustomobject][ordered]@{ Name = $id; SidecarPath = $rel })
        }
        @{ Objects = $objects.ToArray(); Sidecars = $sidecars.ToArray(); Notes = $notes.ToArray() }
    })
# NOTE: custom trainable classifiers have no export cmdlet (documented gap; see README).

# === Data Loss Prevention ====================================================
Trace-Area (Get-SnapshotArea -Area 'Dlp.Policies' -Cmdlet 'Get-DlpCompliancePolicy' -Collect { Get-DlpCompliancePolicy })
Trace-Area (Get-SnapshotArea -Area 'Dlp.Rules' -Cmdlet 'Get-DlpComplianceRule' `
    -StableKeyProperty @('Guid', 'ParentPolicyName', 'Name') -Collect { Get-DlpComplianceRule })
Trace-Area (Get-SnapshotArea -Area 'Dlp.EndpointGlobalSettings' -Cmdlet 'Get-PolicyConfig' -Collect { Get-PolicyConfig })

# === Data Lifecycle & Records ================================================
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.Labels' -Cmdlet 'Get-ComplianceTag' -Collect { Get-ComplianceTag })
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.Policies' -Cmdlet 'Get-RetentionCompliancePolicy' -Collect { Get-RetentionCompliancePolicy -DistributionDetail })
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.Rules' -Cmdlet 'Get-RetentionComplianceRule' `
    -StableKeyProperty @('Guid', 'Policy', 'Name') -Collect { Get-RetentionComplianceRule })
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.EventTypes' -Cmdlet 'Get-ComplianceRetentionEventType' -Collect { Get-ComplianceRetentionEventType })
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.AdaptiveScopes' -Cmdlet 'Get-AdaptiveScope' -Collect { Get-AdaptiveScope })
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.FilePlanAuthorities' -Cmdlet 'Get-FilePlanPropertyAuthority' -Collect { Get-FilePlanPropertyAuthority })
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.FilePlanCategories' -Cmdlet 'Get-FilePlanPropertyCategory' -Collect { Get-FilePlanPropertyCategory })
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.FilePlanSubCategories' -Cmdlet 'Get-FilePlanPropertySubCategory' -Collect { Get-FilePlanPropertySubCategory })
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.FilePlanCitations' -Cmdlet 'Get-FilePlanPropertyCitation' -Collect { Get-FilePlanPropertyCitation })
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.FilePlanDepartments' -Cmdlet 'Get-FilePlanPropertyDepartment' -Collect { Get-FilePlanPropertyDepartment })
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.FilePlanReferenceIds' -Cmdlet 'Get-FilePlanPropertyReferenceId' -Collect { Get-FilePlanPropertyReferenceId })

# === Audit configuration =====================================================
Trace-Area (Get-SnapshotArea -Area 'Audit.UnifiedAuditIngestion' -Cmdlet 'Get-AdminAuditLogConfig' -Collect { Get-AdminAuditLogConfig })
Trace-Area (Get-SnapshotArea -Area 'Audit.LogRetentionPolicies' -Cmdlet 'Get-UnifiedAuditLogRetentionPolicy' -Collect { Get-UnifiedAuditLogRetentionPolicy })
# Full Exchange organization configuration: captured for reference, excluded from the
# diff guarantees (large, and many operational fields move without configuration
# intent) - see the volatile-field register.
Trace-Area (Get-SnapshotArea -Area 'Audit.OrganizationConfig' -Cmdlet 'Get-OrganizationConfig' -DiffExcluded -Collect { Get-OrganizationConfig })

# === Diagnostics (opt-in, out-of-band corroborating evidence; D5/D6) =========
Trace-Area (Get-SnapshotArea -Area 'Diagnostics.PurviewConfigZip' -Cmdlet 'Export-PurviewConfig' -DiffExcluded `
    -Skip:(-not $IncludePurviewConfigZip) -SkipReason 'IncludePurviewConfigZip not set' `
    -Collect {
        # The ZIP arrives as byte[]; hold it in a property so the pipeline cannot
        # enumerate it byte-by-byte.
        [pscustomobject]@{ Bytes = (Export-PurviewConfig -Components DLP, MIPLabels, ClassificationAndTextExtraction, DLM) }
    } `
    -Process {
        param($results)
        $bytes = $results[0].Bytes
        $dir = Join-Path $script:SidecarRoot 'Diagnostics.PurviewConfigZip'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'PurviewConfig.zip'), $bytes)
        $rel = 'sidecars/Diagnostics.PurviewConfigZip/PurviewConfig.zip'
        @{
            Objects  = @([pscustomobject][ordered]@{ Name = 'PurviewConfig.zip'; SidecarPath = $rel; SizeBytes = $bytes.Length })
            Sidecars = @([pscustomobject][ordered]@{ name = 'PurviewConfig.zip'; path = $rel; diffExcluded = $true })
        }
    })

$script:RunCompleted = $true

# --- Console summary ----------------------------------------------------------
$script:Areas | Select-Object area, status, count | Format-Table -AutoSize
Write-Host "Snapshot run complete." -ForegroundColor Cyan

} finally {
    # Crash safety: the snapshot (everything collected so far), the manifest view and
    # the transcript are produced even when a terminating error aborts the run.
    $endedUtc = (Get-Date).ToUniversalTime()
    $outcome = if ($script:RunCompleted) { 'Completed' } else { 'Aborted' }
    try {
        $prov = Get-SnapshotProvenance -UserPrincipalName $SourceUpn -Parameters $PSBoundParameters `
            -StartedUtc $startedUtc -EndedUtc $endedUtc -ScriptName 'Invoke-PurviewSourceDiscovery.ps1' -Outcome $outcome
        $doc = Get-PurviewSnapshotDocument -Provenance $prov -Areas @($script:Areas)
        Write-PurviewSnapshot -Document $doc -Path (Join-Path $runDir 'snapshot.json')
        Write-Host "Snapshot: $(Join-Path $runDir 'snapshot.json') ($outcome)" -ForegroundColor Cyan
    } catch { Write-Warning "Snapshot write failed: $($_.Exception.Message)" }
    if ($script:Areas.Count -gt 0) {
        try { Write-SnapshotManifestCsv -Areas @($script:Areas) -Path (Join-Path $runDir '_manifest.csv') }
        catch { Write-Warning "Manifest view write failed: $($_.Exception.Message)" }
    }
    try { Stop-Transcript | Out-Null } catch { }
}
