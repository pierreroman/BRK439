[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [ValidateSet('Foundation', 'Runtime')][string]$Phase = 'Foundation',
    [switch]$AuthorizeAzureReads,
    [switch]$ExistingPrivateConnectivityApproved,
    [switch]$ExistingEgressApproved
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1') -Force
$config = Import-DemoConfig -Path $ConfigPath -Phase $Phase
if ($config.network.accessMode -eq 'existing-private-connection' -and -not $ExistingPrivateConnectivityApproved) {
    throw 'Document/approve private routing and private DNS connectivity into the new demo VNet, then pass -ExistingPrivateConnectivityApproved.'
}
if (-not $config.network.provisionNatGateway -and -not $ExistingEgressApproved) {
    throw 'No implicit VM outbound access: document/approve routed existing egress for Entra, ARM, AMA and package endpoints, then pass -ExistingEgressApproved.'
}
if ($config.network.accessMode -eq 'bastion') {
    $cidr = $config.network.bastionSubnetCidr
    if ($cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/(\d|[12]\d|3[0-2])$' -or [int]$cidr.Split('/')[1] -gt 26) {
        throw 'Bastion Standard requires an explicit AzureBastionSubnet CIDR of /26 or larger.'
    }
    function Get-NetworkRange([string]$Value) {
        $ip, $prefix = $Value.Split('/')
        $bytes = ([ipaddress]::Parse($ip)).GetAddressBytes()
        $number = ([uint64]$bytes[0] -shl 24) + ([uint64]$bytes[1] -shl 16) + ([uint64]$bytes[2] -shl 8) + $bytes[3]
        $size = [uint64][math]::Pow(2, 32 - [int]$prefix)
        if ($number % $size) { throw 'CIDR must use its network address.' }
        return @{ start = $number; end = $number + $size - 1 }
    }
    $bastion = Get-NetworkRange $cidr
    $vnet = Get-NetworkRange $config.network.vnetCidr
    if ($bastion.start -lt $vnet.start -or $bastion.end -gt $vnet.end) { throw 'Bastion subnet must lie within the VNet.' }
    foreach ($name in 'computeSubnetCidr', 'endpointSubnetCidr') {
        $other = Get-NetworkRange $config.network[$name]
        if ($bastion.start -le $other.end -and $other.start -le $bastion.end) { throw 'Bastion subnet overlaps another subnet.' }
    }
}
Get-Command az -ErrorAction Stop | Select-Object Name, Source
if (-not $AuthorizeAzureReads) {
    [pscustomobject]@{
        Mode = 'Offline'
        Configuration = 'Valid'
        LiveChecks = 'NOT RUN: context, aliases, policies/exemptions, availability, quota, image, private routes, activation and local RBAC.'
    }
    return
}
Assert-DemoAzureContext -Config $config
$aliases = @{}
foreach ($provider in 'Microsoft.Storage', 'Microsoft.Compute') {
    $result = Invoke-AzJson -Arguments @('provider', 'show', '--namespace', $provider, '--expand', 'resourceTypes/aliases')
    if ($result.registrationState -ne 'Registered') { throw "$provider must be registered by an authorized platform operator." }
    foreach ($type in $result.resourceTypes) {
        foreach ($alias in $type.aliases) { $aliases[$alias.name] = $alias }
    }
}
foreach ($required in @(
    'Microsoft.Storage/storageAccounts/encryption.keySource',
    'Microsoft.Compute/virtualMachines/hardwareProfile.vmSize',
    'Microsoft.Compute/virtualMachines/securityProfile.securityType'
)) {
    if (-not $aliases.ContainsKey($required)) { throw "Required policy alias is unavailable: $required" }
    [pscustomobject]@{ PolicyAlias = $required; Validated = $true }
}
$scope = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroup)"
$assignments = Invoke-AzJson -Arguments @('policy', 'assignment', 'list', '--scope', $scope, '--disable-scope-strict-match', 'true')
$exemptions = Invoke-AzJson -Arguments @('policy', 'exemption', 'list', '--scope', $scope, '--disable-scope-strict-match', 'true')
[pscustomobject]@{ EffectiveAssignments = $assignments; Exemptions = $exemptions }
if ($config.policyMode -eq 'existing-slz') {
    foreach ($id in $config.existingPolicyAssignmentIds) {
        $assignment = @($assignments | Where-Object { $_.id -eq $id })
        if ($assignment.Count -ne 1 -or $assignment[0].enforcementMode -eq 'DoNotEnforce') {
            throw "Required existing SLZ assignment is absent or non-enforcing: $id"
        }
    }
}
$skus = Invoke-AzJson -Arguments @('vm', 'list-skus', '--location', $config.location, '--size', $config.vmSize, '--all')
$available = @($skus | Where-Object { $_.name -eq $config.vmSize -and $_.resourceType -eq 'virtualMachines' -and $_.restrictions.Count -eq 0 })
if ($available.Count -eq 0) { throw 'Requested confidential VM SKU is unavailable or restricted.' }
$capabilities = @($available[0].capabilities | Where-Object { $_.name -eq 'ConfidentialComputingType' -and $_.value -notin @('', 'None') })
if ($capabilities.Count -eq 0) { throw 'SKU does not advertise confidential-computing capability.' }
$urn = '{0}:{1}:{2}:{3}' -f $config.imageReference.publisher, $config.imageReference.offer, $config.imageReference.sku, $config.imageReference.version
$image = Invoke-AzJson -Arguments @('vm', 'image', 'show', '--location', $config.location, '--urn', $urn)
if (@($image.features | Where-Object { $_.name -eq 'SecurityType' -and $_.value -match 'ConfidentialVM' }).Count -eq 0) {
    throw 'Image does not advertise ConfidentialVM support; validate the image/SKU pairing.'
}
$usage = Invoke-AzJson -Arguments @('vm', 'list-usage', '--location', $config.location)
[pscustomobject]@{
    Mode = 'AuthorizedAzureReadOnly'
    Image = $image
    VmQuota = $usage
    RemainingGate = 'Operator must review quota, HSM regional capacity/pricing, all inherited policies/exemptions, private DNS/egress and Storage trusted-service bypass. No readiness claim.'
}
