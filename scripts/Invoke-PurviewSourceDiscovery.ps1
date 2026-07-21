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
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$OutputRoot = "C:\PurviewDiscovery",
    # Optional engagement label stamped into provenance (e.g. Baseline, Closeout).
    [string]$SnapshotLabel = '',
    [switch]$IncludePurviewConfigZip,
    # Opt-in per-mailbox hold sweep (D12: off by default, aggregate-first). The
    # default aggregate records COUNTS by hold state - no user principal names.
    [switch]$IncludeMailboxHolds,
    # Second opt-in: per-mailbox rows (includes UPNs - treat output as confidential).
    [switch]$MailboxDetail,
    [switch]$ReuseExistingSession
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PurviewSnapshot.psm1') -Force

# --- Run scaffold (UTC stamps; D9) ------------------------------------------
$startedUtc = (Get-Date).ToUniversalTime()
$runDir = Join-Path $OutputRoot ("PurviewSnapshot-" + $startedUtc.ToString('yyyyMMdd-HHmmss'))
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

# Derived per-area CSV view columns (D9, Task 5d), frozen against documented
# property names at the sandbox checkpoint. A column absent on live objects emits
# blank - see "Unverified projections" in docs/SNAPSHOT-SCHEMA.md. Areas without a
# registered view (Dlp.EndpointGlobalSettings, the diff-excluded areas) are
# represented by snapshot.json alone.
$script:AreaCsvViews = @{
    'InformationProtection.SensitivityLabels'  = @('Name', 'Guid', 'DisplayName', 'ParentLabelDisplayName', 'Priority', 'ContentType', 'Disabled')
    'InformationProtection.LabelPolicies'      = @('Name', 'Guid', 'Mode', 'Enabled', 'Workload', 'Labels')
    'InformationProtection.AutoLabelPolicies'  = @('Name', 'Guid', 'Mode', 'ApplySensitivityLabel', 'Workload')
    'InformationProtection.AutoLabelRules'     = @('Name', 'Guid', 'ParentPolicyName', 'Disabled', 'Workload')
    'Classification.SensitiveInformationTypes' = @('Name', 'Id', 'Publisher', 'Type', 'RulePackId')
    'Classification.SitRulePackages'           = @('Name', 'RulePackId', 'Publisher', 'Version', 'SidecarPath')
    'Classification.EdmSchemas'                = @('Name', 'SidecarPath')
    'Dlp.Policies'                             = @('Name', 'Guid', 'Mode', 'Enabled', 'ExchangeLocation', 'SharePointLocation', 'OneDriveLocation', 'TeamsLocation', 'EndpointDlpLocation')
    'Dlp.Rules'                                = @('Name', 'Guid', 'ParentPolicyName', 'Disabled', 'BlockAccess', 'BlockAccessScope', 'GenerateAlert', 'GenerateIncidentReport', 'NotifyUser', 'NotifyAllowOverride', 'ReportSeverityLevel')
    'RetentionRecords.Labels'                  = @('Name', 'Guid', 'RetentionAction', 'RetentionDuration', 'RetentionType', 'IsRecordLabel', 'Notes')
    'RetentionRecords.Policies'                = @('Name', 'Guid', 'Enabled', 'Mode', 'Workload', 'RestrictiveRetention')
    'RetentionRecords.Rules'                   = @('Name', 'Guid', 'Policy', 'RetentionDuration', 'RetentionComplianceAction', 'ExpirationDateOption')
    'RetentionRecords.EventTypes'              = @('Name', 'Guid')
    'RetentionRecords.AdaptiveScopes'          = @('Name', 'Guid', 'LocationType', 'Mode', 'FilterQuery')
    'RetentionRecords.FilePlanAuthorities'     = @('Name', 'Guid')
    'RetentionRecords.FilePlanCategories'      = @('Name', 'Guid')
    'RetentionRecords.FilePlanSubCategories'   = @('Name', 'Guid')
    'RetentionRecords.FilePlanCitations'       = @('Name', 'Guid')
    'RetentionRecords.FilePlanDepartments'     = @('Name', 'Guid')
    'RetentionRecords.FilePlanReferenceIds'    = @('Name', 'Guid')
    'Audit.UnifiedAuditIngestion'              = @('UnifiedAuditLogIngestionEnabled', 'AdminAuditLogEnabled')
    'Audit.LogRetentionPolicies'               = @('Name', 'Priority', 'RecordTypes', 'Operations', 'UserIds', 'RetentionDuration')
    'ExchangeCompliance.MrmPolicies'           = @('Name', 'Guid', 'RetentionPolicyTagLinks', 'IsDefault')
    'ExchangeCompliance.MrmTags'               = @('Name', 'Guid', 'Type', 'AgeLimitForRetention', 'RetentionAction', 'RetentionEnabled', 'MessageClass')
    'ExchangeCompliance.JournalRules'          = @('Name', 'Guid', 'Enabled', 'Scope', 'Recipient', 'JournalEmailAddress')
    'Alerts.ProtectionAlerts'                  = @('Name', 'Guid', 'Disabled', 'Category', 'Severity', 'ThreatType', 'Operation', 'NotifyUser', 'AggregationType')
    'Alerts.ActivityAlerts'                    = @('Name', 'Guid', 'Disabled', 'Type', 'Category', 'Operation', 'NotifyUser')
    'InformationBarriers.Policies'             = @('Name', 'Guid', 'State', 'AssignedSegment', 'SegmentsAllowed', 'SegmentsBlocked')
    'InformationBarriers.Segments'             = @('Name', 'Guid', 'UserGroupFilter')
    'Classification.KeywordDictionaries'       = @('Name', 'Identity', 'Description')
    'Governance.RoleGroups'                    = @('Name', 'Guid', 'DisplayName', 'Description', 'Roles')
    'Governance.RoleGroupMembers'              = @('RoleGroup', 'MemberName', 'DisplayName', 'MemberGuid', 'RecipientType')
    'Legacy.HoldPolicies'                      = @('Name', 'Guid', 'Enabled', 'Mode', 'Workload')
    'Legacy.HoldRules'                         = @('Name', 'Guid', 'Policy', 'Disabled', 'HoldContent', 'HoldDurationDisplayHint')
    'Legacy.ExchangeDlpPolicies'               = @('Name', 'Guid', 'State', 'Mode', 'Description')
    'RetentionRecords.AppRetentionPolicies'    = @('Name', 'Guid', 'Enabled', 'Mode', 'Applications')
    'RetentionRecords.AppRetentionRules'       = @('Name', 'Guid', 'Policy', 'RetentionDuration', 'RetentionComplianceAction', 'ExpirationDateOption')
    'InsiderRisk.Policies'                     = @('Name', 'Guid', 'InsiderRiskScenario')
    'CommunicationCompliance.Policies'         = @('Name', 'Guid', 'Enabled')
    'CommunicationCompliance.Rules'            = @('Name', 'Guid', 'Policy', 'SamplingRate')
    'Ediscovery.Cases'                         = @('Name', 'Guid', 'CaseType', 'Status')
    'Ediscovery.CaseHoldPolicies'              = @('Name', 'Guid', 'Enabled', 'Mode', 'CaseId')
    'Ediscovery.CaseHoldRules'                 = @('Name', 'Guid', 'Policy', 'ContentMatchQuery')
    'Ediscovery.Searches'                      = @('Name', 'Guid', 'CaseName', 'ContentMatchQuery', 'Status')
    'Ediscovery.SecurityFilters'               = @('FilterName', 'Users', 'Filters', 'Action', 'Description')
    'Ediscovery.CaseAdmins'                    = @('Name', 'DisplayName')
    'InformationProtection.IrmConfig'          = @('AzureRMSLicensingEnabled', 'InternalLicensingEnabled', 'ExternalLicensingEnabled', 'JournalReportDecryptionEnabled', 'SimplifiedClientAccessEnabled', 'TransportDecryptionSetting')
    'InformationProtection.RmsTemplates'       = @('Name', 'Guid', 'Description', 'Type')
    'Mailboxes.HoldSummary'                    = @('Metric', 'Value', 'Mailboxes')
    'Mailboxes.HoldDetail'                     = @('UserPrincipalName', 'LitigationHoldEnabled', 'RetentionHoldEnabled', 'ComplianceTagHoldApplied', 'DelayHoldApplied', 'InPlaceHolds', 'RetentionPolicy', 'AuditEnabled')
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

Connect-PurviewSnapshotSession -UserPrincipalName $UserPrincipalName -ReuseExistingSession:$ReuseExistingSession

# === Information Protection ==================================================
Trace-Area (Get-SnapshotArea -Area 'InformationProtection.SensitivityLabels' -Cmdlet 'Get-Label' -Collect { Get-Label })
Trace-Area (Get-SnapshotArea -Area 'InformationProtection.LabelPolicies' -Cmdlet 'Get-LabelPolicy' -Collect { Get-LabelPolicy })
Trace-Area (Get-SnapshotArea -Area 'InformationProtection.AutoLabelPolicies' -Cmdlet 'Get-AutoSensitivityLabelPolicy' -Collect { Get-AutoSensitivityLabelPolicy })
Trace-Area (Get-SnapshotArea -Area 'InformationProtection.AutoLabelRules' -Cmdlet 'Get-AutoSensitivityLabelRule' `
    -StableKeyProperty @('Guid', 'ParentPolicyName', 'Name') -Collect { Get-AutoSensitivityLabelRule })
Trace-Area (Get-SnapshotArea -Area 'InformationProtection.IrmConfig' -Cmdlet 'Get-IRMConfiguration' `
    -StableKeyProperty @('Identity') -Collect { Get-IRMConfiguration })
Trace-Area (Get-SnapshotArea -Area 'InformationProtection.RmsTemplates' -Cmdlet 'Get-RMSTemplate' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-RMSTemplate })

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
Trace-Area (Get-SnapshotArea -Area 'Classification.KeywordDictionaries' -Cmdlet 'Get-DlpKeywordDictionary' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-DlpKeywordDictionary })
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
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.AppRetentionPolicies' -Cmdlet 'Get-AppRetentionCompliancePolicy' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-AppRetentionCompliancePolicy })
Trace-Area (Get-SnapshotArea -Area 'RetentionRecords.AppRetentionRules' -Cmdlet 'Get-AppRetentionComplianceRule' `
    -StableKeyProperty @('Guid', 'Policy', 'Name') -Collect { Get-AppRetentionComplianceRule })
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

# === Exchange compliance (MRM & journaling; batch 3) ========================
Trace-Area (Get-SnapshotArea -Area 'ExchangeCompliance.MrmPolicies' -Cmdlet 'Get-RetentionPolicy' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-RetentionPolicy })
Trace-Area (Get-SnapshotArea -Area 'ExchangeCompliance.MrmTags' -Cmdlet 'Get-RetentionPolicyTag' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-RetentionPolicyTag })
Trace-Area (Get-SnapshotArea -Area 'ExchangeCompliance.JournalRules' -Cmdlet 'Get-JournalRule' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-JournalRule })

# === Alert policies ==========================================================
Trace-Area (Get-SnapshotArea -Area 'Alerts.ProtectionAlerts' -Cmdlet 'Get-ProtectionAlert' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-ProtectionAlert })
# Legacy activity alerts: absent on most modern tenants - CmdletNotAvailable is
# the expected durable record there.
Trace-Area (Get-SnapshotArea -Area 'Alerts.ActivityAlerts' -Cmdlet 'Get-ActivityAlert' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-ActivityAlert })

# === Information barriers ====================================================
Trace-Area (Get-SnapshotArea -Area 'InformationBarriers.Policies' -Cmdlet 'Get-InformationBarrierPolicy' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-InformationBarrierPolicy })
Trace-Area (Get-SnapshotArea -Area 'InformationBarriers.Segments' -Cmdlet 'Get-OrganizationSegment' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-OrganizationSegment })

# === Governance (Purview role groups) ========================================
Trace-Area (Get-SnapshotArea -Area 'Governance.RoleGroups' -Cmdlet 'Get-RoleGroup' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-RoleGroup })
# Membership rows are toolkit-shaped descriptors (group context + member
# identity) because the same member can appear in many groups; the underlying
# member property names are in the unverified-projections list.
Trace-Area (Get-SnapshotArea -Area 'Governance.RoleGroupMembers' -Cmdlet @('Get-RoleGroup', 'Get-RoleGroupMember') `
    -StableKeyProperty @('RoleGroup', 'MemberName') -Collect {
        foreach ($rg in @(Get-RoleGroup)) {
            foreach ($m in @(Get-RoleGroupMember -Identity "$($rg.Identity)")) {
                if ($null -eq $m) { continue }
                [pscustomobject][ordered]@{
                    RoleGroup     = "$($rg.Name)"
                    MemberName    = if ($m.PSObject.Properties['Name'] -and "$($m.Name)" -ne '') { "$($m.Name)" } else { "$m" }
                    DisplayName   = if ($m.PSObject.Properties['DisplayName']) { "$($m.DisplayName)" } else { $null }
                    MemberGuid    = if ($m.PSObject.Properties['Guid']) { "$($m.Guid)" } else { $null }
                    RecipientType = if ($m.PSObject.Properties['RecipientType']) { "$($m.RecipientType)" } else { $null }
                }
            }
        }
    })

