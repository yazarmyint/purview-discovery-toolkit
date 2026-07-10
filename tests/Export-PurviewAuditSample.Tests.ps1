# Pester v5 characterization + regression suite for scripts/Export-PurviewAuditSample.ps1 ("C").
#
# Runs fully offline: the Exchange Online cmdlets are stubbed so they can be mocked, and
# Search-UnifiedAuditLog is replaced with a fake that returns synthetic audit rows and honours
# ReturnLargeSet paging (returns once per SessionId, then empty to terminate the page loop).
#
# Legend:
#   [green] locks correct current behaviour (windowing, dedup, DLP parse, no-spurious-cap)
#   [RED]   encodes an audit bug as a failing test today; flips green once the fix lands
#           - S1: a malformed/empty/null AuditData row must not terminate the run
#           - S2: later days must be represented when MaxPerDay is small (per-day, not global, budget)
#
# The read-only AST guard lives in ReadOnlyInvariant.Tests.ps1 (covers all scripts).

BeforeAll {
    # Nested Join-Path (multi-argument Join-Path is PS 6.2+; the suite runs on 5.1 too, D8).
    $script:ScriptPath = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts') 'Export-PurviewAuditSample.ps1'

    # Stubs so the EXO cmdlets exist as commands for Mock to hook (the module is never loaded).
    function Connect-ExchangeOnline { param([string]$UserPrincipalName, [switch]$ShowBanner) }
    function Search-UnifiedAuditLog {
        param(
            [datetime]$StartDate, [datetime]$EndDate, [string]$RecordType, [switch]$Formatted,
            [string]$SessionId, [string]$SessionCommand, [int]$ResultSize
        )
    }

    # Build a fake formatted audit record. $AuditData may be a hashtable (-> JSON), a raw string, or $null.
    function New-FakeRec {
        param([string]$Id, [string]$RecordType = 'DLPEndpoint', $AuditData, [datetime]$Created)
        if (-not $Created) { $Created = (Get-Date).ToUniversalTime() }
        $ad = if (($AuditData -is [string]) -or ($null -eq $AuditData)) { $AuditData }
              else { $AuditData | ConvertTo-Json -Depth 8 }
        [pscustomobject]@{ Identity = $Id; CreationDate = $Created; RecordType = $RecordType; AuditData = $ad }
    }

    # A valid DLP AuditData payload (exercises PolicyName + SIT extraction in Expand-AuditRow).
    function New-DlpAuditData {
        param([string]$Policy = 'PCI-DSS Cardholder Data', [string]$Sit = 'Credit Card Number', [string]$User = 'alice@contoso.example')
        @{
            Operation = 'DLPRuleMatch'; UserId = $User; Workload = 'Exchange'; ObjectId = 'msg-0001'
            PolicyDetails = @(@{ PolicyName = $Policy; Rules = @(@{ ConditionsMatched = @{ SensitiveInformation = @(@{ SensitiveInformationTypeName = $Sit }) } }) })
        }
    }

    function Get-SampleDir { param([string]$Root) (Get-ChildItem -Path $Root -Directory -Filter 'AuditSample-*' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }

    # Invoke script C in an isolated child scope (via &) so its $ErrorActionPreference='Stop'
    # and functions don't leak into the test session. Mocks still apply (same session state).
    function Invoke-C {
        param([string]$Root, [string[]]$RecordTypes, [int]$DaysBack = 1, [int]$MaxPerDay = 5000)
        & $script:ScriptPath -SourceUpn 'tester@contoso.example' -OutputRoot $Root `
            -RecordTypes $RecordTypes -DaysBack $DaysBack -MaxPerDay $MaxPerDay -ReuseExistingSession *> $null
    }

    function New-Root { Join-Path $TestDrive ([guid]::NewGuid()) }
}

Describe 'Expand-AuditRow (JSON parse paths)' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Connect-ExchangeOnline {}
        Mock Search-UnifiedAuditLog { @() }
        $eap = $ErrorActionPreference
        # Dot-source once (body is a no-op with an empty Search) to bring Expand-AuditRow into scope.
        . $script:ScriptPath -SourceUpn 'x@y.example' -OutputRoot (Join-Path $TestDrive 'ds') `
            -RecordTypes @('DLPEndpoint') -DaysBack 1 -ReuseExistingSession *> $null
        $script:ExpandFn = ${function:Expand-AuditRow}
        $ErrorActionPreference = $eap
    }

    It '[green] extracts core fields + policy + SIT from a valid DLP record' {
        $rec = New-FakeRec -Id 'r1' -RecordType 'DLPEndpoint' -AuditData (New-DlpAuditData -Policy 'PCI' -Sit 'Credit Card Number' -User 'alice@contoso.example')
        $row = & $script:ExpandFn $rec 'DLPEndpoint'
        $row.Operation  | Should -Be 'DLPRuleMatch'
        $row.UserId     | Should -Be 'alice@contoso.example'
        $row.Workload   | Should -Be 'Exchange'
        $row.PolicyName | Should -Be 'PCI'
        $row.SitName    | Should -Be 'Credit Card Number'
    }
    It '[green] leaves policy/SIT empty for a non-DLP record' {
        $rec = New-FakeRec -Id 'r2' -RecordType 'MIPLabel' -AuditData @{ Operation = 'SensitivityLabelApplied'; UserId = 'bob@contoso.example'; Workload = 'SharePoint'; ObjectId = 'file-9' }
        $row = & $script:ExpandFn $rec 'MIPLabel'
        $row.Operation  | Should -Be 'SensitivityLabelApplied'
        $row.PolicyName | Should -BeNullOrEmpty
        $row.SitName    | Should -BeNullOrEmpty
    }

    # Run under EAP='Stop' to mirror the script; today ConvertFrom-Json terminates on bad input.
    Context 'S1 - malformed / empty / null AuditData must not terminate (EAP=Stop, as in the script)' {
        It '[RED->green after S1] non-JSON AuditData does not throw' {
            $ErrorActionPreference = 'Stop'
            $rec = New-FakeRec -Id 'bad' -RecordType 'DLPEndpoint' -AuditData '<<< not json >>>'
            { & $script:ExpandFn $rec 'DLPEndpoint' } | Should -Not -Throw
        }
        It '[RED->green after S1] empty-string AuditData does not throw' {
            $ErrorActionPreference = 'Stop'
            $rec = New-FakeRec -Id 'empty' -RecordType 'DLPEndpoint' -AuditData ''
            { & $script:ExpandFn $rec 'DLPEndpoint' } | Should -Not -Throw
        }
        It '[RED->green after S1] null AuditData does not throw' {
            $ErrorActionPreference = 'Stop'
            $rec = New-FakeRec -Id 'null' -RecordType 'DLPEndpoint' -AuditData $null
            { & $script:ExpandFn $rec 'DLPEndpoint' } | Should -Not -Throw
        }
    }
}

Describe 'Windowing - one-day slices (integration)' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Connect-ExchangeOnline {}
        Mock Search-UnifiedAuditLog { @() }   # empty -> inner page loop ends after one call per day
    }
    It '[green] segments an N-day window into N one-day searches' {
        Invoke-C -Root (New-Root) -RecordTypes @('DLPEndpoint') -DaysBack 3
        Should -Invoke Search-UnifiedAuditLog -Exactly -Times 3 -ParameterFilter {
            ($EndDate - $StartDate).TotalDays -gt 0.99 -and ($EndDate - $StartDate).TotalDays -lt 1.01
        }
    }
}

