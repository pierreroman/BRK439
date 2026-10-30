#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('CaptureCloud', 'RunLocal', 'SaveFallback', 'ShowFallback')][string] $Mode,
    [string] $StateDirectory = (Join-Path $env:LOCALAPPDATA 'BRK439\Demo4'),
    [switch] $ConfirmAirplaneMode,
    [switch] $NoBrowser
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Demo4.psm1') -Force
$prompt = Get-D4Prompt
$page = $null
switch ($Mode) {
    'CaptureCloud' {
        $config = Read-D4Json (Join-Path $StateDirectory 'cloud-config.json')
        $governance = Assert-D4CloudState $config
        $token = Invoke-D4Az @('account', 'get-access-token', '--subscription', $config.subscriptionId, '--resource', 'https://cognitiveservices.azure.com', '--query', 'accessToken')
        try {
            $endpoint = "https://$($config.accountName).openai.azure.com/openai/deployments/$($config.deploymentName)/chat/completions?api-version=2024-10-21"
            $result = Invoke-D4Request -Uri $endpoint -Model $config.deploymentName -Prompt $prompt -Headers @{ Authorization = "Bearer $token" }
        } finally { $token = $null }
        $capture = New-D4Capture -Source cloud -Response $result.response -Prompt $prompt -Model "$($governance.model.name)/$($governance.model.version)" -ElapsedMs $result.elapsedMs -Governance $governance
        Write-D4Json (Join-Path $StateDirectory 'cloud.json') $capture
        Write-Host "REAL cloud answer saved. Measured full-response request time: $($capture.elapsedMs) ms. Do not recapture cloud after airplane mode."
    }
    'RunLocal' {
        if (-not $ConfirmAirplaneMode) { throw 'Enable airplane mode, disable Ethernet and alternate uplinks, and verify isolation yourself. Then add -ConfirmAirplaneMode. This is an attestation, not automatic proof.' }
        $cloud = Read-D4Json (Join-Path $StateDirectory 'cloud.json')
        Assert-D4Capture $cloud 'cloud'
        if ($cloud.promptSha256 -cne $prompt.sha256) { throw 'The cloud answer used a different prompt. Recapture it while online before running the local side.' }
        $config = Read-D4Json (Join-Path $StateDirectory 'local-config.json')
        Assert-D4LocalEndpoint $config.baseUrl
        $governance = @{
            endpoint = $config.baseUrl
            model = $config.modelId
            logging = 'This client stores the full fictional prompt/answer in local.json and generated comparison/fallback HTML. Foundry runtime logs are separate: inspect foundry server status / foundry server logs; their contents and retention are not audited by this kit.'
            filters = 'No managed Azure content-filter policy is applied by this client. Model/runtime safeguards may still exist; inspect the exact model and runtime. Do not equate local with ungoverned or inherently safe.'
            access = 'Loopback HTTP with no bearer token sent by this client. No per-user RBAC is configured. Local processes able to reach this service may call it; validate runtime binding, firewall and OS access. Never expose the port to the LAN.'
            isolation = 'Only literal 127.0.0.1 HTTP is permitted. Proxy bypass and redirect rejection are enabled. Airplane mode is operator-attested, not independently measured.'
        }
        $result = Invoke-D4Request -Uri "$($config.baseUrl)/chat/completions" -Model $config.modelId -Prompt $prompt -Local
        $capture = New-D4Capture -Source local -Response $result.response -Prompt $prompt -Model $config.modelId -ElapsedMs $result.elapsedMs -Governance $governance -AirplaneModeAttested $true
        Write-D4Json (Join-Path $StateDirectory 'local.json') $capture
        $page = New-D4Comparison -StateDirectory $StateDirectory -OutputPath (Join-Path $StateDirectory 'comparison.html') -Mode stage
        Write-Host "REAL local answer captured. Measured full-response request time: $($capture.elapsedMs) ms."
    }
    'SaveFallback' {
        $page = New-D4Comparison -StateDirectory $StateDirectory -OutputPath (Join-Path $StateDirectory 'fallback.html') -Mode fallback
        Write-Host 'Fallback saved from real captures. Later failed requests cannot overwrite this standalone fallback page.'
    }
    'ShowFallback' {
        $page = Join-Path $StateDirectory 'fallback.html'
        if (-not (Test-Path -LiteralPath $page -PathType Leaf)) { throw 'No captured fallback exists. Complete a successful rehearsal and SaveFallback first. No synthetic answer will be invented.' }
    }
}
if ($page) {
    $url = ([Uri][IO.Path]::GetFullPath($page)).AbsoluteUri
    Write-Host "Open comparison: $url"
    if (-not $NoBrowser) { Start-Process -FilePath $url }
}
