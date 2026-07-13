#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a client-ready, self-contained HTML inventory report from the Purview
    discovery toolkit output. Reads a PurviewSnapshot-* run folder and renders a
    read-only inventory of the tenant's information-protection configuration.

    The report is fully offline (inline CSS + inline SVG charts + inline JS, no CDN),
    print-to-PDF friendly. It is pure discovery: neutral counts and distributions of
    what exists, plus the enumerated inventory tables. It makes no assessment.

.EXAMPLE
    .\New-PurviewReport.ps1 `
        -Path C:\PurviewDiscovery\PurviewSnapshot-20260628-101500 `
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

# Neutral palette (the report grades nothing): one brass accent + one neutral grey.
$Palette = @{ Accent='#9a6a1e'; Info='#8a94a2' }

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
    param([object[]]$Items,[int]$Width=560,[int]$BarH=22,[int]$Gap=12,[string]$Color='#9a6a1e')
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
function New-Kpi([string]$Value,[string]$Label,[string]$Sub,[string]$Accent='#9a6a1e'){
    "<div class='kpi' style='border-top-color:$Accent'><div class='kpi-v'>$(Enc $Value)</div><div class='kpi-l'>$(Enc $Label)</div><div class='kpi-s'>$(Enc $Sub)</div></div>"
}
# Collapsible inventory card (PPA sumhead pattern): collapsed-by-default, glanceable
# count on the right. $Count $null/'' -> no glance. Slug matches the section-anchor style.
function New-DetailCard([string]$Title,$Count,[string]$Body){
    $slug = (($Title -replace '&amp;','and') -replace '[^A-Za-z0-9]+','-').Trim('-').ToLower()
    $glance = if($null -ne $Count -and "$Count" -ne ''){ "<span class=""sum-glance count"">$(Enc "$Count")</span>" } else { '' }
@"
  <div class="card mt-3" id="det-$slug">
    <div class="card-header sumhead" data-toggle="collapse" data-target="#body-det-$slug" role="button" tabindex="0" aria-expanded="false" aria-controls="body-det-$slug"><i class="fas fa-chevron-right chev"></i><strong>$Title</strong>$glance</div>
    <div class="collapse" id="body-det-$slug"><div class="card-body">$Body</div></div>
  </div>
"@
}

# ----------------------------------------------------------------------------
# Read the discovery export (raw inventory CSVs)
# ----------------------------------------------------------------------------
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

# ---- Neutral inventory counts (composition of what exists; no scoring) ----
$lblTotal  = $labels.Count
$lblEnc    = @($labels | Where-Object { Test-True $_.EncryptionEnabled }).Count
$lblParent = @($labels | Where-Object { [string]::IsNullOrWhiteSpace($_.ParentLabel) }).Count
$sitCustom = @($sits   | Where-Object { Test-True $_.IsCustom }).Count
$dlpTotal  = $dlp.Count
$retTotal  = $retLab.Count
$records   = @($retLab | Where-Object { Test-True $_.IsRecordLabel }).Count

# ---- Environment Summary: neutral count tiles ----
$kpiHtml = (New-Kpi "$lblTotal" 'Sensitivity labels' "$lblParent top-level, $($lblTotal-$lblParent) sublabels" $Palette.Accent) +
           (New-Kpi "$dlpTotal" 'DLP policies' "$($dlpRules.Count) rules" $Palette.Accent) +
           (New-Kpi "$retTotal" 'Retention labels' "$records record-type" $Palette.Accent) +
           (New-Kpi "$sitCustom" 'Custom SITs' 'tenant-defined' $Palette.Accent)

# ---- Distribution: neutral distributions of what exists ----
$donutLbl = New-Donut -CenterValue "$lblTotal" -CenterLabel 'labels' -Segments @(
    [pscustomobject]@{Label='With encryption';Value=$lblEnc;Color=$Palette.Accent},
    [pscustomobject]@{Label='Without encryption';Value=($lblTotal-$lblEnc);Color=$Palette.Info})
$areaBars = New-Bars -Items @(
    [pscustomobject]@{Label='Sensitivity labels';Value=$lblTotal},
    [pscustomobject]@{Label='Label policies';Value=$labelPol.Count},
    [pscustomobject]@{Label='Auto-label policies';Value=$autoPol.Count},
    [pscustomobject]@{Label='Custom SITs';Value=$sitCustom},
    [pscustomobject]@{Label='DLP policies';Value=$dlpTotal},
    [pscustomobject]@{Label='DLP rules';Value=$dlpRules.Count},
    [pscustomobject]@{Label='Retention labels';Value=$retTotal},
    [pscustomobject]@{Label='Retention policies';Value=$retPol.Count})
$chartHtml = (New-ChartCard 'Sensitivity labels by encryption' $donutLbl) +
             (New-ChartCard 'Inventory by type' $areaBars)

# ---- Inventory: the enumerated tables (collapsed-by-default cards) ----
$detailHtml = @(
    (New-DetailCard 'Sensitivity labels' $lblTotal (New-Table $labels @('DisplayName','Priority','ContentType','ParentLabel','EncryptionEnabled','ContentMarking','Disabled'))),
    (New-DetailCard 'Label &amp; auto-label policies' ($labelPol.Count + $autoPol.Count) ((New-Table $labelPol @('Name','Mode','Enabled','Labels','Workload')) + (New-Table $autoPol @('Name','Mode','Enabled','ApplySensitivityLabel','Workload')))),
    (New-DetailCard 'Custom sensitive information types' $sitCustom (New-Table (@($sits | Where-Object { Test-True $_.IsCustom })) @('Name','Type','Publisher'))),
    (New-DetailCard 'DLP policies' $dlpTotal (New-Table $dlp @('Name','Mode','Enabled','Workload','Exchange','SharePoint','OneDrive','Teams','Endpoint'))),
    (New-DetailCard 'DLP rules' $dlpRules.Count (New-Table $dlpRules @('Name','Policy','Disabled','BlockAccess','GenerateAlert','HasUserOverride','ReportSeverityLevel'))),
    (New-DetailCard 'Retention labels' $retTotal (New-Table $retLab @('Name','RetentionAction','RetentionDuration','IsRecordLabel','Regulatory','FilePlan'))),
    (New-DetailCard 'Retention policies' $retPol.Count (New-Table $retPol @('Name','Mode','Enabled','Workload','ScopeType'))),
    (New-DetailCard 'Audit configuration' $null ((New-Table $auditIng @('UnifiedAuditLogIngestionEnabled','AdminAuditLogEnabled')) + (New-Table $auditRet @('Name','Priority','RecordTypes','RetentionDuration')))),
    (New-DetailCard 'Discovery manifest (every export, status &amp; count)' $null (New-Table $manifest @('Area','Artifact','Cmdlet','Status','Count')))
) -join "`n"

