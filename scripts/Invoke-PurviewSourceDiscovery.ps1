#Requires -Version 5.1
<#
.SYNOPSIS
    Source tenant Microsoft Purview configuration discovery export.
    Exports Information Protection, Classification, DLP, Data Lifecycle and Records
    configuration to JSON (fidelity) + CLIXML (re-import) + summary CSV (review),
    with a manifest and transcript. Resilient: missing cmdlets / empty results are
    logged and skipped, never fatal.
.NOTES
    Connects to BOTH Security & Compliance PowerShell (IPPS) and Exchange Online (EXO).
    Read-only: issues only Get-* / Export-* cmdlets. Run against the SOURCE tenant.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceUpn,
    [string]$OutputRoot = "C:\PurviewDiscovery",
    [switch]$IncludePurviewConfigZip,
    [switch]$ReuseExistingSession
)

$ErrorActionPreference = 'Stop'
function Get-SafeName([string]$n){ if([string]::IsNullOrWhiteSpace($n)){'unnamed'}else{($n -replace '[\\/:*?"<>|]','_').Trim()} }

# --- Output scaffold -------------------------------------------------------
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $OutputRoot "SourceDiscovery-$stamp"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
Start-Transcript -Path (Join-Path $runDir '_transcript.log') -Force | Out-Null
$script:Manifest = [System.Collections.Generic.List[object]]::new()
Write-Host "Output: $runDir" -ForegroundColor Cyan

# --- Connect ---------------------------------------------------------------
Import-Module ExchangeOnlineManagement -ErrorAction Stop
if (-not $ReuseExistingSession) {
    Write-Host "Connecting to Security & Compliance PowerShell (sign in as $SourceUpn)..." -ForegroundColor Yellow
    Connect-IPPSSession -UserPrincipalName $SourceUpn
    Write-Host "Connecting to Exchange Online (sign in as $SourceUpn)..." -ForegroundColor Yellow
    Connect-ExchangeOnline -UserPrincipalName $SourceUpn -ShowBanner:$false
}

# --- Resilient export wrapper ---------------------------------------------
function Export-Artifact {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Name,
        [string]$Cmd,
        [Parameter(Mandatory)][scriptblock]$Get,
        [object[]]$CsvSelect
    )
    $areaDir = Join-Path $runDir $Area
    New-Item -ItemType Directory -Force -Path $areaDir | Out-Null
    $base = Join-Path $areaDir (Get-SafeName $Name)
    $rec  = [ordered]@{ Area=$Area; Artifact=$Name; Cmdlet=$Cmd; Status=$null; Count=0; File=$null; Timestamp=(Get-Date).ToString('o') }

    if ($Cmd -and -not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        $rec.Status = 'CmdletNotAvailable'
        Write-Warning "[$Area] $Name : cmdlet '$Cmd' not present in this session/SKU - skipped."
        $script:Manifest.Add([pscustomobject]$rec); return
    }
    try {
        $data  = & $Get
        $count = @($data).Count
        $rec.Count = $count
        if ($count -eq 0) {
            $rec.Status = 'Empty'
            Write-Host "[$Area] $Name : 0 objects." -ForegroundColor DarkGray
        } else {
            $data | ConvertTo-Json -Depth 12 | Out-File "$base.json" -Encoding utf8
            $data | Export-Clixml -Path "$base.xml"
            if ($CsvSelect) { $data | Select-Object $CsvSelect | Export-Csv "$base.csv" -NoTypeInformation -Encoding utf8 }
            $rec.Status = 'Success'; $rec.File = "$base.json"
            Write-Host "[$Area] $Name : $count exported." -ForegroundColor Green
        }
    } catch {
        $rec.Status = "Failed: $($_.Exception.Message)"
        Write-Warning "[$Area] $Name failed: $($_.Exception.Message)"
    }
    $script:Manifest.Add([pscustomobject]$rec)
}

