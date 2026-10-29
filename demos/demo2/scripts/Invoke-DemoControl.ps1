[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('Arm','Disable','Restore','Read','Status','Reset')][string]$Action,
    [ValidateSet('Live','Twin')][string]$Target = 'Live',
    [Parameter(Mandatory)][guid]$RunId,
    [switch]$AuthorizeLiveChanges
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1') -Force
$config = Import-DemoConfig -Path $ConfigPath -Phase Runtime
if ($Action -in 'Arm','Disable','Restore','Reset' -and -not $AuthorizeLiveChanges) {
    throw "$Action requires -AuthorizeLiveChanges. No request was sent."
}
if ($RunId -eq [guid]::Empty) { throw 'An empty run ID is not allowed.' }
if ([string]$config.sshUser -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw 'Invalid SSH user.' }
if ([string]$config.sshHost -cnotmatch '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$') { throw 'Invalid SSH host; use an IPv4 address or DNS hostname.' }
$port = 0
if (-not [int]::TryParse([string]$config.sshPort, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'Invalid SSH port.' }
$sshArgs = @('-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10','-p',"$port")
if ($config.sshIdentityFile) { $sshArgs += @('-i',[string]$config.sshIdentityFile) }
$sshArgs += @("$($config.sshUser)@$($config.sshHost)",'pwsh','-NoProfile','-File','/opt/demo2/host/Submit-Request.ps1',
    '-Action',$Action,'-Target',$Target,'-RunId',$RunId.ToString('D'))
$output = & ssh @sshArgs
$exitCode = $LASTEXITCODE
$text = $output -join "`n"
if ($exitCode -ne 0) { throw "SSH/remote request failed (exit $exitCode). Response: $text" }
try { $response = $text | ConvertFrom-Json -ErrorAction Stop }
catch { throw "Controller returned invalid JSON: $text" }
if ($response.action -ne $Action -or $response.target -ne $Target -or [string]$response.runId -ne $RunId.ToString('D')) {
    throw "Controller correlation mismatch. Response: $text"
}
if ($response.ok -ne $true) { throw "Controller rejected $Action. Response: $text" }
$response