if(-not $OutputPath){ $OutputPath = Join-Path $Path 'Purview-Discovery-Baseline-Report.html' }

# Logo: embedded image when supplied, else the neutral placeholder from the cover chrome.
$logoBox = '<div class="logo-ph">Client logo</div>'
if($LogoPath -and (Test-Path $LogoPath)){
    $b=[IO.File]::ReadAllBytes($LogoPath); $ext=([IO.Path]::GetExtension($LogoPath)).TrimStart('.')
    if($ext -eq 'svg'){$ext='svg+xml'}
    $logoBox="<img alt='logo' style='max-width:230px;max-height:132px;border-radius:4px' src='data:image/$ext;base64,$([Convert]::ToBase64String($b))'>"
}
$tenantRow = if($TenantLabel){ "<tr><td>Tenant</td><td>:&nbsp; $(Enc $TenantLabel)</td></tr>" } else { '' }
$genDate = (Get-Date).ToString('dd MMMM yyyy')

# ----------------------------------------------------------------------------
# Assemble document. The stylesheet + interactive script are the approved
# PurviewPostureAnalyzer visual system, embedded inline (no CDN).
# ----------------------------------------------------------------------------
$css = @'
  /* =====================================================================
     CAMP report stylesheet - enterprise compliance-brief style (Mockup A v2).
     Editorial: serif display + humanist sans body, warm paper, one brass accent,
     wider responsive shell with capped prose measure. Same markup + hooks as before.
     Layer 1 (compat: grid + FA glyph map + collapse) is preserved so the report
     stays framework-free / offline; layers 2-3 are the tokens + components.
     ===================================================================== */

  /* ---- 1. framework-free compat layer (structural - preserved) ---- */
  *,*::before,*::after{box-sizing:border-box;}
  body{margin:0;font-family:var(--font-sans);line-height:1.5;color:var(--body);}
  img{max-width:100%;height:auto;}
  p{margin:0 0 1rem;}
  .row{display:flex;flex-wrap:wrap;}
  .container-fluid{width:100%;padding-left:12px;padding-right:12px;}
  .navbar{display:flex;flex-wrap:wrap;align-items:center;padding:.5rem 1rem;}
  .col,.col-sm{flex:1 1 0%;min-width:0;}
  .col-auto{flex:0 0 auto;width:auto;}
  .col-sm-10{flex:1 1 auto;min-width:0;}
  .col-sm-2{flex:0 0 auto;margin-left:auto;text-align:right;}
  .col-6{flex:0 0 50%;max-width:50%;padding-left:6px;padding-right:6px;}
  @media (min-width:768px){ .col-md-3{flex:0 0 25%;max-width:25%;} }
  .text-right{text-align:right;} .text-center{text-align:center;}
  .ml-3{margin-left:1rem;} .mt-3{margin-top:1.35rem;} .p-3{padding:1rem;}
  .text-success{color:var(--sev-ok);} .text-danger{color:#b23b2e;}
  .text-muted{color:var(--faint);} .text-secondary{color:var(--sev-verify);}
  .bg-light{background:var(--paper);}
  table{border-collapse:collapse;}
  .table{width:100%;margin-bottom:1rem;}
  .table td,.table th{padding:.5rem .55rem;text-align:left;}
  .table-sm td,.table-sm th{padding:.34rem .45rem;}
  .table-borderless td,.table-borderless th{border:0;}
  .fas,.far,.fa{font-style:normal;display:inline-block;line-height:1;font-family:inherit;}
  .fa-chevron-right::before{content:"\203A";}
  .fa-external-link-square-alt::before{content:"\2197";}
  .fa-tools::before{content:"\2699";}
  .fa-info-circle::before{content:"\2139";}
  .fa-check-circle::before{content:"\2714";}
  .fa-times-circle::before{content:"\2716";}
  .fa-user-check::before{content:"\25CB";}
  .fa-user-cog::before,.fa-shield-alt::before,.fa-archive::before,.fa-user-secret::before,.fa-search::before,.fa-robot::before,.fa-binoculars::before{content:"\25AA";}
  .collapse{display:none;} .collapse.show{display:block;}

  /* ---- 2. design tokens ---- */
  :root{
    --font-serif:Georgia,'Iowan Old Style','Palatino Linotype',Palatino,'Book Antiqua',Cambria,'Times New Roman',serif;
    --font-sans:system-ui,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;
    --font-mono:ui-monospace,'Cascadia Code','Cascadia Mono',Consolas,'Courier New',monospace;
    --fs-xs:11px; --fs-sm:12.5px; --fs-base:14px; --fs-md:15px; --fs-lg:19px; --fs-xl:24px;
    --ink:#1b2a44; --ink-soft:#2c3c56; --body:#3c4858; --muted:#5c6a7c; --faint:#7c8a9b;
    --paper:#faf7f0; --surface:#ffffff; --surface-1:#f7f3ea; --surface-2:#efe9db; --hover:#faf5e9;
    --hairline:#e8e1d2; --border:#d9d0be;
    --accent:#9a6a1e; --accent-strong:#7c5316; --accent-soft:#f3e9d4;
    --link:#1b527d; --link-strong:#123e60;
    --sev-ok:#1f7a37; --sev-impr:#b4690e; --sev-rec:#0f6a86; --sev-info:#8a94a2; --sev-verify:#56636f;
    --badge-ok-bg:#1f7a37; --badge-ok-fg:#ffffff;
    --badge-impr-bg:#eda93a; --badge-impr-fg:#3a2905;
    --badge-rec-bg:#0f6a86; --badge-rec-fg:#ffffff;
    --badge-info-bg:#6d7889; --badge-info-fg:#ffffff;
    --badge-verify-bg:#39434f; --badge-verify-fg:#ffffff;
    --radius:7px; --radius-sm:4px; --radius-pill:16px;
    --shadow:0 1px 2px rgba(27,42,68,.05),0 8px 26px -18px rgba(27,42,68,.28);
  }

  h2,h5,h6,.card-title,.card-header strong,.card-header a{font-family:var(--font-serif);}
  h2{font-size:var(--fs-xl);font-weight:600;letter-spacing:-.01em;color:var(--ink);margin:0 0 .35rem;line-height:1.15;}
  h5{font-size:1.2rem;font-weight:600;color:var(--ink);margin:0 0 .5rem;}
  h6{font-size:1.02rem;font-weight:600;margin:0 0 .5rem;}
  a{color:var(--link);}
  a:focus-visible,button:focus-visible,input:focus-visible,summary:focus-visible,[tabindex]:focus-visible{
    outline:2px solid var(--accent); outline-offset:2px; border-radius:2px; }

  /* ---- 3. structural chrome ---- */
  .navbar-custom{ background:var(--ink); color:#fff; padding:.7rem 1rem; box-shadow:inset 0 -3px 0 var(--accent); }
  .navbar-custom strong{ font-family:var(--font-serif); font-weight:600; letter-spacing:.01em; font-size:var(--fs-md); }
  .navbar-custom .fa-binoculars::before{ content:"\25C8"; }
  .btn{ display:inline-block;font-weight:600;text-align:center;padding:.4rem .95rem;font-size:var(--fs-sm);line-height:1.4;border:1px solid transparent;border-radius:var(--radius-sm);cursor:pointer;font-family:var(--font-sans); }
  .btn-primary{ color:var(--ink); background:#fff; border-color:rgba(255,255,255,.5); }
  .btn-primary:hover{ background:var(--accent-soft); }

  .app-body{ max-width:1680px; margin:0 auto; padding:1.75rem clamp(16px,3.5vw,52px) 3rem; }
  .card{ position:relative; background:var(--surface); border:1px solid var(--hairline); border-radius:var(--radius); box-shadow:var(--shadow); }
  .card-body{ padding:1.15rem 1.4rem; }
  .card-title{ margin-bottom:.5rem; }
  .card > .card-body > .row > .col > strong:first-of-type{ color:var(--accent-strong); font-family:var(--font-sans); font-weight:700; font-size:var(--fs-sm); text-transform:uppercase; letter-spacing:.06em; }

  /* Card headers: light, serif, ruled - editorial (not a solid blue bar). */
  .card-header{ background:var(--surface); color:var(--ink); padding:.85rem 1.4rem; border-bottom:1px solid var(--hairline); border-radius:var(--radius) var(--radius) 0 0; }
  .card-header strong{ font-size:var(--fs-md); font-weight:600; letter-spacing:.005em; }
  .card-header a{ color:var(--ink); text-decoration:none; }
  .seccard > .card-header{ border-bottom:2px solid var(--ink); }
  .sec-hiddennote{ display:none; font-size:var(--fs-sm); font-weight:400; font-family:var(--font-sans); color:var(--faint); margin-left:10px; }
  .seccard.sec-allhidden .sec-hiddennote{ display:inline; }

  .logo-ph{ width:230px; height:132px; border:1px dashed var(--border); border-radius:var(--radius-sm); color:var(--faint); display:flex; align-items:center; justify-content:center; font-size:var(--fs-sm); font-family:var(--font-sans); background:var(--surface-1); }
  .mock-flag{ background:var(--ink); color:#e9e2d2; font-family:var(--font-sans); font-size:var(--fs-sm); letter-spacing:.02em; text-align:center; padding:7px; }
  .redact-flag{ background:#6a1f1f; color:#ffe1e1; font-family:var(--font-sans); font-size:var(--fs-sm); text-align:center; padding:7px; }
  .app-footer{ background:var(--ink); color:#d7dae1; padding:16px 0; font-family:var(--font-sans); font-size:var(--fs-sm); margin-top:2rem; }
  .app-footer .container-fluid{ max-width:1680px; margin:0 auto; }
  .app-footer a{ color:#e7d3ac; }

  /* ---- badges (solid, calm pills) ---- */
  .badge{ display:inline-block;padding:.32em .6em;font-size:var(--fs-xs);font-weight:700;line-height:1;text-align:center;white-space:nowrap;border-radius:var(--radius-pill);vertical-align:baseline;letter-spacing:.02em;font-family:var(--font-sans); }
  .badge-success{ background:var(--badge-ok-bg); color:var(--badge-ok-fg); }
  .badge-warning{ background:var(--badge-impr-bg); color:var(--badge-impr-fg); }
  .badge-info{ background:var(--badge-rec-bg); color:var(--badge-rec-fg); }
  .badge-secondary{ background:var(--badge-info-bg); color:var(--badge-info-fg); }
  .badge-dark{ background:var(--badge-verify-bg); color:var(--badge-verify-fg); }
  .seccard > .card-header .badge{ margin-left:5px; }

  /* ---- severity dots ---- */
  .gdot{ width:9px; height:9px; border-radius:50%; display:inline-block; flex:none; }
  .gdot.ok{ background:var(--sev-ok); } .gdot.impr{ background:var(--sev-impr); } .gdot.rec{ background:var(--sev-rec); }
  .gdot.info{ background:var(--sev-info); } .gdot.verify{ background:var(--sev-verify); }

  /* ---- collapsible summary headers (posture / coverage) ---- */
  .card-header.sumhead{ display:flex; align-items:center; cursor:pointer; background:var(--surface-1); border-bottom:1px solid var(--hairline); }
  .card-header.sumhead:hover{ background:var(--hover); }
  .sumhead .chev{ color:var(--accent); margin-right:9px; width:12px; font-size:1.05rem; }
  .sumhead[aria-expanded="true"] .chev{ transform:rotate(90deg); }
  .sum-glance{ margin-left:auto; display:inline-flex; align-items:center; flex-wrap:wrap; gap:14px; font-size:var(--fs-base); font-weight:600; color:var(--ink-soft); font-family:var(--font-sans); }
  .sum-glance .sg-item{ display:inline-flex; align-items:center; gap:6px; }
  .sum-glance .gdot{ box-shadow:0 0 0 1.5px var(--surface),0 0 0 2.5px rgba(27,42,68,.12); }

  /* ---- EXECUTIVE HERO BAND (injected by A.js; degrades to glance dots) ---- */
  .execband{ margin-top:1.35rem; background:var(--surface); border:1px solid var(--hairline); border-top:3px solid var(--accent); border-radius:var(--radius); box-shadow:var(--shadow); padding:1.2rem 1.4rem 1.35rem; }
  .eb-head{ display:flex; align-items:baseline; justify-content:space-between; flex-wrap:wrap; gap:8px; margin-bottom:.85rem; }
  .eb-kicker{ font-family:var(--font-sans); font-size:var(--fs-xs); font-weight:700; text-transform:uppercase; letter-spacing:.12em; color:var(--accent-strong); }
  .eb-total{ font-family:var(--font-serif); font-size:var(--fs-lg); font-weight:600; color:var(--ink); }
  .eb-total span{ color:var(--faint); font-size:var(--fs-sm); font-family:var(--font-sans); font-weight:600; margin-left:4px; }
  .eb-bar{ display:flex; height:20px; border-radius:5px; overflow:hidden; border:1px solid var(--hairline); background:var(--surface-2); }
  .eb-seg{ min-width:0; }
  .eb-seg.ok{ background:var(--sev-ok); } .eb-seg.impr{ background:var(--sev-impr); } .eb-seg.rec{ background:var(--sev-rec); }
  .eb-seg.info{ background:var(--sev-info); } .eb-seg.verify{ background:var(--sev-verify); }
  .eb-legend{ display:flex; flex-wrap:wrap; gap:8px 20px; margin-top:.85rem; }
  .eb-li{ display:inline-flex; align-items:baseline; gap:7px; font-family:var(--font-sans); font-size:var(--fs-sm); color:var(--muted); }
  .eb-li b{ font-size:var(--fs-md); color:var(--ink); font-weight:700; }
  .eb-li .gdot{ align-self:center; }

  /* ---- posture summary body ---- */
  .es-meta{ color:var(--muted); font-size:var(--fs-base); margin-bottom:.9rem; font-family:var(--font-sans); }
  .es-tiles{ display:flex; flex-wrap:wrap; gap:12px; margin-bottom:1rem; }
  .es-tile{ border:1px solid var(--hairline); border-radius:var(--radius); padding:.7rem 1.15rem; min-width:120px; text-align:center; background:var(--surface-1); }
  .es-num{ font-size:var(--fs-lg); font-weight:800; padding:5px 13px; display:inline-block; border-radius:var(--radius-pill); }
  .es-lbl{ font-size:var(--fs-xs); color:var(--muted); font-weight:700; text-transform:uppercase; letter-spacing:.04em; margin-top:8px; font-family:var(--font-sans); }
  .es-top{ font-family:var(--font-serif); font-size:1.05rem; font-weight:600; color:var(--ink); margin:0 0 .5rem; padding-top:.4rem; border-top:1px solid var(--hairline); }
  .es-list a.es-item{ display:flex; align-items:baseline; gap:9px; padding:5px 0; color:inherit; text-decoration:none; font-size:var(--fs-base); border-bottom:1px solid var(--surface-1); }
  .es-list a.es-item:last-child{ border-bottom:0; }
  .es-list a.es-item:hover{ color:var(--accent-strong); }
  .es-list a.es-item strong{ font-family:var(--font-mono); font-size:var(--fs-sm); color:var(--ink); font-weight:700; }
  .es-list .gdot{ align-self:center; }
  .es-sec{ color:var(--faint); font-size:var(--fs-sm); margin-left:auto; padding-left:12px; white-space:nowrap; font-family:var(--font-sans); }
  .es-more{ color:var(--muted); font-size:var(--fs-sm); padding:6px 0 0 18px; font-style:italic; }
  .es-none{ color:var(--muted); font-size:var(--fs-base); margin:0; }

  /* ---- filter bar (slim, quiet) ---- */
  .filterbar{ position:sticky; top:8px; z-index:100; background:rgba(255,255,255,.94); backdrop-filter:saturate(1.1) blur(3px); border:1px solid var(--hairline); border-radius:var(--radius);
              padding:.5rem .8rem; margin-top:1.35rem; display:flex; flex-wrap:wrap; align-items:center; gap:8px; box-shadow:var(--shadow); }
  .fb-label{ font-size:var(--fs-xs); font-weight:700; color:var(--muted); text-transform:uppercase; letter-spacing:.08em; font-family:var(--font-sans); }
  .fb-chip{ border:1px solid var(--border); background:var(--surface); border-radius:var(--radius-pill); font-size:var(--fs-sm); font-weight:600; color:var(--muted); padding:3px 12px; cursor:pointer; display:inline-flex; align-items:center; gap:7px; font-family:var(--font-sans); }
  .fb-chip:hover{ border-color:var(--accent); }
  .fb-chip.active{ background:var(--accent-soft); border-color:var(--accent); color:var(--accent-strong); }
  .fb-chip:not(.active) .gdot{ opacity:.32; }
  .fb-search{ border:1px solid var(--border); border-radius:var(--radius-sm); font-size:var(--fs-base); padding:5px 11px; min-width:210px; flex:1 1 210px; max-width:330px; font-family:var(--font-sans); }
  .fb-search:focus{ border-color:var(--accent); outline:none; }
  .fb-reset{ border:1px solid var(--border); background:var(--surface); border-radius:var(--radius-sm); font-size:var(--fs-sm); font-weight:600; color:var(--muted); padding:5px 13px; cursor:pointer; font-family:var(--font-sans); }
  .fb-reset:hover{ border-color:var(--accent); color:var(--accent-strong); }
  .fb-status{ font-size:var(--fs-sm); color:var(--faint); margin-left:auto; font-family:var(--font-sans); }
  .finding.fb-hidden{ display:none; }
  .seccard.sec-allhidden .card-body{ display:none; }

  /* ---- environment at a glance ---- */
  .glance .cell{ display:block; border:1px solid var(--hairline); border-radius:var(--radius); padding:.7rem .85rem; height:100%; text-decoration:none; color:inherit; background:var(--surface); transition:border-color .12s ease, box-shadow .12s ease; }
  .glance .cell:hover{ border-color:var(--accent); box-shadow:var(--shadow); }
  .glance .nm{ font-size:var(--fs-sm); color:var(--muted); font-weight:600; display:flex; align-items:center; gap:8px; margin-bottom:5px; font-family:var(--font-sans); }
  .glance .mx{ font-family:var(--font-serif); font-size:var(--fs-xl); font-weight:600; letter-spacing:-.01em; line-height:1.1; color:var(--ink); }
  .glance .sub{ font-size:var(--fs-xs); color:var(--faint); margin-top:2px; font-family:var(--font-sans); }

  /* ---- solutions summary ---- */
  table.summary td{ vertical-align:middle; padding:.42rem .5rem; }
  .sscount{ width:32px; padding:.32rem 0; text-align:center; display:inline-block; margin-left:3px; font-size:var(--fs-sm); border-radius:var(--radius-sm); }
  .ssparent{ background:var(--surface-1); }
  .ssparent td{ font-family:var(--font-serif); font-weight:600; color:var(--ink); letter-spacing:.005em; }
  .sschild a{ color:var(--link); text-decoration:none; }
  .sschild a:hover{ color:var(--link-strong); text-decoration:underline; }

  /* ---- findings ---- */
  .finding{ border-bottom:1px solid var(--hairline); }
  .finding:last-of-type{ border-bottom:0; }
  .finding-head{ cursor:pointer; padding:.75rem .5rem; margin:0; align-items:center; border-radius:var(--radius-sm); }
  .finding-head:hover{ background:var(--hover); }
  .finding-head h6{ margin:0; display:inline; font-weight:600; font-family:var(--font-serif); color:var(--ink); }
  .chev{ color:var(--accent); transition:transform .15s ease; margin-right:11px; width:12px; font-size:1.05rem; }
  .finding-head[aria-expanded="true"] .chev{ transform:rotate(90deg); }
  .finding:target{ background:var(--accent-soft); box-shadow:inset 3px 0 0 var(--accent); }

  .bd-callout{ padding:1rem 1.2rem; margin:.35rem 0 1rem; border:1px solid var(--hairline); border-left-width:4px; border-radius:var(--radius-sm); background:var(--surface-1); }
  .bd-callout-info{ border-left-color:var(--sev-rec); }
  .bd-callout-warning{ border-left-color:var(--sev-impr); }
  .bd-callout-success{ border-left-color:var(--sev-ok); }
  .bd-callout-secondary{ border-left-color:var(--sev-info); }
  .bd-callout-dark{ border-left-color:var(--sev-verify); }
  .whyline{ color:var(--body); margin:.1rem 0 .35rem; font-size:var(--fs-base); }

  table.detail{ font-size:var(--fs-base); margin-top:.7rem; margin-bottom:.25rem; background:var(--surface); border:1px solid var(--hairline); border-radius:var(--radius-sm); overflow:hidden; }
  table.detail thead th{ background:var(--surface-2); border-bottom:2px solid var(--border); font-size:var(--fs-xs); text-transform:uppercase; letter-spacing:.05em; color:var(--muted); padding:.45rem .7rem; font-family:var(--font-sans); }
  table.detail td{ padding:.45rem .7rem; vertical-align:top; border-top:1px solid var(--hairline); }
  table.detail tbody tr:first-child td{ border-top:0; }
  .rowstat{ white-space:nowrap; font-weight:600; font-family:var(--font-sans); font-size:var(--fs-sm); }
  .remarks{ background:var(--surface-2); border:0; color:var(--body); font-size:var(--fs-sm); }
  .remarks i{ color:var(--faint); margin-right:6px; }

  .learnmore{ margin-top:.65rem; padding-top:.5rem; border-top:1px dashed var(--hairline); }
  .learnmore a{ text-decoration:none; display:block; padding:3px 0; color:var(--link); font-size:var(--fs-base); }
  .learnmore a:hover{ color:var(--link-strong); }
  .lm-tag{ font-size:var(--fs-xs); color:var(--faint); text-transform:uppercase; margin-left:7px; letter-spacing:.04em; }
  .anchor-link{ margin-left:9px; color:var(--faint); text-decoration:none; font-weight:700; opacity:0; transition:opacity .12s ease; }
  .finding-head:hover .anchor-link{ opacity:1; }
  .anchor-link:hover{ color:var(--accent); }
  .anchor-link.copied{ color:var(--sev-ok); opacity:1; }
  .backlink a{ color:var(--link); text-decoration:none; font-size:var(--fs-sm); }
  .backlink a:hover{ text-decoration:underline; }

  /* ---- remediation ---- */
  details.remed{ margin-top:.65rem; border-top:1px dashed var(--hairline); padding-top:.5rem; }
  details.remed summary{ cursor:pointer; font-size:var(--fs-base); font-weight:600; color:var(--accent-strong); list-style-position:inside; font-family:var(--font-sans); }
  details.remed summary i{ margin-right:5px; color:var(--accent); }
  .remed-draft-tag{ font-size:var(--fs-xs); color:var(--faint); text-transform:uppercase; letter-spacing:.05em; border:1px solid var(--border); border-radius:var(--radius-sm); padding:1px 6px; margin-left:7px; vertical-align:middle; }
  .remed-body{ padding:.5rem .1rem .1rem; }
  .remed-portal{ font-size:var(--fs-base); margin-bottom:.5rem; color:var(--body); }
  .remed-learn{ font-size:var(--fs-base); text-decoration:none; display:inline-block; padding:2px 0; color:var(--link); }
  .remed-note{ font-size:var(--fs-sm); color:var(--faint); margin:.45rem 0 0; }

  .profile-note{ color:var(--muted); font-size:var(--fs-sm); margin:1.35rem 2px 0; padding:.55rem .8rem; background:var(--surface-2); border:1px solid var(--hairline); border-radius:var(--radius); font-family:var(--font-sans); }

  /* ---- coverage matrix (None hatching / Unknown dotting preserved) ---- */
  table.covm-grid{ border-collapse:collapse; width:100%; font-size:var(--fs-base); margin-top:.4rem; }
  table.covm-grid thead th{ background:var(--ink); color:#fff; border:1px solid var(--ink); font-size:var(--fs-xs); text-transform:uppercase; letter-spacing:.05em; padding:.5rem .6rem; text-align:center; font-family:var(--font-sans); }
  table.covm-grid th.covm-row{ background:var(--surface-1); border:1px solid var(--border); text-align:left; padding:.5rem .6rem; font-size:var(--fs-sm); color:var(--ink); font-weight:600; width:16%; }
  td.covm-cell{ border:1px solid var(--border); padding:.5rem .6rem; text-align:center; vertical-align:middle; }
  .covm-cell a.covm-link{ text-decoration:none; color:inherit; }
  .covm-glyph{ font-weight:800; margin-right:5px; }
  .covm-text{ font-weight:700; font-size:var(--fs-sm); font-family:var(--font-sans); }
  .covm-covered{ background:#e7f4ea; color:#186a2f; }
  .covm-partial{ background:#fbeecd; color:#7a5410; }
  .covm-testonly{ background:#e8eef6; color:#164e6e; }
  .covm-none{ background:repeating-linear-gradient(45deg,#f7dcd8,#f7dcd8 6px,#ffffff 6px,#ffffff 12px); color:#9a2a22; }
  .covm-unknown{ background:radial-gradient(#cfd6dd 1.3px,#f6f3ec 1.3px); background-size:8px 8px; color:var(--body); }
  .covm-na{ background:var(--surface-1); color:var(--faint); }
  .covm-held{ background:#ffffff; color:var(--faint); }
  .covm-held sup a{ text-decoration:none; color:var(--link); }
  .covm-reason{ display:inline-block; border:1px solid var(--border); border-radius:var(--radius-sm); font-size:10px; padding:0 6px; margin-top:3px; color:var(--muted); background:var(--surface); }
  .covm-prov{ color:#a8781f; margin-left:4px; cursor:help; font-weight:700; }
  .covm-banner{ background:#fbf1d6; border:1px solid var(--sev-impr); border-radius:var(--radius); padding:.5rem .8rem; margin-bottom:.6rem; font-size:var(--fs-base); }
  .covm-strip{ font-size:var(--fs-base); margin:.7rem 0 0; color:var(--ink-soft); }
  .covm-strip a{ color:var(--link); text-decoration:none; }
  .covm-foot{ color:var(--faint); font-size:var(--fs-sm); margin:.5rem 0 0; }

  @media (prefers-reduced-motion:reduce){ .chev{ transition:none; } .glance .cell{ transition:none; } }

  /* ---- print / PDF (asserted substrings kept verbatim; brief adds around them) ---- */
  /* ---- v2 additions: wider shell alignment, readable prose measure, per-section solution icons ---- */
  .navbar-custom .container-fluid{ max-width:1680px; margin:0 auto; }
  .card-body .col > p{ max-width:82ch; }
  .bd-callout p{ max-width:82ch; }
  .es-list{ display:grid; grid-template-columns:1fr; gap:0 34px; }
  @media (min-width:920px){ .es-list{ grid-template-columns:1fr 1fr; } }
  .es-list .es-more{ grid-column:1 / -1; }
  .seccard > .card-header .col-sm > a{ font-size:1.08rem; font-weight:600; letter-spacing:.005em; }
  @media print{
    *{ print-color-adjust:exact; -webkit-print-color-adjust:exact; }
    body{ background:#fff; font-size:11.5pt; }
    .app-body{ max-width:none; margin:0; padding:0; }
    .navbar-custom .container-fluid, .app-footer .container-fluid{ max-width:none; }
    .filterbar, .anchor-link, .backlink, .navbar-custom .btn, .mock-flag, .chev{ display:none !important; }
    .collapse{ display:block !important; height:auto !important; }
    .card{ box-shadow:none; border:1px solid #d7cfbe; }
    .execband{ break-inside:avoid; page-break-inside:avoid; }
    .postsum{ break-after:page; page-break-after:always; }
    .seccard{ break-before:page; page-break-before:always; }
    .finding, .glance .cell, .bd-callout{ break-inside:avoid; page-break-inside:avoid; }
    .finding-head{ cursor:default; }
    .card-header.sumhead{ cursor:default; }
  }
  /* ===== discovery-report addendum: the discovery report's OWN components,
     restyled onto the PPA token system. Same markup + data; PPA look. ===== */
  :root{ --disc-priority:#a5342a; }
  .app-body section{ padding:1.6rem 0; border-bottom:1px solid var(--hairline); }
  .app-body section:last-of-type{ border-bottom:0; }
  .app-body section > h2{ font-size:var(--fs-xl); margin:0 0 .2rem; }
  .lead{ color:var(--muted); font-size:var(--fs-base); font-family:var(--font-sans); margin:.1rem 0 1.15rem; max-width:82ch; }

  /* in-page table of contents (discovery's own nav, PPA surface idiom) */
  .toc{ position:sticky; top:0; z-index:30; background:rgba(255,255,255,.94); backdrop-filter:saturate(1.1) blur(3px); border-bottom:1px solid var(--hairline); box-shadow:var(--shadow); }
  .toc-inner{ max-width:1680px; margin:0 auto; padding:.6rem clamp(16px,3.5vw,52px); display:flex; flex-wrap:wrap; gap:8px 22px; font-family:var(--font-sans); font-size:var(--fs-sm); }
  .toc a{ color:var(--link); text-decoration:none; font-weight:600; }
  .toc a:hover{ color:var(--link-strong); text-decoration:underline; }

  /* cover chrome */
  .cover .chip{ display:inline-block; background:var(--accent-soft); color:var(--accent-strong); border:1px solid var(--accent); border-radius:var(--radius-pill); padding:2px 12px; font-size:var(--fs-xs); font-weight:700; text-transform:uppercase; letter-spacing:.06em; font-family:var(--font-sans); margin-bottom:.7rem; }
  .cover .sub{ color:var(--muted); font-size:var(--fs-md); font-family:var(--font-sans); margin:.1rem 0 .9rem; }
  .cover table{ margin:0; }
  .cover table td{ padding:.16rem .5rem .16rem 0; font-size:var(--fs-sm); color:var(--body); font-family:var(--font-sans); vertical-align:top; }
  .cover table td:first-child{ color:var(--accent-strong); font-weight:700; text-transform:uppercase; letter-spacing:.05em; white-space:nowrap; }

  /* executive summary narrative (bd-callout idiom) */
  .narr{ background:var(--surface-1); border:1px solid var(--hairline); border-left:4px solid var(--accent); border-radius:var(--radius-sm); padding:1rem 1.2rem; font-size:var(--fs-base); color:var(--body); max-width:none; }
  .narr b{ color:var(--ink); }

  /* KPI metric cells */
  .kpis{ display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:14px; margin:1.15rem 0; }
  .kpi{ background:var(--surface); border:1px solid var(--hairline); border-top:3px solid var(--accent); border-radius:var(--radius); box-shadow:var(--shadow); padding:.9rem 1.1rem; }
  .kpi-v{ font-family:var(--font-serif); font-size:var(--fs-xl); font-weight:600; color:var(--ink); line-height:1.1; }
  .kpi-l{ font-size:var(--fs-sm); font-weight:700; color:var(--muted); text-transform:uppercase; letter-spacing:.04em; margin-top:6px; font-family:var(--font-sans); }
  .kpi-s{ font-size:var(--fs-xs); color:var(--faint); margin-top:3px; font-family:var(--font-sans); }

  /* headline items (es-top / es-list idiom) */
  .callout{ margin-top:1.1rem; }
  .callout h3{ font-family:var(--font-serif); font-size:1.05rem; font-weight:600; color:var(--ink); margin:0 0 .5rem; }
  .callout ul{ list-style:none; margin:0; padding:0; }
  .callout li{ display:flex; align-items:center; gap:10px; padding:6px 0; border-bottom:1px solid var(--hairline); font-size:var(--fs-base); color:var(--body); }
  .callout li:last-child{ border-bottom:0; }

  /* posture charts (card idiom) */
  .charts{ display:flex; flex-wrap:wrap; gap:16px; }
  .chartcard{ flex:1 1 300px; background:var(--surface); border:1px solid var(--hairline); border-radius:var(--radius); box-shadow:var(--shadow); padding:1rem 1.2rem; }
  .chartcard h4{ margin:0 0 .7rem; font-size:var(--fs-xs); color:var(--muted); text-transform:uppercase; letter-spacing:.06em; font-family:var(--font-sans); font-weight:700; }
  .donutwrap{ display:flex; align-items:center; gap:16px; flex-wrap:wrap; }
  .donut-num{ font-family:var(--font-serif); font-size:26px; font-weight:600; fill:var(--ink); }
  .donut-lbl{ font-size:11px; fill:var(--muted); font-family:var(--font-sans); }
  .legend{ display:flex; flex-direction:column; gap:6px; font-size:var(--fs-sm); font-family:var(--font-sans); color:var(--body); }
  .leg{ white-space:nowrap; }
  .dot{ display:inline-block; width:11px; height:11px; border-radius:50%; margin-right:7px; vertical-align:middle; }
  .barlbl{ font-size:12px; fill:var(--ink); font-family:var(--font-sans); }
  .barval{ font-size:12px; fill:var(--muted); font-weight:700; font-family:var(--font-sans); }

  /* key observations (bd-callout idiom; discovery's own severity model) */
  .obs{ background:var(--surface); border:1px solid var(--hairline); border-left:4px solid var(--border); border-radius:var(--radius-sm); box-shadow:var(--shadow); padding:.85rem 1.1rem; margin:.7rem 0; }
  .obs-head{ display:flex; align-items:center; gap:10px; margin-bottom:4px; }
  .obs-area{ font-size:var(--fs-xs); color:var(--faint); text-transform:uppercase; letter-spacing:.06em; font-family:var(--font-sans); font-weight:700; }
  .obs-title{ font-family:var(--font-serif); font-weight:600; font-size:var(--fs-md); color:var(--ink); }
  .obs-detail{ font-size:var(--fs-base); color:var(--body); margin-top:3px; }
  .obs-rec{ font-size:var(--fs-sm); margin-top:8px; background:var(--surface-2); border-radius:var(--radius-sm); padding:8px 11px; color:var(--body); }
  .obs-rec b{ color:var(--accent-strong); }

  /* badges: PPA pill shape, discovery inline severity color (remapped) + white ink */
  .badge{ display:inline-block; padding:.32em .6em; font-size:var(--fs-xs); font-weight:700; line-height:1; border-radius:var(--radius-pill); letter-spacing:.02em; font-family:var(--font-sans); color:#fff; white-space:nowrap; }

  /* tables (table.detail idiom) */
  .tablewrap{ overflow-x:auto; margin:.3rem 0 .2rem; }
  .tablewrap table{ width:100%; border-collapse:collapse; font-size:var(--fs-sm); background:var(--surface); border:1px solid var(--hairline); border-radius:var(--radius-sm); }
  .tablewrap th{ background:var(--surface-2); border-bottom:2px solid var(--border); text-align:left; padding:.45rem .7rem; font-size:var(--fs-xs); text-transform:uppercase; letter-spacing:.04em; color:var(--muted); font-family:var(--font-sans); font-weight:700; position:sticky; top:0; }
  .tablewrap td{ padding:.42rem .7rem; vertical-align:top; border-top:1px solid var(--hairline); color:var(--body); }
  .tablewrap tbody tr:first-child td{ border-top:0; }
  .tablewrap tbody tr:nth-child(even){ background:var(--surface-1); }
  .muted{ color:var(--muted); font-size:var(--fs-sm); padding:8px 2px; font-family:var(--font-sans); }

  /* detail collapse cards reuse .card + .card-header.sumhead + .collapse from the base */
  .card-header.sumhead strong{ font-family:var(--font-serif); font-size:var(--fs-md); font-weight:600; color:var(--ink); }
  .sum-glance.count{ font-family:var(--font-mono); color:var(--muted); font-weight:700; }

  /* footer prepared-by line */
  .app-footer .cls{ font-weight:700; text-transform:uppercase; letter-spacing:.06em; color:#e7d3ac; display:block; margin-bottom:5px; }

  @media print{
    .toc{ display:none !important; }
    .app-body section{ border-bottom:1px solid #d7cfbe; page-break-inside:avoid; }
    .kpi,.chartcard,.obs,.narr,.card{ page-break-inside:avoid; }
  }
'@

$polishJs = @'
<script>
(function () {
  'use strict';
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(text); return; }
    var ta = document.createElement('textarea');
    ta.value = text; ta.setAttribute('readonly', '');
    ta.style.position = 'absolute'; ta.style.left = '-9999px';
    document.body.appendChild(ta); ta.select();
    try { document.execCommand('copy'); } catch (e) { }
    document.body.removeChild(ta);
  }
  // Per-finding anchor: copy the deep link; stop the click reaching the collapse toggle.
  document.addEventListener('click', function (ev) {
    var t = ev.target;
    var a = (t && t.closest) ? t.closest('.anchor-link') : null;
    if (!a) { return; }
    ev.stopPropagation();
    copyText(location.href.split('#')[0] + a.getAttribute('href'));
    a.classList.add('copied');
    setTimeout(function () { a.classList.remove('copied'); }, 1200);
  }, true);

  // Vanilla collapse: a click on any collapse toggle (the section headers) shows or
  // hides its data-target and flips aria-expanded. Matched via [data-target].
  document.addEventListener('click', function (ev) {
    var t = ev.target;
    if (t.closest && t.closest('.anchor-link')) { return; }
    var h = (t && t.closest) ? t.closest('[data-target]') : null;
    if (!h) { return; }
    var sel = h.getAttribute('data-target');
    if (!sel) { return; }
    var body = document.querySelector(sel);
    if (!body) { return; }
    var open = body.classList.toggle('show');
    h.setAttribute('aria-expanded', open ? 'true' : 'false');
  });

  // Keyboard toggle (Enter/Space) for focusable collapse headers (the summary sections).
  document.addEventListener('keydown', function (ev) {
    if (ev.key !== 'Enter' && ev.key !== ' ' && ev.key !== 'Spacebar') { return; }
    var h = (ev.target && ev.target.closest) ? ev.target.closest('[data-target]') : null;
    if (!h || !h.hasAttribute('tabindex')) { return; }
    ev.preventDefault();
    h.click();
  });

  // Auto-expand on anchor: a deep link to a collapsed section opens it so the target
  // never lands on an empty-looking section.
  function expandForHash() {
    var id = (location.hash || '').slice(1);
    if (!id) { return; }
    var el = document.getElementById(id);
    if (!el) { return; }
    var head = el.classList.contains('finding')
      ? el.querySelector('.finding-head[data-target]')
      : el.querySelector('.card-header.sumhead[data-target]');
    if (!head) { return; }
    var sel = head.getAttribute('data-target');
    var body = sel && document.querySelector(sel);
    if (body && !body.classList.contains('show')) {
      body.classList.add('show');
      head.setAttribute('aria-expanded', 'true');
    }
    el.scrollIntoView({ block: 'start' });
  }
  window.addEventListener('hashchange', expandForHash);

  // Print: expand every drill-down before printing, restore afterwards. The
  // @media print .collapse rule remains as a CSS fallback.
  var printOpened = [];
  window.addEventListener('beforeprint', function () {
    printOpened = [];
    [].slice.call(document.querySelectorAll('.collapse:not(.show)')).forEach(function (el) {
      el.classList.add('show'); printOpened.push(el);
    });
    [].slice.call(document.querySelectorAll('details:not([open])')).forEach(function (el) {
      el.setAttribute('open', ''); el.setAttribute('data-print-opened', '');
    });
  });
  window.addEventListener('afterprint', function () {
    printOpened.forEach(function (el) { el.classList.remove('show'); });
    printOpened = [];
    [].slice.call(document.querySelectorAll('details[data-print-opened]')).forEach(function (el) {
      el.removeAttribute('open'); el.removeAttribute('data-print-opened');
    });
  });

  expandForHash();
})();
</script>
'@

$html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
<style>
$css
</style>
<title>$(Enc $OrganizationName) - Purview $subtitle</title>
</head>
<body class="app bg-light">

<nav class="navbar navbar-custom">
  <div class="container-fluid">
    <div class="col-sm" style="text-align:left"><div class="row"><div><i class="fas fa-binoculars"></i></div>
      <div class="ml-3"><strong>Microsoft Purview Discovery Baseline</strong></div></div></div>
    <div class="col-sm" style="text-align:right"><button type="button" class="btn btn-primary" onclick="window.print();">Print</button></div>
  </div>
</nav>

<div class="app-body p-3"><main class="main">

  <div class="card cover"><div class="card-body">
    <div class="row">
      <div class="col">
        <div class="chip">$(Enc $Classification)</div>
        <h2 class="card-title">$(Enc $ReportTitle)</h2>
        <div class="sub">$(Enc $subtitle)</div>
        <table>
          <tr><td>Organization</td><td>:&nbsp; $(Enc $OrganizationName)</td></tr>
          $tenantRow
          <tr><td>Prepared by</td><td>:&nbsp; $(Enc $PreparedBy)</td></tr>
          <tr><td>Date</td><td>:&nbsp; $genDate</td></tr>
        </table>
      </div>
      <div class="col-auto">$logoBox</div>
    </div>
  </div></div>

  <nav class="toc"><div class="toc-inner">
  <a href="#summary">Environment Summary</a>
  <a href="#distribution">Distribution</a>
  <a href="#inventory">Inventory</a>
  <a href="#method">Methodology</a>
  </div></nav>

  <section id="summary"><h2>Environment Summary</h2>
    <p class="lead">Counts of the Microsoft Purview objects discovered in the environment.</p>
    <div class="kpis">$kpiHtml</div>
  </section>

  <section id="distribution"><h2>Distribution</h2>
    <p class="lead">Distribution of the discovered objects by type.</p>
    <div class="charts">$chartHtml</div>
  </section>

  <section id="inventory"><h2>Inventory</h2>
    <p class="lead">Full inventory of the discovered objects. Expand each area; complete data is in the CSV/JSON exports.</p>
$detailHtml
  </section>

  <section id="method"><h2>Methodology &amp; Scope</h2>
    <p class="lead">How this report was produced and what it does and does not cover.</p>
    <div class="narr" style="border-left-color:var(--muted)">
      This report was generated from a <b>read-only</b> discovery export of the tenant's Microsoft Purview
      configuration (Information Protection, Classification, Data Loss Prevention, Data Lifecycle and Records, and Audit
      configuration), collected via Security &amp; Compliance and Exchange Online PowerShell. It reflects configuration
      observed at the time of discovery and is provided as a record of the discovered configuration.
      It is <b>not</b> a compliance attestation. Items that cannot be exported programmatically - custom trainable
      classifiers, disposition-review state, Compliance Manager evidence, and Activity Explorer trends - are captured
      manually and are out of scope of the automated sections above.
    </div>
  </section>

</main></div>

$polishJs
<footer class="app-footer"><div class="container-fluid">
    <div class="cls">$(Enc $Classification)</div>
    Prepared by $(Enc $PreparedBy) for $(Enc $OrganizationName). Generated $genDate.
    This document may contain configuration details about the client environment and should be handled per its classification.
</div></footer>
</body>
</html>
"@

# UTF-8 without BOM (DECISIONS.md D7): source stays ASCII, but tenant data in the
# report (label names, org names) may be non-ASCII and must survive intact.
[System.IO.File]::WriteAllText($OutputPath, $html, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Report written: $OutputPath" -ForegroundColor Cyan
Write-Host ("Inventory: {0} sensitivity labels, {1} DLP policies, {2} retention labels, {3} custom SITs" -f `
    $lblTotal, $dlpTotal, $retTotal, $sitCustom) -ForegroundColor Gray