# ===========================================================================
# 1. INFORMATION PROTECTION
# ===========================================================================
Export-Artifact -Area '1-InformationProtection' -Name 'SensitivityLabels' -Cmd 'Get-Label' `
    -Get { Get-Label } `
    -CsvSelect @('DisplayName','Name','Guid','Priority','ContentType','Disabled',
        @{n='ParentLabel';e={$_.ParentLabelDisplayName}},
        @{n='EncryptionEnabled';e={$_.EncryptionEnabled}},
        @{n='ContentMarking';e={$_.ApplyContentMarkingHeaderEnabled -or $_.ApplyContentMarkingFooterEnabled -or $_.ApplyWaterMarkingEnabled}})

Export-Artifact -Area '1-InformationProtection' -Name 'LabelPolicies' -Cmd 'Get-LabelPolicy' `
    -Get { Get-LabelPolicy } `
    -CsvSelect @('Name','Guid','Mode','Enabled',@{n='Labels';e={($_.Labels -join '; ')}},@{n='Workload';e={$_.Workload}})

Export-Artifact -Area '1-InformationProtection' -Name 'AutoLabelPolicies' -Cmd 'Get-AutoSensitivityLabelPolicy' `
    -Get { Get-AutoSensitivityLabelPolicy } `
    -CsvSelect @('Name','Guid','Mode','Enabled','ApplySensitivityLabel',@{n='Workload';e={$_.Workload}})

Export-Artifact -Area '1-InformationProtection' -Name 'AutoLabelRules' -Cmd 'Get-AutoSensitivityLabelRule' `
    -Get { Get-AutoSensitivityLabelRule } `
    -CsvSelect @('Name',@{n='Policy';e={$_.ParentPolicyName}},'Disabled',@{n='Workload';e={$_.Workload}})

# ===========================================================================
# 2. CLASSIFICATION (SITs, EDM, trainable classifiers)
# ===========================================================================
# All SITs - flag custom (Publisher not Microsoft) for rationalization
Export-Artifact -Area '2-Classification' -Name 'SensitiveInfoTypes_All' -Cmd 'Get-DlpSensitiveInformationType' `
    -Get { Get-DlpSensitiveInformationType } `
    -CsvSelect @('Name','Id','Type','Publisher','RulePackId',
        @{n='IsCustom';e={$_.Publisher -ne 'Microsoft Corporation'}})

# Custom SIT rule packages -> raw XML (the actual regex/keyword logic)
$sitDir = Join-Path $runDir '2-Classification\SIT-RulePackages'
New-Item -ItemType Directory -Force -Path $sitDir | Out-Null
if (Get-Command Get-DlpSensitiveInformationTypeRulePackage -ErrorAction SilentlyContinue) {
    try {
        $pkgs = Get-DlpSensitiveInformationTypeRulePackage
        foreach ($p in $pkgs) {
            $idVal = if ($p.Identity) { $p.Identity } else { $p.Name }
            $pName = Get-SafeName $idVal
            try {
                $xml = [System.Text.Encoding]::Unicode.GetString($p.SerializedClassificationRuleCollection)
                $xml | Out-File (Join-Path $sitDir "$pName.xml") -Encoding utf8
            } catch { $p | Export-Clixml (Join-Path $sitDir "$pName.xml.clixml") }
        }
        $script:Manifest.Add([pscustomobject]@{Area='2-Classification';Artifact='SIT-RulePackages';Cmdlet='Get-DlpSensitiveInformationTypeRulePackage';Status='Success';Count=@($pkgs).Count;File=$sitDir;Timestamp=(Get-Date).ToString('o')})
    } catch {
        $script:Manifest.Add([pscustomobject]@{Area='2-Classification';Artifact='SIT-RulePackages';Cmdlet='Get-DlpSensitiveInformationTypeRulePackage';Status="Failed: $($_.Exception.Message)";Count=0;File=$null;Timestamp=(Get-Date).ToString('o')})
    }
}

