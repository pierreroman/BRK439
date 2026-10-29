[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [switch]$AuthorizeLiveChanges,
    [switch]$ActivationConfirmed,
    [string]$ResolvedConfigPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1') -Force
$config = Import-DemoConfig -Path $ConfigPath -Phase Foundation
if (-not $AuthorizeLiveChanges) {
    [pscustomobject]@{
        Mode = 'OfflinePlan'
        Activation = 'STOP: custodians must manually activate HSM over private access with approved wrapping certificates/quorum. This script never generates or outputs private keys/security-domain material.'
        Bootstrap = 'After activation, create or resolve two non-exportable RSA-HSM CMKs; grant storage encryption per key and recovery attribute read/write per key; persist pinned versions in protected config.'
    }
    return
}
if (-not $ActivationConfirmed -or [string]::IsNullOrWhiteSpace($ResolvedConfigPath)) {
    throw 'Manual activation confirmation and an explicit protected -ResolvedConfigPath are mandatory.'
}
foreach ($field in 'controllerIdentityClientId', 'controllerPrincipalId', 'liveStorageIdentityPrincipalId', 'twinStorageIdentityPrincipalId') {
    Assert-DemoGuid -Value $config[$field] -Name $field
}
Assert-DemoAzureContext -Config $config
if (-not $PSCmdlet.ShouldProcess($config.hsmName, 'Create/resolve dedicated CMKs and key-scoped HSM local roles after manual activation')) { return }
foreach ($identity in @(
    @{ suffix = 'controller'; principalField = 'controllerPrincipalId' },
    @{ suffix = 'live-storage'; principalField = 'liveStorageIdentityPrincipalId' },
    @{ suffix = 'twin-storage'; principalField = 'twinStorageIdentityPrincipalId' }
)) {
    $actual = Invoke-AzJson -Arguments @('identity', 'show', '--resource-group', $config.resourceGroup, '--name', "demo2-$($config.nameSuffix)-$($identity.suffix)")
    if ($actual.principalId -ne $config[$identity.principalField] -or
        ($identity.suffix -eq 'controller' -and $actual.clientId -ne $config.controllerIdentityClientId)) {
        throw 'Configured identity IDs do not match the dedicated foundation identities.'
    }
}
if (@($config.controllerPrincipalId, $config.liveStorageIdentityPrincipalId, $config.twinStorageIdentityPrincipalId, $config.manualRecoveryObjectId | Sort-Object -Unique).Count -ne 4) {
    throw 'Controller, per-storage identities and separate manual-recovery operator must be distinct principals.'
}
# An unactivated or unreachable HSM must fail before any key or role mutation.
$existingKeys = @(Invoke-AzJson -Arguments @('keyvault', 'key', 'list', '--hsm-name', $config.hsmName))
$roleName = "Demo2-$($config.nameSuffix)-RecoveryAttributes"
$actions = @('Microsoft.KeyVault/managedHsm/keys/read/action', 'Microsoft.KeyVault/managedHsm/keys/write/action')
$definitions = @(Invoke-AzJson -Arguments @('keyvault', 'role', 'definition', 'list', '--hsm-name', $config.hsmName))
$role = @($definitions | Where-Object {
    $properties = if ($_['properties']) { $_['properties'] } else { $_ }
    $properties['roleName'] -eq $roleName
})
if ($role.Count -gt 1) { throw 'Ambiguous recovery role definition.' }
if ($role.Count -eq 0) {
    $definition = @{ roleName = $roleName; description = 'Dedicated Demo 2 key attribute recovery only'; actions = @(); notActions = @(); dataActions = $actions; notDataActions = @() }
    $definitionPath = New-TemporaryFile
    try {
        $definition | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $definitionPath.FullName -Encoding utf8
        $role = @(Invoke-AzJson -Arguments @('keyvault', 'role', 'definition', 'create', '--hsm-name', $config.hsmName, '--role-definition', ('@' + $definitionPath.FullName)))
    } finally {
        Remove-Item -LiteralPath $definitionPath.FullName -Force
    }
} else {
    $properties = if ($role[0]['properties']) { $role[0]['properties'] } else { $role[0] }
    $permissions = $properties['permissions']
    if (@($permissions).Count -ne 1 -or @($permissions[0].actions).Count -ne 0 -or @($permissions[0].notActions).Count -ne 0 -or
        @($permissions[0].notDataActions).Count -ne 0 -or
        (@($permissions[0].dataActions | Sort-Object) -join ',') -cne (@($actions | Sort-Object) -join ',')) {
        throw 'Existing recovery role is not the exact approved read/write dataActions role.'
    }
}
function Initialize-KeyLocalRole {
    param([string]$PrincipalId, [string]$Scope, [string]$RoleName, [string]$RoleId)
    $assignments = @(Invoke-AzJson -Arguments @('keyvault', 'role', 'assignment', 'list', '--hsm-name', $config.hsmName, '--scope', $Scope))
    $matching = @($assignments | Where-Object {
        $properties = if ($_['properties']) { $_['properties'] } else { $_ }
        $properties['principalId'] -eq $PrincipalId -and
        $properties['scope'] -eq $Scope -and
        $properties['roleDefinitionId'] -match ([regex]::Escape($RoleId) + '$')
    })
    if ($matching.Count -eq 0) {
        $null = Invoke-AzJson -Arguments @('keyvault', 'role', 'assignment', 'create', '--hsm-name', $config.hsmName, '--scope', $Scope, '--role', $RoleName, '--assignee-object-id', $PrincipalId)
    }
}
$recoveryRoleId = if ($role[0]['name']) { $role[0]['name'] } else { ($role[0]['id'] -split '/')[-1] }
Assert-DemoGuid -Value $recoveryRoleId -Name 'recoveryRoleId'
foreach ($target in 'Live', 'Twin') {
    $settings = $config.targets[$target]
    if ($settings.keyVersion) {
        $key = Invoke-AzJson -Arguments @('keyvault', 'key', 'show', '--id', (Get-DemoKeyUri -Config $config -Target $target))
    } elseif (@($existingKeys | Where-Object { $_.kid -match "/keys/$([regex]::Escape($settings.keyName))(/|$)" }).Count -gt 0) {
        $key = Invoke-AzJson -Arguments @('keyvault', 'key', 'show', '--hsm-name', $config.hsmName, '--name', $settings.keyName)
    } else {
        $key = Invoke-AzJson -Arguments @('keyvault', 'key', 'create', '--hsm-name', $config.hsmName, '--name', $settings.keyName, '--kty', 'RSA-HSM', '--size', '3072', '--ops', 'wrapKey', 'unwrapKey', '--exportable', 'false')
    }
    if ($key.key.kty -ne 'RSA-HSM' -or $key.attributes.enabled -ne $true -or
        ($key.attributes.ContainsKey('exportable') -and $key.attributes.exportable -eq $true) -or
        (@($key.key.keyOps | Sort-Object) -join ',') -cne 'unwrapKey,wrapKey') {
        throw "$target key is not an enabled, dedicated RSA-HSM wrapping key."
    }
    $prefix = "https://$($config.hsmName).managedhsm.azure.net/keys/$($settings.keyName)/"
    if (-not $key.key.kid.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected HSM key identifier.' }
    $settings.keyVersion = $key.key.kid.Substring($prefix.Length)
    if ($settings.keyVersion -notmatch '^[a-fA-F0-9]{32}$') { throw 'Invalid resolved key version.' }
    $principal = if ($target -eq 'Live') { $config.liveStorageIdentityPrincipalId } else { $config.twinStorageIdentityPrincipalId }
    $scope = "/keys/$($settings.keyName)"
    Initialize-KeyLocalRole -PrincipalId $principal -Scope $scope -RoleName 'Managed HSM Crypto Service Encryption User' -RoleId '33413926-3206-4cdd-b39a-83574fe37a17'
    foreach ($recovery in $config.controllerPrincipalId, $config.manualRecoveryObjectId) {
        Initialize-KeyLocalRole -PrincipalId $recovery -Scope $scope -RoleName $roleName -RoleId $recoveryRoleId
    }
    [pscustomobject]@{ Target = $target; KeyUri = $key.key.kid; LocalRbacScope = $scope }
}
$null = $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ResolvedConfigPath -NoNewline
Write-Output "Pinned configuration saved to the explicitly selected path. Protect it; verify identity propagation before storage deployment."
