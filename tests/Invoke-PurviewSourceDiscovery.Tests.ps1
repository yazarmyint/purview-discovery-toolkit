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
