targetScope = 'subscription'

var policyDefinitionName = 'EnforceAadRoleAssignmentOnAzureSql'

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2020-03-01' = {
  name: policyDefinitionName
  properties: {
    displayName: 'Enforce AAD Role Assignment on Azure SQL'
    policyType: 'Custom'
    mode: 'Indexed'
    description: 'Deploys a script to assign an AAD user/group to a role in newly created Azure SQL databases.'
    metadata: {
      version: '1.0.0'
      category: 'SQL'
    }
    parameters: {
      principalNameToAssign: {
        type: 'String'
        metadata: {
          description: 'The name of the AAD user or group to assign'
          displayName: 'AAD Principal Name'
        }
      }
      userAssignedIdentityResourceId: {
        type: 'String'
        metadata: {
          description: 'Resource ID of the User Assigned Managed Identity to run the deployment script'
          displayName: 'User Assigned Managed Identity Resource ID'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Sql/servers/databases'
          }
          {
            field: 'name'
            notEquals: 'master'
          }
          {
            field: 'tags[\'sqlRBACApplied\']'
            notEquals: '1.0.0'
          }
        ]
      }
      then: {
        effect: 'DeployIfNotExists'
        details: {
          // Self-reference the database resource and check for the tag directly.
          // This avoids the false-positive where any AssignAadUserToSql-* deployment
          // script in the RG (e.g. from a different database) satisfies the existence
          // check and incorrectly marks an untagged database as compliant.
          // field('fullName') is required for child resource types (returns 'server/db');
          // field('name') only returns the leaf segment ('db') which Azure Policy cannot
          // resolve to a valid resource, causing the DINE trigger to silently fail.
          type: 'Microsoft.Sql/servers/databases'
          name: '[field(\'fullName\')]'
          existenceCondition: {
            field: 'tags[\'sqlRBACApplied\']'
            equals: '1.0.0'
          }
          roleDefinitionIds: [
            '/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c'
          ]
          deploymentScope: 'resourceGroup'
          deployment: {
            properties: {
              mode: 'incremental'
              template: {
                '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
                contentVersion: '1.0.0.0'
                parameters: {
                  sqlServerName: {
                    type: 'string'
                  }
                  sqlDatabaseName: {
                    type: 'string'
                  }
                  principalNameToAssign: {
                    type: 'string'
                  }
                  userAssignedIdentityResourceId: {
                    type: 'string'
                  }
                }
                resources: [
                  {
                    type: 'Microsoft.Resources/deploymentScripts'
                    apiVersion: '2020-10-01'
                    name: '[concat(\'AssignAadUserToSql-\', parameters(\'sqlDatabaseName\'))]'
                    location: '[resourceGroup().location]'
                    kind: 'AzurePowerShell'
                    identity: {
                      type: 'UserAssigned'
                      userAssignedIdentities: {
                        '[parameters(\'userAssignedIdentityResourceId\')]': {}
                      }
                    }
                    properties: {
                      azPowerShellVersion: '12.1'
                      timeout: 'PT15M'
                      cleanupPreference: 'OnSuccess'
                      retentionInterval: 'P1D'
                      arguments: '[concat(\'-principalNameToAssign "\', parameters(\'principalNameToAssign\'), \'" -sqlServer "\', parameters(\'sqlServerName\'), \'" -dbName "\', parameters(\'sqlDatabaseName\'), \'" -sqlSuffix "\', environment().suffixes.sqlServerHostname, \'" -subscriptionId "\', subscription().subscriptionId, \'" -resourceGroupName "\', resourceGroup().name, \'"\')]'
                      scriptContent: loadTextContent('../../SetPrincipalName.ps1')
                    }
                  }
                ]
              }
              parameters: {
                sqlServerName: {
                  value: '[split(field(\'id\'), \'/\')[8]]'
                }
                sqlDatabaseName: {
                  value: '[field(\'name\')]'
                }
                principalNameToAssign: {
                  value: '[parameters(\'principalNameToAssign\')]'
                }
                userAssignedIdentityResourceId: {
                  value: '[parameters(\'userAssignedIdentityResourceId\')]'
                }
              }
            }
          }
        }
      }
    }
  }
}

@description('The resource ID of the policy definition')
output policyDefinitionId string = policyDefinition.id
