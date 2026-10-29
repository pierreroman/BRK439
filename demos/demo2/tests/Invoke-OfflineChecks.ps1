#Requires -Version 7.4
[CmdletBinding()]
param(
    [switch]$SkipInfrastructureScan,
    [string]$CheckovPython,
    [string]$CheckovScript
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$parseFailures = 0
foreach ($file in Get-ChildItem $root -Recurse -File -Include '*.ps1', '*.psm1') {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($error in $errors) { Write-Output $error; $parseFailures++ }
}
if ($parseFailures) { throw "$parseFailures PowerShell parser failures." }
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
$result = Invoke-Pester -Path $PSScriptRoot -PassThru -Output Detailed
if ($result.Result -ne 'Passed' -or $result.PassedCount -eq 0) { throw 'Offline Pester checks failed, a test container failed discovery, or no checks executed.' }
Import-Module PSScriptAnalyzer -ErrorAction Stop
$issues = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error)
$issues | Format-List *
if ($issues.Count) { throw 'PowerShell analysis reported errors.' }
if (-not $SkipInfrastructureScan) {
    if ($CheckovPython -or $CheckovScript) {
        if (-not $CheckovPython -or -not $CheckovScript) { throw 'Supply both explicit CheckovPython and CheckovScript paths.' }
        & $CheckovPython $CheckovScript -d (Join-Path $root 'infra') --framework bicep --skip-download --compact
    } else {
        & checkov -d (Join-Path $root 'infra') --framework bicep --skip-download --compact
    }
    if ($LASTEXITCODE -ne 0) { throw 'Infrastructure scan failed or checkov is unavailable.' }
}
Write-Output 'Offline checks passed. This is not evidence of Azure deployment or live key recovery.'
