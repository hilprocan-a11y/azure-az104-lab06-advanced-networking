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

@description('Enable the discard route to VNet B. Use only for the UDR exercise.')
param blockWithUdr bool = false

@description('Inbound ICMP filtering on NSG B. None restores default NSG rules.')
@allowed([
  'None'
  'Ip'
  'Asg'
])
param icmpFilterMode string = 'None'

@description('Verified current VM A private IPv4 used as the source of the ICMP test rule.')
param sourcePrivateIpv4 string = '10.60.1.4'

@description('Verified current VM B private IPv4 used only for the IP-targeted rule.')
param destinationPrivateIpv4 string = '10.61.1.4'

@description('Storage account name already verified in this lab; globally unique on a fresh deployment.')
param storageAccountName string = 'sthnlab06networking'

@description('Final state is PrivateOnly. AllNetworks is only for seeding a fresh test blob.')
@allowed([
  'PrivateOnly'
  'SelectedNetworks'
  'AllNetworks'
])
param storageAccessMode string = 'PrivateOnly'

@description('Keep the portal-created B link name when adopting the existing private DNS zone.')
param blobDnsLinkBName string = 'vdldlkm3mxxg6'

@description('Existing private link service connection name; read back before adopting the portal resource.')
param blobPrivateLinkConnectionName string = 'pe-lab06-blob'

@description('Existing DNS configuration name inside the default zone group; read back before adoption.')
param blobDnsConfigName string = 'privatelink-blob-core-windows-net'

@description('Existing assignment GUIDs keyed by VM suffix a/b. Leave empty only for fresh identities with no existing assignments.')
param existingBlobReaderRoleAssignmentNames object = {}

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

resource routeTableA 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-lab06-a'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    // The parent owns the array so setting false removes the test route.
    routes: blockWithUdr ? [
      {
        name: 'drop-to-vnet-b'
        properties: {
          addressPrefix: '10.61.0.0/16'
          nextHopType: 'None'
        }
      }
    ] : []
  }
}

resource asgB 'Microsoft.Network/applicationSecurityGroups@2024-05-01' = {
  name: 'asg-lab06-b'
  location: location
  tags: tags
  properties: {}
}

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
        properties: union({
          addressPrefix: node.subnetPrefix
          // Private subnet: no implicit default outbound connectivity.
          defaultOutboundAccess: false
        }, node.suffix == 'a' ? {
          routeTable: {
            id: routeTableA.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
              locations: [
                location
              ]
            }
          ]
        } : {
          privateEndpointNetworkPolicies: 'Disabled'
        })
      }
    ]
  }
}]

resource nsgs 'Microsoft.Network/networkSecurityGroups@2024-05-01' = [for node in nodes: {
  name: 'nsg-lab06-${node.suffix}'
  location: location
  tags: tags
  properties: {
    // The parent owns the array; None removes either test rule on redeployment.
    // NSG A always has no custom rules, including any mistakenly placed rule.
    securityRules: node.suffix == 'b' && icmpFilterMode != 'None' ? [
      {
        name: icmpFilterMode == 'Asg' ? 'deny-icmp-a-to-asg-b' : 'deny-icmp-a-to-b'
        properties: union({
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Icmp'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '${sourcePrivateIpv4}/32'
        }, icmpFilterMode == 'Asg' ? {
          destinationApplicationSecurityGroups: [
            {
              id: asgB.id
            }
          ]
        } : {
          destinationAddressPrefix: '${destinationPrivateIpv4}/32'
        })
      }
    ] : []
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
          applicationSecurityGroups: node.suffix == 'b' ? [
            {
              id: asgB.id
            }
          ] : []
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
  identity: {
    type: 'SystemAssigned'
  }
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

// Custom VM DNS records are service-managed by autoregistration, not declared here.
resource vmDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'lab06.internal'
  location: 'global'
  tags: tags
}

@batchSize(1)
resource vmDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (node, i) in nodes: {
  parent: vmDnsZone
  name: 'link-vnet-lab06-${node.suffix}'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnets[i].id
    }
    registrationEnabled: true
  }
}]

resource publicDnsZone 'Microsoft.Network/dnsZones@2018-05-01' = {
  name: 'lab06.example'
  location: 'global'
  tags: tags
  properties: {
    zoneType: 'Public'
  }
}

resource publicWww 'Microsoft.Network/dnsZones/A@2018-05-01' = {
  parent: publicDnsZone
  name: 'www'
  properties: {
    TTL: 60
    ARecords: [
      {
        ipv4Address: '192.0.2.10'
      }
    ]
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    isHnsEnabled: false
    isSftpEnabled: false
    isNfsV3Enabled: false
    allowCrossTenantReplication: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: storageAccessMode == 'PrivateOnly' ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: storageAccessMode == 'AllNetworks' ? 'Allow' : 'Deny'
      bypass: 'None'
      ipRules: []
      virtualNetworkRules: [
        {
          id: '${vnets[0].id}/subnets/subnet-workload'
          action: 'Allow'
        }
      ]
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: false
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-06-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: false
    changeFeed: {
      enabled: false
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource testContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01' = {
  parent: blobService
  name: 'endpoint-tests'
  properties: {
    publicAccess: 'None'
  }
}

// The nested deployment receives the newly created principal ID as an input.
module blobReaderRoles './blob-reader-role.bicep' = [for (node, i) in nodes: {
  name: 'lab06-blob-reader-${node.suffix}'
  params: {
    storageAccountName: storage.name
    principalId: vms[i].identity.principalId
    existingAssignmentName: existingBlobReaderRoleAssignmentNames[?node.suffix] ?? ''
  }
}]

resource blobDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

@batchSize(1)
resource blobDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (node, i) in nodes: {
  parent: blobDnsZone
  name: node.suffix == 'a' ? 'link-blob-vnet-lab06-a' : blobDnsLinkBName
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnets[i].id
    }
    registrationEnabled: false
  }
}]

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-lab06-blob'
  location: location
  tags: tags
  properties: {
    customNetworkInterfaceName: 'nic-pe-lab06-blob'
    subnet: {
      id: '${vnets[1].id}/subnets/subnet-workload'
    }
    privateLinkServiceConnections: [
      {
        name: blobPrivateLinkConnectionName
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

// This group manages the storage A record; do not also declare it manually.
resource blobDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: blobDnsConfigName
        properties: {
          privateDnsZoneId: blobDnsZone.id
        }
      }
    ]
  }
}

output virtualMachineNames array = [for (node, i) in nodes: vms[i].name]
output networkInterfaceNames array = [for (node, i) in nodes: nics[i].name]
output privateIpAddresses array = [for (node, i) in nodes: nics[i].properties.ipConfigurations[0].properties.privateIPAddress]
output peeringEnabled bool = enablePeering
output routeTableName string = routeTableA.name
output applicationSecurityGroupName string = asgB.name
output discardRouteEnabled bool = blockWithUdr
output activeIcmpFilterMode string = icmpFilterMode
output vmManagedIdentityPrincipalIds array = [for (node, i) in nodes: vms[i].identity.principalId]
output storageBlobEndpoint string = storage.properties.primaryEndpoints.blob
output finalStorageAccessMode string = storageAccessMode
output privateEndpointName string = blobPrivateEndpoint.name
output vmPrivateDnsZoneName string = vmDnsZone.name
output blobPrivateDnsZoneName string = blobDnsZone.name
output publicDnsNameServers array = publicDnsZone.properties.nameServers
