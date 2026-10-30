targetScope = 'resourceGroup'

@allowed(['canadacentral'])
param location string = 'canadacentral'

param accountName string = 'd4-${uniqueString(resourceGroup().id)}'
param principalObjectId string
@allowed(['User', 'ServicePrincipal'])
param principalType string = 'User'
@allowed(['gpt-4.1-mini', 'gpt-4o-mini', 'gpt-4.1-nano'])
param modelName string
param modelVersion string
@minValue(1)
@maxValue(10)
param capacity int = 1

var policyName = 'demo4-filter'
var filterSettings = [
  { name: 'Hate', source: 'Prompt' }
  { name: 'Sexual', source: 'Prompt' }
  { name: 'Violence', source: 'Prompt' }
  { name: 'Selfharm', source: 'Prompt' }
  { name: 'Hate', source: 'Completion' }
  { name: 'Sexual', source: 'Completion' }
  { name: 'Violence', source: 'Completion' }
  { name: 'Selfharm', source: 'Completion' }
]

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  tags: { demo: 'BRK439-Demo4' }
  properties: {
    customSubDomainName: accountName
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: 'demo4'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Demo 4 - AI taste test'
    description: 'Fictional incident summarization; regional Canada Central deployment.'
  }
}

resource filter 'Microsoft.CognitiveServices/accounts/raiPolicies@2025-06-01' = {
  parent: account
  name: policyName
  properties: {
    basePolicyName: 'Microsoft.Default'
    mode: 'Blocking'
    contentFilters: [for setting in filterSettings: {
      name: setting.name
      source: setting.source
      enabled: true
      blocking: true
      severityThreshold: 'Medium'
    }]
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: 'taste-test'
  sku: {
    name: 'Standard'
    capacity: capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    raiPolicyName: filter.name
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

var inferenceRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
resource caller 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, principalObjectId, inferenceRole)
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: inferenceRole
  }
}

output accountName string = account.name
output accountId string = account.id
output projectId string = project.id
output projectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${project.name}'
output endpoint string = 'https://${account.name}.openai.azure.com'
output deploymentName string = deployment.name
output region string = location
output sku string = deployment.sku.name
output policyName string = filter.name
