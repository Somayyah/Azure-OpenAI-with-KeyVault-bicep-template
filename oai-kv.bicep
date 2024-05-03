param guidValue string = uniqueString(newGuid()) // to generate unique names for the resources each time
@description('Optional. The version of the customer managed key to reference for encryption. If not provided, latest is used.')
param cMKKeyVersion string = ''
param skuType string = 'S0'
param openAiService string = 'OpenAI'
param disableLocalAuth bool = false
param dynamicThrottlingEnabled bool = false
param publicNetworkAccess string = 'Enabled'
param restrictOutboundNetworkAccess bool = false
param cogservName string = substring('salfriah-aoai-${guidValue}', 0, 24)
param kvName string = substring('salfriah-kv-${guidValue}', 0, 24)
param location string = 'westeurope'
param keyVaultKeyName string = substring('salfriah-k-${guidValue}', 0, 24)
param userAssignedIDname string = substring('salfriah-uaid-${guidValue}', 0, 24)
param keyVaultSku object = {
  name: 'standard'
  family: 'A'
}

// user assigned ID is used to manage OAI access to KV
resource userAssignedID 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: userAssignedIDname
  location: location
}

// Create the Keyvault with the access policy
resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: kvName
  location: location
  properties: {
    accessPolicies: [
      {
        objectId: userAssignedID.properties.principalId
        permissions: {
          keys: [
            'get'
            'wrapKey'
            'unwrapKey'          
          ]
        }
        tenantId: tenant().tenantId
      }
    ]
    enablePurgeProtection: true
    enableRbacAuthorization: false
    enableSoftDelete: true
    publicNetworkAccess: 'enabled'
    sku: keyVaultSku
    softDeleteRetentionInDays: 10
    tenantId: tenant().tenantId
  }
  // will be created only after the role is assigned, important
  dependsOn: [assignKVCryptoServiceEncryptionUser]
}

// Create the KVKey, depends on Key vault
resource keyVaultKey 'Microsoft.KeyVault/vaults/keys@2022-07-01' = {
  name: keyVaultKeyName
  parent: keyVault
  properties: {
    kty: 'RSA'
    keyOps: ['decrypt', 'encrypt', 'sign', 'unwrapKey', 'verify', 'wrapKey']
    keySize: 2048
    attributes: {
      enabled: true
      exportable: false
    }
    rotationPolicy: {
      attributes: {
        expiryTime: 'P1Y'
      }
      lifetimeActions: [
        {
          trigger: {
            timeAfterCreate: 'P11M'
          }
          action: {
            type: 'Rotate'
          }
        }
        {
          trigger: {
            timeBeforeExpiry: 'P1M'
          }
          action: {
            type: 'Notify'
          }
        }
      ]
    }
  }
}

// Create role assignment for KV Crypto Service Encryption User, depends on userAssignedID
resource assignKVCryptoServiceEncryptionUser 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  scope: userAssignedID
  name: guid(userAssignedID.id, 'e147488a-f6f5-4113-8e2d-b22465e65bf6')
  properties: {
    principalId: userAssignedID.properties.principalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'e147488a-f6f5-4113-8e2d-b22465e65bf6')
    principalType: 'User'
  }
}

// Create the OAI resource, depends on role assignements and KeyVault
resource cognitiveService 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: cogservName
  location: location
  sku: {
    name: skuType
  }
  kind: openAiService
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedID.id}': {}
    }
  }
  properties: {
    disableLocalAuth: disableLocalAuth
    dynamicThrottlingEnabled: dynamicThrottlingEnabled
    publicNetworkAccess: publicNetworkAccess
    restrictOutboundNetworkAccess: restrictOutboundNetworkAccess
    encryption: !empty(keyVaultKey) ? {
      keySource: 'Microsoft.KeyVault'
      keyVaultProperties: {
        identityClientId: userAssignedID.properties.clientId
        keyVaultUri: keyVault.properties.vaultUri
        keyName: keyVaultKeyName
        keyVersion: !empty(cMKKeyVersion) ? cMKKeyVersion : last(split(keyVaultKey.properties.keyUriWithVersion, '/'))
      }
    } : null
  }
  dependsOn: [assignKVCryptoServiceEncryptionUser]
}