# EDM schemas -> per-schema XML (cannot migrate; this documents what to rebuild)
$edmDir = Join-Path $runDir '2-Classification\EDM-Schemas'
New-Item -ItemType Directory -Force -Path $edmDir | Out-Null
if (Get-Command Get-DlpEdmSchema -ErrorAction SilentlyContinue) {
    try {
        $schemas = Get-DlpEdmSchema
        foreach ($s in $schemas) {
            try {
                $detail = Get-DlpEdmSchema -Identity $s.Identity
                $detail.EdmSchemaXML | Set-Content -Path (Join-Path $edmDir ((Get-SafeName $s.Identity) + '.xml'))
            } catch { Write-Warning "EDM schema '$($s.Identity)' XML export failed: $($_.Exception.Message)" }
        }
        $script:Manifest.Add([pscustomobject]@{Area='2-Classification';Artifact='EDM-Schemas';Cmdlet='Get-DlpEdmSchema';Status='Success';Count=@($schemas).Count;File=$edmDir;Timestamp=(Get-Date).ToString('o')})
    } catch {
        $script:Manifest.Add([pscustomobject]@{Area='2-Classification';Artifact='EDM-Schemas';Cmdlet='Get-DlpEdmSchema';Status="Failed: $($_.Exception.Message)";Count=0;File=$null;Timestamp=(Get-Date).ToString('o')})
    }
}
# NOTE: Custom TRAINABLE CLASSIFIERS have no supported export cmdlet - document manually
#       from the portal (Data classification > Trainable classifiers). See README.

# ===========================================================================
# 3. DATA LOSS PREVENTION
# ===========================================================================
Export-Artifact -Area '3-DLP' -Name 'DlpPolicies' -Cmd 'Get-DlpCompliancePolicy' `
    -Get { Get-DlpCompliancePolicy } `
    -CsvSelect @('Name','Guid','Mode','Enabled',@{n='Workload';e={$_.Workload}},
        @{n='Exchange';e={[bool]$_.ExchangeLocation}},
        @{n='SharePoint';e={[bool]$_.SharePointLocation}},
        @{n='OneDrive';e={[bool]$_.OneDriveLocation}},
        @{n='Teams';e={[bool]$_.TeamsLocation}},
        @{n='Endpoint';e={[bool]$_.EndpointDlpLocation}})

Export-Artifact -Area '3-DLP' -Name 'DlpRules' -Cmd 'Get-DlpComplianceRule' `
    -Get { Get-DlpComplianceRule } `
    -CsvSelect @('Name',@{n='Policy';e={$_.ParentPolicyName}},'Disabled','BlockAccess','BlockAccessScope',
        'GenerateAlert','GenerateIncidentReport',
        @{n='NotifyUser';e={($_.NotifyUser -join '; ')}},
        @{n='HasUserOverride';e={[bool]$_.NotifyAllowOverride}},
        @{n='Override';e={($_.NotifyAllowOverride -join '; ')}},
        'ReportSeverityLevel')

# Endpoint DLP global settings (restricted apps/browsers/USB/printer/network share groups)
Export-Artifact -Area '3-DLP' -Name 'EndpointDlpGlobalSettings' -Cmd 'Get-PolicyConfig' `
    -Get { Get-PolicyConfig }

# ===========================================================================
# 4. DATA LIFECYCLE & RECORDS MANAGEMENT
# ===========================================================================
Export-Artifact -Area '4-Retention-Records' -Name 'RetentionLabels' -Cmd 'Get-ComplianceTag' `
    -Get { Get-ComplianceTag } `
    -CsvSelect @('Name','Guid','RetentionAction','RetentionDuration','RetentionType',
        'IsRecordLabel','Regulatory','HasRetentionAction','Notes',
        @{n='FilePlan';e={if($_.FilePlanMetadata){'yes'}else{'no'}}})

Export-Artifact -Area '4-Retention-Records' -Name 'RetentionPolicies' -Cmd 'Get-RetentionCompliancePolicy' `
    -Get { Get-RetentionCompliancePolicy -DistributionDetail } `
    -CsvSelect @('Name','Guid','Mode','Enabled',@{n='Workload';e={$_.Workload}},
        @{n='ScopeType';e={if($_.IsAdaptiveScopePolicy){'Adaptive'}else{'Static'}}},
        'RestrictiveRetention')

Export-Artifact -Area '4-Retention-Records' -Name 'RetentionRules' -Cmd 'Get-RetentionComplianceRule' `
    -Get { Get-RetentionComplianceRule } `
    -CsvSelect @('Name',@{n='Policy';e={$_.Policy}},'RetentionDuration','RetentionComplianceAction','ExpirationDateOption')

Export-Artifact -Area '4-Retention-Records' -Name 'RetentionEventTypes' -Cmd 'Get-ComplianceRetentionEventType' `
    -Get { Get-ComplianceRetentionEventType } -CsvSelect @('Name','Guid')

