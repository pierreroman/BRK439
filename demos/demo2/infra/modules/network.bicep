param config object
param prefix string
var tags = { purpose: 'demo2-only' }
var bastion = config.network.accessMode == 'bastion'

resource natIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (config.network.provisionNatGateway) {
  name: '${prefix}-egress-ip'
  location: config.location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}
resource nat 'Microsoft.Network/natGateways@2024-05-01' = if (config.network.provisionNatGateway) {
  name: '${prefix}-nat'
  location: config.location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIpAddresses: [{ id: natIp!.id }] }
}
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${prefix}-compute-nsg'
  location: config.location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowPrivateSsh'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: bastion ? config.network.bastionSubnetCidr : 'VirtualNetwork'
          destinationAddressPrefix: config.network.computeSubnetCidr
        }
      }
      {
        name: 'DenyOtherInbound'
        properties: {
          priority: 4096
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-vnet'
  location: config.location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [config.network.vnetCidr] }
    subnets: concat([
      {
        name: 'compute'
        properties: union({
          addressPrefix: config.network.computeSubnetCidr
          networkSecurityGroup: { id: nsg.id }
          defaultOutboundAccess: false
        }, config.network.provisionNatGateway ? { natGateway: { id: nat!.id } } : {})
      }
      {
        name: 'endpoints'
        properties: {
          addressPrefix: config.network.endpointSubnetCidr
          privateEndpointNetworkPolicies: 'Disabled'
          defaultOutboundAccess: false
        }
      }
    ], bastion ? [{
      name: 'AzureBastionSubnet'
      properties: { addressPrefix: config.network.bastionSubnetCidr }
    }] : [])
  }
}
resource bastionIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (bastion) {
  name: '${prefix}-bastion-ip'
  location: config.location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}
resource bastionHost 'Microsoft.Network/bastionHosts@2024-05-01' = if (bastion) {
  name: '${prefix}-bastion'
  location: config.location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    enableTunneling: true
    enableShareableLink: false
    scaleUnits: 2
    ipConfigurations: [{
      name: 'bastion'
      properties: {
        subnet: { id: '${vnet.id}/subnets/AzureBastionSubnet' }
        publicIPAddress: { id: bastionIp!.id }
      }
    }]
  }
}
var zoneNames = ['privatelink.managedhsm.azure.net', 'privatelink.blob.${environment().suffixes.storage}']
resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in zoneNames: {
  name: zone
  location: 'global'
  tags: tags
}]
resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, index) in zoneNames: {
  parent: zones[index]
  name: '${prefix}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]
output computeSubnetId string = '${vnet.id}/subnets/compute'
output endpointSubnetId string = '${vnet.id}/subnets/endpoints'
output hsmDnsZoneId string = zones[0].id
