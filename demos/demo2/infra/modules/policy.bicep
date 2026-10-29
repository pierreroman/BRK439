targetScope = 'subscription'
param config object
var prefix = 'demo2-${config.nameSuffix}'
resource demo 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: config.resourceGroup
}

resource cmkDefinition 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${prefix}-storage-cmk'
  properties: {
    displayName: 'Demo 2 sandbox: deny storage without CMK'
    policyType: 'Custom'
    mode: 'All'
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.Storage/storageAccounts' }
          { field: 'Microsoft.Storage/storageAccounts/encryption.keySource', notEquals: 'Microsoft.Keyvault' }
        ]
      }
      then: { effect: 'Deny' }
    }
  }
}
resource vmDefinition 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${prefix}-confidential-vm'
  properties: {
    displayName: 'Demo 2 sandbox: approved confidential VMs only'
    policyType: 'Custom'
    mode: 'All'
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.Compute/virtualMachines' }
          {
            anyOf: [
              { field: 'Microsoft.Compute/virtualMachines/hardwareProfile.vmSize', notIn: config.allowedConfidentialVmSkus }
              { field: 'Microsoft.Compute/virtualMachines/securityProfile.securityType', notEquals: 'ConfidentialVM' }
            ]
          }
        ]
      }
      then: { effect: 'Deny' }
    }
  }
}
module assignments 'policy-assignments.bicep' = {
  name: '${prefix}-assignments'
  scope: demo
  params: {
    config: config
    cmkDefinitionId: cmkDefinition.id
    vmDefinitionId: vmDefinition.id
  }
}
