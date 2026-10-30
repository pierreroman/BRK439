#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-D4Az {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $Arguments)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is missing. Install Azure CLI, open a new PowerShell 7 terminal and run az login.'
    }
    $result = & az @Arguments --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed (exit $LASTEXITCODE). See its error above. No fallback region or SKU will be used." }
    if (-not $result) { throw 'Azure CLI returned no JSON.' }
    return ($result -join "`n" | ConvertFrom-Json -AsHashtable)
}

function Write-D4Json {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Value)
    $fullPath = [IO.Path]::GetFullPath($Path)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $fullPath))
    $temporary = "$fullPath.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $fullPath, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Read-D4Json {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file is missing: $Path" }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable)
}

function Get-D4Prompt {
    [CmdletBinding()]
    param()
    $report = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\content\incident.txt') -Raw).Replace("`r`n", "`n").Trim()
    $prompt = "Summarize this fictional incident in exactly three short bullets: impact, cause and resolution, and next actions. Preserve uncertainty. Do not invent facts.`n`n$report"
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($prompt)))
    return @{ text = $prompt; sha256 = $hash }
}

function Assert-D4LocalEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $BaseUrl)
    $uri = [Uri]$BaseUrl
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'http' -or
        $uri.Host -cne '127.0.0.1' -or $uri.AbsolutePath -cne '/v1' -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'Local endpoint must be http://127.0.0.1:PORT/v1 with no credentials, query or fragment. Remote/cluster endpoints are intentionally unsupported by this laptop kit.'
    }
}

function New-D4Capture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('cloud', 'local')][string] $Source,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Response,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Prompt,
        [Parameter(Mandatory)][string] $Model,
        [Parameter(Mandatory)][ValidateRange(0, 3600000)][double] $ElapsedMs,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Governance,
        [bool] $AirplaneModeAttested = $false
    )
    $choices = $Response['choices']
    if (-not $choices -or -not $choices[0]['message'] -or
        [string]::IsNullOrWhiteSpace($choices[0]['message']['content'])) {
        throw 'Inference returned no answer. A blocked or failed request is not a successful capture.'
    }
    $finish = $choices[0]['finish_reason']
    if ($finish -notin @('stop', 'length')) { throw "Unexpected inference finish reason: $finish. Capture was not replaced." }
    return @{
        schema = 1
        source = $Source
        provenance = 'real-endpoint-capture'
        capturedAt = [DateTime]::UtcNow.ToString('o')
        model = $Model
        prompt = $Prompt.text
        promptSha256 = $Prompt.sha256
        answer = $choices[0]['message']['content']
        elapsedMs = [Math]::Round($ElapsedMs, 1)
        timing = 'Client wall-clock, non-streaming request through full response; excludes authentication, deployment, downloads and explicit model loading. Warmth is not controlled.'
        finishReason = $finish
        usage = $Response['usage']
        filtersReturned = @{
            prompt = $Response['prompt_filter_results']
            completion = $choices[0]['content_filter_results']
        }
        generation = @{ max_tokens = 180; temperature = 0; stream = $false }
        airplaneModeAttested = $AirplaneModeAttested
        isolationEvidence = $(if ($Source -eq 'local') { 'Operator attestation only; physical isolation was not independently verified by this script.' } else { 'Cloud capture requires connectivity.' })
        governance = $Governance
    }
}

function Invoke-D4Request {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $Model,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Prompt,
        [hashtable] $Headers = @{},
        [switch] $Local
    )
    $body = @{
        model = $Model
        messages = @(@{ role = 'user'; content = $Prompt.text })
        max_tokens = 180
        temperature = 0
        stream = $false
    } | ConvertTo-Json -Depth 10
    $arguments = @{
        Uri = $Uri; Method = 'Post'; ContentType = 'application/json; charset=utf-8'
        Body = [Text.Encoding]::UTF8.GetBytes($body); Headers = $Headers
        TimeoutSec = 180; MaximumRedirection = 0
    }
    if ($Local) { $arguments.NoProxy = $true }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try { $response = Invoke-RestMethod @arguments }
    finally { $timer.Stop() }
    return @{
        response = ($response | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable)
        elapsedMs = $timer.Elapsed.TotalMilliseconds
    }
}

