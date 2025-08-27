/*
  Deploy an Azure Application Gateway with WAF v2 and a custom domain name.
*/

@description('This is the base name for each Azure resource name (6-12 chars)')
param baseName string

@description('The resource group location')
param location string = resourceGroup().location

@description('Domain name to use for App Gateway')
param customDomainName string

param gatewayCertSecretUri string

// existing resource name params
param vnetName string
param appGatewaySubnetName string
param appName string
param keyVaultName string
param logWorkspaceName string

//variables
var appGateWayName = 'agw-${baseName}'
var appGatewayManagedIdentityName = 'id-${appGateWayName}'
var appGatewayPublicIpName = 'pip-${baseName}'
var appGateWayFqdn = 'fe-${baseName}'
var wafPolicyName = 'waf-${baseName}'

// ---- Existing resources ----
resource vnet 'Microsoft.Network/virtualNetworks@2022-11-01' existing = {
  name: vnetName

  resource appGatewaySubnet 'subnets' existing = {
    name: appGatewaySubnetName
  }
}

resource webApp 'Microsoft.Web/sites@2022-09-01' existing = {
  name: appName
}

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: logWorkspaceName
}

// Built-in Azure RBAC role that is applied to a Key Vault to grant with secrets content read privileges. Granted to both Key Vault and our workload's identity.
resource keyVaultSecretsUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '4633458b-17de-408a-b874-0445c86b69e6'
  scope: subscription()
}

// ---- App Gateway resources ----

// Managed Identity for App Gateway.
resource appGatewayManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: appGatewayManagedIdentityName
  location: location
}

// Grant the Azure Application Gateway managed identity with key vault secrets role permissions; this allows pulling certificates.
module appGatewaySecretsUserRoleAssignmentModule './modules/keyvaultRoleAssignment.bicep' = {
  name: 'appGatewaySecretsUserRoleAssignmentDeploy'
  params: {
    roleDefinitionId: keyVaultSecretsUserRole.id
    principalId: appGatewayManagedIdentity.properties.principalId
    keyVaultName: keyVaultName
  }
}

//External IP for App Gateway
resource appGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2022-11-01' = {
  name: appGatewayPublicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
    dnsSettings: {
      domainNameLabel: appGateWayFqdn
    }
  }
}

//WAF policy definition
resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2022-11-01' = {
  name: wafPolicyName
  location: location
  properties: {
    policySettings: {
      fileUploadLimitInMb: 10
      state: 'Enabled'
      mode: 'Prevention'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
          ruleGroupOverrides: []
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '0.1'
          ruleGroupOverrides: []
        }
      ]
    }
  }
}

//App Gateway
resource appGateWay 'Microsoft.Network/applicationGateways@2022-11-01' = {
  name: appGateWayName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appGatewayManagedIdentity.id}': {}
    }
  }
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    sslPolicy: {
      policyType: 'CustomV2'
      cipherSuites: [
        'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384'
        'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256'
      ]
      minProtocolVersion: 'TLSv1_3'
    }

    gatewayIPConfigurations: [
      {
        name: 'app-gateway-ip-config'
        properties: {
          subnet: {
            id: vnet::appGatewaySubnet.id
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'app-gateway-public-ip'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: appGatewayPublicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port-443'
        properties: {
          port: 443
        }
      }
    ]
    probes: [
      {
        name: 'probe-https-${baseName}'
        properties: {
          protocol: 'Https'
          path: '/health'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          minServers: 0
          match: {
            statusCodes: [
              '200-399'
              '401'
              '403'
            ]
          }
        }
      }
    ]
    firewallPolicy: {
      id: wafPolicy.id
    }
    enableHttp2: false
    sslCertificates: [
      {
        name: '${appGateWayName}-ssl-certificate'
        properties: {
          keyVaultSecretId: gatewayCertSecretUri
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'pool-${appName}'
        properties: {
          backendAddresses: [
            {
              fqdn: webApp.properties.defaultHostName
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'backend-https-${baseName}'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 20
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGateWayName, 'probe-https-${baseName}')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener-https-${baseName}'
        properties: {
          frontendIPConfiguration: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/frontendIPConfigurations',
              appGateWayName,
              'app-gateway-public-ip'
            )
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGateWayName, 'port-443')
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/sslCertificates',
              appGateWayName,
              '${appGateWayName}-ssl-certificate'
            )
          }
          hostName: customDomainName
          hostNames: []
          requireServerNameIndication: true
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'https'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/httpListeners',
              appGateWayName,
              'listener-https-${baseName}'
            )
          }
          backendAddressPool: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/backendAddressPools',
              appGateWayName,
              'pool-${appName}'
            )
          }
          backendHttpSettings: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
              appGateWayName,
              'backend-https-${baseName}'
            )
          }
        }
      }
    ]
    autoscaleConfiguration: {
      minCapacity: 2
      maxCapacity: 3
    }
  }
  dependsOn: [
    appGatewaySecretsUserRoleAssignmentModule
  ]
}

// App Gateway diagnostics
resource appGatewayDiagSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${appGateWay.name}-diagnostic-settings'
  scope: appGateWay
  properties: {
    workspaceId: logWorkspace.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

@description('The name of the app gateway resource.')
output appGateWayName string = appGateWay.name
