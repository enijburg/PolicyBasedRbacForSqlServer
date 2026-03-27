targetScope = 'resourceGroup'

@description('Name of the user-assigned managed identity')
param managedIdentityName string

@description('Location for the managed identity')
param location string = resourceGroup().location

// Built-in Contributor role definition ID
var contributorRoleDefinitionId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
}

resource contributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, contributorRoleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleDefinitionId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('The resource ID of the managed identity')
output managedIdentityResourceId string = managedIdentity.id

@description('The principal ID (object ID) of the managed identity')
output managedIdentityPrincipalId string = managedIdentity.properties.principalId

@description('The client ID of the managed identity')
output managedIdentityClientId string = managedIdentity.properties.clientId
