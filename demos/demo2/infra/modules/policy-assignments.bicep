param config object
param cmkDefinitionId string
param vmDefinitionId string
var prefix = 'demo2-${config.nameSuffix}'
resource locationPolicy 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${prefix}-locations'
  properties: {
    displayName: 'Demo 2 sandbox: allowed resource locations'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')
    enforcementMode: 'Default'
    parameters: { listOfAllowedLocations: { value: config.allowedLocations } }
  }
}
resource cmkAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${prefix}-cmk'
  properties: { policyDefinitionId: cmkDefinitionId, enforcementMode: 'Default' }
}
resource vmAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${prefix}-cvm'
  properties: { policyDefinitionId: vmDefinitionId, enforcementMode: 'Default' }
}
