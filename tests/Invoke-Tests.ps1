#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the toolkit's Pester v5 test suite offline (no tenant, no network).
.EXAMPLE
    pwsh -NoProfile -File .\tests\Invoke-Tests.ps1
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param([string]$Path)

# Default resolved in the body: under Windows PowerShell 5.1 $PSScriptRoot is empty
# when evaluated in a parameter default, so a param-default here breaks discovery.
if (-not $Path) { $Path = $PSScriptRoot }

Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop
$cfg = New-PesterConfiguration
$cfg.Run.Path = $Path
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