function Assert-D4CloudState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Config)
    if ($Config['accountName'] -notmatch '^[a-z0-9][a-z0-9-]{1,62}$' -or
        $Config['deploymentName'] -ne 'taste-test' -or
        $Config['subscriptionId'] -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'Invalid cloud configuration; refusing to acquire a token or call an endpoint.'
    }
    $account = Invoke-D4Az @('cognitiveservices', 'account', 'show', '--subscription', $Config.subscriptionId, '--resource-group', $Config.resourceGroup, '--name', $Config.accountName)
    $deployment = Invoke-D4Az @('cognitiveservices', 'account', 'deployment', 'show', '--subscription', $Config.subscriptionId, '--resource-group', $Config.resourceGroup, '--name', $Config.accountName, '--deployment-name', $Config.deploymentName)
    if ($account.id -cne $Config.accountId -or $account.location -ne 'canadacentral' -or $deployment.sku.name -ne 'Standard' -or
        $account.properties.disableLocalAuth -ne $true -or
        $deployment.properties.raiPolicyName -ne 'demo4-filter') {
        throw 'Cloud governance drift: require Canada Central, regional Standard, key auth disabled and demo4-filter. Refusing capture.'
    }
    $policy = Invoke-D4Az @('rest', '--method', 'get', '--url', "https://management.azure.com$($Config.accountId)/raiPolicies/demo4-filter?api-version=2025-06-01")
    foreach ($source in @('Prompt', 'Completion')) {
        foreach ($category in @('Hate', 'Sexual', 'Violence', 'Selfharm')) {
            $matching = @($policy.properties.contentFilters | Where-Object {
                $_.name -eq $category -and $_.source -eq $source -and
                $_.enabled -eq $true -and $_.blocking -eq $true -and $_.severityThreshold -eq 'Medium'
            })
            if ($matching.Count -ne 1) { throw "Content filter drift: expected blocking Medium $category/$source. Refusing capture." }
        }
    }
    $roles = Invoke-D4Az @('role', 'assignment', 'list', '--subscription', $Config.subscriptionId, '--scope', $Config.accountId, '--include-inherited')
    return @{
        region = $account.location
        sku = $deployment.sku.name
        endpoint = "https://$($Config.accountName).openai.azure.com"
        model = $deployment.properties.model
        policy = $policy['properties']
        keyAuthentication = 'Disabled; Microsoft Entra bearer token required.'
        access = @($roles | ForEach-Object { @{ role = $_['roleDefinitionName']; scope = $_['scope']; principalType = $_['principalType'] } })
        accessCaveat = 'Snapshot of direct/inherited role assignments, not a complete effective-access audit (for example, group membership and privileged activation). Endpoint is public; no private endpoint is configured.'
        logging = 'This client stores the full fictional prompt/answer in cloud.json and the comparison/fallback HTML on this laptop. No Application Insights or Azure Monitor prompt-body logging is configured by this kit. Service-side abuse monitoring/retention is separate; consult current Azure terms.'
    }
}

function Assert-D4Capture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Capture, [Parameter(Mandatory)][string] $Source)
    if ($Capture['schema'] -ne 1 -or $Capture['source'] -ne $Source -or
        $Capture['provenance'] -ne 'real-endpoint-capture' -or
        [string]::IsNullOrWhiteSpace($Capture['answer']) -or
        [string]::IsNullOrWhiteSpace($Capture['model']) -or
        $Capture['elapsedMs'] -isnot [ValueType] -or
        -not [double]::IsFinite([double]$Capture['elapsedMs']) -or $Capture['elapsedMs'] -lt 0 -or
        $Capture['finishReason'] -notin @('stop', 'length') -or -not $Capture['governance']) {
        throw "Invalid $Source capture. No sample answer or invented timing will be substituted."
    }
    $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$Capture['prompt'])))
    if ($actualHash -cne $Capture['promptSha256']) { throw "$Source capture prompt hash does not match its text." }
    if (-not $Capture['generation'] -or $Capture['generation']['max_tokens'] -ne 180 -or
        $Capture['generation']['temperature'] -ne 0 -or $Capture['generation']['stream'] -ne $false) {
        throw "$Source capture uses unexpected generation settings; recapture both sides."
    }
}

function New-D4Comparison {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $StateDirectory,
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][ValidateSet('stage', 'fallback')][string] $Mode
    )
    $cloud = Read-D4Json (Join-Path $StateDirectory 'cloud.json')
    $local = Read-D4Json (Join-Path $StateDirectory 'local.json')
    Assert-D4Capture $cloud 'cloud'
    Assert-D4Capture $local 'local'
    if ($cloud.promptSha256 -cne $local.promptSha256) {
        throw 'Captures must use identical prompt text and generation settings. Recapture both sides after changing the prompt.'
    }
    if (-not $local.airplaneModeAttested) { throw 'Local capture needs explicit airplane-mode attestation before building the comparison.' }
    $pair = @($cloud, $local)
    if ([Security.Cryptography.RandomNumberGenerator]::GetInt32(2) -eq 1) { $pair = @($local, $cloud) }
    $payload = @{
        mode = $Mode
        builtAt = [DateTime]::UtcNow.ToString('o')
        prompt = $cloud.prompt
        a = $pair[0]
        b = $pair[1]
    } | ConvertTo-Json -Depth 40 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $template = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\comparison.template.html') -Raw
    $html = $template.Replace('__DEMO4_PAYLOAD_BASE64__', $encoded)
    $fullPath = [IO.Path]::GetFullPath($OutputPath)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $fullPath))
    $temporary = "$fullPath.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $html, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $fullPath, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
    return $fullPath
}

Export-ModuleMember -Function Invoke-D4Az, Write-D4Json, Read-D4Json, Get-D4Prompt, Assert-D4LocalEndpoint, New-D4Capture, Invoke-D4Request, Assert-D4CloudState, Assert-D4Capture, New-D4Comparison
