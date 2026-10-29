[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('Live','Twin')][string]$Target,
    [switch]$AuthorizeKeyRestore
)
$ErrorActionPreference = 'Stop'
if (-not $AuthorizeKeyRestore) { throw 'Manual recovery requires -AuthorizeKeyRestore and a separately authorized recovery login.' }
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1') -Force
$config = Import-DemoConfig -Path $ConfigPath -Phase Runtime
$accountOutput = & az account show --output json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'az account show failed; no mutation attempted.' }
$account = ($accountOutput -join "`n") | ConvertFrom-Json
if ($account.tenantId -ne $config.tenantId -or $account.id -ne $config.subscriptionId) { throw 'Active Azure tenant/subscription does not match the explicit demo configuration.' }
$key = $config.targets.$Target
if ($config.hsmName -cnotmatch '^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$' -or
    $key.keyName -cnotmatch '^[A-Za-z0-9-]{1,127}$' -or $key.keyVersion -cnotmatch '^[a-fA-F0-9]{32}$') { throw 'Invalid pinned HSM key identity.' }
$uri = "https://$($config.hsmName).managedhsm.azure.net/keys/$($key.keyName)/$($key.keyVersion)"
if ($PSCmdlet.ShouldProcess($uri, 'Enable only this exact pinned key version for manual recovery')) {
    & az keyvault key set-attributes --id $uri --enabled true --only-show-errors --query '{kid:key.kid,enabled:attributes.enabled}' --output json
    if ($LASTEXITCODE -ne 0) { throw 'Manual key enable failed. Preserve recovery intent and escalate.' }
    $result = & az keyvault key show --id $uri --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw 'Enable submitted but key readback failed; recovery is not verified.' }
    $verified = ($result -join "`n") | ConvertFrom-Json
    if ($verified.attributes.enabled -ne $true -or $verified.key.kid -ne $uri) { throw 'Exact pinned key enabled state was not verified.' }
    Write-Output "KEY_ENABLED: $uri. STORAGE_READ_RESTORED is not yet established. Reconcile all in-flight disables and perform a fresh authenticated document read."
}