# === Legacy compliance artifacts =============================================
Trace-Area (Get-SnapshotArea -Area 'Legacy.HoldPolicies' -Cmdlet 'Get-HoldCompliancePolicy' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-HoldCompliancePolicy })
Trace-Area (Get-SnapshotArea -Area 'Legacy.HoldRules' -Cmdlet 'Get-HoldComplianceRule' `
    -StableKeyProperty @('Guid', 'Policy', 'Name') -Collect { Get-HoldComplianceRule })
# Legacy EXO DLP (distinct from Get-DlpCompliancePolicy).
Trace-Area (Get-SnapshotArea -Area 'Legacy.ExchangeDlpPolicies' -Cmdlet 'Get-DlpPolicy' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-DlpPolicy })

# === Insider risk & communication compliance (role/licence-gated) ===========
# On accounts without the corresponding role, the wrapper records AccessDenied -
# a durable, classified record instead of a crash or a false Empty.
Trace-Area (Get-SnapshotArea -Area 'InsiderRisk.Policies' -Cmdlet 'Get-InsiderRiskPolicy' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-InsiderRiskPolicy })
Trace-Area (Get-SnapshotArea -Area 'CommunicationCompliance.Policies' -Cmdlet 'Get-SupervisoryReviewPolicyV2' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-SupervisoryReviewPolicyV2 })
Trace-Area (Get-SnapshotArea -Area 'CommunicationCompliance.Rules' -Cmdlet 'Get-SupervisoryReviewRule' `
    -StableKeyProperty @('Guid', 'Policy', 'Name') -Collect { Get-SupervisoryReviewRule })