# Adaptive scopes (cmdlet may be absent on older modules - wrapper guards it)
Export-Artifact -Area '4-Retention-Records' -Name 'AdaptiveScopes' -Cmd 'Get-AdaptiveScope' `
    -Get { Get-AdaptiveScope } -CsvSelect @('Name','Guid','LocationType','Mode')

# File plan descriptors
foreach ($fp in 'Authority','Category','SubCategory','Citation','Department','ReferenceId') {
    Export-Artifact -Area '4-Retention-Records' -Name "FilePlan_$fp" -Cmd "Get-FilePlanProperty$fp" `
        -Get ([scriptblock]::Create("Get-FilePlanProperty$fp")) -CsvSelect @('Name','Guid')
}

# ===========================================================================
# 5. AUDIT CONFIGURATION (EXO) + AUDIT RETENTION POLICIES (IPPS)
# ===========================================================================
Export-Artifact -Area '5-Audit' -Name 'UnifiedAuditIngestionStatus' -Cmd 'Get-AdminAuditLogConfig' `
    -Get { Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled,AdminAuditLogEnabled } `
    -CsvSelect @('UnifiedAuditLogIngestionEnabled','AdminAuditLogEnabled')

Export-Artifact -Area '5-Audit' -Name 'AuditLogRetentionPolicies' -Cmd 'Get-UnifiedAuditLogRetentionPolicy' `
    -Get { Get-UnifiedAuditLogRetentionPolicy } `
    -CsvSelect @('Name','Priority','RecordTypes','Operations','UserIds','RetentionDuration')

Export-Artifact -Area '5-Audit' -Name 'OrganizationConfig' -Cmd 'Get-OrganizationConfig' `
    -Get { Get-OrganizationConfig }

# ===========================================================================
# 6. BONUS - one-shot Purview diagnostic config ZIP (newer tenants only)
# ===========================================================================
if ($IncludePurviewConfigZip -and (Get-Command Export-PurviewConfig -ErrorAction SilentlyContinue)) {
    try {
        $zip = Export-PurviewConfig -Components DLP,MIPLabels,ClassificationAndTextExtraction,DLM
        $zipPath = Join-Path $runDir '6-PurviewConfigDiagnostic.zip'
        [IO.File]::WriteAllBytes($zipPath, $zip)
        Write-Host "Export-PurviewConfig ZIP saved: $zipPath" -ForegroundColor Green
        $script:Manifest.Add([pscustomobject]@{Area='6-Diagnostic';Artifact='Export-PurviewConfig';Cmdlet='Export-PurviewConfig';Status='Success';Count=1;File=$zipPath;Timestamp=(Get-Date).ToString('o')})
    } catch { Write-Warning "Export-PurviewConfig failed: $($_.Exception.Message)" }
}

# --- Manifest + close ------------------------------------------------------
$script:Manifest | Export-Csv (Join-Path $runDir '_manifest.csv') -NoTypeInformation -Encoding utf8
$script:Manifest | Format-Table Area,Artifact,Status,Count -AutoSize
Write-Host "`nDiscovery complete. Manifest: $(Join-Path $runDir '_manifest.csv')" -ForegroundColor Cyan
Stop-Transcript | Out-Null
