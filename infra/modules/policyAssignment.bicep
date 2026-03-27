targetScope = 'resourceGroup'

@description('Name of the policy assignment')
param policyAssignmentName string

@description('Location for the policy assignment (required when using a managed identity for remediation)')
param location string = resourceGroup().location

@description('The policy definition resource ID')
param policyDefinitionId string

@description('The name of the AAD group/user to assign as a database user')
param principalNameToAssign string

@description('The resource ID of the user-assigned managed identity to run the deployment script')
param userAssignedIdentityResourceId string

resource policyAssignment 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: policyAssignmentName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    displayName: 'Enforce AAD Role Assignment on Azure SQL'
    policyDefinitionId: policyDefinitionId
    parameters: {
      principalNameToAssign: {
        value: principalNameToAssign
      }
      userAssignedIdentityResourceId: {
        value: userAssignedIdentityResourceId
      }
    }
  }
}

@description('The resource ID of the policy assignment')
output policyAssignmentId string = policyAssignment.id
