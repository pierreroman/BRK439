param config object
param budgetStartDate string
param bootstrapEnabled bool = false

var prefix = 'demo2-${config.nameSuffix}'
var tags = { purpose: 'demo2-only' }

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    config: config
    prefix: prefix
  }
}

resource controller 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-controller'
  location: config.location
  tags: tags
}
resource storageIdentities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [for target in ['live', 'twin']: {
  name: '${prefix}-${target}-storage'
  location: config.location
  tags: tags
}]
resource bootstrap 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (bootstrapEnabled) {
  name: '${prefix}-bootstrap'
  location: config.location
  tags: tags
}
resource bootstrapReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (bootstrapEnabled) {
  name: guid(resourceGroup().id, bootstrap!.id, 'bootstrap-reader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: bootstrap!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource hsm 'Microsoft.KeyVault/managedHSMs@2024-11-01' = {
  name: config.hsmName
  location: config.location
  tags: tags
  sku: { name: 'Standard_B1', family: 'B' }
  properties: {
    tenantId: subscription().tenantId
    initialAdminObjectIds: bootstrapEnabled ? union(config.initialAdminObjectIds, [bootstrap!.properties.principalId]) : config.initialAdminObjectIds
    enableSoftDelete: true
    softDeleteRetentionInDays: config.hsmRetentionDays
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      // Storage service-side CMK wrapping does not traverse the VM private endpoint.
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

module hsmEndpoint 'modules/private-endpoint.bicep' = {
  name: 'hsm-endpoint'
  params: {
    name: '${prefix}-hsm-pe'
    location: config.location
    subnetId: network.outputs.endpointSubnetId
    resourceId: hsm.id
    groupId: 'managedhsm'
    dnsZoneId: network.outputs.hsmDnsZoneId
  }
}

module host 'modules/host.bicep' = {
  name: 'host'
  params: {
    config: config
    prefix: prefix
    subnetId: network.outputs.computeSubnetId
    controllerIdentityId: controller.id
    bootstrapIdentityId: bootstrapEnabled ? bootstrap!.id : ''
    adminUsername: bootstrapEnabled ? 'demoadmin' : config.sshUser
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    config: config
    prefix: prefix
      vmId: host.outputs.vmId
      hsmId: hsm.id
    budgetStartDate: budgetStartDate
  }
}

output resources object = {
  controllerIdentityId: controller.id
  controllerIdentityClientId: controller.properties.clientId
  controllerPrincipalId: controller.properties.principalId
  liveStorageIdentityPrincipalId: storageIdentities[0].properties.principalId
  twinStorageIdentityPrincipalId: storageIdentities[1].properties.principalId
  hsmUri: hsm.properties.hsmUri
  vmId: host.outputs.vmId
  custodyDiskId: host.outputs.custodyDiskId
  bootstrapIdentityId: bootstrapEnabled ? bootstrap!.id : ''
  bootstrapClientId: bootstrapEnabled ? bootstrap!.properties.clientId : ''
  bootstrapPrincipalId: bootstrapEnabled ? bootstrap!.properties.principalId : ''
  bootstrapReaderAssignmentId: bootstrapEnabled ? bootstrapReader!.id : ''
  workspaceId: monitoring.outputs.workspaceId
  activationGate: 'Activate the HSM manually through approved private access before Initialize-Hsm; keys and local RBAC must precede the storage stage.'
}