Describe 'Dedup - rows sharing an Identity collapse (integration)' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Connect-ExchangeOnline {}
        $seen = @{}
        $json = @{ Operation = 'DLPRuleMatch'; UserId = 'u@contoso.example'; Workload = 'Exchange'; ObjectId = 'm1'
                   PolicyDetails = @(@{ PolicyName = 'PCI'; Rules = @(@{ ConditionsMatched = @{ SensitiveInformation = @(@{ SensitiveInformationTypeName = 'Credit Card Number' }) } }) }) } | ConvertTo-Json -Depth 8
        Mock Search-UnifiedAuditLog {
            if ($seen.ContainsKey($SessionId)) { return @() }
            $seen[$SessionId] = $true
            @(
                [pscustomobject]@{ Identity = 'dup';  CreationDate = $StartDate; RecordType = 'DLPEndpoint'; AuditData = $json },
                [pscustomobject]@{ Identity = 'dup';  CreationDate = $StartDate; RecordType = 'DLPEndpoint'; AuditData = $json },
                [pscustomobject]@{ Identity = 'uniq'; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; AuditData = $json }
            )
        }
    }
    It '[green] the per-type seen-set (HashSet on Identity) keeps one row per Identity' {
        $root = New-Root
        Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 1
        $csv = Import-Csv (Join-Path (Get-SampleDir $root) 'DLPEndpoint.csv')
        $csv.Count | Should -Be 2
    }
}

