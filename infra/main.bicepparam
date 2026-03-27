using './main.bicep'

// Required: the resource group where the managed identity, policy assignment,
// and optionally the SQL Server will be deployed.
param resourceGroupName = 'rg_testsqlpolicy'

// Azure region for all resources
param location = 'northeurope'

// Name of the User-Assigned Managed Identity that the policy deployment script runs as
param managedIdentityName = 'uamiTestSqlPolicy'

// Name of the AAD security group that acts as the SQL Server administrator.
// Groups are pre-created via 'az ad group create' before running this deployment.
param aadAdminGroupName = 'SqlDbAdmins'

// Object ID (GUID) of the SqlDbAdmins AAD group.
// Retrieve with: az ad group show --group SqlDbAdmins --query id --output tsv
param aadAdminGroupObjectId = '<object-id>'

// Name of the AAD group that will be assigned db_datareader inside every new database.
// Groups are pre-created via 'az ad group create' before running this deployment.
param aadUserGroupName = 'SqlDbUsers'

// Name for the Azure Policy assignment (scoped to the resource group)
param policyAssignmentName = 'EnforceAadRoleAssignmentOnAzureSql-Assignment'

// Name of the Azure SQL Server to create.
// Set to an empty string '' to skip SQL Server creation.
param sqlServerName = 'sqlpolicytest'

// List of database names to create on the SQL Server.
// Leave empty [] to create no databases initially.
param sqlDatabaseNames = []

// Optional: single client IP address to allow through the SQL Server firewall.
// Set to your office/home public IP for external access (e.g. SSMS). Leave empty to deny all external IPs.
// Retrieve your current public IP: Invoke-RestMethod https://api.ipify.org
param allowedClientIpAddress = ''
