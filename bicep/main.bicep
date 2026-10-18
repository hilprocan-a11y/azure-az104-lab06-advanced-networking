targetScope = 'resourceGroup'

@description('Azure region. The selected ARM64 VM size was verified in Central US.')
param location string = resourceGroup().location

@description('Public SSH key for VM A. Never supply a private key.')
@minLength(20)
param sshPublicKeyA string

@description('Public SSH key for VM B. Never supply a private key.')
@minLength(20)
param sshPublicKeyB string

param adminUsername string = 'azureuser'

@description('ARM64 VM size; availability and quota must be checked before deployment.')
param vmSize string = 'Standard_B2pts_v2'

@description('Ubuntu ARM64 image version. latest can resolve to a newer build on a later deployment.')
param imageVersion string = 'latest'

@description('Set false only for an initial deployment without peering. Incremental deployments do not delete existing peerings when this becomes false.')
param enablePeering bool = true

param tags object = {
  Environment: 'Training'
  Lab: 'Lab06'
  Project: 'AZ104'
  Owner: 'Hilaire'
}

var nodes = [
  {
    suffix: 'a'
    addressSpace: '10.60.0.0/16'
    subnetPrefix: '10.60.1.0/24'
    publicKey: sshPublicKeyA
  }
  {
    suffix: 'b'
    addressSpace: '10.61.0.0/16'
    subnetPrefix: '10.61.1.0/24'
    publicKey: sshPublicKeyB
  }
]

resource vnets 'Microsoft.Network/virtualNetworks@2024-05-01' = [for node in nodes: {
  name: 'vnet-lab06-${node.suffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        node.addressSpace
      ]
    }
    subnets: [
      {
        name: 'subnet-workload'
        properties: {
          addressPrefix: node.subnetPrefix
          // Private subnet: no implicit default outbound connectivity.
          defaultOutboundAccess: false
        }
      }
    ]
  }
}]

resource nsgs 'Microsoft.Network/networkSecurityGroups@2024-05-01' = [for node in nodes: {
  name: 'nsg-lab06-${node.suffix}'
  location: location
  tags: tags
  properties: {
    // Azure supplies the default rules. No custom SSH rule is created.
    securityRules: []
  }
}]

resource nics 'Microsoft.Network/networkInterfaces@2024-05-01' = [for (node, i) in nodes: {
  name: 'nic-lab06-${node.suffix}'
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: false
    enableIPForwarding: false
    networkSecurityGroup: {
      id: nsgs[i].id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          primary: true
          privateIPAddressVersion: 'IPv4'
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${vnets[i].id}/subnets/subnet-workload'
          }
        }
      }
    ]
  }
}]

resource vms 'Microsoft.Compute/virtualMachines@2024-11-01' = [for (node, i) in nodes: {
  name: 'vm-lab06-${node.suffix}'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    // With this pre-2025-11-01 API, omit securityProfile for a non-Trusted Launch VM.
    // Explicit Standard requires the UseStandardSecurityType feature on this subscription.
    storageProfile: {
      diskControllerType: 'SCSI'
      imageReference: {
        publisher: 'canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server-arm64'
        version: imageVersion
      }
      osDisk: {
        name: 'osdisk-lab06-${node.suffix}'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'vm-lab06-${node.suffix}'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: node.publicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'ImageDefault'
          assessmentMode: 'ImageDefault'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[i].id
          properties: {
            primary: true
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      // No storage URI means Azure-managed boot diagnostics storage.
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}]

// Serialize the two network updates to avoid overlapping peering operations.
@batchSize(1)
resource peerings 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = [for (node, i) in nodes: if (enablePeering) {
  name: '${vnets[i].name}/peer-${node.suffix}-to-${nodes[1 - i].suffix}'
  properties: {
    remoteVirtualNetwork: {
      id: vnets[1 - i].id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}]

output virtualMachineNames array = [for (node, i) in nodes: vms[i].name]
output networkInterfaceNames array = [for (node, i) in nodes: nics[i].name]
output privateIpAddresses array = [for (node, i) in nodes: nics[i].properties.ipConfigurations[0].properties.privateIPAddress]
output peeringEnabled bool = enablePeering
