targetScope = 'resourceGroup'

@description('Region supporting Bastion Developer. The lab uses Central US.')
param location string = resourceGroup().location

@description('Public SSH key for VM A. Never supply a private key.')
@minLength(20)
param sshPublicKeyA string

@description('Public SSH key for VM B. Never supply a private key.')
@minLength(20)
param sshPublicKeyB string

param tags object = {
  Environment: 'Training'
  Lab: 'Lab06'
  Project: 'AZ104'
  Owner: 'Hilaire'
}

// Reuse the verified two-VM baseline, including peering and empty custom NSG rules.
module baseline './main.bicep' = {
  name: '${deployment().name}-baseline'
  params: {
    location: location
    sshPublicKeyA: sshPublicKeyA
    sshPublicKeyB: sshPublicKeyB
    tags: tags
  }
}

// Developer uses a VNet reference, without a dedicated subnet or public IP.
resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: 'vnet-lab06-a-bastion'
  location: location
  tags: tags
  sku: {
    name: 'Developer'
  }
  properties: {
    virtualNetwork: {
      id: resourceId('Microsoft.Network/virtualNetworks', 'vnet-lab06-a')
    }
  }
  dependsOn: [
    baseline
  ]
}

// Keep the existing regional Network Watcher outside this lab's deployment scope.
// Next hop and IP flow verify are operational tests, not deployable resources.
output bastionName string = bastion.name
output bastionSku string = bastion.sku.name
output virtualMachineNames array = baseline.outputs.virtualMachineNames
output networkInterfaceNames array = baseline.outputs.networkInterfaceNames
output privateIpAddresses array = baseline.outputs.privateIpAddresses
output peeringEnabled bool = baseline.outputs.peeringEnabled
