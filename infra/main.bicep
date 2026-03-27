targetScope = 'subscription'

@description('Name of the resource group where resources will be deployed')
param resourceGroupName string

@description('Location for all resources')
param location string = 'northeurope'

@description('Name of the user-assigned managed identity')
param managedIdentityName string = 'uamiTestSqlPolicy'

@description('Display name of the AAD security group used as the SQL Server administrator (must be pre-created in Entra ID)')
param aadAdminGroupName string = 'SqlDbAdmins'

@description('Object ID of the AAD security group used as the SQL Server administrator')
param aadAdminGroupObjectId string

@description('Name of the AAD group or user to assign as database user (e.g. db_datareader role)')
param aadUserGroupName string = 'SqlDbUsers'

@description('Name of the policy assignment')
param policyAssignmentName string = 'EnforceAadRoleAssignmentOnAzureSql-Assignment'

@description('Base name of the SQL Server; the location abbreviation is appended automatically (e.g. sqlpolicytest → sqlpolicytest-neu). Leave empty to skip SQL Server creation.')
param sqlServerName string = ''

@description('List of SQL Database names to create on the SQL Server')
param sqlDatabaseNames array = []

@description('Optional client IP address to allow through the SQL Server firewall (e.g. office IP for SSMS access). Leave empty to skip.')
param allowedClientIpAddress string = ''

// Map full Azure location names to short abbreviations used in resource names
var locationAbbreviations = {
  northeurope: 'neu'
  westeurope: 'weu'
  eastus: 'eus'
  eastus2: 'eus2'
  westus: 'wus'
  westus2: 'wus2'
  centralus: 'cus'
  southeastasia: 'sea'
  eastasia: 'ea'
  uksouth: 'uks'
  ukwest: 'ukw'
}
var locationAbbr = locationAbbreviations[?location] ?? location

// Deploy the policy definition at subscription scope
module policyDef 'modules/policyDefinition.bicep' = {
  name: 'deploy-policyDefinition'
}

// Deploy the user-assigned managed identity and grant it Contributor access
module managedIdentity 'modules/managedIdentity.bicep' = {
  name: 'deploy-managedIdentity'
  scope: resourceGroup(resourceGroupName)
  params: {
    managedIdentityName: '${managedIdentityName}-${locationAbbr}'
    location: location
  }
}

// Assign the policy at resource group scope with the managed identity resource ID
module policyAssignment 'modules/policyAssignment.bicep' = {
  name: 'deploy-policyAssignment'
  scope: resourceGroup(resourceGroupName)
  params: {
    policyAssignmentName: policyAssignmentName
    location: location
    policyDefinitionId: policyDef.outputs.policyDefinitionId
    principalNameToAssign: aadUserGroupName
    userAssignedIdentityResourceId: managedIdentity.outputs.managedIdentityResourceId
  }
}

// Optionally deploy the SQL Server with AAD-only authentication
module sqlServerModule 'modules/sqlServer.bicep' = if (!empty(sqlServerName)) {
  name: 'deploy-sqlServer'
  scope: resourceGroup(resourceGroupName)
  params: {
    sqlServerName: '${sqlServerName}-${locationAbbr}'
    location: location
    aadAdminGroupName: aadAdminGroupName
    aadAdminGroupObjectId: aadAdminGroupObjectId
    databaseNames: sqlDatabaseNames
    allowedClientIpAddress: allowedClientIpAddress
  }
}

@description('The principal ID (object ID) of the managed identity — add this to the SqlDbAdmins group after deployment')
output managedIdentityPrincipalId string = managedIdentity.outputs.managedIdentityPrincipalId

@description('The resource ID of the managed identity — used as the userAssignedIdentityResourceId policy parameter')
output managedIdentityResourceId string = managedIdentity.outputs.managedIdentityResourceId

@description('The resource ID of the policy assignment')
output policyAssignmentId string = policyAssignment.outputs.policyAssignmentId

@description('The principal ID of the SQL Server system-assigned identity — used by deploy.ps1 to grant Directory Readers in Entra ID')
output sqlServerPrincipalId string = sqlServerModule.?outputs.?sqlServerPrincipalId ?? ''
