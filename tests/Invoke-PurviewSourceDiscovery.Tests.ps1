# Pester v5 offline tests for scripts/Invoke-PurviewSourceDiscovery.ps1 ("A").
#
# Fully offline: -ReuseExistingSession skips Connect-*, Import-Module is mocked, and
# the SCC/EXO cmdlets are absent in the test session, so the wrapper's Get-Command
# guard records CmdletNotAvailable rows without touching any tenant.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path (Join-Path $repoRoot 'scripts') 'Invoke-PurviewSourceDiscovery.ps1'
}

Describe 'Crash safety - a terminating error mid-run still yields manifest + closed transcript' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        # Simulated I/O failure at the 5-Audit area folder: New-Item there runs outside
        # Export-Artifact's try/catch, so it is a terminating error that escapes the
        # wrapper mid-run (sections 1-4 have already written manifest rows by then).
        Mock New-Item { throw 'Simulated I/O failure' } -ParameterFilter { "$Path" -like '*5-Audit*' }

        $script:Root = Join-Path $TestDrive 'crash'
        $script:ThrewAsExpected = $false
        try {
            & $script:ScriptPath -SourceUpn 'tester@contoso.example' -OutputRoot $script:Root -ReuseExistingSession *> $null
        } catch {
            $script:ThrewAsExpected = $true
        }
        $script:RunDir = (Get-ChildItem -Path $script:Root -Directory -Filter 'SourceDiscovery-*' -ErrorAction SilentlyContinue |
            Select-Object -First 1).FullName
    }
    AfterAll {
        # If the script leaked a running transcript (the pre-fix behaviour), close it so
        # TestDrive cleanup is not blocked by an open file handle.
        try { Stop-Transcript | Out-Null } catch { }
    }

    It 'the simulated failure escapes the run (precondition)' {
        $script:ThrewAsExpected | Should -BeTrue
    }
    It 'still writes _manifest.csv with the rows collected before the failure' {
        Test-Path (Join-Path $script:RunDir '_manifest.csv') | Should -BeTrue
        @(Import-Csv (Join-Path $script:RunDir '_manifest.csv')).Count | Should -BeGreaterThan 0
    }
    It 'stops the transcript (end marker present in _transcript.log)' {
        $t = Join-Path $script:RunDir '_transcript.log'
        Test-Path $t | Should -BeTrue
        (Get-Content $t -Raw) | Should -Match '(?i)transcript end'
    }
}

Describe 'Export-Artifact status paths (characterization; D9 keeps these statuses)' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }

        # Stubs so the wrapper's Get-Command guard resolves these three; the mocks then
        # drive one status path each. Every other SCC/EXO cmdlet stays absent in this
        # session, exercising the CmdletNotAvailable path.
        function Get-Label {}
        function Get-LabelPolicy {}
        function Get-AutoSensitivityLabelPolicy {}
        Mock Get-Label {
            @([pscustomobject]@{ DisplayName = 'L1'; Name = 'l1'; Guid = 'g-1' },
              [pscustomobject]@{ DisplayName = 'L2'; Name = 'l2'; Guid = 'g-2' })
        }
        Mock Get-LabelPolicy { @() }
        Mock Get-AutoSensitivityLabelPolicy { throw 'Simulated access denied' }

        $root = Join-Path $TestDrive 'status'
        & $script:ScriptPath -SourceUpn 'tester@contoso.example' -OutputRoot $root -ReuseExistingSession *> $null
        $runDir = (Get-ChildItem -Path $root -Directory -Filter 'SourceDiscovery-*' | Select-Object -First 1).FullName
        $script:Rows = @(Import-Csv (Join-Path $runDir '_manifest.csv'))
    }

    It 'a cmdlet returning objects records Success with the object count and an artifact file' {
        $row = $script:Rows | Where-Object { $_.Artifact -eq 'SensitivityLabels' }
        $row.Status | Should -Be 'Success'
        $row.Count  | Should -Be 2
        Test-Path $row.File | Should -BeTrue
    }
    It 'a cmdlet returning nothing records Empty with count 0 and no file' {
        $row = $script:Rows | Where-Object { $_.Artifact -eq 'LabelPolicies' }
        $row.Status | Should -Be 'Empty'
        $row.Count  | Should -Be 0
        $row.File   | Should -BeNullOrEmpty
    }
    It 'a throwing cmdlet records Failed with the exception message' {
        $row = $script:Rows | Where-Object { $_.Artifact -eq 'AutoLabelPolicies' }
        $row.Status | Should -Match '^Failed: Simulated access denied'
        $row.Count  | Should -Be 0
    }
    It 'an absent cmdlet records CmdletNotAvailable' {
        $row = $script:Rows | Where-Object { $_.Artifact -eq 'DlpPolicies' }
        $row.Status | Should -Be 'CmdletNotAvailable'
    }
}
