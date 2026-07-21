# Pester v5 offline tests for scripts/Invoke-PurviewSourceDiscovery.ps1 ("A").
#
# Fully offline: -ReuseExistingSession short-circuits the connect (no module import,
# no tenant), and the SCC/EXO cmdlets are absent in this session unless stubbed, so
# the wrapper's CommandNotFound handling records CmdletNotAvailable without touching
# any tenant. Collect blocks are bound to the script session, so stubs + mocks work.

BeforeDiscovery {
    # Batch 3 Stop 1 area specs: one row per always-readable area. Drives the
    # uniform status-path tests (Success / AccessDenied / CmdletNotAvailable /
    # Empty) and pins each area's composite stable key and frozen view columns.
    $script:Stop1Specs = @(
        @{ Area = 'ExchangeCompliance.MrmPolicies';           Cmdlet = 'Get-RetentionPolicy';              Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'RetentionPolicyTagLinks', 'IsDefault') }
        @{ Area = 'ExchangeCompliance.MrmTags';               Cmdlet = 'Get-RetentionPolicyTag';           Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'Type', 'AgeLimitForRetention', 'RetentionAction', 'RetentionEnabled', 'MessageClass') }
        @{ Area = 'ExchangeCompliance.JournalRules';          Cmdlet = 'Get-JournalRule';                  Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'Enabled', 'Scope', 'Recipient', 'JournalEmailAddress') }
        @{ Area = 'Alerts.ProtectionAlerts';                  Cmdlet = 'Get-ProtectionAlert';              Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'Disabled', 'Category', 'Severity', 'ThreatType', 'Operation', 'NotifyUser', 'AggregationType') }
        @{ Area = 'Alerts.ActivityAlerts';                    Cmdlet = 'Get-ActivityAlert';                Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'Disabled', 'Type', 'Category', 'Operation', 'NotifyUser') }
        @{ Area = 'InformationBarriers.Policies';             Cmdlet = 'Get-InformationBarrierPolicy';     Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'State', 'AssignedSegment', 'SegmentsAllowed', 'SegmentsBlocked') }
        @{ Area = 'InformationBarriers.Segments';             Cmdlet = 'Get-OrganizationSegment';          Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'UserGroupFilter') }
        @{ Area = 'Classification.KeywordDictionaries';       Cmdlet = 'Get-DlpKeywordDictionary';         Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Identity', 'Description') }
        @{ Area = 'Governance.RoleGroups';                    Cmdlet = 'Get-RoleGroup';                    Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'RG-A'; Columns = @('Name', 'Guid', 'DisplayName', 'Description', 'Roles') }
        @{ Area = 'Governance.RoleGroupMembers';              Cmdlet = 'Get-RoleGroup';                    Key = @('RoleGroup', 'MemberName'); Count = 4; FirstProp = 'MemberName'; First = 'm-aa'; Columns = @('RoleGroup', 'MemberName', 'DisplayName', 'MemberGuid', 'RecipientType') }
        @{ Area = 'Legacy.HoldPolicies';                      Cmdlet = 'Get-HoldCompliancePolicy';         Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'Enabled', 'Mode', 'Workload') }
        @{ Area = 'Legacy.HoldRules';                         Cmdlet = 'Get-HoldComplianceRule';           Key = @('Guid', 'Policy', 'Name'); Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'Policy', 'Disabled', 'HoldContent', 'HoldDurationDisplayHint') }
        @{ Area = 'Legacy.ExchangeDlpPolicies';               Cmdlet = 'Get-DlpPolicy';                    Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'State', 'Mode', 'Description') }
        @{ Area = 'RetentionRecords.AppRetentionPolicies';    Cmdlet = 'Get-AppRetentionCompliancePolicy'; Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'Enabled', 'Mode', 'Applications') }
        @{ Area = 'RetentionRecords.AppRetentionRules';       Cmdlet = 'Get-AppRetentionComplianceRule';   Key = @('Guid', 'Policy', 'Name'); Count = 2; FirstProp = 'Name';       First = 'aa';   Columns = @('Name', 'Guid', 'Policy', 'RetentionDuration', 'RetentionComplianceAction', 'ExpirationDateOption') }
    )
    # Batch 3 Stop 2 area specs: the RBAC/licence-gated areas. AccessDenied
    # handling is the point - a role failure must classify, never read as Empty.
    $script:Stop2Specs = @(
        @{ Area = 'InsiderRisk.Policies';               Cmdlet = 'Get-InsiderRiskPolicy';           Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';           Columns = @('Name', 'Guid', 'InsiderRiskScenario') }
        @{ Area = 'CommunicationCompliance.Policies';   Cmdlet = 'Get-SupervisoryReviewPolicyV2';   Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';           Columns = @('Name', 'Guid', 'Enabled') }
        @{ Area = 'CommunicationCompliance.Rules';      Cmdlet = 'Get-SupervisoryReviewRule';       Key = @('Guid', 'Policy', 'Name'); Count = 2; FirstProp = 'Name';       First = 'aa';           Columns = @('Name', 'Guid', 'Policy', 'SamplingRate') }
        @{ Area = 'Ediscovery.Cases';                   Cmdlet = 'Get-ComplianceCase';              Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';           Columns = @('Name', 'Guid', 'CaseType', 'Status') }
        @{ Area = 'Ediscovery.CaseHoldPolicies';        Cmdlet = 'Get-CaseHoldPolicy';              Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'hp-aa';        Columns = @('Name', 'Guid', 'Enabled', 'Mode', 'CaseId') }
        @{ Area = 'Ediscovery.CaseHoldRules';           Cmdlet = 'Get-CaseHoldRule';                Key = @('Guid', 'Policy', 'Name'); Count = 2; FirstProp = 'Name';       First = 'rule-hp-aa';   Columns = @('Name', 'Guid', 'Policy', 'ContentMatchQuery') }
        @{ Area = 'Ediscovery.Searches';                Cmdlet = 'Get-ComplianceSearch';            Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';           Columns = @('Name', 'Guid', 'CaseName', 'ContentMatchQuery', 'Status') }
        @{ Area = 'Ediscovery.SecurityFilters';         Cmdlet = 'Get-ComplianceSecurityFilter';    Key = @('FilterName');             Count = 2; FirstProp = 'FilterName'; First = 'aa';           Columns = @('FilterName', 'Users', 'Filters', 'Action', 'Description') }
        @{ Area = 'Ediscovery.CaseAdmins';              Cmdlet = 'Get-eDiscoveryCaseAdmin';         Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';           Columns = @('Name', 'DisplayName') }
        @{ Area = 'InformationProtection.IrmConfig';    Cmdlet = 'Get-IRMConfiguration';            Key = @('Identity');               Count = 1; FirstProp = 'Identity';   First = 'ControlPoint'; Columns = @('AzureRMSLicensingEnabled', 'InternalLicensingEnabled', 'ExternalLicensingEnabled', 'JournalReportDecryptionEnabled', 'SimplifiedClientAccessEnabled', 'TransportDecryptionSetting') }
        @{ Area = 'InformationProtection.RmsTemplates'; Cmdlet = 'Get-RMSTemplate';                 Key = @('Guid', 'Name');           Count = 2; FirstProp = 'Name';       First = 'aa';           Columns = @('Name', 'Guid', 'Description', 'Type') }
    )
}

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path (Join-Path $repoRoot 'scripts') 'Invoke-PurviewSourceDiscovery.ps1'
    function Get-RunDir([string]$Root) {
        (Get-ChildItem -Path $Root -Directory -Filter 'PurviewSnapshot-*' -ErrorAction SilentlyContinue |
            Select-Object -First 1).FullName
    }
    function Read-Snapshot([string]$RunDir) {
        Get-Content -Raw (Join-Path $RunDir 'snapshot.json') | ConvertFrom-Json
    }
}

Describe 'Snapshot run - the full D9 status vocabulary end to end (integration)' {
    BeforeAll {
        # Stubs make four cmdlets resolvable; the mocks drive one status each.
        # Everything else stays absent -> CmdletNotAvailable. No
        # -IncludePurviewConfigZip -> the diagnostics area is NotAttempted.
        function Get-Label {}
        function Get-LabelPolicy {}
        function Get-AutoSensitivityLabelPolicy {}
        function Get-AutoSensitivityLabelRule {}
        Mock Get-Label {
            @([pscustomobject]@{ Guid = 'g-2'; Name = 'zeta';  DisplayName = 'Zeta' },
              [pscustomobject]@{ Guid = 'g-1'; Name = 'alpha'; DisplayName = 'Alpha' })
        }
        Mock Get-LabelPolicy { @() }
        Mock Get-AutoSensitivityLabelPolicy { throw 'Access is denied. Insufficient permissions.' }
        Mock Get-AutoSensitivityLabelRule { throw 'catastrophic parse error' }

        $script:Root = Join-Path $TestDrive 'statuses'
        & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:Root `
            -SnapshotLabel 'Baseline' -ReuseExistingSession *> $null
        $script:RunDir = Get-RunDir $script:Root
        $script:Snap = Read-Snapshot $script:RunDir
        $script:AreasByName = @{}
        foreach ($a in @($script:Snap.areas)) { $script:AreasByName[$a.area] = $a }
    }

    It 'writes snapshot.json with the frozen schema version' {
        $script:Snap.schemaVersion | Should -Be '1.0'
    }
    It 'rule areas declare documented composite stable keys (frozen at checkpoint)' {
        @($script:AreasByName['Dlp.Rules'].stableKeyProperties)                          | Should -Be @('Guid', 'ParentPolicyName', 'Name')
        @($script:AreasByName['InformationProtection.AutoLabelRules'].stableKeyProperties) | Should -Be @('Guid', 'ParentPolicyName', 'Name')
        @($script:AreasByName['RetentionRecords.Rules'].stableKeyProperties)             | Should -Be @('Guid', 'Policy', 'Name')
        @($script:AreasByName['InformationProtection.SensitivityLabels'].stableKeyProperties).Count | Should -Be 0
    }
    It 'Success: objects captured and ordered by stable key, not arrival order' {
        $a = $script:AreasByName['InformationProtection.SensitivityLabels']
        $a.status | Should -Be 'Success'
        $a.count  | Should -Be 2
        @($a.objects)[0].Guid | Should -Be 'g-1'
    }
    It 'Empty: envelope present with count 0' {
        $a = $script:AreasByName['InformationProtection.LabelPolicies']
        $a.status | Should -Be 'Empty'
        $a.count  | Should -Be 0
    }
    It 'AccessDenied is distinguished from Failed' {
        $script:AreasByName['InformationProtection.AutoLabelPolicies'].status | Should -Be 'AccessDenied'
        $script:AreasByName['InformationProtection.AutoLabelRules'].status   | Should -Be 'Failed'
    }
    It 'absent cmdlets record CmdletNotAvailable - including the former hand-rolled areas' {
        $script:AreasByName['Dlp.Policies'].status                    | Should -Be 'CmdletNotAvailable'
        $script:AreasByName['Classification.SitRulePackages'].status | Should -Be 'CmdletNotAvailable'
        $script:AreasByName['Classification.EdmSchemas'].status      | Should -Be 'CmdletNotAvailable'
    }
    It 'absent cmdlet records CmdletNotAvailable: <Area>' -ForEach $script:Stop1Specs {
        # No Stop-1 stubs exist in this run: every batch-3 area must record the
        # absence durably, never crash or vanish.
        $script:AreasByName[$Area].status | Should -Be 'CmdletNotAvailable'
    }
    It 'absent cmdlet records CmdletNotAvailable: <Area>' -ForEach $script:Stop2Specs {
        $script:AreasByName[$Area].status | Should -Be 'CmdletNotAvailable'
    }
    It 'the opt-in mailbox sweep records NotAttempted when its switch is absent (D12)' {
        $s = $script:AreasByName['Mailboxes.HoldSummary']
        $s.status | Should -Be 'NotAttempted'
        $s.error  | Should -Match 'IncludeMailboxHolds'
        $d = $script:AreasByName['Mailboxes.HoldDetail']
        $d.status | Should -Be 'NotAttempted'
    }
    It 'the opt-in diagnostics ZIP records NotAttempted when the switch is absent (D6)' {
        $a = $script:AreasByName['Diagnostics.PurviewConfigZip']
        $a.status       | Should -Be 'NotAttempted'
        $a.diffExcluded | Should -Be $true
    }
    It 'every area carries status + count, and every objects value serializes as an array' {
        @($script:Snap.areas).Count | Should -BeGreaterOrEqual 20
        foreach ($a in @($script:Snap.areas)) {
            "$($a.status)" | Should -Not -BeNullOrEmpty
            ($null -ne $a.count) | Should -BeTrue
        }
        $raw = Get-Content -Raw (Join-Path $script:RunDir 'snapshot.json')
        $m = [regex]::Matches($raw, '"objects":\s*(\S)')
        $m.Count | Should -Be @($script:Snap.areas).Count
        foreach ($x in $m) { $x.Groups[1].Value | Should -Be '[' }
    }
    It 'provenance records the run context with outcome Completed' {
        $p = $script:Snap.provenance
        $p.userPrincipalName | Should -Be 'tester@contoso.example'
        $p.outcome           | Should -Be 'Completed'
        $p.parameters.OutputRoot | Should -Not -BeNullOrEmpty
        # D11 renames: the engagement label lands in provenance, and the recorded
        # parameters carry the new name, not the migration-era one.
        $p.snapshotLabel | Should -Be 'Baseline'
        $paramNames = @($p.parameters.PSObject.Properties | ForEach-Object { $_.Name })
        $paramNames | Should -Contain 'UserPrincipalName'
        $paramNames | Should -Not -Contain 'SourceUpn'
        # Timestamps asserted on the raw JSON text: pwsh's ConvertFrom-Json converts
        # ISO-8601 strings to [datetime] (5.1 keeps strings), so the parsed value is
        # not engine-stable but the serialized document is.
        $raw = Get-Content -Raw (Join-Path $script:RunDir 'snapshot.json')
        $raw | Should -Match '"startedUtc":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z"'
        $raw | Should -Match '"endedUtc":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z"'
    }
    It 'embeds the volatile-field register (D9 diff support)' {
        @($script:Snap.volatileFields).Count | Should -BeGreaterThan 0
    }
    It 'writes the _manifest.csv status view derived from the envelopes' {
        $rows = @(Import-Csv (Join-Path $script:RunDir '_manifest.csv'))
        $rows.Count | Should -Be @($script:Snap.areas).Count
        @($rows | Where-Object { $_.Status -eq 'NotAttempted' }).Count | Should -BeGreaterOrEqual 1
    }
    It 'derives per-area CSV views from the snapshot with the frozen columns; unverified columns emit blank' {
        $vp = Join-Path (Join-Path $script:RunDir 'views') 'InformationProtection.SensitivityLabels.csv'
        Test-Path $vp | Should -BeTrue
        $rows = @(Import-Csv $vp)
        $rows.Count | Should -Be 2
        @($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) |
            Should -Be @('Name', 'Guid', 'DisplayName', 'ParentLabelDisplayName', 'Priority', 'ContentType', 'Disabled')
        $rows[0].Name | Should -Be 'alpha'
        $rows[0].DisplayName | Should -Be 'Alpha'
        $rows[0].ParentLabelDisplayName | Should -Be ''
    }
    It 'writes no view for areas without objects' {
        $views = Join-Path $script:RunDir 'views'
        Test-Path (Join-Path $views 'InformationProtection.LabelPolicies.csv')     | Should -BeFalse
        Test-Path (Join-Path $views 'InformationProtection.AutoLabelPolicies.csv') | Should -BeFalse
    }
    It 'emits nothing outside the snapshot, its derived views and the run logs' {
        @(Get-ChildItem -Path $script:RunDir -File -Recurse | Where-Object {
            $_.Name -notin @('snapshot.json', '_manifest.csv', '_transcript.log') -and
            $_.DirectoryName -notmatch '\\(views|sidecars)(\\|$)'
        }).Count | Should -Be 0
    }
}

Describe 'Export-Clixml is gone from the toolkit (D10)' {
    It 'no script or module references Export-Clixml' {
        $hits = @(Get-ChildItem -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts') -File |
            Where-Object { (Get-Content -Raw $_.FullName) -match 'Export-Clixml' })
        $hits.Count | Should -Be 0
    }
}

Describe 'Sidecar areas route through the wrapper (integration)' {
    BeforeAll {
        function Get-DlpSensitiveInformationTypeRulePackage {}
        Mock Get-DlpSensitiveInformationTypeRulePackage {
            @([pscustomobject]@{
                Identity = 'Contoso Rule Pack'
                SerializedClassificationRuleCollection = [System.Text.Encoding]::Unicode.GetBytes('<RulePackage>demo</RulePackage>')
            })
        }
        $script:Root2 = Join-Path $TestDrive 'sidecars'
        & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:Root2 -ReuseExistingSession *> $null
        $script:RunDir2 = Get-RunDir $script:Root2
        $script:Snap2 = Read-Snapshot $script:RunDir2
    }
    It 'writes the rule-pack XML sidecar and references it by relative forward-slash path' {
        $a = @($script:Snap2.areas) | Where-Object { $_.area -eq 'Classification.SitRulePackages' }
        $a.status | Should -Be 'Success'
        $a.count  | Should -Be 1
        $rel = @($a.sidecars)[0].path
        $rel | Should -Match '^sidecars/Classification\.SitRulePackages/.+\.xml$'
        $fsPath = Join-Path $script:RunDir2 ($rel -replace '/', '\')
        Test-Path $fsPath | Should -BeTrue
        (Get-Content -Raw $fsPath) | Should -Match '<RulePackage>demo</RulePackage>'
        @($a.objects)[0].SidecarPath | Should -Be $rel
    }
}

Describe 'Non-terminating cmdlet errors record failure statuses, never Empty (sandbox regression)' {
    BeforeAll {
        # Reproduces the sandbox defect: the EXO proxy module wrote
        # ErrorOnlyAllowInEopException as a NON-terminating error (its module session
        # state does not see the script's ErrorActionPreference='Stop'), and the area
        # recorded [Empty] 0 instead of a failure.
        function Get-DlpSensitiveInformationTypeRulePackage {}
        Mock Get-DlpSensitiveInformationTypeRulePackage {
            $ErrorActionPreference = 'Continue'
            Write-Error 'The operation is only allowed to run in Exchange Online Protection environment. (ErrorOnlyAllowInEopException)'
        }
        $script:Root4 = Join-Path $TestDrive 'eop'
        & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:Root4 -ReuseExistingSession *> $null
        $script:Snap4 = Read-Snapshot (Get-RunDir $script:Root4)
    }
    It 'the rule-package area records Failed with the EOP message, not Empty' {
        $a = @($script:Snap4.areas) | Where-Object { $_.area -eq 'Classification.SitRulePackages' }
        $a.status | Should -Be 'Failed'
        $a.count  | Should -Be 0
        $a.error  | Should -Match 'Exchange Online Protection'
    }
}

Describe 'Batch 3 Stop 1 areas - success path (stable keys + derived views)' {
    BeforeAll {
        # Uniform two-object sample: g1/aa must sort before g2/zz under every
        # declared composite key. Policy feeds the rule-area composites.
        function Get-RetentionPolicy {}
        function Get-RetentionPolicyTag {}
        function Get-JournalRule {}
        function Get-ProtectionAlert {}
        function Get-ActivityAlert {}
        function Get-InformationBarrierPolicy {}
        function Get-OrganizationSegment {}
        function Get-DlpKeywordDictionary {}
        function Get-HoldCompliancePolicy {}
        function Get-HoldComplianceRule {}
        function Get-DlpPolicy {}
        function Get-AppRetentionCompliancePolicy {}
        function Get-AppRetentionComplianceRule {}
        function Get-RoleGroup {}
        function Get-RoleGroupMember { param($Identity) }
        $uniform = {
            @([pscustomobject]@{ Guid = 'g2'; Name = 'zz'; Policy = 'P1' },
              [pscustomobject]@{ Guid = 'g1'; Name = 'aa'; Policy = 'P1' })
        }
        foreach ($c in @('Get-RetentionPolicy', 'Get-RetentionPolicyTag', 'Get-JournalRule',
                         'Get-ProtectionAlert', 'Get-ActivityAlert', 'Get-InformationBarrierPolicy',
                         'Get-OrganizationSegment', 'Get-DlpKeywordDictionary', 'Get-HoldCompliancePolicy',
                         'Get-HoldComplianceRule', 'Get-DlpPolicy', 'Get-AppRetentionCompliancePolicy',
                         'Get-AppRetentionComplianceRule')) {
            Mock -CommandName $c -MockWith $uniform
        }
        Mock Get-RoleGroup {
            @([pscustomobject]@{ Guid = 'g2'; Name = 'RG-B'; Identity = 'RG-B' },
              [pscustomobject]@{ Guid = 'g1'; Name = 'RG-A'; Identity = 'RG-A' })
        }
        Mock Get-RoleGroupMember {
            @([pscustomobject]@{ Name = 'm-zz'; DisplayName = 'M ZZ'; Guid = 'mg2'; RecipientType = 'UserMailbox' },
              [pscustomobject]@{ Name = 'm-aa'; DisplayName = 'M AA'; Guid = 'mg1'; RecipientType = 'Group' })
        }
        $script:S1Root = Join-Path $TestDrive 'stop1-success'
        & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:S1Root -ReuseExistingSession *> $null
        $script:S1RunDir = Get-RunDir $script:S1Root
        $script:S1Snap = Read-Snapshot $script:S1RunDir
        $script:S1AreasByName = @{}
        foreach ($a in @($script:S1Snap.areas)) { $script:S1AreasByName[$a.area] = $a }
    }
    It 'records Success in composite stable-key order: <Area>' -ForEach $script:Stop1Specs {
        $a = $script:S1AreasByName[$Area]
        $a.status | Should -Be 'Success'
        $a.count  | Should -Be $Count
        @($a.stableKeyProperties) | Should -Be $Key
        @($a.objects)[0].$FirstProp | Should -Be $First
    }
    It 'derives the view with the frozen columns: <Area>' -ForEach $script:Stop1Specs {
        $vp = Join-Path (Join-Path $script:S1RunDir 'views') ($Area + '.csv')
        Test-Path $vp | Should -BeTrue
        $rows = @(Import-Csv $vp)
        $rows.Count | Should -Be $Count
        @($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) | Should -Be $Columns
    }
    It 'role-group membership rows carry the group context (descriptor shape)' {
        $o = @($script:S1AreasByName['Governance.RoleGroupMembers'].objects)[0]
        $o.RoleGroup     | Should -Be 'RG-A'
        $o.MemberName    | Should -Be 'm-aa'
        $o.MemberGuid    | Should -Be 'mg1'
        $o.RecipientType | Should -Be 'Group'
    }
}

Describe 'Batch 3 Stop 1 areas - a role failure records AccessDenied, never Empty' {
    BeforeAll {
        function Get-RetentionPolicy {}
        function Get-RetentionPolicyTag {}
        function Get-JournalRule {}
        function Get-ProtectionAlert {}
        function Get-ActivityAlert {}
        function Get-InformationBarrierPolicy {}
        function Get-OrganizationSegment {}
        function Get-DlpKeywordDictionary {}
        function Get-HoldCompliancePolicy {}
        function Get-HoldComplianceRule {}
        function Get-DlpPolicy {}
        function Get-AppRetentionCompliancePolicy {}
        function Get-AppRetentionComplianceRule {}
        function Get-RoleGroup {}
        function Get-RoleGroupMember { param($Identity) }
        $denied = { throw 'Access is denied. Check role assignments.' }
        foreach ($c in @('Get-RetentionPolicy', 'Get-RetentionPolicyTag', 'Get-JournalRule',
                         'Get-ProtectionAlert', 'Get-ActivityAlert', 'Get-InformationBarrierPolicy',
                         'Get-OrganizationSegment', 'Get-DlpKeywordDictionary', 'Get-HoldCompliancePolicy',
                         'Get-HoldComplianceRule', 'Get-DlpPolicy', 'Get-AppRetentionCompliancePolicy',
                         'Get-AppRetentionComplianceRule', 'Get-RoleGroup', 'Get-RoleGroupMember')) {
            Mock -CommandName $c -MockWith $denied
        }
        $script:S1DRoot = Join-Path $TestDrive 'stop1-denied'
        & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:S1DRoot -ReuseExistingSession *> $null
        $script:S1DSnap = Read-Snapshot (Get-RunDir $script:S1DRoot)
        $script:S1DAreasByName = @{}
        foreach ($a in @($script:S1DSnap.areas)) { $script:S1DAreasByName[$a.area] = $a }
    }
    It 'records AccessDenied: <Area>' -ForEach $script:Stop1Specs {
        $a = $script:S1DAreasByName[$Area]
        $a.status | Should -Be 'AccessDenied'
        $a.count  | Should -Be 0
    }
}

Describe 'Batch 3 Stop 1 areas - a quiet tenant records Empty (valid negative evidence)' {
    BeforeAll {
        function Get-RetentionPolicy {}
        function Get-RetentionPolicyTag {}
        function Get-JournalRule {}
        function Get-ProtectionAlert {}
        function Get-ActivityAlert {}
        function Get-InformationBarrierPolicy {}
        function Get-OrganizationSegment {}
        function Get-DlpKeywordDictionary {}
        function Get-HoldCompliancePolicy {}
        function Get-HoldComplianceRule {}
        function Get-DlpPolicy {}
        function Get-AppRetentionCompliancePolicy {}
        function Get-AppRetentionComplianceRule {}
        function Get-RoleGroup {}
        function Get-RoleGroupMember { param($Identity) }
        $none = { @() }
        foreach ($c in @('Get-RetentionPolicy', 'Get-RetentionPolicyTag', 'Get-JournalRule',
                         'Get-ProtectionAlert', 'Get-ActivityAlert', 'Get-InformationBarrierPolicy',
                         'Get-OrganizationSegment', 'Get-DlpKeywordDictionary', 'Get-HoldCompliancePolicy',
                         'Get-HoldComplianceRule', 'Get-DlpPolicy', 'Get-AppRetentionCompliancePolicy',
                         'Get-AppRetentionComplianceRule', 'Get-RoleGroup', 'Get-RoleGroupMember')) {
            Mock -CommandName $c -MockWith $none
        }
        $script:S1ERoot = Join-Path $TestDrive 'stop1-empty'
        & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:S1ERoot -ReuseExistingSession *> $null
        $script:S1ESnap = Read-Snapshot (Get-RunDir $script:S1ERoot)
        $script:S1EAreasByName = @{}
        foreach ($a in @($script:S1ESnap.areas)) { $script:S1EAreasByName[$a.area] = $a }
    }
    It 'records Empty with count 0: <Area>' -ForEach $script:Stop1Specs {
        $a = $script:S1EAreasByName[$Area]
        $a.status | Should -Be 'Empty'
        $a.count  | Should -Be 0
    }
}

Describe 'Batch 3 Stop 2 areas - success path (gated areas, stable keys + views)' {
    BeforeAll {
        function Get-InsiderRiskPolicy {}
        function Get-SupervisoryReviewPolicyV2 {}
        function Get-SupervisoryReviewRule {}
        function Get-ComplianceCase { param($CaseType) }
        function Get-CaseHoldPolicy { param($Case) }
        function Get-CaseHoldRule { param($Policy) }
        function Get-ComplianceSearch {}
        function Get-ComplianceSecurityFilter {}
        function Get-eDiscoveryCaseAdmin {}
        function Get-IRMConfiguration {}
        function Get-RMSTemplate {}
        $uniform = {
            @([pscustomobject]@{ Guid = 'g2'; Name = 'zz'; Policy = 'P1' },
              [pscustomobject]@{ Guid = 'g1'; Name = 'aa'; Policy = 'P1' })
        }
        foreach ($c in @('Get-InsiderRiskPolicy', 'Get-SupervisoryReviewPolicyV2', 'Get-SupervisoryReviewRule',
                         'Get-ComplianceSearch', 'Get-eDiscoveryCaseAdmin', 'Get-RMSTemplate')) {
            Mock -CommandName $c -MockWith $uniform
        }
        # Both case types are enumerated; only the core type has cases here.
        Mock Get-ComplianceCase {
            if ($CaseType -eq 'eDiscovery') {
                @([pscustomobject]@{ Guid = 'g2'; Name = 'zz'; Identity = 'zz'; CaseType = 'eDiscovery' },
                  [pscustomobject]@{ Guid = 'g1'; Name = 'aa'; Identity = 'aa'; CaseType = 'eDiscovery' })
            } else { @() }
        }
        Mock Get-CaseHoldPolicy {
            ,([pscustomobject]@{ Guid = "g-$Case"; Name = "hp-$Case"; Enabled = $true; Mode = 'Enforce' })
        }
        Mock Get-CaseHoldRule {
            ,([pscustomobject]@{ Guid = "r-$Policy"; Name = "rule-$Policy"; Policy = "$Policy" })
        }
        Mock Get-ComplianceSecurityFilter {
            @([pscustomobject]@{ FilterName = 'zz'; Action = 'All' },
              [pscustomobject]@{ FilterName = 'aa'; Action = 'All' })
        }
        Mock Get-IRMConfiguration {
            ,([pscustomobject]@{ Identity = 'ControlPoint'; AzureRMSLicensingEnabled = $true })
        }
        $script:S2Root = Join-Path $TestDrive 'stop2-success'
        & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:S2Root -ReuseExistingSession *> $null
        $script:S2RunDir = Get-RunDir $script:S2Root
        $script:S2Snap = Read-Snapshot $script:S2RunDir
        $script:S2AreasByName = @{}
        foreach ($a in @($script:S2Snap.areas)) { $script:S2AreasByName[$a.area] = $a }
    }
    It 'records Success in composite stable-key order: <Area>' -ForEach $script:Stop2Specs {
        $a = $script:S2AreasByName[$Area]
        $a.status | Should -Be 'Success'
        $a.count  | Should -Be $Count
        @($a.stableKeyProperties) | Should -Be $Key
        @($a.objects)[0].$FirstProp | Should -Be $First
    }
    It 'derives the view with the frozen columns: <Area>' -ForEach $script:Stop2Specs {
        $vp = Join-Path (Join-Path $script:S2RunDir 'views') ($Area + '.csv')
        Test-Path $vp | Should -BeTrue
        $rows = @(Import-Csv $vp)
        $rows.Count | Should -Be $Count
        @($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) | Should -Be $Columns
    }
    It 'case holds enumerate per case and keep the policy linkage' {
        $p = @($script:S2AreasByName['Ediscovery.CaseHoldPolicies'].objects)
        @($p | ForEach-Object { $_.Name }) | Should -Be @('hp-aa', 'hp-zz')
        $r = @($script:S2AreasByName['Ediscovery.CaseHoldRules'].objects)
        $r[0].Policy | Should -Be 'hp-aa'
    }
}

Describe 'Batch 3 Stop 2 areas - a gated role failure records AccessDenied, never Empty' {
    BeforeAll {
        function Get-InsiderRiskPolicy {}
        function Get-SupervisoryReviewPolicyV2 {}
        function Get-SupervisoryReviewRule {}
        function Get-ComplianceCase { param($CaseType) }
        function Get-CaseHoldPolicy { param($Case) }
        function Get-CaseHoldRule { param($Policy) }
        function Get-ComplianceSearch {}
        function Get-ComplianceSecurityFilter {}
        function Get-eDiscoveryCaseAdmin {}
        function Get-IRMConfiguration {}
        function Get-RMSTemplate {}
        $denied = { throw 'Access is denied. A role assignment is required to read this configuration.' }
        foreach ($c in @('Get-InsiderRiskPolicy', 'Get-SupervisoryReviewPolicyV2', 'Get-SupervisoryReviewRule',
                         'Get-ComplianceCase', 'Get-CaseHoldPolicy', 'Get-CaseHoldRule', 'Get-ComplianceSearch',
                         'Get-ComplianceSecurityFilter', 'Get-eDiscoveryCaseAdmin', 'Get-IRMConfiguration',
                         'Get-RMSTemplate')) {
            Mock -CommandName $c -MockWith $denied
        }
        # One gated area exercises the 5b path: the role failure arrives as a
        # NON-terminating error (EXO proxy-module mechanism), not a throw.
        Mock Get-InsiderRiskPolicy {
            $ErrorActionPreference = 'Continue'
            Write-Error 'Access is denied. A role assignment is required to read this configuration.'
        }
        # -IncludeMailboxHolds is ON here but Get-EXOMailbox is absent: the sweep
        # must record the missing cmdlet, and detail stays NotAttempted.
        $script:S2DRoot = Join-Path $TestDrive 'stop2-denied'
        & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:S2DRoot `
            -IncludeMailboxHolds -ReuseExistingSession *> $null
        $script:S2DSnap = Read-Snapshot (Get-RunDir $script:S2DRoot)
        $script:S2DAreasByName = @{}
        foreach ($a in @($script:S2DSnap.areas)) { $script:S2DAreasByName[$a.area] = $a }
    }
    It 'records AccessDenied: <Area>' -ForEach $script:Stop2Specs {
        $a = $script:S2DAreasByName[$Area]
        $a.status | Should -Be 'AccessDenied'
        $a.count  | Should -Be 0
    }
    It 'a gated non-terminating role error also classifies AccessDenied (EXO proxy mechanism)' {
        # Belt and braces for the gated set: the 5b error-stream path, not a throw.
        $a = $script:S2DAreasByName['InsiderRisk.Policies']
        $a.error | Should -Match '(?i)role assignment'
    }
    It 'the enabled mailbox sweep without the cmdlet records CmdletNotAvailable; detail stays NotAttempted' {
        $script:S2DAreasByName['Mailboxes.HoldSummary'].status | Should -Be 'CmdletNotAvailable'
        $script:S2DAreasByName['Mailboxes.HoldDetail'].status  | Should -Be 'NotAttempted'
    }
}

Describe 'Batch 3 Stop 2 areas - a quiet tenant records Empty (valid negative evidence)' {
    BeforeAll {
        function Get-InsiderRiskPolicy {}
        function Get-SupervisoryReviewPolicyV2 {}
        function Get-SupervisoryReviewRule {}
        function Get-ComplianceCase { param($CaseType) }
        function Get-CaseHoldPolicy { param($Case) }
        function Get-CaseHoldRule { param($Policy) }
        function Get-ComplianceSearch {}
        function Get-ComplianceSecurityFilter {}
        function Get-eDiscoveryCaseAdmin {}
        function Get-IRMConfiguration {}
        function Get-RMSTemplate {}
        $none = { @() }
        foreach ($c in @('Get-InsiderRiskPolicy', 'Get-SupervisoryReviewPolicyV2', 'Get-SupervisoryReviewRule',
                         'Get-ComplianceCase', 'Get-CaseHoldPolicy', 'Get-CaseHoldRule', 'Get-ComplianceSearch',
                         'Get-ComplianceSecurityFilter', 'Get-eDiscoveryCaseAdmin', 'Get-IRMConfiguration',
                         'Get-RMSTemplate')) {
            Mock -CommandName $c -MockWith $none
        }
        $script:S2ERoot = Join-Path $TestDrive 'stop2-empty'
        & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:S2ERoot -ReuseExistingSession *> $null
        $script:S2ESnap = Read-Snapshot (Get-RunDir $script:S2ERoot)
        $script:S2EAreasByName = @{}
        foreach ($a in @($script:S2ESnap.areas)) { $script:S2EAreasByName[$a.area] = $a }
    }
    It 'records Empty with count 0: <Area>' -ForEach $script:Stop2Specs {
        $a = $script:S2EAreasByName[$Area]
        $a.status | Should -Be 'Empty'
        $a.count  | Should -Be 0
    }
}

Describe 'Opt-in mailbox sweep (D12: off by default, aggregate-first)' {
    BeforeAll {
        function Get-EXOMailbox { param($ResultSize, $Properties) }
        Mock Get-EXOMailbox {
            @([pscustomobject]@{ UserPrincipalName = 'u1@contoso.example'; LitigationHoldEnabled = $true
                                 InPlaceHolds = @('hold1'); ComplianceTagHoldApplied = $false; DelayHoldApplied = $false
                                 RetentionHoldEnabled = $true; RetentionPolicy = 'Default MRM Policy'; AuditEnabled = $true },
              [pscustomobject]@{ UserPrincipalName = 'u2@contoso.example'; LitigationHoldEnabled = $true
                                 InPlaceHolds = @(); ComplianceTagHoldApplied = $false; DelayHoldApplied = $false
                                 RetentionHoldEnabled = $false; RetentionPolicy = 'Default MRM Policy'; AuditEnabled = $true },
              [pscustomobject]@{ UserPrincipalName = 'u3@contoso.example'; LitigationHoldEnabled = $false
                                 InPlaceHolds = @(); ComplianceTagHoldApplied = $true; DelayHoldApplied = $false
                                 RetentionHoldEnabled = $false; RetentionPolicy = $null; AuditEnabled = $false })
        }
        $script:MbRoot = Join-Path $TestDrive 'mbx-aggregate'
        & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:MbRoot `
            -IncludeMailboxHolds -ReuseExistingSession *> $null
        $script:MbRunDir = Get-RunDir $script:MbRoot
        $script:MbSnap = Read-Snapshot $script:MbRunDir
        $script:MbAreas = @{}
        foreach ($a in @($script:MbSnap.areas)) { $script:MbAreas[$a.area] = $a }
        function Get-SummaryCount([string]$Metric, [string]$Value) {
            $row = @($script:MbAreas['Mailboxes.HoldSummary'].objects) |
                Where-Object { $_.Metric -eq $Metric -and $_.Value -eq $Value }
            [int]$row.Mailboxes
        }
    }
    It 'aggregates hold state as counts, keyed Metric|Value' {
        $a = $script:MbAreas['Mailboxes.HoldSummary']
        $a.status | Should -Be 'Success'
        @($a.stableKeyProperties) | Should -Be @('Metric', 'Value')
        Get-SummaryCount 'TotalMailboxes' 'All'            | Should -Be 3
        Get-SummaryCount 'LitigationHoldEnabled' 'True'    | Should -Be 2
        Get-SummaryCount 'LitigationHoldEnabled' 'False'   | Should -Be 1
        Get-SummaryCount 'HasInPlaceHolds' 'True'          | Should -Be 1
        Get-SummaryCount 'RetentionHoldEnabled' 'True'     | Should -Be 1
        Get-SummaryCount 'ComplianceTagHoldApplied' 'True' | Should -Be 1
        Get-SummaryCount 'AuditEnabled' 'False'            | Should -Be 1
        Get-SummaryCount 'RetentionPolicy' 'Default MRM Policy' | Should -Be 2
        Get-SummaryCount 'RetentionPolicy' '(none)'        | Should -Be 1
    }
    It 'the aggregate puts no user principal names into evidence' {
        foreach ($o in @($script:MbAreas['Mailboxes.HoldSummary'].objects)) {
            @($o.PSObject.Properties | ForEach-Object { $_.Name }) | Should -Be @('Metric', 'Value', 'Mailboxes')
        }
        $raw = Get-Content -Raw (Join-Path $script:MbRunDir 'snapshot.json')
        $raw | Should -Not -Match 'u1@contoso\.example'
    }
    It 'per-mailbox detail stays NotAttempted without -MailboxDetail' {
        $script:MbAreas['Mailboxes.HoldDetail'].status | Should -Be 'NotAttempted'
        $script:MbAreas['Mailboxes.HoldDetail'].error  | Should -Match 'MailboxDetail'
    }
}

Describe 'Opt-in mailbox sweep - per-mailbox detail (second switch)' {
    BeforeAll {
        function Get-EXOMailbox { param($ResultSize, $Properties) }
        Mock Get-EXOMailbox {
            @([pscustomobject]@{ UserPrincipalName = 'u2@contoso.example'; LitigationHoldEnabled = $true
                                 InPlaceHolds = @(); ComplianceTagHoldApplied = $false; DelayHoldApplied = $false
                                 RetentionHoldEnabled = $false; RetentionPolicy = 'Default MRM Policy'; AuditEnabled = $true },
              [pscustomobject]@{ UserPrincipalName = 'u1@contoso.example'; LitigationHoldEnabled = $true
                                 InPlaceHolds = @('hold1'); ComplianceTagHoldApplied = $false; DelayHoldApplied = $false
                                 RetentionHoldEnabled = $true; RetentionPolicy = 'Default MRM Policy'; AuditEnabled = $true })
        }
        $script:MbDRoot = Join-Path $TestDrive 'mbx-detail'
        & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:MbDRoot `
            -IncludeMailboxHolds -MailboxDetail -ReuseExistingSession *> $null
        $script:MbDRunDir = Get-RunDir $script:MbDRoot
        $script:MbDSnap = Read-Snapshot $script:MbDRunDir
        $script:MbDAreas = @{}
        foreach ($a in @($script:MbDSnap.areas)) { $script:MbDAreas[$a.area] = $a }
    }
    It 'emits per-mailbox rows keyed by UserPrincipalName, and the aggregate too' {
        $d = $script:MbDAreas['Mailboxes.HoldDetail']
        $d.status | Should -Be 'Success'
        $d.count  | Should -Be 2
        @($d.stableKeyProperties) | Should -Be @('UserPrincipalName')
        @($d.objects)[0].UserPrincipalName | Should -Be 'u1@contoso.example'
        $script:MbDAreas['Mailboxes.HoldSummary'].status | Should -Be 'Success'
    }
    It 'derives the detail view with the frozen columns' {
        $vp = Join-Path (Join-Path $script:MbDRunDir 'views') 'Mailboxes.HoldDetail.csv'
        Test-Path $vp | Should -BeTrue
        $rows = @(Import-Csv $vp)
        @($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) |
            Should -Be @('UserPrincipalName', 'LitigationHoldEnabled', 'RetentionHoldEnabled', 'ComplianceTagHoldApplied', 'DelayHoldApplied', 'InPlaceHolds', 'RetentionPolicy', 'AuditEnabled')
        ($rows | Where-Object { $_.UserPrincipalName -eq 'u1@contoso.example' }).InPlaceHolds | Should -Be 'hold1'
    }
}

Describe 'Crash safety - a terminating error mid-run still yields snapshot + manifest + closed transcript' {
    BeforeAll {
        # Simulated top-level failure at the first Audit-area progress line: every
        # earlier area envelope is already collected when the throw happens. (Seam is
        # the area NAME, not a folder name, so later renames do not invalidate it.)
        Mock Write-Host { throw 'Simulated console failure' } -ParameterFilter { "$Object" -like '*Audit.UnifiedAuditIngestion*' }

        $script:Root3 = Join-Path $TestDrive 'crash'
        $script:Threw = $false
        try {
            & $script:ScriptPath -UserPrincipalName 'tester@contoso.example' -OutputRoot $script:Root3 -ReuseExistingSession *> $null
        } catch {
            $script:Threw = $true
        }
        $script:RunDir3 = Get-RunDir $script:Root3
    }
    AfterAll {
        # If the script leaked a running transcript (pre-fix behaviour), close it so
        # TestDrive cleanup is not blocked.
        try { Stop-Transcript | Out-Null } catch { }
    }
    It 'the simulated failure escapes the run (precondition)' {
        $script:Threw | Should -BeTrue
    }
    It 'snapshot.json exists with outcome Aborted and the areas collected so far' {
        Test-Path (Join-Path $script:RunDir3 'snapshot.json') | Should -BeTrue
        $snap = Read-Snapshot $script:RunDir3
        $snap.provenance.outcome | Should -Be 'Aborted'
        @($snap.areas).Count | Should -BeGreaterThan 0
    }
    It 'still writes the _manifest.csv status view' {
        Test-Path (Join-Path $script:RunDir3 '_manifest.csv') | Should -BeTrue
        @(Import-Csv (Join-Path $script:RunDir3 '_manifest.csv')).Count | Should -BeGreaterThan 0
    }
    It 'stops the transcript (end marker present in _transcript.log)' {
        $t = Join-Path $script:RunDir3 '_transcript.log'
        Test-Path $t | Should -BeTrue
        (Get-Content $t -Raw) | Should -Match '(?i)transcript end'
    }
}