Describe 'No spurious cap - all rows kept when under MaxPerType (integration)' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Connect-ExchangeOnline {}
        $seen = @{}
        $json = @{ Operation = 'DLPRuleMatch'; UserId = 'u@contoso.example'; Workload = 'Exchange'; ObjectId = 'm1' } | ConvertTo-Json -Depth 8
        Mock Search-UnifiedAuditLog {
            if ($seen.ContainsKey($SessionId)) { return @() }
            $seen[$SessionId] = $true
            1..3 | ForEach-Object { [pscustomobject]@{ Identity = "row$_"; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; AuditData = $json } }
        }
    }
    It '[green] returns every distinct row' {
        $root = New-Root
        Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 1 -MaxPerDay 100
        $csv = Import-Csv (Join-Path (Get-SampleDir $root) 'DLPEndpoint.csv')
        $csv.Count | Should -Be 3
    }
}

Describe 'Intra-day paging - all ReturnLargeSet pages consumed within a day (integration)' {
    # Pins the shared day/page gate that S2's fix will edit: within ONE day, successive
    # ReturnLargeSet pages (same SessionId) are all consumed until an empty page, and the
    # cap stops paging mid-day. Page number is carried in UserId ('u1'/'u2'/'u3') because
    # Expand-AuditRow drops Identity from its output.
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Connect-ExchangeOnline {}
        $calls = @{}
        Mock Search-UnifiedAuditLog {
            if (-not $calls.ContainsKey($SessionId)) { $calls[$SessionId] = 0 }
            $calls[$SessionId]++
            $p = $calls[$SessionId]
            if ($p -le 3) {
                1..2 | ForEach-Object { [pscustomobject]@{ Identity = "p$p-r$_"; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; AuditData = (@{ Operation = 'X'; UserId = "u$p" } | ConvertTo-Json) } }
            } else { @() }
        }
    }
    It '[green] consumes every page within the day (high cap)' {
        $root = New-Root
        Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 1 -MaxPerDay 100
        $csv = Import-Csv (Join-Path (Get-SampleDir $root) 'DLPEndpoint.csv')
        $csv.Count | Should -Be 6                                       # 3 pages x 2 rows, all consumed
        ($csv | Where-Object { $_.UserId -eq 'u3' }).Count | Should -Be 2   # last page is included
    }
    It '[green] stops paging once the cap is reached within the day' {
        $root = New-Root
        Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 1 -MaxPerDay 4
        $csv = Import-Csv (Join-Path (Get-SampleDir $root) 'DLPEndpoint.csv')
        $csv.Count | Should -Be 4                                       # stops after 2 pages
        ($csv | Where-Object { $_.UserId -eq 'u3' }).Count | Should -Be 0   # third page never fetched
    }
}

Describe 'S1 - run survives a malformed row (integration)' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Connect-ExchangeOnline {}
        $seen = @{}
        $okJson = @{ Operation = 'SensitivityLabelApplied'; UserId = 'u@contoso.example' } | ConvertTo-Json
        Mock Search-UnifiedAuditLog {
            if ($seen.ContainsKey($SessionId)) { return @() }
            $seen[$SessionId] = $true
            if ($RecordType -eq 'DLPEndpoint') { @( [pscustomobject]@{ Identity = 'bad1'; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; AuditData = '<<< not json >>>' } ) }
            elseif ($RecordType -eq 'MIPLabel') { @( [pscustomobject]@{ Identity = 'ok1'; CreationDate = $StartDate; RecordType = 'MIPLabel'; AuditData = $okJson } ) }
            else { @() }
        }
    }
    It '[RED->green after S1] does not terminate the whole run' {
        { Invoke-C -Root (New-Root) -RecordTypes @('DLPEndpoint', 'MIPLabel') -DaysBack 1 } | Should -Not -Throw
    }
    It '[RED->green after S1] still exports the later record type (MIPLabel.csv)' {
        $root = New-Root
        try { Invoke-C -Root $root -RecordTypes @('DLPEndpoint', 'MIPLabel') -DaysBack 1 } catch {}
        Test-Path (Join-Path (Get-SampleDir $root) 'MIPLabel.csv') | Should -BeTrue
    }
}

