/*
  Deploy a web app with a managed identity, diagnostic, and a private endpoint
*/

@description('This is the base name for each Azure resource name (6-12 chars)')
param baseName string

@description('The resource group location')
param location string = resourceGroup().location

param dockerImage string
param developmentEnvironment bool

// existing resource name params
param vnetName string
param appServicesSubnetName string
param privateEndpointsSubnetName string
param keyVaultName string
param logWorkspaceName string

// variables
var appName = 'app-${baseName}'
var appServicePlanName = 'asp-${appName}'
var appServiceManagedIdentityName = 'id-${appName}'
var appServicePrivateEndpointName = 'pep-${appName}'
var appInsightsName = 'appinsights-${appName}'

var appServicePlanPremiumSku = 'Premium'
var appServicePlanBasicSku = 'Basic'
var appServicePlanSettings = {
  Basic: {
    name: 'B3'
    capacity: 1
  }
  Premium: {
    name: 'P1V3'
    capacity: 3
  }
}

var appServicesDnsZoneName = 'privatelink.azurewebsites.net'
var appServicesDnsGroupName = '${appServicePrivateEndpointName}/default'

// ---- Existing resources ----
resource vnet 'Microsoft.Network/virtualNetworks@2022-11-01' existing = {
  name: vnetName

  resource appServicesSubnet 'subnets' existing = {
    name: appServicesSubnetName
  }
  resource privateEndpointsSubnet 'subnets' existing = {
    name: privateEndpointsSubnetName
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: logWorkspaceName
}

// Built-in Azure RBAC role that is applied to a Key Vault to grant secrets content read permissions.
resource keyVaultSecretsUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '4633458b-17de-408a-b874-0445c86b69e6'
  scope: subscription()
}

// ---- Web App resources ----

// Managed Identity for App Service
resource appServiceManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: appServiceManagedIdentityName
  location: location
}

// Grant the App Service managed identity key vault secrets role permissions
module appServiceSecretsUserRoleAssignmentModule './modules/keyvaultRoleAssignment.bicep' = {
  name: 'appServiceSecretsUserRoleAssignmentDeploy'
  params: {
    roleDefinitionId: keyVaultSecretsUserRole.id
    principalId: appServiceManagedIdentity.properties.principalId
    keyVaultName: keyVaultName
  }
}

//App service plan
resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'
  sku: developmentEnvironment
    ? appServicePlanSettings[appServicePlanBasicSku]
    : appServicePlanSettings[appServicePlanPremiumSku]
  properties: {
    reserved: true // Forces Linux OS
    zoneRedundant: !developmentEnvironment
  }
}

// Web App
resource webApp 'Microsoft.Web/sites@2024-04-01' = {
  name: appName
  location: location
  kind: 'app,linux,container'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appServiceManagedIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    vnetRouteAllEnabled: true
    vnetImagePullEnabled: false
    vnetContentShareEnabled: true
    virtualNetworkSubnetId: vnet::appServicesSubnet.id
    httpsOnly: false
    keyVaultReferenceIdentity: appServiceManagedIdentity.id
    hostNamesDisabled: false
    siteConfig: {
      linuxFxVersion: 'DOCKER|${dockerImage}'
      acrUseManagedIdentityCreds: true
      acrUserManagedIdentityID: appServiceManagedIdentity.id
      vnetRouteAllEnabled: true
      http20Enabled: true
      minTlsVersion: '1.3'
      minTlsCipherSuite: 'TLS_AES_256_GCM_SHA384'
      publicNetworkAccess: 'Disabled'
      alwaysOn: true
    }
  }
  dependsOn: [
    appServiceSecretsUserRoleAssignmentModule
  ]
}

// App Settings
resource appsettings 'Microsoft.Web/sites/config@2024-04-01' = {
  name: 'appsettings'
  parent: webApp
  properties: {
    AZURE_SQL_CONNECTIONSTRING: '@Microsoft.KeyVault(SecretUri=https://${keyVault.name}${environment().suffixes.keyvaultDns}/secrets/adWorksConnString)'
    APPINSIGHTS_INSTRUMENTATIONKEY: appInsights.properties.InstrumentationKey
    APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString
    ApplicationInsightsAgent_EXTENSION_VERSION: '~2'
  }
}

resource appServicePrivateEndpoint 'Microsoft.Network/privateEndpoints@2022-11-01' = {
  name: appServicePrivateEndpointName
  location: location
  properties: {
    subnet: {
      id: vnet::privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: appServicePrivateEndpointName
        properties: {
          privateLinkServiceId: webApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

resource appServiceDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: appServicesDnsZoneName
  location: 'global'
  properties: {}
}

resource appServiceDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: appServiceDnsZone
  name: '${appServicesDnsZoneName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource appServiceDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2022-11-01' = {
  name: appServicesDnsGroupName
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink.azurewebsites.net'
        properties: {
          privateDnsZoneId: appServiceDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    appServicePrivateEndpoint
  ]
}

// App service plan diagnostic settings
resource appServicePlanDiagSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${appServicePlan.name}-diagnosticSettings'
  scope: appServicePlan
  properties: {
    workspaceId: logWorkspace.id
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

//Web App diagnostic settings
resource webAppDiagSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${webApp.name}-diagnosticSettings'
  scope: webApp
  properties: {
    workspaceId: logWorkspace.id
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        categoryGroup: null
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        categoryGroup: null
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        categoryGroup: null
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

// create application insights resource
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logWorkspace.id
  }
}

@description('The name of the app service plan.')
output appServicePlanName string = appServicePlan.name

@description('The name of the web app.')
output appName string = webApp.name
