#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $DestinationDirectory = (Join-Path $env:LOCALAPPDATA 'BRK439\Demo3'),
    [switch] $NoBrowser,
    [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'portal.html'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "Simulator asset is missing: $source. Copy the complete demos\demo3 directory."
}
if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) {
    throw 'DestinationDirectory cannot be empty.'
}

$destination = [IO.Path]::GetFullPath($DestinationDirectory)
$target = Join-Path $destination 'portal.html'
if ([IO.Path]::GetFullPath($source) -eq $target) {
    throw 'Choose an installation directory other than the source directory.'
}
if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
}
Copy-Item -LiteralPath $source -Destination $target -Force
if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {
    throw 'Installed portal failed its SHA-256 integrity check.'
}

$url = ([Uri]$target).AbsoluteUri
if ($SelfTest) {
    $url += '?selftest=1'
}

Write-Host 'DEMO 3 - LAPTOP SIMULATION ONLY' -ForegroundColor Yellow
Write-Host 'No Azure resources, real VMs, network changes, or security controls are deployed.'
Write-Host "Installed: $target"
Write-Host "Open: $url"
Write-Host 'Browser state persists at this file location in this browser profile.'
Write-Host 'Use Reset rehearsal in the portal before each performance.'
if (-not $NoBrowser) {
    Start-Process -FilePath $url
}

[pscustomobject]@{
    Mode = 'Simulation'
    PortalPath = $target
    Url = $url
    SelfTest = [bool]$SelfTest
}
