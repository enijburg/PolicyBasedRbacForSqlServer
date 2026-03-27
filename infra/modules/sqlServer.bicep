targetScope = 'resourceGroup'

@description('Name of the SQL Server')
param sqlServerName string

@description('Location for the SQL Server')
param location string = resourceGroup().location

@description('The display name of the AAD admin group')
param aadAdminGroupName string

@description('The object ID of the AAD admin group')
param aadAdminGroupObjectId string

@description('The Azure AD tenant ID')
param tenantId string = tenant().tenantId

@description('Array of database names to create')
param databaseNames array = []

@description('Optional client IP address to whitelist in the firewall (e.g. office IP). Leave empty to skip.')
param allowedClientIpAddress string = ''

resource sqlServer 'Microsoft.Sql/servers@2022-11-01-preview' = {
  name: sqlServerName
  location: location
  // System-assigned identity is required for the SQL server to resolve AAD group
  // memberships. The identity must be granted the Directory Readers role in Entra ID
  // (handled in deploy.ps1 Phase 4).
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'Group'
      login: aadAdminGroupName
      sid: aadAdminGroupObjectId
      tenantId: tenantId
      azureADOnlyAuthentication: true
    }
  }
}

// Allow Azure-hosted services (e.g. policy DINE deployment scripts) to reach the SQL server.
resource firewallRuleAzureServices 'Microsoft.Sql/servers/firewallRules@2022-11-01-preview' = {
  parent: sqlServer
  name: 'AllowAllAzureIPs'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Optional: allow a specific client IP (e.g. office/home) for external access such as SSMS.
resource firewallRuleClientIp 'Microsoft.Sql/servers/firewallRules@2022-11-01-preview' = if (!empty(allowedClientIpAddress)) {
  parent: sqlServer
  name: 'AllowClientIP'
  properties: {
    startIpAddress: allowedClientIpAddress
    endIpAddress: allowedClientIpAddress
  }
}

resource databases 'Microsoft.Sql/servers/databases@2022-11-01-preview' = [
  for dbName in databaseNames: {
    parent: sqlServer
    name: dbName
    location: location
    sku: {
      name: 'Basic'
      tier: 'Basic'
    }
  }
]

@description('The name of the SQL Server')
output sqlServerName string = sqlServer.name

@description('The resource ID of the SQL Server')
output sqlServerId string = sqlServer.id

@description('The fully qualified domain name of the SQL Server')
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName

@description('The principal ID of the SQL Server system-assigned identity — must be granted Directory Readers in Entra ID')
output sqlServerPrincipalId string = sqlServer.identity.principalId
