targetScope = 'resourceGroup'

param storageAccountName string
param principalId string

@description('Existing portal assignment GUID. Empty selects a fresh identity-aware deterministic GUID.')
param existingAssignmentName string = ''

resource storage 'Microsoft.Storage/storageAccounts@2025-06-01' existing = {
  name: storageAccountName
}

var blobReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: empty(existingAssignmentName) ? guid(storage.id, principalId, blobReaderRoleId) : existingAssignmentName
  scope: storage
  properties: {
    roleDefinitionId: blobReaderRoleId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

output roleAssignmentId string = assignment.id
