targetScope = 'resourceGroup'

@description('Globally unique PostgreSQL Flexible Server name (3-63 lowercase letters, numbers, hyphens).')
@minLength(3)
@maxLength(63)
param serverName string

@description('PostgreSQL administrator login. Store the password outside source control.')
param administratorLogin string

@secure()
@description('Strong PostgreSQL administrator password. Supplied securely at deployment time.')
param administratorPassword string

@description('PostgreSQL major version.')
@allowed([
  '15'
  '16'
  '17'
])
param postgresVersion string = '16'

@description('Azure region; defaults to resource group location.')
param location string = resourceGroup().location

@description('Development/test SKU only. Review pricing and performance before production.')
param skuName string = 'Standard_B1ms'

@description('Compute tier.')
@allowed([
  'Burstable'
  'GeneralPurpose'
])
param skuTier string = 'Burstable'

@description('Storage size in GiB. Minimum depends on selected server configuration.')
@minValue(32)
param storageSizeGB int = 32

@description('Backup retention in days.')
@minValue(7)
@maxValue(35)
param backupRetentionDays int = 7

@description('Virtual network name shared with the separately configured Container Apps environment.')
param virtualNetworkName string = 'vnet-safecircle-student'

@description('Private DNS zone name for PostgreSQL Flexible Server.')
param privateDnsZoneName string = 'safecircle.private.postgres.database.azure.com'

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: virtualNetworkName
}

resource postgresSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: 'snet-postgres'
}

resource containerAppsSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: 'snet-containerapps'
}

resource postgresPrivateDns 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource dnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: postgresPrivateDns
  name: 'safecircle-vnet-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: serverName
  location: location
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: postgresVersion
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    storage: {
      storageSizeGB: storageSizeGB
      autoGrow: 'Disabled'
      tier: 'P4'
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: postgresSubnet.id
      privateDnsZoneArmResourceId: postgresPrivateDns.id
      publicNetworkAccess: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
  dependsOn: [
    dnsVnetLink
  ]
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgres
  name: 'safecircle_db'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

output postgresServerFqdn string = postgres.properties.fullyQualifiedDomainName
output postgresDatabaseName string = database.name
output virtualNetworkId string = vnet.id
output postgresSubnetId string = postgresSubnet.id
output containerAppsInfrastructureSubnetId string = containerAppsSubnet.id

@description('Allow the PostGIS extension required by SafeCircle location queries.')
resource postgisAllowlist 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: postgres
  name: 'azure.extensions'
  properties: {
    value: 'POSTGIS'
    source: 'user-override'
  }
}
