#Requires -Version 5.1
<#
.SYNOPSIS
    Diffs a SOURCE tenant discovery run against a DESTINATION (target) tenant discovery
    run - both produced by Invoke-PurviewSourceDiscovery.ps1 - and emits a migration
    mapping workbook (CSV) + an HTML report with a suggested action for each control.

    NOTE: "Match" is a STRUCTURAL match on the compared properties only, not a behavioural
    equivalence. Detection logic, full DLP rule conditions/actions, and label-encryption
    detail are not exhaustively diffed - verify behaviour before retiring a source control.
    For client-facing output, render this workbook with New-PurviewReport.ps1 -ReportType
    Comparison; the HTML produced here is an internal quick-look.
.PARAMETER SourcePath
    Path to the SOURCE tenant run folder (a SourceDiscovery-* directory).
.PARAMETER TargetPath
    Path to the DESTINATION tenant run folder (run the same export script in the new tenant).
.EXAMPLE
    .\Compare-SourceToTarget.ps1 `
        -SourcePath C:\PurviewDiscovery\SourceDiscovery-20260628-101500 `
        -TargetPath C:\PurviewDiscovery\SourceDiscovery-20260901-090000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$TargetPath,
    [string]$OutputRoot = "C:\PurviewDiscovery"
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $SourcePath)) { throw "SourcePath not found: $SourcePath" }
if (-not (Test-Path $TargetPath)) { throw "TargetPath not found: $TargetPath" }

# Artifact map: Area | relative file (no extension) | Key property | Properties to diff.
# SIT and DLP-rule diffs are deepened so a "Match" is more meaningful (still structural).
$artifacts = @(
    @{ Area='Information Protection'; File='1-InformationProtection\SensitivityLabels'; Key='DisplayName'; Props=@('Priority','ContentType','EncryptionEnabled','ParentLabelDisplayName','Disabled') }
    @{ Area='Information Protection'; File='1-InformationProtection\LabelPolicies';     Key='Name';        Props=@('Mode','Enabled','Labels') }
    @{ Area='Information Protection'; File='1-InformationProtection\AutoLabelPolicies'; Key='Name';        Props=@('Mode','Enabled','ApplySensitivityLabel') }
    @{ Area='Information Protection'; File='1-InformationProtection\AutoLabelRules';    Key='Name';        Props=@('Disabled') }
    @{ Area='Classification';        File='2-Classification\SensitiveInfoTypes_All';   Key='Name';        Props=@('Type','Publisher','RulePackId') }
    @{ Area='DLP';                   File='3-DLP\DlpPolicies';                          Key='Name';        Props=@('Mode','Enabled','ExchangeLocation','SharePointLocation','OneDriveLocation','TeamsLocation','EndpointDlpLocation') }
    @{ Area='DLP';                   File='3-DLP\DlpRules';                             Key='Name';        Props=@('Disabled','BlockAccess','BlockAccessScope','GenerateAlert','NotifyUser','ReportSeverityLevel') }
    @{ Area='Retention & Records';   File='4-Retention-Records\RetentionLabels';        Key='Name';        Props=@('RetentionAction','RetentionDuration','IsRecordLabel','Regulatory') }
    @{ Area='Retention & Records';   File='4-Retention-Records\RetentionPolicies';      Key='Name';        Props=@('Mode','Enabled') }
    @{ Area='Retention & Records';   File='4-Retention-Records\RetentionRules';         Key='Name';        Props=@('RetentionDuration','RetentionComplianceAction') }
)

# Families that are NOT auto-compared (no stable cross-tenant key, or structure too complex)
# - surfaced explicitly so they aren't mistaken for "nothing to do".
$notCompared = @(
    @{ Area='Classification';      Item='SIT rule packages (regex/keyword XML)' }
    @{ Area='Classification';      Item='EDM schemas' }
    @{ Area='DLP';                 Item='Endpoint DLP global settings (Get-PolicyConfig)' }
    @{ Area='Retention & Records'; Item='Retention event types' }
    @{ Area='Retention & Records'; Item='Adaptive scopes' }
    @{ Area='Retention & Records'; Item='File-plan descriptors' }
    @{ Area='Audit';               Item='Audit configuration & retention policies' }
)

