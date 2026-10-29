param config object
param prefix string
param subnetId string
param controllerIdentityId string
param bootstrapIdentityId string = ''
param adminUsername string = config.sshUser

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${prefix}-nic'
  location: config.location
  tags: { purpose: 'demo2-only' }
  properties: {
    ipConfigurations: [{
      name: 'private'
      properties: {
        privateIPAllocationMethod: 'Dynamic'
        subnet: { id: subnetId }
      }
    }]
  }
}
resource custodyDisk 'Microsoft.Compute/disks@2024-03-02' = {
  // checkov:skip=CKV_AZURE_93:Disposable demo custody disk deliberately uses platform-managed encryption independent of the two revocable demo CMKs; single-operator online custody is an approved demo-only exception.
  name: '${prefix}-custody'
  location: config.location
  tags: { purpose: 'demo2-only' }
  sku: { name: 'StandardSSD_LRS' }
  properties: {
    creationData: { createOption: 'Empty' }
    diskSizeGB: 32
    encryption: { type: 'EncryptionAtRestWithPlatformKey' }
    networkAccessPolicy: 'DenyAll'
    publicNetworkAccess: 'Disabled'
  }
}
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  // checkov:skip=CKV_AZURE_50:AMA is the single explicitly declared extension required for independently observed watchdog telemetry; disabling extensions would break monitoring.
  // checkov:skip=CKV_AZURE_97:The OS uses TPM-bound confidential disk encryption and the separate custody disk uses platform-managed encryption at rest; no unvalidated encryption-at-host combination is enabled. See infra/README.md.
  // checkov:skip=CKV_AZURE_151:DiskWithVMGuestState provides confidential OS disk encryption; generic ADE/EncryptionAtHost detection does not model it. Recovery boot must remain independent of both revocable demo CMKs.
  name: '${prefix}-access'
  location: config.location
  tags: { purpose: 'demo2-only' }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: union({ '${controllerIdentityId}': {} }, empty(bootstrapIdentityId) ? {} : { '${bootstrapIdentityId}': {} })
  }
  properties: {
    hardwareProfile: { vmSize: config.vmSize }
    securityProfile: {
      securityType: 'ConfidentialVM'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
    osProfile: {
      computerName: '${prefix}-access'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: config.sshPublicKey }] }
      }
    }
    storageProfile: {
      imageReference: config.imageReference
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: {
          storageAccountType: 'Premium_LRS'
          securityProfile: { securityEncryptionType: 'DiskWithVMGuestState' }
        }
        deleteOption: 'Delete'
      }
      dataDisks: [{
        lun: 0
        createOption: 'Attach'
        managedDisk: { id: custodyDisk.id }
        caching: 'None'
        deleteOption: 'Detach'
      }]
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}
resource ama 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: config.location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}
output vmId string = vm.id
output custodyDiskId string = custodyDisk.id
