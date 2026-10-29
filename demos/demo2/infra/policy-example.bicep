@description('A separately authorized real deployment probe, never part of normal deployment.')
param config object
@allowed(['denied-region', 'platform-key', 'positive'])
param example string
@minLength(3)
@maxLength(24)
param candidateName string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: 'demo2-${config.nameSuffix}-live-storage'
}
module candidate 'modules/storage-account.bicep' = {
  name: 'candidate-${candidateName}'
  params: {
    name: candidateName
    location: example == 'denied-region' ? config.deniedLocation : config.location
    identityId: identity.id
    hsmName: config.hsmName
    keyName: config.targets.Live.keyName
    keyVersion: config.targets.Live.keyVersion
    containerName: config.container
    controllerPrincipalId: config.controllerPrincipalId
    keySource: example == 'platform-key' ? 'Microsoft.Storage' : 'Microsoft.Keyvault'
  }
}
