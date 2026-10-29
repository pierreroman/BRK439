targetScope = 'subscription'

@description('Explicit, validated demo configuration. Never contains credentials or HSM security-domain material.')
param config object
@allowed(['foundation', 'storage'])
param stage string
param installationId string = ''
param bootstrapEnabled bool = false
param budgetStartDate string = utcNow('yyyy-MM-01T00:00:00Z')

resource demo 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: config.resourceGroup
  location: config.location
  tags: {
    purpose: 'demo2-only'
    installationId: installationId
  }
}

module policy 'modules/policy.bicep' = if (stage == 'foundation' && config.policyMode == 'sandbox') {
  name: 'demo2-sandbox-policy'
  params: { config: config }
  dependsOn: [demo]
}

module foundation 'foundation.bicep' = if (stage == 'foundation') {
  name: 'demo2-foundation'
  scope: demo
  params: {
    config: config
    budgetStartDate: budgetStartDate
    bootstrapEnabled: bootstrapEnabled
  }
}

module storage 'storage.bicep' = if (stage == 'storage') {
  name: 'demo2-storage'
  scope: demo
  params: {
    config: config
  }
}

output foundationResources object = stage == 'foundation' ? foundation!.outputs.resources : {}
output storageResources array = stage == 'storage' ? storage!.outputs.resources : []