Describe 'S2 - per-day budget: every day represented, early flood capped (integration)' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Connect-ExchangeOnline {}
        $calls = @{}
        # 3-day window. The earliest day floods across multiple pages (ResultCount=10 available);
        # the middle and latest days each return a single, complete 2-row page (ResultCount=2). Age
        # thresholds are wide (2.5 / 1.5) so execution-time drift can't misclassify a day.
        Mock Search-UnifiedAuditLog {
            if (-not $calls.ContainsKey($SessionId)) { $calls[$SessionId] = 0 }
            $calls[$SessionId]++
            $p = $calls[$SessionId]
            $age = ((Get-Date).ToUniversalTime() - $StartDate).TotalDays
            if ($age -gt 2.5) {
                if ($p -le 5) { 1..2 | ForEach-Object { $ix = (($p - 1) * 2) + $_; [pscustomobject]@{ Identity = "early-$p-$_"; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; ResultIndex = $ix; ResultCount = 10; AuditData = (@{ Operation = 'X'; UserId = 'EARLYDAY' } | ConvertTo-Json) } } } else { @() }
            } elseif ($age -lt 1.5) {
                if ($p -le 1) { 1..2 | ForEach-Object { [pscustomobject]@{ Identity = "late-$_"; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; ResultIndex = $_; ResultCount = 2; AuditData = (@{ Operation = 'X'; UserId = 'LATEDAY' } | ConvertTo-Json) } } } else { @() }
            } else {
                if ($p -le 1) { 1..2 | ForEach-Object { [pscustomobject]@{ Identity = "mid-$_"; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; ResultIndex = $_; ResultCount = 2; AuditData = (@{ Operation = 'X'; UserId = 'MIDDAY' } | ConvertTo-Json) } } } else { @() }
            }
        }
    }
    It '[green after S2] every day is represented and the flooded day is capped at MaxPerDay' {
        $root = New-Root
        Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 3 -MaxPerDay 4
        $rows = Import-Csv (Join-Path (Get-SampleDir $root) 'DLPEndpoint.csv')
        # Distribution (unchanged): every day represented, the flood capped at the per-day budget.
        ($rows | Where-Object { $_.UserId -eq 'EARLYDAY' }).Count | Should -Be 4
        ($rows | Where-Object { $_.UserId -eq 'MIDDAY'  }).Count | Should -Be 2
        ($rows | Where-Object { $_.UserId -eq 'LATEDAY' }).Count | Should -Be 2
        $rows.Count | Should -Be 8
        # Truncation (added, not replacing the above): only the flooded early day is truncated, at
        # its budget; the complete mid/late days are not.
        $sum = Import-Csv (Join-Path (Get-SampleDir $root) '_AuditSampleSummary.csv')
        # @(...) around Where-Object: under WinPS 5.1 a single PSCustomObject has no
        # intrinsic .Count (returns $null); PS Core added it in 6.1.
        @($sum | Where-Object { $_.Truncated -eq 'True' }).Count       | Should -Be 1
        $truncRow = $sum | Where-Object { $_.Truncated -eq 'True' }
        $truncRow.TruncationReason | Should -Be 'MaxPerDay'
        $truncRow.Retrieved        | Should -Be 4
        @($sum | Where-Object { $_.TruncationReason -eq 'none' }).Count | Should -Be 2
    }
}

Describe 'S12 - CSV is lean; raw.json keeps full fidelity (integration)' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Connect-ExchangeOnline {}
        $seen = @{}
        # ExtraDetail is a field Expand-AuditRow does NOT project; it must survive ONLY in raw.json.
        $json = @{ Operation = 'DLPRuleMatch'; UserId = 'u@contoso.example'; Workload = 'Exchange'; ObjectId = 'obj-1'; ExtraDetail = 'DEEP-FIDELITY-XYZ' } | ConvertTo-Json -Depth 8
        Mock Search-UnifiedAuditLog {
            if ($seen.ContainsKey($SessionId)) { return @() }
            $seen[$SessionId] = $true
            @( [pscustomobject]@{ Identity = 'r1'; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; AuditData = $json } )
        }
    }
    It '[RED->green after S12] CSV drops the RawAuditData column; raw.json retains full detail' {
        $root = New-Root
        Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 1
        $dir = Get-SampleDir $root
        $rows = Import-Csv (Join-Path $dir 'DLPEndpoint.csv')
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'RawAuditData'
        (Get-Content (Join-Path $dir 'DLPEndpoint.csv') -Raw)      | Should -Not -Match 'DEEP-FIDELITY-XYZ'   # lean CSV
        (Get-Content (Join-Path $dir 'DLPEndpoint.raw.json') -Raw) | Should -Match 'DEEP-FIDELITY-XYZ'        # full-fidelity raw
    }
}

