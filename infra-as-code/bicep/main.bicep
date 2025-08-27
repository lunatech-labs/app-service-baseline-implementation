@description('The location in which all resources should be deployed.')
param location string = resourceGroup().location

@description('This is the base name for each Azure resource name (6-12 chars)')
@minLength(6)
@maxLength(12)
param baseName string

@description('The administrator username of the SQL server')
param sqlAdministratorLogin string

@description('The administrator password of the SQL server.')
@secure()
param sqlAdministratorLoginPassword string

@description('Docker image to use for deployment')
param dockerImage string

@description('Domain name to use for App Gateway')
param customDomainName string

@description('The certificate data for app gateway TLS termination. The value is base64 encoded')
@secure()
param appGatewayListenerCertificate string

@description('Optional. When true will deploy a cost-optimised environment for development purposes. Note that when this param is true, the deployment is not suitable or recommended for Production environments. Default = false.')
param developmentEnvironment bool = false

// ---- Availability Zones ----
var availabilityZones = ['1', '2', '3']
var logWorkspaceName = 'log-${baseName}'

// ---- Log Analytics workspace ----
resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Deploy vnet with subnets and NSGs
module networkModule 'network.bicep' = {
  name: 'networkDeploy'
  params: {
    location: location
    baseName: baseName
    developmentEnvironment: developmentEnvironment
  }
}

// Deploy a SQL server with a sample database, a private endpoint and a DNS zone
module databaseModule 'database.bicep' = {
  name: 'databaseDeploy'
  params: {
    location: location
    baseName: baseName
    sqlAdministratorLogin: sqlAdministratorLogin
    sqlAdministratorLoginPassword: sqlAdministratorLoginPassword
    vnetName: networkModule.outputs.vnetNName
    privateEndpointsSubnetName: networkModule.outputs.privateEndpointsSubnetName
  }
}

// Deploy a Key Vault with a private endpoint and DNS zone
module secretsModule 'secrets.bicep' = {
  name: 'secretsDeploy'
  params: {
    location: location
    baseName: baseName
    vnetName: networkModule.outputs.vnetNName
    privateEndpointsSubnetName: networkModule.outputs.privateEndpointsSubnetName
    appGatewayListenerCertificate: appGatewayListenerCertificate
    sqlConnectionString: databaseModule.outputs.sqlConnectionString
  }
}

// Deploy a web app
module webappModule 'webapp.bicep' = {
  name: 'webappDeploy'
  params: {
    location: location
    baseName: baseName
    dockerImage: dockerImage
    developmentEnvironment: developmentEnvironment
    keyVaultName: secretsModule.outputs.keyVaultName
    vnetName: networkModule.outputs.vnetNName
    appServicesSubnetName: networkModule.outputs.appServicesSubnetName
    privateEndpointsSubnetName: networkModule.outputs.privateEndpointsSubnetName
    logWorkspaceName: logWorkspace.name
  }
}

//Deploy an Azure Application Gateway with WAF v2 and a custom domain name.
module gatewayModule 'gateway.bicep' = {
  name: 'gatewayDeploy'
  params: {
    location: location
    baseName: baseName
    developmentEnvironment: developmentEnvironment
    availabilityZones: availabilityZones
    customDomainName: customDomainName
    appName: webappModule.outputs.appName
    vnetName: networkModule.outputs.vnetNName
    appGatewaySubnetName: networkModule.outputs.appGatewaySubnetName
    keyVaultName: secretsModule.outputs.keyVaultName
    gatewayCertSecretUri: secretsModule.outputs.gatewayCertSecretUri
    logWorkspaceName: logWorkspace.name
  }
}