# === eDiscovery metadata (gated; enumeration of EXISTING objects only) =======
# Read-only: cases, holds, searches, security filters and case admins are LISTED,
# never created, started or exported (pinned by the AST guard).
Trace-Area (Get-SnapshotArea -Area 'Ediscovery.Cases' -Cmdlet 'Get-ComplianceCase' `
    -StableKeyProperty @('Guid', 'Name') -Collect {
        @(Get-ComplianceCase -CaseType eDiscovery) + @(Get-ComplianceCase -CaseType AdvancedEdiscovery)
    })
Trace-Area (Get-SnapshotArea -Area 'Ediscovery.CaseHoldPolicies' -Cmdlet @('Get-ComplianceCase', 'Get-CaseHoldPolicy') `
    -StableKeyProperty @('Guid', 'Name') -Collect {
        foreach ($case in @(@(Get-ComplianceCase -CaseType eDiscovery) + @(Get-ComplianceCase -CaseType AdvancedEdiscovery))) {
            Get-CaseHoldPolicy -Case "$($case.Identity)"
        }
    })
Trace-Area (Get-SnapshotArea -Area 'Ediscovery.CaseHoldRules' -Cmdlet @('Get-ComplianceCase', 'Get-CaseHoldPolicy', 'Get-CaseHoldRule') `
    -StableKeyProperty @('Guid', 'Policy', 'Name') -Collect {
        foreach ($case in @(@(Get-ComplianceCase -CaseType eDiscovery) + @(Get-ComplianceCase -CaseType AdvancedEdiscovery))) {
            foreach ($p in @(Get-CaseHoldPolicy -Case "$($case.Identity)")) {
                Get-CaseHoldRule -Policy "$($p.Name)"
            }
        }
    })
Trace-Area (Get-SnapshotArea -Area 'Ediscovery.Searches' -Cmdlet 'Get-ComplianceSearch' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-ComplianceSearch })
Trace-Area (Get-SnapshotArea -Area 'Ediscovery.SecurityFilters' -Cmdlet 'Get-ComplianceSecurityFilter' `
    -StableKeyProperty @('FilterName') -Collect { Get-ComplianceSecurityFilter })
