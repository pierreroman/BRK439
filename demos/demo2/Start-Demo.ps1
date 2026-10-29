#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Plan','Setup','Status','Rehearse','Run','RetirementPlan')]
    [string]$Mode = 'Setup',
    [string]$InstallPath,
    [switch]$AuthorizeLiveChanges
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Demo.Setup.psm1')
Invoke-DemoSetup -Mode $Mode -InstallPath $InstallPath -AuthorizeLiveChanges:$AuthorizeLiveChanges