Describe 'S1 - skipped rows are tallied durably (integration)' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Connect-ExchangeOnline {}
        $seen = @{}
        $okJson = @{ Operation = 'DLPRuleMatch'; UserId = 'u@contoso.example' } | ConvertTo-Json
        # One malformed row + one valid row for the same type: Kept should be 1, Skipped 1.
        Mock Search-UnifiedAuditLog {
            if ($seen.ContainsKey($SessionId)) { return @() }
            $seen[$SessionId] = $true
            @(
                [pscustomobject]@{ Identity = 'bad1'; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; AuditData = '<<< not json >>>' },
                [pscustomobject]@{ Identity = 'ok1';  CreationDate = $StartDate; RecordType = 'DLPEndpoint'; AuditData = $okJson }
            )
        }
    }
    It '[RED->green after tally] _AuditSampleSummary.csv records Kept and Skipped per record type' {
        $root = New-Root
        Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 1
        $sum = Import-Csv (Join-Path (Get-SampleDir $root) '_AuditSampleSummary.csv')
        $dlp = $sum | Where-Object { $_.RecordType -eq 'DLPEndpoint' }
        $dlp.Kept    | Should -Be 1
        $dlp.Skipped | Should -Be 1
    }
}

Describe 'S15 - parameter validation' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Connect-ExchangeOnline {}
        Mock Search-UnifiedAuditLog { @() }
    }
    It '[RED->green after S15] rejects a non-positive -DaysBack instead of silently sampling nothing' {
        { Invoke-C -Root (New-Root) -RecordTypes @('DLPEndpoint') -DaysBack 0 }  | Should -Throw
        { Invoke-C -Root (New-Root) -RecordTypes @('DLPEndpoint') -DaysBack -5 } | Should -Throw
    }
}