Trace-Area (Get-SnapshotArea -Area 'Ediscovery.CaseAdmins' -Cmdlet 'Get-eDiscoveryCaseAdmin' `
    -StableKeyProperty @('Guid', 'Name') -Collect { Get-eDiscoveryCaseAdmin })

# === Mailboxes (opt-in sweep; D12: off by default, aggregate-first) ==========
Trace-Area (Get-SnapshotArea -Area 'Mailboxes.HoldSummary' -Cmdlet 'Get-EXOMailbox' `
    -StableKeyProperty @('Metric', 'Value') `
    -Skip:(-not $IncludeMailboxHolds) -SkipReason 'IncludeMailboxHolds not set' `
    -Collect {
        Get-EXOMailbox -ResultSize Unlimited -Properties LitigationHoldEnabled, InPlaceHolds,
            ComplianceTagHoldApplied, DelayHoldApplied, RetentionHoldEnabled, RetentionPolicy, AuditEnabled
    } `
    -Process {
        param($mbx)
        # Aggregate-first (D12): counts by hold state. No user principal names in
        # the default evidence.
        $rows = [System.Collections.Generic.List[object]]::new()
        $rows.Add([pscustomobject][ordered]@{ Metric = 'TotalMailboxes'; Value = 'All'; Mailboxes = [int]@($mbx).Count })
        foreach ($metric in @('LitigationHoldEnabled', 'ComplianceTagHoldApplied', 'DelayHoldApplied',
                              'RetentionHoldEnabled', 'AuditEnabled')) {
            foreach ($g in @(@($mbx) | Group-Object { "$($_.$metric)" })) {
                $rows.Add([pscustomobject][ordered]@{ Metric = $metric; Value = "$($g.Name)"; Mailboxes = [int]$g.Count })
            }
        }
        foreach ($g in @(@($mbx) | Group-Object { if (@($_.InPlaceHolds).Count -gt 0) { 'True' } else { 'False' } })) {
            $rows.Add([pscustomobject][ordered]@{ Metric = 'HasInPlaceHolds'; Value = "$($g.Name)"; Mailboxes = [int]$g.Count })
        }
        foreach ($g in @(@($mbx) | Group-Object { $v = "$($_.RetentionPolicy)"; if ($v -eq '') { '(none)' } else { $v } })) {
            $rows.Add([pscustomobject][ordered]@{ Metric = 'RetentionPolicy'; Value = "$($g.Name)"; Mailboxes = [int]$g.Count })
        }
        @{ Objects = $rows.ToArray() }
    })
# Per-mailbox rows carry UPNs: separate second opt-in (treat output confidential).
Trace-Area (Get-SnapshotArea -Area 'Mailboxes.HoldDetail' -Cmdlet 'Get-EXOMailbox' `
    -StableKeyProperty @('UserPrincipalName') `
    -Skip:(-not ($IncludeMailboxHolds -and $MailboxDetail)) -SkipReason 'MailboxDetail not set (per-mailbox rows are opt-in)' `
    -Collect {
        Get-EXOMailbox -ResultSize Unlimited -Properties LitigationHoldEnabled, InPlaceHolds,
            ComplianceTagHoldApplied, DelayHoldApplied, RetentionHoldEnabled, RetentionPolicy, AuditEnabled
    })

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
        $prov = Get-SnapshotProvenance -UserPrincipalName $UserPrincipalName -Parameters $PSBoundParameters `
            -StartedUtc $startedUtc -EndedUtc $endedUtc -ScriptName 'Invoke-PurviewSourceDiscovery.ps1' `
            -SnapshotLabel $SnapshotLabel -Outcome $outcome
        $doc = Get-PurviewSnapshotDocument -Provenance $prov -Areas @($script:Areas)
        Write-PurviewSnapshot -Document $doc -Path (Join-Path $runDir 'snapshot.json')
        Write-Host "Snapshot: $(Join-Path $runDir 'snapshot.json') ($outcome)" -ForegroundColor Cyan
    } catch { Write-Warning "Snapshot write failed: $($_.Exception.Message)" }
    try {
        # Derived views: projected from the collected envelopes, never a second
        # tenant call (D9).
        $views = Write-SnapshotAreaCsvViews -Areas @($script:Areas) -Directory (Join-Path $runDir 'views') -Columns $script:AreaCsvViews
        if (@($views).Count -gt 0) {
            Write-Host "Views: $(@($views).Count) per-area CSVs under views/ (derived from the snapshot)" -ForegroundColor Cyan
        }
    } catch { Write-Warning "View write failed: $($_.Exception.Message)" }
    if ($script:Areas.Count -gt 0) {
        try { Write-SnapshotManifestCsv -Areas @($script:Areas) -Path (Join-Path $runDir '_manifest.csv') }
        catch { Write-Warning "Manifest view write failed: $($_.Exception.Message)" }
    }
    try { Stop-Transcript | Out-Null } catch { }
}
