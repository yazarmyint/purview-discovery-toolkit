#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the toolkit's Pester v5 test suite offline (no tenant, no network).
.EXAMPLE
    pwsh -NoProfile -File .\tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param([string]$Path = $PSScriptRoot)

Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop
$cfg = New-PesterConfiguration
$cfg.Run.Path = $Path
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
