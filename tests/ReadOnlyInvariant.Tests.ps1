# Pester v5 static AST guard: every script in scripts/ is read-only toolkit code.
#
# Generalized from the C-suite guard (DECISIONS.md D13). Invariants per script:
#   1. No tenant-mutating command is invoked (Set/Remove/Enable/... or non-local New-*).
#      Local, machine-only commands (New-Item, Set-Content, Start/Stop-Transcript, ...)
#      are allowlisted; functions a script defines itself are exempt by construction.
#   2. The connect/search/import surface is exactly the known cmdlet set.
#   3. The Export-* surface is exactly the known set (tenant reads + local serialization),
#      so any new tenant-touching call must be added here deliberately.

BeforeDiscovery {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $scriptFiles = Get-ChildItem -Path (Join-Path $repoRoot 'scripts') -Filter '*.ps1' |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
}

Describe 'Read-only invariant (static AST guard): <Name>' -ForEach $scriptFiles {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $localFunctions = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name }
        $script:CmdNames = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ -and ($_ -notin $localFunctions) } |
            Select-Object -Unique
    }

    It 'invokes no tenant-mutating cmdlets' {
        # Local, machine-only commands the toolkit legitimately uses.
        $allowedLocal = @('New-Item', 'New-Object', 'New-Guid', 'New-Variable', 'New-TimeSpan',
                          'Set-Content', 'Start-Transcript', 'Stop-Transcript')
        $mutatingPattern = '^(New|Set|Remove|Add|Clear|Enable|Disable|Update|Start|Stop|Restart|' +
                           'Suspend|Resume|Grant|Revoke|Submit|Publish|Unpublish|Install|Uninstall|' +
                           'Register|Unregister|Move|Rename|Invoke)-'
        $mutating = $script:CmdNames | Where-Object { $_ -match $mutatingPattern -and $_ -notin $allowedLocal }
        $mutating | Should -BeNullOrEmpty
    }

    It 'connect/search/import surface is exactly the known set' {
        $allowed = @('Connect-IPPSSession', 'Connect-ExchangeOnline', 'Search-UnifiedAuditLog',
                     'Import-Module', 'Import-Csv')
        $surface = $script:CmdNames | Where-Object { $_ -match '^(Connect|Disconnect|Search|Import)-' }
        foreach ($c in $surface) { $c | Should -BeIn $allowed }
    }

    It 'export surface is exactly the known set (tenant reads + local serialization)' {
        $allowed = @('Export-ContentExplorerData', 'Export-PurviewConfig',   # tenant read/export (D5/D6)
                     'Export-Csv', 'Export-Clixml')                          # local files
        $surface = $script:CmdNames | Where-Object { $_ -match '^Export-' }
        foreach ($c in $surface) { $c | Should -BeIn $allowed }
    }
}
