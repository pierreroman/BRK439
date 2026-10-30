#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $SubscriptionId,
    [ValidatePattern('^[a-zA-Z0-9-]{1,60}$')][string] $ResourceGroupName = 'rg-brk439-demo4',
    [ValidateSet('gpt-4.1-mini', 'gpt-4o-mini', 'gpt-4.1-nano')][string] $ModelName,
    [string] $ModelVersion,
    [ValidateRange(1, 10)][int] $Capacity = 1,
    [string] $PrincipalObjectId,
    [ValidateSet('User', 'ServicePrincipal')][string] $PrincipalType = 'User',
    [string] $StateDirectory = (Join-Path $env:LOCALAPPDATA 'BRK439\Demo4'),
    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Demo4.psm1') -Force

$catalog = Invoke-D4Az @('cognitiveservices', 'model', 'list', '--subscription', $SubscriptionId, '--location', 'canadacentral')
$supported = @($catalog | Where-Object {
    $_.model.format -eq 'OpenAI' -and $_.model.name -in @('gpt-4.1-mini', 'gpt-4o-mini', 'gpt-4.1-nano') -and
    @($_.model.skus | Where-Object { $_.name -eq 'Standard' }).Count -gt 0
})
$supported | ForEach-Object { [pscustomobject]@{ Model = $_.model.name; Version = $_.model.version; SKU = 'Standard'; Region = 'canadacentral' } } | Format-Table -AutoSize | Out-Host
if (-not $ModelName -or -not $ModelVersion) {
    Write-Host 'Choose an exact model/version above and rerun with -ModelName and -ModelVersion. Nothing was provisioned.'
    if (-not $supported.Count) { throw 'No supported regional Standard model found in Canada Central. Request availability/quota; do not use GlobalStandard as a sovereignty fallback.' }
    return
}
if (-not @($supported | Where-Object { $_.model.name -eq $ModelName -and $_.model.version -eq $ModelVersion }).Count) {
    throw 'The requested model/version does not support regional Standard in Canada Central. No alternative region/SKU will be selected.'
}
$usage = Invoke-D4Az @('cognitiveservices', 'usage', 'list', '--subscription', $SubscriptionId, '--location', 'canadacentral')
$quota = @($usage | Where-Object { $_.name.value -eq "OpenAI.Standard.$ModelName" })
if ($quota.Count -ne 1 -or ($quota[0].limit - $quota[0].currentValue) -lt $Capacity) {
    throw 'Cannot verify sufficient regional Standard quota. Review az cognitiveservices usage list and request quota; nothing was provisioned.'
}
Write-Host "Target: subscription $SubscriptionId; resource group $ResourceGroupName; Canada Central; $ModelName/$ModelVersion; Standard capacity $Capacity."
Write-Host 'Creates a public Foundry endpoint/project, disables key authentication, assigns one Entra inference caller and applies blocking Medium prompt/completion filters.'
Write-Host 'Billable model usage applies. Regional availability and quota do not guarantee deployment capacity.'
if (-not $Apply) { Write-Host 'Preflight only. Add -Apply to provision, after reviewing cost and your organization policy.'; return }
if (-not $PrincipalObjectId) {
    if ($PrincipalType -ne 'User') { throw 'Supply -PrincipalObjectId for a service principal.' }
    $PrincipalObjectId = Invoke-D4Az @('ad', 'signed-in-user', 'show', '--query', 'id')
}
if (-not [Guid]::TryParse($PrincipalObjectId, [ref]([Guid]::Empty))) { throw 'PrincipalObjectId must be an Entra object ID (GUID), not an application/client ID.' }
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $ResourceGroupName", 'Provision billable Demo 4 Foundry resources and RBAC in Canada Central')) { return }

$exists = Invoke-D4Az @('group', 'exists', '--subscription', $SubscriptionId, '--name', $ResourceGroupName)
if ($exists) {
    $group = Invoke-D4Az @('group', 'show', '--subscription', $SubscriptionId, '--name', $ResourceGroupName)
    if (-not $group['tags'] -or $group['tags']['demo'] -ne 'BRK439-Demo4') { throw 'Existing resource group is not tagged for Demo 4. Choose a new dedicated resource group; unrelated resources will not be modified.' }
} else {
    $null = Invoke-D4Az @('group', 'create', '--subscription', $SubscriptionId, '--name', $ResourceGroupName, '--location', 'canadacentral', '--tags', 'demo=BRK439-Demo4')
}
$template = Join-Path $PSScriptRoot 'infra\main.bicep'
$parameters = @("principalObjectId=$PrincipalObjectId", "principalType=$PrincipalType", "modelName=$ModelName", "modelVersion=$ModelVersion", "capacity=$Capacity")
$arguments = @('--subscription', $SubscriptionId, '--resource-group', $ResourceGroupName, '--template-file', $template, '--parameters') + $parameters
$null = Invoke-D4Az (@('deployment', 'group', 'validate') + $arguments)
$result = Invoke-D4Az (@('deployment', 'group', 'create', '--name', 'demo4') + $arguments)
$outputs = $result.properties.outputs
$config = @{
    subscriptionId = $SubscriptionId; resourceGroup = $ResourceGroupName
    accountName = $outputs.accountName.value; accountId = $outputs.accountId.value
    deploymentName = $outputs.deploymentName.value
    projectEndpoint = $outputs.projectEndpoint.value
}
Write-D4Json (Join-Path $StateDirectory 'cloud-config.json') $config
Write-Host "Deployment complete. Non-secret configuration saved to $StateDirectory\cloud-config.json."
Write-Host 'Wait for Entra role propagation before CaptureCloud. A failure is surfaced; never switch to API keys to hide it.'
