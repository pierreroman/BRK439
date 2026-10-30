[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [ValidateSet('foundation', 'storage')][string]$Stage = 'foundation',
    [switch]$AuthorizeDeployment,
    [switch]$PreflightReviewed,
    [switch]$HsmBootstrapVerified,
    [switch]$ExistingPrivateConnectivityApproved,
    [switch]$ExistingEgressApproved,
    [ValidatePattern('^$|^[a-f0-9]{32}$')][string]$InstallationId = '',
    [switch]$BootstrapEnabled
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1') -Force
$phase = if ($Stage -eq 'foundation') { 'Foundation' } else { 'Runtime' }
$config = Import-DemoConfig -Path $ConfigPath -Phase $phase
$preflight = @{
    ConfigPath = $ConfigPath; Phase = $phase
    ExistingPrivateConnectivityApproved = $ExistingPrivateConnectivityApproved
    ExistingEgressApproved = $ExistingEgressApproved
}
& (Join-Path $PSScriptRoot 'Test-AzurePrerequisites.ps1') @preflight
$template = Join-Path $PSScriptRoot '..\infra\main.bicep'
if (-not $AuthorizeDeployment) {
    [pscustomobject]@{
        Mode = 'OfflinePlan'; Stage = $Stage; Template = $template
        Next = 'Opt-in Azure read preflight; review policies, pricing and budget; deploy foundation; manually activate HSM; bootstrap keys/local RBAC; then deploy storage.'
    }
    return
}
if (-not $PreflightReviewed) { throw 'Run and review opt-in Azure preflight, costs and inherited policy/exemption evidence, then pass -PreflightReviewed.' }
if ($Stage -eq 'storage' -and -not $HsmBootstrapVerified) {
    throw 'Storage cannot be created until manual HSM activation and key-scoped HSM local RBAC are verified. Pass -HsmBootstrapVerified only after Initialize-Hsm.'
}
Assert-DemoAzureContext -Config $config
if (-not $PSCmdlet.ShouldProcess("$($config.subscriptionId)/$($config.resourceGroup)", "Deploy $Stage infrastructure (billable; purge-protected HSM)")) { return }
if ($Stage -eq 'storage') {
    foreach ($target in 'Live', 'Twin') {
        $key = Invoke-AzJson -Arguments @('keyvault', 'key', 'show', '--id', (Get-DemoKeyUri -Config $config -Target $target))
        if ($key.attributes.enabled -ne $true -or $key.key.kty -ne 'RSA-HSM') { throw "$target pinned CMK must be enabled RSA-HSM." }
        $assignments = Invoke-AzJson -Arguments @('keyvault', 'role', 'assignment', 'list', '--hsm-name', $config.hsmName, '--scope', "/keys/$($config.targets[$target].keyName)")
        $principal = if ($target -eq 'Live') { $config.liveStorageIdentityPrincipalId } else { $config.twinStorageIdentityPrincipalId }
        if (@($assignments | Where-Object {
            $properties = if ($_['properties']) { $_['properties'] } else { $_ }
            $properties['principalId'] -eq $principal -and
            $properties['roleDefinitionId'] -match '33413926-3206-4cdd-b39a-83574fe37a17$' -and
            $properties['scope'] -eq "/keys/$($config.targets[$target].keyName)"
        }).Count -eq 0) {
            throw "$target storage identity lacks verified per-key Managed HSM Crypto Service Encryption User local role."
        }
    }
}
$parameters = 'config=@' + (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
$result = Invoke-AzJson -Arguments @(
    'deployment', 'sub', 'create', '--name', $(if ($InstallationId) { if ($Stage -eq 'foundation') { "demo2-$InstallationId" } else { "demo2-storage-$InstallationId" } } else { "demo2-$($config.nameSuffix)-$Stage" }),
    '--subscription', $config.subscriptionId, '--location', $config.location,
    '--template-file', $template, '--parameters', $parameters, "stage=$Stage",
    "installationId=$InstallationId", "bootstrapEnabled=$($BootstrapEnabled.ToString().ToLowerInvariant())"
)
$result.properties.outputs
