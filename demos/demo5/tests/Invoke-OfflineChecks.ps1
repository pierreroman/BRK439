#requires -Version 7.5
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = 0
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1', '*.psm1') {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($errorRecord in $parseErrors) { Write-Output $errorRecord; $failures++ }
}
if ($failures) { throw "$failures PowerShell parse errors." }
Write-Host 'PASS PowerShell syntax.'
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
$result = Invoke-Pester -Path (Join-Path $PSScriptRoot 'Demo5.Tests.ps1') -PassThru -Output Detailed
if ($result.Result -ne 'Passed' -or $result.PassedCount -eq 0) { throw 'Demo 5 offline tests failed or no tests were executed.' }
Import-Module PSScriptAnalyzer -ErrorAction Stop
$issues = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error)
$issues | Format-List *
if ($issues.Count) { throw 'Demo 5 PowerShell error-level analysis failed.' }
Write-Host 'PASS Offline tests and PowerShell error-level analysis. No real Lockbox requests or tenant operations were performed.'