Describe 'Phase 1 - default window is 7 days' {
    BeforeAll {
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Connect-ExchangeOnline {}
        Mock Search-UnifiedAuditLog { @() }
    }
    It '[RED->green after default change] omitting -DaysBack searches seven one-day windows' {
        # Invoked directly (not via Invoke-C, which passes -DaysBack) to exercise the script default.
        & $script:ScriptPath -SourceUpn 'x@y.example' -OutputRoot (New-Root) -RecordTypes @('DLPEndpoint') `
            -MaxPerDay 5000 -ReuseExistingSession *> $null
        Should -Invoke Search-UnifiedAuditLog -Exactly -Times 7
    }
}

Describe 'Phase 2 - truncation flagging in _AuditSampleSummary.csv (integration)' {
    Context 'MaxPerDay budget reached while more results exist' {
        BeforeAll {
            Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
            Mock Connect-ExchangeOnline {}
            $calls = @{}
            # Pages of 2, ResultCount=10 (10 available); MaxPerDay 4 stops us after 2 pages.
            Mock Search-UnifiedAuditLog {
                if (-not $calls.ContainsKey($SessionId)) { $calls[$SessionId] = 0 }
                $calls[$SessionId]++
                $p = $calls[$SessionId]
                if ($p -le 5) {
                    1..2 | ForEach-Object {
                        $ix = (($p - 1) * 2) + $_
                        [pscustomobject]@{ Identity = "r$ix"; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; ResultIndex = $ix; ResultCount = 10; AuditData = (@{ Operation = 'X'; UserId = 'u' } | ConvertTo-Json) }
                    }
                } else { @() }
            }
        }
        It '[RED->green after Phase 2] flags Truncated / TruncationReason=MaxPerDay' {
            $root = New-Root
            Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 1 -MaxPerDay 4
            $row = (Import-Csv (Join-Path (Get-SampleDir $root) '_AuditSampleSummary.csv'))[0]
            $row.Retrieved        | Should -Be 4
            $row.Truncated        | Should -Be 'True'
            $row.TruncationReason | Should -Be 'MaxPerDay'
        }
    }
    Context 'Session ~50k ceiling reached before the budget (more available)' {
        BeforeAll {
            Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
            Mock Connect-ExchangeOnline {}
            $calls = @{}
            # One page of 10 with ResultCount=25, then empty: the platform stopped feeding us
            # though more existed (scaled-down analogue of the 50,000-per-session ceiling).
            Mock Search-UnifiedAuditLog {
                if (-not $calls.ContainsKey($SessionId)) { $calls[$SessionId] = 0 }
                $calls[$SessionId]++
                if ($calls[$SessionId] -eq 1) {
                    1..10 | ForEach-Object { [pscustomobject]@{ Identity = "r$_"; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; ResultIndex = $_; ResultCount = 25; AuditData = (@{ Operation = 'X'; UserId = 'u' } | ConvertTo-Json) } }
                } else { @() }
            }
        }
        It '[RED->green after Phase 2] flags Truncated / TruncationReason=SessionCap-50k' {
            $root = New-Root
            Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 1 -MaxPerDay 1000
            $row = (Import-Csv (Join-Path (Get-SampleDir $root) '_AuditSampleSummary.csv'))[0]
            $row.Truncated        | Should -Be 'True'
            $row.TruncationReason | Should -Be 'SessionCap-50k'
        }
    }
    Context 'Day fully retrieved (nothing more available)' {
        BeforeAll {
            Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
            Mock Connect-ExchangeOnline {}
            $calls = @{}
            # 6 rows, ResultCount=6 (exhausted), then empty. Count == cap must NOT read as truncated.
            Mock Search-UnifiedAuditLog {
                if (-not $calls.ContainsKey($SessionId)) { $calls[$SessionId] = 0 }
                $calls[$SessionId]++
                if ($calls[$SessionId] -eq 1) {
                    1..6 | ForEach-Object { [pscustomobject]@{ Identity = "r$_"; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; ResultIndex = $_; ResultCount = 6; AuditData = (@{ Operation = 'X'; UserId = 'u' } | ConvertTo-Json) } }
                } else { @() }
            }
        }
        It '[RED->green after Phase 2] flags Truncated=False / TruncationReason=none' {
            $root = New-Root
            Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 1 -MaxPerDay 1000
            $row = (Import-Csv (Join-Path (Get-SampleDir $root) '_AuditSampleSummary.csv'))[0]
            $row.Truncated        | Should -Be 'False'
            $row.TruncationReason | Should -Be 'none'
        }
    }
}

Describe 'Phase 2 - truncation fallback when paging fields are absent (integration)' {
    Context 'Stopped at MaxPerDay but rows carry no ResultIndex/ResultCount' {
        BeforeAll {
            Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
            Mock Connect-ExchangeOnline {}
            $calls = @{}
            # Pages of 2 with NO ResultIndex/ResultCount; more pages exist but MaxPerDay 4 stops us,
            # so completeness cannot be confirmed from the response.
            Mock Search-UnifiedAuditLog {
                if (-not $calls.ContainsKey($SessionId)) { $calls[$SessionId] = 0 }
                $calls[$SessionId]++
                if ($calls[$SessionId] -le 5) {
                    1..2 | ForEach-Object { [pscustomobject]@{ Identity = "n$($calls[$SessionId])-$_"; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; AuditData = (@{ Operation = 'X'; UserId = 'u' } | ConvertTo-Json) } }
                } else { @() }
            }
        }
        It '[green] flags Truncated=True / TruncationReason=MaxPerDay? (possibly truncated, not silent none)' {
            $root = New-Root
            Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 1 -MaxPerDay 4
            $row = (Import-Csv (Join-Path (Get-SampleDir $root) '_AuditSampleSummary.csv'))[0]
            $row.Retrieved        | Should -Be 4
            $row.Truncated        | Should -Be 'True'
            $row.TruncationReason | Should -Be 'MaxPerDay?'
        }
    }
    Context 'Exhausted under budget with fields absent (empty page confirms completeness)' {
        BeforeAll {
            Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
            Mock Connect-ExchangeOnline {}
            $calls = @{}
            # 3 rows (no fields) then an empty page: genuine exhaustion well below the budget.
            Mock Search-UnifiedAuditLog {
                if (-not $calls.ContainsKey($SessionId)) { $calls[$SessionId] = 0 }
                $calls[$SessionId]++
                if ($calls[$SessionId] -eq 1) {
                    1..3 | ForEach-Object { [pscustomobject]@{ Identity = "r$_"; CreationDate = $StartDate; RecordType = 'DLPEndpoint'; AuditData = (@{ Operation = 'X'; UserId = 'u' } | ConvertTo-Json) } }
                } else { @() }
            }
        }
        It '[green] stays Truncated=False / none (an empty page under budget means complete)' {
            $root = New-Root
            Invoke-C -Root $root -RecordTypes @('DLPEndpoint') -DaysBack 1 -MaxPerDay 1000
            $row = (Import-Csv (Join-Path (Get-SampleDir $root) '_AuditSampleSummary.csv'))[0]
            $row.Truncated        | Should -Be 'False'
            $row.TruncationReason | Should -Be 'none'
        }
    }
}
