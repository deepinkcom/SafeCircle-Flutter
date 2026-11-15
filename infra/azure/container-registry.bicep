targetScope = 'resourceGroup'

@description('Globally unique Azure Container Registry name (5-50 alphanumeric characters).')
@minLength(5)
@maxLength(50)
param registryName string

@description('Standard is a candidate only if the Azure for Students 31-day free-service allowance is verified; otherwise select Basic after pricing review. Premium is required for private endpoints.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param registrySku string = 'Standard'

@description('Azure region; defaults to resource group location.')
param location string = resourceGroup().location

@description('Disable public network access only after private endpoint connectivity and a private build runner are configured.')
param disablePublicNetworkAccess bool = false

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  sku: {
    name: registrySku
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: disablePublicNetworkAccess ? 'Disabled' : 'Enabled'
    policies: {
      quarantinePolicy: {
        status: 'disabled'
      }
      retentionPolicy: {
        days: 7
        status: 'disabled'
      }
      trustPolicy: {
        type: 'Notary'
        status: 'disabled'
      }
    }
  }
}

output registryName string = registry.name
output loginServer string = registry.properties.loginServer
output registryId string = registry.id
output sku string = registry.sku.name
