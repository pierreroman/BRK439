param config object
var prefix = 'demo2-${config.nameSuffix}'
var targets = [
  { label: 'live', settings: config.targets.Live }
  { label: 'twin', settings: config.targets.Twin }
]
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = { name: '${prefix}-vnet' }
resource dns 'Microsoft.Network/privateDnsZones@2024-06-01' existing = { name: 'privatelink.blob.${environment().suffixes.storage}' }
resource identities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = [for target in targets: {
  name: '${prefix}-${target.label}-storage'
}]
module accounts 'modules/storage-account.bicep' = [for (target, index) in targets: {
  name: '${target.label}-storage'
  params: {
    name: target.settings.accountName
    location: config.location
    identityId: identities[index].id
    hsmName: config.hsmName
    keyName: target.settings.keyName
    keyVersion: target.settings.keyVersion
    containerName: config.container
    controllerPrincipalId: config.controllerPrincipalId
  }
}]
module endpoints 'modules/private-endpoint.bicep' = [for (target, index) in targets: {
  name: '${target.label}-endpoint'
  params: {
    name: '${prefix}-${target.label}-pe'
    location: config.location
    subnetId: '${vnet.id}/subnets/endpoints'
    resourceId: accounts[index].outputs.id
    groupId: 'blob'
    dnsZoneId: dns.id
  }
}]
output resources array = [for (target, index) in targets: {
  target: target.label
  id: accounts[index].outputs.id
}]
