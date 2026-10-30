#requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Model = 'qwen2.5-0.5b',
    [string] $ModelId,
    [ValidateRange(1024, 65535)][int] $Port = 39839,
    [string] $StateDirectory = (Join-Path $env:LOCALAPPDATA 'BRK439\Demo4')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Demo4.psm1') -Force
if (-not (Get-Command foundry -ErrorAction SilentlyContinue)) {
    throw 'Foundry Local is missing. Install using winget install Microsoft.FoundryLocal, review its terms, open a new terminal, and rerun while online.'
}
function Invoke-Foundry {
    param([string[]] $Arguments)
    & foundry @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Foundry Local failed: $($Arguments -join ' '). Resolve the displayed error; no mock result is substituted." }
}
Write-Host 'ONLINE preparation: downloads model and execution providers. Review model license/terms and hardware requirements before continuing.'
Invoke-Foundry @('--version')
Invoke-Foundry @('server', 'start', '--port', "$Port", '--idle-timeout', '0')
Invoke-Foundry @('model', 'list')
Invoke-Foundry @('model', 'download', $Model)
Invoke-Foundry @('model', 'load', $Model)
$baseUrl = "http://127.0.0.1:$Port/v1"
Assert-D4LocalEndpoint $baseUrl
$models = Invoke-RestMethod -Uri "$baseUrl/models" -NoProxy -MaximumRedirection 0 -TimeoutSec 30 |
    ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
$available = @($models['data'] | ForEach-Object { $_['id'] })
if ($ModelId) {
    if ($ModelId -notin $available) { throw "ModelId is not in the local API catalog. Available IDs: $($available -join ', ')" }
} else {
    $matches = @($available | Where-Object { $_ -eq $Model })
    if (-not $matches.Count) { $matches = @($available | Where-Object { $_.StartsWith($Model, [StringComparison]::OrdinalIgnoreCase) }) }
    if ($matches.Count -ne 1) { throw "Cannot choose an unambiguous API model ID. Rerun with -ModelId from: $($available -join ', ')" }
    $ModelId = $matches[0]
}
$prompt = Get-D4Prompt
$warmup = Invoke-D4Request -Uri "$baseUrl/chat/completions" -Model $ModelId -Prompt $prompt -Local
$null = New-D4Capture -Source local -Response $warmup.response -Prompt $prompt -Model $ModelId -ElapsedMs $warmup.elapsedMs -Governance @{ purpose = 'Online preparation warmup, not stage evidence.' }
Write-D4Json (Join-Path $StateDirectory 'local-config.json') @{
    baseUrl = $baseUrl; modelId = $ModelId; alias = $Model; preparedAt = [DateTime]::UtcNow.ToString('o')
}
Write-Host "Local model loaded and warmup succeeded. Configuration: $StateDirectory\local-config.json"
Write-Host 'The Foundry daemon is intentionally left running with idle timeout disabled. Stop it after the event with foundry server stop; it may be shared by other applications.'
Write-Host 'If a daemon already used a different port, inspect foundry server status and rerun with that port. This script never restarts a shared daemon.'