function Import-Run([string]$root,[string]$rel){
    $xml  = Join-Path $root "$rel.xml"
    $json = Join-Path $root "$rel.json"
    if (Test-Path $xml)  { return @(Import-Clixml $xml) }
    if (Test-Path $json) { return @(Get-Content $json -Raw | ConvertFrom-Json) }
    return @()
}
function Get-Val($obj,$prop){
    $v = $obj.$prop
    if ($null -eq $v) { return '' }
    # Sort multi-valued properties before joining so order differences don't read as "Changed".
    if ($v -is [System.Array]) { return (($v | ForEach-Object { "$_" } | Sort-Object) -join ';') }
    return "$v"
}
function Get-ManifestStatus([string]$root){
    $h = @{}
    $m = Join-Path $root '_manifest.csv'
    if (Test-Path $m) { foreach($r in (Import-Csv $m)){ if($r.Artifact){ $h[$r.Artifact] = $r.Status } } }
    $h
}
function Test-ExportBad($status){ (-not $status) -or ($status -eq 'CmdletNotAvailable') -or ("$status" -like 'Failed*') }
function Get-Decision($status){
    switch ($status){
        'Match'        { 'Carry forward (verify, then decommission source)' }
        'Changed'      { 'Review delta (confirm intended vs. drift)' }
        'OnlyInSource' { 'Retire or recreate (decide carry-forward)' }
        'OnlyInTarget' { 'Confirm net-new (validate intended)' }
        'Inconclusive' { 'Re-run discovery (export failed/unavailable one side)' }
        'KeyCollision' { 'Resolve duplicate display names (sublabels) before trusting' }
        'NotCompared'  { 'Manual review (not auto-compared)' }
        default        { 'Review' }
    }
}
function ConvertTo-HtmlText($s){ "$s" -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $OutputRoot "Comparison-$stamp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$workbook = [System.Collections.Generic.List[object]]::new()

$srcStatus = Get-ManifestStatus $SourcePath
$tgtStatus = Get-ManifestStatus $TargetPath
$gate = (Test-Path (Join-Path $SourcePath '_manifest.csv')) -and (Test-Path (Join-Path $TargetPath '_manifest.csv'))

foreach ($a in $artifacts){
    $artName = Split-Path $a.File -Leaf

    # If a manifest shows the export failed or the cmdlet was unavailable on either side,
    # the data is missing-not-empty: report INCONCLUSIVE rather than a one-sided diff.
    if ($gate -and ((Test-ExportBad $srcStatus[$artName]) -or (Test-ExportBad $tgtStatus[$artName]))) {
        $workbook.Add([pscustomobject]@{
            Area=$a.Area; Artifact=$artName; Key='(whole family)'; Status='Inconclusive'
            SuggestedDecision=(Get-Decision 'Inconclusive'); ChangedProperties=''
            SourceValues="src=$($srcStatus[$artName])"; TargetValues="tgt=$($tgtStatus[$artName])" })
        continue
    }

    $src = Import-Run $SourcePath $a.File
    $tgt = Import-Run $TargetPath $a.File

    # Build keyed maps and detect display-name collisions (e.g. parent vs sublabel sharing a name).
    $sMap=@{}; $tMap=@{}; $collide=[System.Collections.Generic.List[string]]::new()
    foreach($o in $src){ if($o){ $k="$($o.$($a.Key))"; if($k){ $kl=$k.ToLower(); if($sMap.ContainsKey($kl)){ $collide.Add("source:$k") }; $sMap[$kl]=$o } } }
    foreach($o in $tgt){ if($o){ $k="$($o.$($a.Key))"; if($k){ $kl=$k.ToLower(); if($tMap.ContainsKey($kl)){ $collide.Add("target:$k") }; $tMap[$kl]=$o } } }
    if($collide.Count){
        $workbook.Add([pscustomobject]@{
            Area=$a.Area; Artifact=$artName; Key='(duplicate keys)'; Status='KeyCollision'
            SuggestedDecision=(Get-Decision 'KeyCollision'); ChangedProperties=($collide -join '; ')
            SourceValues=''; TargetValues='' })
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $allKeys = @($sMap.Keys + $tMap.Keys) | Select-Object -Unique
    foreach($k in $allKeys){
        $inS = $sMap.ContainsKey($k); $inT = $tMap.ContainsKey($k)
        $changed = @(); $sv = @(); $tv = @()
        if($inS -and $inT){
            foreach($p in $a.Props){
                $v1 = Get-Val $sMap[$k] $p; $v2 = Get-Val $tMap[$k] $p
                if($v1 -ne $v2){ $changed += $p; $sv += "$p=$v1"; $tv += "$p=$v2" }
            }
            if($changed.Count){ $status='Changed' } else { $status='Match' }
            $keyName = $sMap[$k].$($a.Key)
        } elseif($inS){ $status='OnlyInSource'; $keyName = $sMap[$k].$($a.Key) }
        else          { $status='OnlyInTarget'; $keyName = $tMap[$k].$($a.Key) }

        $row = [pscustomobject]@{
            Area              = $a.Area
            Artifact          = $artName
            Key               = $keyName
            Status            = $status
            SuggestedDecision = (Get-Decision $status)
            ChangedProperties = ($changed -join ';')
            SourceValues      = ($sv -join ' | ')
            TargetValues      = ($tv -join ' | ')
        }
        $rows.Add($row); $workbook.Add($row)
    }
    if($rows.Count){ $rows | Export-Csv (Join-Path $outDir ($artName+'.csv')) -NoTypeInformation -Encoding utf8 }
}

# Explicitly record the families this tool does not auto-compare.
foreach($nc in $notCompared){
    $workbook.Add([pscustomobject]@{
        Area=$nc.Area; Artifact=$nc.Item; Key='(family)'; Status='NotCompared'
        SuggestedDecision=(Get-Decision 'NotCompared'); ChangedProperties=''; SourceValues=''; TargetValues='' })
}

# Consolidated mapping workbook
$workbook | Export-Csv (Join-Path $outDir '_MigrationMappingWorkbook.csv') -NoTypeInformation -Encoding utf8

# ---------------- HTML report (internal quick-look) ----------------
$colors = @{ Match='#2e7d32'; Changed='#c47d00'; OnlyInSource='#b10e1c'; OnlyInTarget='#1565c0'
             Inconclusive='#6b7280'; KeyCollision='#7e57c2'; NotCompared='#9aa0a6' }
$css = @"
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1f;background:#fafafa}
h1{font-size:22px;margin:0 0 4px} h2{font-size:16px;margin:24px 0 8px;border-bottom:2px solid #ddd;padding-bottom:4px}
.sub{color:#666;font-size:13px;margin-bottom:16px}
.cards{display:flex;gap:12px;flex-wrap:wrap;margin:12px 0}
.card{border-radius:8px;padding:12px 16px;color:#fff;min-width:140px}
.card .n{font-size:26px;font-weight:700} .card .l{font-size:12px;opacity:.9}
table{border-collapse:collapse;width:100%;background:#fff;font-size:12px;margin-top:8px}
th,td{border:1px solid #e0e0e0;padding:6px 8px;text-align:left;vertical-align:top}
th{background:#f0f0f3;position:sticky;top:0}
.badge{display:inline-block;padding:1px 8px;border-radius:10px;color:#fff;font-size:11px}
.legend{font-size:12px;color:#444;margin:8px 0}
.legend span{display:inline-block;margin-right:14px}
.dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:4px;vertical-align:middle}
"@

$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append("<!doctype html><html><head><meta charset='utf-8'><title>Purview Source-to-Target Comparison</title><style>$css</style></head><body>")
[void]$sb.Append("<h1>Microsoft Purview - Source-to-Target Migration Comparison</h1>")
[void]$sb.Append("<div class='sub'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')<br>Source: $(ConvertTo-HtmlText $SourcePath)<br>Target: $(ConvertTo-HtmlText $TargetPath)</div>")

# Summary cards by status
[void]$sb.Append("<div class='cards'>")
foreach($st in 'Match','Changed','OnlyInSource','OnlyInTarget'){
    $n = @($workbook | Where-Object Status -eq $st).Count
    [void]$sb.Append("<div class='card' style='background:$($colors[$st])'><div class='n'>$n</div><div class='l'>$st</div></div>")
}
[void]$sb.Append("</div>")
[void]$sb.Append("<div class='legend'>Suggested actions: " +
    "<span><span class='dot' style='background:$($colors.Match)'></span>Match &rarr; Carry forward (verify, then decommission source)</span>" +
    "<span><span class='dot' style='background:$($colors.Changed)'></span>Changed &rarr; Review delta (confirm intended vs. drift)</span>" +
    "<span><span class='dot' style='background:$($colors.OnlyInSource)'></span>Only in source &rarr; Retire or recreate (decide carry-forward)</span>" +
    "<span><span class='dot' style='background:$($colors.OnlyInTarget)'></span>Only in target &rarr; Confirm net-new (validate intended)</span></div>")

# Per-area breakdown
[void]$sb.Append("<h2>Breakdown by area</h2><table><tr><th>Area</th><th>Match</th><th>Changed</th><th>Only in source</th><th>Only in target</th></tr>")
foreach($areaGrp in ($workbook | Group-Object Area | Sort-Object Name)){
    $m =@($areaGrp.Group | Where-Object Status -eq 'Match').Count
    $c =@($areaGrp.Group | Where-Object Status -eq 'Changed').Count
    $s =@($areaGrp.Group | Where-Object Status -eq 'OnlyInSource').Count
    $t =@($areaGrp.Group | Where-Object Status -eq 'OnlyInTarget').Count
    [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $areaGrp.Name)</td><td>$m</td><td>$c</td><td>$s</td><td>$t</td></tr>")
}
[void]$sb.Append("</table>")

# Full detail table
[void]$sb.Append("<h2>Control-by-control detail</h2><table><tr><th>Area</th><th>Artifact</th><th>Control</th><th>Status</th><th>Suggested decision</th><th>Changed</th><th>Source &rarr; Target</th></tr>")
foreach($r in ($workbook | Sort-Object Area,Artifact,Status,Key)){
    $c = $colors[$r.Status]; if(-not $c){ $c = '#555' }
    $delta = if($r.ChangedProperties){ (ConvertTo-HtmlText $r.SourceValues) + ' &rarr; ' + (ConvertTo-HtmlText $r.TargetValues) } else { '' }
    [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $r.Area)</td><td>$(ConvertTo-HtmlText $r.Artifact)</td><td>$(ConvertTo-HtmlText $r.Key)</td>" +
        "<td><span class='badge' style='background:$c'>$($r.Status)</span></td><td>$(ConvertTo-HtmlText $r.SuggestedDecision)</td>" +
        "<td>$(ConvertTo-HtmlText $r.ChangedProperties)</td><td>$delta</td></tr>")
}
[void]$sb.Append("</table>")
[void]$sb.Append("<p class='sub' style='margin-top:24px'>Note: <b>Match is a structural match on the compared properties only - not a behavioural equivalence.</b> " +
    "Suggested actions are heuristics from a config diff. Final decisions require business + compliance owner sign-off. " +
    "Consolidation cannot be inferred automatically - review 'Only in source' clusters for overlap. Families marked NotCompared/Inconclusive/KeyCollision need manual review.</p>")
[void]$sb.Append("</body></html>")
$sb.ToString() | Out-File (Join-Path $outDir '_ComparisonReport.html') -Encoding utf8

Write-Host "`nComparison complete." -ForegroundColor Cyan
Write-Host "  Workbook: $(Join-Path $outDir '_MigrationMappingWorkbook.csv')"
Write-Host "  Report:   $(Join-Path $outDir '_ComparisonReport.html')"
$workbook | Group-Object Status | Select-Object Name,Count | Format-Table -AutoSize
