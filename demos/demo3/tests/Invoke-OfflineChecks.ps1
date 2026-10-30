#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'Start-Demo.ps1'
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('BRK439-Demo3-Test-' + [Guid]::NewGuid().ToString('N'))

try {
    foreach ($path in @($launcher, $PSCommandPath)) {
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw ($parseErrors | Out-String)
        }
        Write-Host "PASS PowerShell syntax: $path"
    }

    $first = & $launcher -DestinationDirectory $testDirectory -NoBrowser
    if ($first.Mode -ne 'Simulation' -or -not (Test-Path -LiteralPath $first.PortalPath)) {
        throw 'Installation did not produce the simulation portal.'
    }
    Write-Host 'PASS First install creates a simulation portal without opening a browser.'

    $second = & $launcher -DestinationDirectory $testDirectory -NoBrowser -SelfTest
    if (-not $second.SelfTest -or -not $second.Url.EndsWith('?selftest=1')) {
        throw 'Self-test URL is incorrect.'
    }
    if ((Get-FileHash -LiteralPath $first.PortalPath).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $root 'portal.html')).Hash) {
        throw 'Installed HTML differs from source after repeat installation.'
    }
    Write-Host 'PASS Repeat install preserves the asset and produces the isolated self-test URL.'

    $html = Get-Content -LiteralPath $first.PortalPath -Raw
    foreach ($required in @('LAPTOP SIMULATION', 'SIMULATED ping', 'POLICY MODEL DENIED',
            'RBAC MODEL DENIED', 'UPDATE MODEL BLOCKED', 'runSelfTests', 'localStorage')) {
        if (-not $html.Contains($required)) { throw "Required simulator surface missing: $required" }
    }
    if ($html -match '(?i)<script[^>]+\bsrc\s*=|<link[^>]+\bhref\s*=|<img[^>]+\bsrc\s*=|fetch\s*\(|XMLHttpRequest|WebSocket|@import|\burl\s*\(') {
        throw 'Unexpected network dependency in the self-contained portal.'
    }
    Write-Host 'PASS Required labels and model surfaces exist; no external asset or network API references.'
    Write-Host 'PASS Offline installation checks completed.'
    Write-Host 'NEXT: Run Start-Demo.ps1 -SelfTest in a browser and confirm all 16 model tests pass.'
}
finally {
    $installedFile = Join-Path $testDirectory 'portal.html'
    if (Test-Path -LiteralPath $installedFile -PathType Leaf) {
        Remove-Item -LiteralPath $installedFile -Force
    }
    if (Test-Path -LiteralPath $testDirectory -PathType Container) {
        Remove-Item -LiteralPath $testDirectory
    }
}
