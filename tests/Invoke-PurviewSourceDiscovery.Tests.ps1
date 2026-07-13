# Pester v5 offline tests for scripts/Invoke-PurviewSourceDiscovery.ps1 ("A").
#
# Fully offline: -ReuseExistingSession short-circuits the connect (no module import,
# no tenant), and the SCC/EXO cmdlets are absent in this session unless stubbed, so
# the wrapper's CommandNotFound handling records CmdletNotAvailable without touching
# any tenant. Collect blocks are bound to the script session, so stubs + mocks work.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path (Join-Path $repoRoot 'scripts') 'Invoke-PurviewSourceDiscovery.ps1'
    function Get-RunDir([string]$Root) {
        (Get-ChildItem -Path $Root -Directory -Filter 'SourceDiscovery-*' -ErrorAction SilentlyContinue |
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
        & $script:ScriptPath -SourceUpn 'tester@contoso.example' -OutputRoot $script:Root -ReuseExistingSession *> $null
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
    It 'emits no per-area JSON/CSV/CLIXML artifacts - the snapshot is the source of truth' {
        @(Get-ChildItem -Path $script:RunDir -File -Recurse |
            Where-Object { $_.Name -notin @('snapshot.json', '_manifest.csv', '_transcript.log') }).Count | Should -Be 0
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
        & $script:ScriptPath -SourceUpn 'tester@contoso.example' -OutputRoot $script:Root2 -ReuseExistingSession *> $null
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
        & $script:ScriptPath -SourceUpn 'tester@contoso.example' -OutputRoot $script:Root4 -ReuseExistingSession *> $null
        $script:Snap4 = Read-Snapshot (Get-RunDir $script:Root4)
    }
    It 'the rule-package area records Failed with the EOP message, not Empty' {
        $a = @($script:Snap4.areas) | Where-Object { $_.area -eq 'Classification.SitRulePackages' }
        $a.status | Should -Be 'Failed'
        $a.count  | Should -Be 0
        $a.error  | Should -Match 'Exchange Online Protection'
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
            & $script:ScriptPath -SourceUpn 'tester@contoso.example' -OutputRoot $script:Root3 -ReuseExistingSession *> $null
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
