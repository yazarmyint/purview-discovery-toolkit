#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a client-ready, self-contained HTML report from the Purview discovery
    toolkit output. Reads a SourceDiscovery-* run folder and renders an
    information-protection discovery baseline report.

    The report is fully offline (inline CSS + inline SVG charts, no CDN / internet),
    print-to-PDF friendly, with an executive summary at the top and technical detail below.

.EXAMPLE
    .\New-PurviewReport.ps1 `
        -Path C:\PurviewDiscovery\SourceDiscovery-20260628-101500 `
        -OrganizationName "Contoso Ltd" -PreparedBy "Acme Advisory" -Classification "Confidential"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$OutputPath,
    [string]$OrganizationName = 'Your Organization',
    [string]$PreparedBy       = 'Your Organization',
    [string]$ReportTitle      = 'Microsoft Purview Configuration Report',
    [string]$Classification = 'Confidential',
    [string]$TenantLabel    = '',
    [string]$LogoPath
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path)) { throw "Path not found: $Path" }

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Enc([string]$s){ if($null -eq $s){return ''}; $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' }
function Test-True($v){ ($v -is [bool] -and $v) -or ("$v" -match '^(?i)\s*true\s*$') }
function Get-Csv([string]$p){ if(Test-Path $p){ @(Import-Csv $p) } else { @() } }

$Palette = @{
    Priority='#b10e1c'; Improvement='#c47d00'; Healthy='#107c10'; Info='#5b6b7b'; Accent='#0f6cbd'
}
$SevLabel = @{ Priority='Priority'; Improvement='Needs improvement'; Healthy='Healthy'; Info='Informational' }
$SevRank  = @{ Priority=0; Improvement=1; Info=2; Healthy=3 }

function New-Donut {
    param([object[]]$Segments,[string]$CenterValue,[string]$CenterLabel,[int]$Size=190)
    $r=70; $cx=$Size/2; $cy=$Size/2; $C=[math]::PI*2*$r
    $sum=($Segments | Measure-Object Value -Sum).Sum; if($sum -le 0){$sum=1}
    $offset=0; $arcs=''
    foreach($s in $Segments){
        $len=($s.Value/$sum)*$C
        if($len -gt 0){
            $arcs += "<circle cx='$cx' cy='$cy' r='$r' fill='none' stroke='$($s.Color)' stroke-width='24' " +
                     "stroke-dasharray='$([math]::Round($len,2)) $([math]::Round($C-$len,2))' stroke-dashoffset='$([math]::Round(-$offset,2))' transform='rotate(-90 $cx $cy)'></circle>"
        }
        $offset += $len
    }
    $svg = "<svg viewBox='0 0 $Size $Size' width='$Size' height='$Size' role='img'>$arcs" +
           "<text x='$cx' y='$($cy-2)' text-anchor='middle' class='donut-num'>$(Enc $CenterValue)</text>" +
           "<text x='$cx' y='$($cy+18)' text-anchor='middle' class='donut-lbl'>$(Enc $CenterLabel)</text></svg>"
    $legend='<div class="legend">'
    foreach($s in $Segments){ $legend += "<div class='leg'><span class='dot' style='background:$($s.Color)'></span>$(Enc $s.Label) <b>$($s.Value)</b></div>" }
    $legend+='</div>'
    "<div class='donutwrap'>$svg$legend</div>"
}

function New-Bars {
    param([object[]]$Items,[int]$Width=560,[int]$BarH=22,[int]$Gap=12,[string]$Color='#0f6cbd')
    if(-not $Items -or $Items.Count -eq 0){ return "<p class='muted'>No data.</p>" }
    $max=($Items | Measure-Object Value -Maximum).Maximum; if($max -le 0){$max=1}
    $lblW=170; $h=$Items.Count*($BarH+$Gap)+6; $y=4; $rows=''
    foreach($it in $Items){
        $w=[math]::Round(($it.Value/$max)*($Width-$lblW-46))
        $col= if($it.Color){$it.Color}else{$Color}
        $rows += "<text x='0' y='$($y+$BarH-6)' class='barlbl'>$(Enc $it.Label)</text>"
        $rows += "<rect x='$lblW' y='$y' width='$([math]::Max($w,1))' height='$BarH' rx='3' fill='$col'></rect>"
        $rows += "<text x='$($lblW+[math]::Max($w,1)+6)' y='$($y+$BarH-6)' class='barval'>$($it.Value)</text>"
        $y += $BarH+$Gap
    }
    "<svg viewBox='0 0 $Width $h' width='100%' height='$h' role='img'>$rows</svg>"
}

function New-Table {
    param([object[]]$Rows,[string[]]$Columns,[int]$Max=500)
    if(-not $Rows -or $Rows.Count -eq 0){ return "<p class='muted'>No items discovered in this area.</p>" }
    if(-not $Columns){ $Columns = $Rows[0].psobject.Properties.Name }
    $th=($Columns | ForEach-Object { "<th>$(Enc $_)</th>" }) -join ''
    $body=''
    foreach($r in ($Rows | Select-Object -First $Max)){
        $tds=($Columns | ForEach-Object { "<td>$(Enc ("{0}" -f $r.$_))</td>" }) -join ''
        $body += "<tr>$tds</tr>"
    }
    $note = if($Rows.Count -gt $Max){ "<p class='muted'>Showing first $Max of $($Rows.Count) rows; full data in the CSV export.</p>" } else {'' }
    "<div class='tablewrap'><table><thead><tr>$th</tr></thead><tbody>$body</tbody></table></div>$note"
}

function New-ChartCard([string]$Title,[string]$Inner){ "<div class='chartcard'><h4>$(Enc $Title)</h4>$Inner</div>" }
function New-Kpi([string]$Value,[string]$Label,[string]$Sub,[string]$Accent='#0f6cbd'){
    "<div class='kpi' style='border-top-color:$Accent'><div class='kpi-v'>$(Enc $Value)</div><div class='kpi-l'>$(Enc $Label)</div><div class='kpi-s'>$(Enc $Sub)</div></div>"
}
function New-ObsHtml([object[]]$Obs){
    if(-not $Obs -or $Obs.Count -eq 0){ return "<p class='muted'>No observations raised.</p>" }
    $h=''
    foreach($o in ($Obs | Sort-Object @{e={$SevRank[$_.Severity]}})){
        $c=$Palette[$o.Severity]; $lbl=$SevLabel[$o.Severity]
        $rec = if($o.Recommendation){ "<div class='obs-rec'><b>Recommendation:</b> $(Enc $o.Recommendation)</div>" } else {''}
        $h += "<div class='obs' style='border-left-color:$c'><div class='obs-head'><span class='badge' style='background:$c'>$lbl</span>" +
              "<span class='obs-area'>$(Enc $o.Area)</span></div><div class='obs-title'>$(Enc $o.Title)</div>" +
              "<div class='obs-detail'>$(Enc $o.Detail)</div>$rec</div>"
    }
    $h
}

# ----------------------------------------------------------------------------
# Build content per report type
# ----------------------------------------------------------------------------
$obs = [System.Collections.Generic.List[object]]::new()
function Add-Obs($Severity,$Area,$Title,$Detail,$Recommendation){
    $obs.Add([pscustomobject]@{Severity=$Severity;Area=$Area;Title=$Title;Detail=$Detail;Recommendation=$Recommendation})
}

$kpiHtml=''; $chartHtml=''; $detailHtml=''; $narrative=''; $subtitle=''

$subtitle = 'Information-Protection Discovery Baseline'
$labels   = Get-Csv (Join-Path $Path '1-InformationProtection\SensitivityLabels.csv')
$labelPol = Get-Csv (Join-Path $Path '1-InformationProtection\LabelPolicies.csv')
$autoPol  = Get-Csv (Join-Path $Path '1-InformationProtection\AutoLabelPolicies.csv')
$sits     = Get-Csv (Join-Path $Path '2-Classification\SensitiveInfoTypes_All.csv')
$dlp      = Get-Csv (Join-Path $Path '3-DLP\DlpPolicies.csv')
$dlpRules = Get-Csv (Join-Path $Path '3-DLP\DlpRules.csv')
$retLab   = Get-Csv (Join-Path $Path '4-Retention-Records\RetentionLabels.csv')
$retPol   = Get-Csv (Join-Path $Path '4-Retention-Records\RetentionPolicies.csv')
$auditIng = Get-Csv (Join-Path $Path '5-Audit\UnifiedAuditIngestionStatus.csv')
$auditRet = Get-Csv (Join-Path $Path '5-Audit\AuditLogRetentionPolicies.csv')
$manifest = Get-Csv (Join-Path $Path '_manifest.csv')

$lblTotal  = $labels.Count
$lblEnc    = @($labels | Where-Object { Test-True $_.EncryptionEnabled }).Count
$lblParent = @($labels | Where-Object { [string]::IsNullOrWhiteSpace($_.ParentLabel) }).Count
$sitCustom = @($sits   | Where-Object { Test-True $_.IsCustom }).Count
$dlpTotal  = $dlp.Count
$dlpEnf    = @($dlp | Where-Object { $_.Mode -eq 'Enable' }).Count
$dlpTest   = @($dlp | Where-Object { $_.Mode -like 'Test*' }).Count
$dlpDis    = @($dlp | Where-Object { $_.Mode -eq 'Disable' }).Count
$dlpBlk    = @($dlpRules | Where-Object { Test-True $_.BlockAccess }).Count
$dlpNoAlrt = @($dlpRules | Where-Object { -not (Test-True $_.GenerateAlert) }).Count
$retTotal  = $retLab.Count
$records   = @($retLab | Where-Object { Test-True $_.IsRecordLabel }).Count
$noFilePln = @($retLab | Where-Object { $_.FilePlan -eq 'no' }).Count
# Only judge audit ingestion if its export actually succeeded (else status is unknown, not "disabled").
$auditArtifact = @($manifest | Where-Object { $_.Artifact -eq 'UnifiedAuditIngestionStatus' })
$auditAssessed = ($auditArtifact.Count -gt 0) -and ($auditArtifact[0].Status -eq 'Success') -and ($auditIng.Count -gt 0)
$auditOn   = $auditAssessed -and (Test-True $auditIng[0].UnifiedAuditLogIngestionEnabled)

# ---- Observations (the assessment interpretation) ----
if($lblTotal -gt 12){ Add-Obs 'Improvement' 'Information Protection' 'Sensitivity-label taxonomy is larger than a typical spine' "$lblTotal labels discovered (count includes sublabels); large taxonomies are harder to apply consistently." 'Consider consolidating to a small top-level spine with justified sublabels during rationalisation.' }
elseif($lblTotal -eq 0){ Add-Obs 'Priority' 'Information Protection' 'No sensitivity labels are published' 'The tenant has no sensitivity-label taxonomy in place.' 'Design a baseline label taxonomy for the tenant.' }
else { Add-Obs 'Healthy' 'Information Protection' 'Sensitivity-label taxonomy is within a manageable range' "$lblTotal labels discovered ($lblParent top-level)." $null }
if($lblTotal -gt 0 -and $lblEnc -eq 0){ Add-Obs 'Improvement' 'Information Protection' 'No labels apply encryption' 'No discovered label enforces label-based encryption / usage restriction.' 'Apply encryption to the top one or two tiers where confidentiality warrants it.' }
if($dlpTotal -gt 0 -and $dlpEnf -eq 0){ Add-Obs 'Priority' 'Data Loss Prevention' 'No DLP policy is in enforcement mode' "$dlpTotal DLP policies exist but none are set to enforce." 'Confirm which policies should move to enforce after a simulation/audit soak.' }
if($dlpTest -gt 0){ Add-Obs 'Improvement' 'Data Loss Prevention' 'DLP policies remain in test/simulation mode' "$dlpTest of $dlpTotal DLP policies are in a test mode." 'Decide per policy whether to promote to enforce or retire during rationalization.' }
if($dlpNoAlrt -gt 0){ Add-Obs 'Info' 'Data Loss Prevention' 'Some DLP rules do not generate alerts' "$dlpNoAlrt DLP rules have alerting disabled, weakening monitoring evidence." 'Standardise alerting on medium/high-severity rules to support SOC 2 / ISO monitoring evidence.' }
if($sitCustom -gt 0){ Add-Obs 'Info' 'Classification' 'Custom sensitive information types require review & validation' "$sitCustom custom SITs discovered; their detection logic (regex/keywords, EDM, trainable classifiers) is tenant-specific." 'Review and validate custom SITs; note that EDM schemas and trainable classifiers are not fully exportable and should be documented separately.' }
if($noFilePln -gt 0){ Add-Obs 'Improvement' 'Retention & Records' 'Retention labels are not mapped to a file plan' "$noFilePln of $retTotal retention labels have no file-plan descriptors." 'Align retention labels to a legally approved records schedule.' }
if($records -gt 0){ Add-Obs 'Info' 'Retention & Records' 'Record-type labels are immutable' "$records record/regulatory-record labels were found; these cannot be relabelled or deleted." 'Plan explicit handling of immutable records.' }
if(-not $auditAssessed){ Add-Obs 'Info' 'Audit' 'Audit ingestion status was not assessed' 'The audit export was missing, empty or failed in this run, so ingestion state could not be confirmed from the data.' 'Re-run discovery with audit permissions to confirm unified audit logging is enabled.' }
elseif(-not $auditOn){ Add-Obs 'Priority' 'Audit' 'Unified audit log ingestion is disabled' 'Audit ingestion is confirmed disabled in the tenant.' 'Enable unified audit logging and extend retention to support evidence collection.' }
else { Add-Obs 'Healthy' 'Audit' 'Unified audit logging is enabled' 'Audit ingestion is active, supporting activity and override evidence.' $null }
if($auditRet.Count -eq 0){ Add-Obs 'Info' 'Audit' 'No custom audit-log retention policies' 'Only default audit retention is in effect.' 'Define audit-retention policies matching your SOC 2 observation window and ISO records retention.' }

$priCount = @($obs | Where-Object Severity -eq 'Priority').Count
$impCount = @($obs | Where-Object Severity -eq 'Improvement').Count

$narrative = "This report presents the Microsoft Purview information-protection baseline discovered in the $(Enc $OrganizationName) tenant. " +
    "Discovery is read-only and captures the tenant's current-state configuration. It identified <b>$lblTotal</b> sensitivity labels, " +
    "<b>$dlpTotal</b> data loss prevention policies and <b>$retTotal</b> retention labels across the assessed control areas. " +
    "<b>$($obs.Count)</b> observations were raised - <b>$priCount</b> priority and <b>$impCount</b> improvement items - to direct remediation and rationalisation."

$auditTxt = if(-not $auditAssessed){'Unknown'}elseif($auditOn){'Enabled'}else{'Disabled'}
$kpiHtml = (New-Kpi "$lblTotal" 'Sensitivity labels' "$lblEnc apply encryption" $Palette.Accent) +
           (New-Kpi "$dlpTotal" 'DLP policies' "$dlpEnf enforce / $dlpTest test" $Palette.Accent) +
           (New-Kpi "$retTotal" 'Retention labels' "$records record-type" $Palette.Accent) +
           (New-Kpi "$sitCustom" 'Custom SITs' 'review required' $Palette.Improvement) +
           (New-Kpi "$($obs.Count)" 'Observations' "$priCount priority" ($(if($priCount){$Palette.Priority}else{$Palette.Healthy}))) +
           (New-Kpi $auditTxt 'Audit ingestion' "$($auditRet.Count) retention policies" ($(if(-not $auditAssessed){$Palette.Info}elseif($auditOn){$Palette.Healthy}else{$Palette.Priority})))

$donutDlp = New-Donut -CenterValue "$dlpTotal" -CenterLabel 'DLP policies' -Segments @(
    [pscustomobject]@{Label='Enforce';Value=$dlpEnf;Color=$Palette.Healthy},
    [pscustomobject]@{Label='Test';Value=$dlpTest;Color=$Palette.Improvement},
    [pscustomobject]@{Label='Disabled';Value=$dlpDis;Color=$Palette.Info})
$donutLbl = New-Donut -CenterValue "$lblTotal" -CenterLabel 'labels' -Segments @(
    [pscustomobject]@{Label='Encryption';Value=$lblEnc;Color=$Palette.Accent},
    [pscustomobject]@{Label='No encryption';Value=($lblTotal-$lblEnc);Color=$Palette.Info})
$areaBars = New-Bars -Items @(
    [pscustomobject]@{Label='Sensitivity labels';Value=$lblTotal},
    [pscustomobject]@{Label='Label policies';Value=$labelPol.Count},
    [pscustomobject]@{Label='Auto-label policies';Value=$autoPol.Count},
    [pscustomobject]@{Label='Custom SITs';Value=$sitCustom},
    [pscustomobject]@{Label='DLP policies';Value=$dlpTotal},
    [pscustomobject]@{Label='DLP rules';Value=$dlpRules.Count},
    [pscustomobject]@{Label='Retention labels';Value=$retTotal},
    [pscustomobject]@{Label='Retention policies';Value=$retPol.Count})
$chartHtml = (New-ChartCard 'DLP enforcement posture' $donutDlp) +
             (New-ChartCard 'Label encryption coverage' $donutLbl) +
             (New-ChartCard 'Control inventory by type' $areaBars)

$detailHtml =
    "<details open><summary>Sensitivity labels ($lblTotal)</summary>$(New-Table $labels @('DisplayName','Priority','ContentType','ParentLabel','EncryptionEnabled','ContentMarking','Disabled'))</details>" +
    "<details><summary>Label &amp; auto-label policies ($($labelPol.Count + $autoPol.Count))</summary>$(New-Table $labelPol @('Name','Mode','Enabled','Labels','Workload'))$(New-Table $autoPol @('Name','Mode','Enabled','ApplySensitivityLabel','Workload'))</details>" +
    "<details><summary>Custom sensitive information types ($sitCustom)</summary>$(New-Table (@($sits | Where-Object { Test-True $_.IsCustom })) @('Name','Type','Publisher'))</details>" +
    "<details open><summary>DLP policies ($dlpTotal)</summary>$(New-Table $dlp @('Name','Mode','Enabled','Workload','Exchange','SharePoint','OneDrive','Teams','Endpoint'))</details>" +
    "<details><summary>DLP rules ($($dlpRules.Count))</summary>$(New-Table $dlpRules @('Name','Policy','Disabled','BlockAccess','GenerateAlert','HasUserOverride','ReportSeverityLevel'))</details>" +
    "<details open><summary>Retention labels ($retTotal)</summary>$(New-Table $retLab @('Name','RetentionAction','RetentionDuration','IsRecordLabel','Regulatory','FilePlan'))</details>" +
    "<details><summary>Retention policies ($($retPol.Count))</summary>$(New-Table $retPol @('Name','Mode','Enabled','Workload','ScopeType'))</details>" +
    "<details><summary>Audit configuration</summary>$(New-Table $auditIng @('UnifiedAuditLogIngestionEnabled','AdminAuditLogEnabled'))$(New-Table $auditRet @('Name','Priority','RecordTypes','RetentionDuration'))</details>" +
    "<details><summary>Discovery manifest (every export, status &amp; count)</summary>$(New-Table $manifest @('Area','Artifact','Cmdlet','Status','Count'))</details>"

if(-not $OutputPath){ $OutputPath = Join-Path $Path 'Purview-Discovery-Baseline-Report.html' }

# Executive headline = top 3 most severe observations
$headline = ($obs | Sort-Object @{e={$SevRank[$_.Severity]}} | Select-Object -First 3 | ForEach-Object {
    "<li><span class='badge' style='background:$($Palette[$_.Severity])'>$($SevLabel[$_.Severity])</span> $(Enc $_.Title)</li>" }) -join ''

# Logo (optional, embedded)
$logoImg=''
if($LogoPath -and (Test-Path $LogoPath)){
    $b=[IO.File]::ReadAllBytes($LogoPath); $ext=([IO.Path]::GetExtension($LogoPath)).TrimStart('.')
    if($ext -eq 'svg'){$ext='svg+xml'}
    $logoImg="<img class='logo' alt='logo' src='data:image/$ext;base64,$([Convert]::ToBase64String($b))'>"
}
$tenantHtml = if($TenantLabel){ "<div class='hb-tenant'>$(Enc $TenantLabel)</div>" } else {'' }
$genDate = (Get-Date).ToString('dd MMMM yyyy')

# ----------------------------------------------------------------------------
# Assemble document
# ----------------------------------------------------------------------------
$css = @'
:root{--brand:#0b2e4f;--brand2:#12477a;--accent:#0f6cbd;--ink:#1b1f24;--muted:#5b6776;--line:#e4e8ec;--bg:#f4f6f8;--card:#fff}
*{box-sizing:border-box}
body{margin:0;font-family:"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:var(--ink);background:var(--bg);line-height:1.5}
.wrap{max-width:1120px;margin:0 auto;padding:0 24px}
.hb{background:linear-gradient(120deg,var(--brand),var(--brand2));color:#fff;padding:34px 0 28px}
.hb-row{display:flex;justify-content:space-between;align-items:flex-start;gap:24px}
.hb h1{margin:0 0 4px;font-size:25px;font-weight:600}
.hb .sub{font-size:15px;opacity:.92}
.hb .meta{font-size:12.5px;opacity:.85;margin-top:14px}
.hb-tenant{font-size:12.5px;opacity:.85;margin-top:2px}
.chip{display:inline-block;background:rgba(255,255,255,.18);border:1px solid rgba(255,255,255,.35);padding:2px 10px;border-radius:12px;font-size:11px;letter-spacing:.5px;text-transform:uppercase;font-weight:600}
.logo{max-width:200px;max-height:120px;background:#fff;padding:6px;border-radius:6px}
nav.toc{position:sticky;top:0;z-index:5;background:#fff;border-bottom:1px solid var(--line);box-shadow:0 1px 3px rgba(0,0,0,.04)}
nav.toc .wrap{display:flex;gap:22px;padding:11px 24px;font-size:13px}
nav.toc a{color:var(--brand2);text-decoration:none;font-weight:600}
nav.toc a:hover{text-decoration:underline}
.btn{margin-left:auto;background:var(--accent);color:#fff;border:0;padding:6px 14px;border-radius:5px;font-size:12.5px;cursor:pointer}
section{padding:26px 0;border-bottom:1px solid var(--line)}
section h2{font-size:18px;margin:0 0 4px;color:var(--brand)}
section .lead{color:var(--muted);font-size:13.5px;margin:0 0 16px}
.narr{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:6px;padding:16px 18px;font-size:14.5px}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:14px;margin:18px 0}
.kpi{background:var(--card);border:1px solid var(--line);border-top:3px solid var(--accent);border-radius:8px;padding:14px 16px}
.kpi-v{font-size:27px;font-weight:700;color:var(--brand)}
.kpi-l{font-size:13px;font-weight:600;margin-top:2px}
.kpi-s{font-size:11.5px;color:var(--muted);margin-top:2px}
.callout{background:#fff;border:1px solid var(--line);border-radius:8px;padding:14px 18px;margin-top:6px}
.callout h3{margin:0 0 8px;font-size:14px;color:var(--brand)}
.callout ul{margin:0;padding-left:4px;list-style:none}
.callout li{margin:7px 0;font-size:13.5px}
.charts{display:flex;flex-wrap:wrap;gap:16px}
.chartcard{flex:1 1 300px;background:var(--card);border:1px solid var(--line);border-radius:8px;padding:14px 16px}
.chartcard h4{margin:0 0 10px;font-size:13px;color:var(--muted);text-transform:uppercase;letter-spacing:.4px}
.donutwrap{display:flex;align-items:center;gap:16px;flex-wrap:wrap}
.donut-num{font-size:26px;font-weight:700;fill:var(--brand)}
.donut-lbl{font-size:11px;fill:var(--muted)}
.legend{display:flex;flex-direction:column;gap:6px;font-size:13px}
.leg{white-space:nowrap}.dot{display:inline-block;width:11px;height:11px;border-radius:50%;margin-right:7px;vertical-align:middle}
.barlbl{font-size:12px;fill:var(--ink)}.barval{font-size:12px;fill:var(--muted);font-weight:600}
.obs{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--muted);border-radius:6px;padding:12px 16px;margin:10px 0}
.obs-head{display:flex;align-items:center;gap:10px;margin-bottom:3px}
.obs-area{font-size:11.5px;color:var(--muted);text-transform:uppercase;letter-spacing:.4px}
.obs-title{font-weight:600;font-size:14px}
.obs-detail{font-size:13.5px;color:#33414f;margin-top:2px}
.obs-rec{font-size:13px;margin-top:7px;background:#f6f9fc;border-radius:5px;padding:7px 10px}
.badge{display:inline-block;color:#fff;font-size:10.5px;font-weight:700;padding:2px 9px;border-radius:10px;text-transform:uppercase;letter-spacing:.3px}
details{background:var(--card);border:1px solid var(--line);border-radius:7px;margin:10px 0;overflow:hidden}
summary{cursor:pointer;padding:11px 16px;font-weight:600;font-size:14px;background:#f7f9fb;list-style:none}
summary::-webkit-details-marker{display:none}
summary:before{content:"\25B8";margin-right:9px;color:var(--accent)}
details[open] summary:before{content:"\25BE"}
.tablewrap{overflow-x:auto;padding:0 4px 8px}
table{border-collapse:collapse;width:100%;font-size:12px;margin:8px 0}
th,td{border:1px solid var(--line);padding:6px 9px;text-align:left;vertical-align:top}
th{background:#eef2f6;color:var(--brand);font-weight:600;position:sticky;top:0}
tbody tr:nth-child(even){background:#fafbfc}
.muted{color:var(--muted);font-size:12.5px;padding:8px 4px}
footer{padding:22px 0;color:var(--muted);font-size:12px}
footer .cls{font-weight:700;text-transform:uppercase;letter-spacing:.5px}
@media print{
  nav.toc,.btn{display:none!important}
  body{background:#fff}
  section{border-bottom:1px solid #ccc;page-break-inside:avoid}
  .chartcard,.kpi,.obs,details,.narr,.callout{page-break-inside:avoid}
  *{-webkit-print-color-adjust:exact;print-color-adjust:exact}
}
'@

$html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$(Enc $OrganizationName) - Purview $subtitle</title><style>$css</style></head><body>
<header class="hb"><div class="wrap hb-row"><div>
  <div class="chip">$(Enc $Classification)</div>
  <h1>$(Enc $ReportTitle)</h1>
  <div class="sub">$(Enc $subtitle)</div>
  $tenantHtml
  <div class="meta">Prepared for <b>$(Enc $OrganizationName)</b> &nbsp;|&nbsp; Prepared by $(Enc $PreparedBy) &nbsp;|&nbsp; $genDate</div>
</div><div>$logoImg</div></div></header>

<nav class="toc"><div class="wrap">
  <a href="#summary">Executive Summary</a>
  <a href="#posture">Posture Overview</a>
  <a href="#observations">Key Observations</a>
  <a href="#detail">Detailed Findings</a>
  <a href="#method">Methodology</a>
  <button class="btn" onclick="window.print()">Print / Save PDF</button>
</div></nav>

<div class="wrap">
  <section id="summary"><h2>Executive Summary</h2>
    <p class="lead">A plain-language overview for business and executive stakeholders.</p>
    <div class="narr">$narrative</div>
    <div class="kpis">$kpiHtml</div>
    <div class="callout"><h3>Headline items</h3><ul>$headline</ul></div>
  </section>

  <section id="posture"><h2>Posture Overview</h2>
    <p class="lead">Visual breakdown of the discovered configuration.</p>
    <div class="charts">$chartHtml</div>
  </section>

  <section id="observations"><h2>Key Observations &amp; Recommendations</h2>
    <p class="lead">Prioritised findings with recommended actions for remediation and rationalisation.</p>
    $(New-ObsHtml $obs)
  </section>

  <section id="detail"><h2>Detailed Findings</h2>
    <p class="lead">Technical drill-down. Expand each area; full data is available in the CSV/JSON exports.</p>
    $detailHtml
  </section>

  <section id="method"><h2>Methodology &amp; Scope</h2>
    <p class="lead">How this report was produced and what it does and does not cover.</p>
    <div class="narr" style="border-left-color:var(--muted)">
      This report was generated from a <b>read-only</b> discovery export of the tenant's Microsoft Purview
      configuration (Information Protection, Classification, Data Loss Prevention, Data Lifecycle and Records, and Audit
      configuration), collected via Security &amp; Compliance and Exchange Online PowerShell. It reflects configuration
      observed at the time of discovery and is provided to support assessment and rationalisation.
      It is <b>not</b> a compliance attestation. Items that cannot be exported programmatically - custom trainable
      classifiers, disposition-review state, Compliance Manager evidence, and Activity Explorer trends - are captured
      manually and are out of scope of the automated sections above.
    </div>
  </section>

  <footer>
    <div class="cls">$(Enc $Classification)</div>
    Prepared by $(Enc $PreparedBy) for $(Enc $OrganizationName). Generated $genDate.
    This document may contain configuration details about the client environment and should be handled per its classification.
  </footer>
</div></body></html>
"@

$html | Out-File -FilePath $OutputPath -Encoding utf8
Write-Host "Report written: $OutputPath" -ForegroundColor Cyan
Write-Host ("Observations: {0} (Priority {1}, Improvement {2})" -f $obs.Count,
    @($obs | Where-Object Severity -eq 'Priority').Count, @($obs | Where-Object Severity -eq 'Improvement').Count) -ForegroundColor Gray
