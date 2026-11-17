targetScope = 'resourceGroup'

@description('Azure region, inherited from the SafeCircle student resource group.')
param location string = resourceGroup().location

@description('Container Apps managed environment name.')
param environmentName string = 'cae-safecircle-student'

@description('Existing VNet name from postgresql-private.bicep.')
param virtualNetworkName string = 'vnet-safecircle-student'

@description('Existing dedicated Container Apps subnet; requires a workload-profiles environment.')
param infrastructureSubnetName string = 'snet-containerapps'

@description('Public HTTPS ingress is required for the Flutter API; PostgreSQL remains private.')
param internalEnvironment bool = false

@description('Disable zone redundancy for the short-lived student demonstration.')
param zoneRedundant bool = false

resource infrastructureSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  name: '${virtualNetworkName}/${infrastructureSubnetName}'
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnet.id
      internal: internalEnvironment
    }
    zoneRedundant: zoneRedundant
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

output managedEnvironmentId string = environment.id
output managedEnvironmentName string = environment.name
output infrastructureSubnetId string = infrastructureSubnet.id
