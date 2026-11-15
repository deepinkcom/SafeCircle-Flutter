targetScope = 'resourceGroup'

@description('Globally unique Azure Container Registry name (5-50 alphanumeric characters).')
@minLength(5)
@maxLength(50)
param registryName string

@description('Registry SKU. Basic is suitable for initial development; choose Premium for private endpoints and zone redundancy.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param registrySku string = 'Basic'

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
        status: 'enabled'
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
