param name string
param location string
param identityId string
param hsmName string
param keyName string
param keyVersion string
param containerName string
param controllerPrincipalId string
@allowed(['Microsoft.Keyvault', 'Microsoft.Storage'])
param keySource string = 'Microsoft.Keyvault'

resource account 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  // checkov:skip=CKV_AZURE_36:Blob access is deliberately private-endpoint-only with bypass None; the required Storage CMK trusted AzureServices bypass belongs on Managed HSM, not this storage account.
  // checkov:skip=CKV_AZURE_206:Approved synthetic same-region LRS demo minimizes cost and excludes geo-replication; replication durability is an accepted demo limitation, not a production recommendation.
  name: name
  location: location
  tags: { purpose: 'demo2-only' }
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    networkAcls: { defaultAction: 'Deny', bypass: 'None', ipRules: [], virtualNetworkRules: [] }
    encryption: union({
      keySource: keySource
      requireInfrastructureEncryption: true
      services: { blob: { enabled: true, keyType: 'Account' }, file: { enabled: true, keyType: 'Account' } }
    }, keySource == 'Microsoft.Keyvault' ? {
      identity: { userAssignedIdentity: identityId }
      keyvaultproperties: {
        keyvaulturi: 'https://${hsmName}.managedhsm.azure.net'
        keyname: keyName
        keyversion: keyVersion
      }
    } : {})
  }
}
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: account
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: containerName
  properties: { publicAccess: 'None' }
}
output id string = account.id

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, controllerPrincipalId, 'blob-reader')
  scope: account
  properties: {
    principalId: controllerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
  }
}
resource bindingReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, controllerPrincipalId, 'arm-reader')
  scope: account
  properties: {
    principalId: controllerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}
