targetScope = 'resourceGroup'

@description('Existing Azure Container Apps managed environment resource ID.')
param containerAppsEnvironmentId string

@description('Existing Azure Container Registry name (without .azurecr.io).')
param acrName string

@description('Container image tag already pushed to the existing ACR. No push is performed by this template.')
param imageTag string

@secure()
@description('PostgreSQL SQLAlchemy connection URL. Use TLS, e.g. postgresql+psycopg2://...?...sslmode=require')
param databaseUrl string

@secure()
@description('Firebase service-account JSON contents. Stored as a Container Apps secret, never emitted as an output.')
param firebaseServiceAccountJson string

@description('Public HTTPS API hostname assigned to the API Container App after ingress creation.')
param apiIngressExternal bool = true

@description('Minimum API replicas. Keep at least one for emergency-service availability.')
@minValue(1)
param apiMinReplicas int = 1

@description('Maximum API replicas.')
@minValue(1)
param apiMaxReplicas int = 3

@description('Worker replicas. Polling worker must not scale to zero.')
@minValue(1)
@maxValue(1)
param workerReplicas int = 1

@description('CPU allocation for each container.')
param cpuCores string = '0.5'

@description('Memory allocation for each container.')
param memorySize string = '1Gi'

var location = resourceGroup().location
var registryServer = '${acrName}.azurecr.io'
var image = '${registryServer}/safecircle-api:${imageTag}'
var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'safecircle-acr-pull'
  location: location
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, pullIdentity.id, acrPullRoleDefinitionId)
  scope: registry
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource api 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'safecircle-api'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${pullIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      secrets: [
        {
          name: 'database-url'
          value: databaseUrl
        }
        {
          name: 'firebase-service-account-json'
          value: firebaseServiceAccountJson
        }
      ]
      registries: [
        {
          server: registryServer
          identity: pullIdentity.id
        }
      ]
      ingress: {
        external: apiIngressExternal
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
      }
    }
    template: {
      revisionSuffix: 'azure'
      containers: [
        {
          name: 'api'
          image: image
          env: [
            {
              name: 'PORT'
              value: '8000'
            }
            {
              name: 'DATABASE_URL'
              secretRef: 'database-url'
            }
            {
              name: 'FIREBASE_SERVICE_ACCOUNT_JSON'
              secretRef: 'firebase-service-account-json'
            }
          ]
          resources: {
            cpu: json(cpuCores)
            memory: memorySize
          }
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: 8000
                scheme: 'HTTP'
              }
              initialDelaySeconds: 10
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health/ready'
                port: 8000
                scheme: 'HTTP'
              }
              initialDelaySeconds: 15
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: 3
            }
          ]
        }
      ]
      scale: {
        minReplicas: apiMinReplicas
        maxReplicas: apiMaxReplicas
      }
    }
  }
  dependsOn: [
    acrPullRole
  ]
}

resource worker 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'safecircle-push-worker'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${pullIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      secrets: [
        {
          name: 'database-url'
          value: databaseUrl
        }
        {
          name: 'firebase-service-account-json'
          value: firebaseServiceAccountJson
        }
      ]
      registries: [
        {
          server: registryServer
          identity: pullIdentity.id
        }
      ]
    }
    template: {
      revisionSuffix: 'azure'
      containers: [
        {
          name: 'push-worker'
          image: image
          command: [
            'python'
            '-m'
            'app.push_worker'
          ]
          env: [
            {
              name: 'DATABASE_URL'
              secretRef: 'database-url'
            }
            {
              name: 'FIREBASE_SERVICE_ACCOUNT_JSON'
              secretRef: 'firebase-service-account-json'
            }
          ]
          resources: {
            cpu: json(cpuCores)
            memory: memorySize
          }
        }
      ]
      scale: {
        minReplicas: workerReplicas
        maxReplicas: workerReplicas
      }
    }
  }
  dependsOn: [
    acrPullRole
  ]
}

output apiContainerAppName string = api.name
output workerContainerAppName string = worker.name
output registryServerName string = registryServer
