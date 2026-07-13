# Pester v5 offline tests for scripts/New-PurviewReport.ps1 ("E").
# Fully offline: the report script reads local CSVs and writes local HTML.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path (Join-Path $repoRoot 'scripts') 'New-PurviewReport.ps1'

    # Builds a minimal snapshot-run-style fixture folder. Non-ASCII content is
    # constructed with [char] so this test source stays ASCII (DECISIONS.md D7).
    function New-FixtureRun {
        param([string]$Root, [string]$LabelName)
        $run = Join-Path $Root 'PurviewSnapshot-fixture'
        $ip  = Join-Path $run '1-InformationProtection'
        New-Item -ItemType Directory -Force -Path $ip | Out-Null
        [pscustomobject]@{
            DisplayName = $LabelName; Name = 'lbl-1'
            Guid = '11111111-1111-1111-1111-111111111111'
            Priority = '0'; ContentType = 'File, Email'; Disabled = 'False'
            ParentLabel = ''; EncryptionEnabled = 'True'; ContentMarking = 'False'
        } | Export-Csv (Join-Path $ip 'SensitivityLabels.csv') -NoTypeInformation -Encoding UTF8
        $run
    }
}

Describe 'Report output encoding (D7: generated output is UTF-8)' {
    BeforeAll {
        $eAcute = [char]0x00E9                        # e-acute, outside ASCII
        $script:Org   = "Soci$($eAcute)t$($eAcute) Contoso"
        $script:Label = "Confidentialit$eAcute"
        $root = Join-Path $TestDrive 'enc'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $run = New-FixtureRun -Root $root -LabelName $script:Label
        $script:OutFile = Join-Path $root 'report.html'
        & $script:ScriptPath -Path $run -OutputPath $script:OutFile -OrganizationName $script:Org *> $null
    }
    It 'writes the report file' {
        Test-Path $script:OutFile | Should -BeTrue
    }
    It 'preserves non-ASCII organization and label names' {
        $text = [System.IO.File]::ReadAllText($script:OutFile, (New-Object System.Text.UTF8Encoding $false))
        $text.Contains($script:Org)   | Should -BeTrue
        $text.Contains($script:Label) | Should -BeTrue
    }
    It 'writes UTF-8 without a byte order mark' {
        $bytes = [System.IO.File]::ReadAllBytes($script:OutFile)
        $lead = '{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2]
        $lead | Should -Not -Be 'EFBBBF'
    }
}
