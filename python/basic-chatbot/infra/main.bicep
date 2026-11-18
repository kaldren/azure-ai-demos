// Steps 1–3b of the baseline Foundry chat architecture.
//
// Step 1, the smallest working core. Diagram hops covered: 3 (Foundry Agent Service), 6 (model),
// 7 (conversation state).
// Step 2, grounding. Diagram hop 4: Azure AI Search (Basic tier) with a hybrid vector index,
// an embedding model, and a project connection so the agent can use the AI Search tool.
// Step 3, chat UI on App Service (managed identity) + Application Insights.
// Step 3b, Entra ID sign-in on the web app (keyless: federated credential, no client secret).
// Step 4, standard agent setup (agent state in our Cosmos DB / Storage / Search).
// Step 5, private networking: VNet, private endpoints + DNS, agent network injection, public access off.
//
// We use the *basic* agent setup here, so conversation state is kept in Microsoft-managed
// storage. Step 4 replaces it with your own Cosmos DB / Storage / AI Search ("standard setup").
//
// Deliberately NOT here yet: App Gateway + WAF, Azure Firewall (step 6), Bastion/jump box (step 7).
// Two layers now: identity (Entra ID + RBAC, no API keys) AND network (private endpoints).

targetScope = 'resourceGroup'

// Lets this template create Entra ID objects (app registration, service principal) next to the
// Azure resources. The version is pinned in bicepconfig.json. The deployer needs Graph permissions
// (Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All).
extension microsoftGraphV1

@description('Region for all resources. Sweden Central was chosen for broad model and agent-tool coverage.')
param location string = resourceGroup().location

@description('Short name used in resource names.')
@maxLength(12)
param baseName string = 'chatbot'

@description('Object ID of the person who runs the scripts locally. Get it with: az ad signed-in-user show --query id -o tsv')
param userPrincipalId string

// Model choice: gpt-5.4-mini is agent-supported (agentsV2) in swedencentral as of 2026-11-15.
// Check with: az cognitiveservices model list -l swedencentral --query "[?model.capabilities.agentsV2=='true']"
param modelName string = 'gpt-5.4-mini'
param modelVersion string = '2026-03-17'

@description('GlobalStandard = pay-per-token and routed to any Azure region. Use DataZoneStandard to keep processing inside the EU data zone.')
@allowed(['GlobalStandard', 'DataZoneStandard'])
param modelSkuName string = 'GlobalStandard'

@description('Rate limit in thousands of tokens per minute. It is a throttle, not a reservation, so it costs nothing until used. 10 was too low once search results were added to the prompt (429s in step 2).')
param modelCapacity int = 50

@description('Step 5, phase B. false: everything is reachable publicly AND privately (build + migrate). true: public network access is disabled on Foundry, Search, both Cosmos DB accounts and Storage; only the web app stays public.')
param lockDown bool = false

@description('Address space of the workload VNet. Must be RFC 1918, not overlap peered networks, and not 192.168.0.0/24 for private endpoints (Foundry hosted-agent sandbox range).')
param vnetAddressPrefix string = '10.20.0.0/16'
param agentSubnetPrefix string = '10.20.0.0/24' // Foundry agent runtime. /27 minimum, /24 recommended.
param privateEndpointSubnetPrefix string = '10.20.1.0/24'
param appServiceSubnetPrefix string = '10.20.2.0/26' // App Service VNet integration. /26 recommended.

var suffix = uniqueString(resourceGroup().id)
// Step 5: a NEW Foundry resource. Network injection (the agent subnet) has to be part of the account
// from the start; the step 1–4 account (fdy-chatbot-<suffix>) is deleted after cutover.
var accountName = 'fdy-${baseName}-vnet-${suffix}'
var publicAccess = lockDown ? 'Disabled' : 'Enabled'

// "Foundry User" (formerly "Azure AI User"): lets a principal use the data plane, i.e. create
// agents and call them. It does NOT grant permission to manage the resource itself.
var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

// The Foundry resource ("Microsoft Foundry resource" box in the diagram).
// This is the security and networking boundary: inbound through its private endpoint, outbound
// (agents calling Search/Cosmos/Storage) from inside our VNet through network injection.
resource account 'Microsoft.CognitiveServices/accounts@2026-05-01' = {
  name: accountName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true // Required for Foundry projects (and therefore agents)
    customSubDomainName: accountName // Required for Entra ID token auth
    disableLocalAuth: true // No API keys. Identity is the only way in.
    publicNetworkAccess: publicAccess
    networkAcls: {
      defaultAction: lockDown ? 'Deny' : 'Allow'
      ipRules: [] // no IP exceptions (decision 2026-11-17): only the web app is public
      virtualNetworkRules: []
      // "Trusted Azure services" exception. AI Search's vectorizer calls the embedding model here as
      // its managed identity; Search Basic can't use a shared private link to Foundry, and Microsoft's
      // own private Foundry IQ tutorial relies on this bypass. Same setting as foundry-samples #15.
      bypass: 'AzureServices'
    }
    // Agents run inside OUR subnet, so their calls to Search, Cosmos DB and Storage use private endpoints.
    #disable-next-line BCP037
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: vnet::agentSubnet.id
        useMicrosoftManagedNetwork: false
      }
    ]
  }
}

// The model ("Azure OpenAI model" box in the diagram). The agent references it by deployment name.
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2026-05-01' = {
  parent: account
  name: modelName
  sku: {
    name: modelSkuName
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

// You play the role that App Service's managed identity takes on in step 3.
resource userFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, userPrincipalId, foundryUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
    principalId: userPrincipalId
    principalType: 'User'
  }
}

// ---------------------------------------------------------------------------------------------
// Step 2: grounding with Azure AI Search (diagram hop 4)
// ---------------------------------------------------------------------------------------------

@description('Embedding model. It turns chunks (at ingest) and questions (at query time) into vectors.')
param embeddingModelName string = 'text-embedding-3-small'
param embeddingModelVersion string = '1'

@description('Search tier. Basic is the cheapest tier with an outbound managed identity, which the vectorizer needs because Foundry keys are disabled. Roughly $0.11/hour, billed while it exists.')
@allowed(['basic', 'standard'])
param searchSku string = 'basic'

var searchName = 'srch-${baseName}-${suffix}'

// Built-in role IDs (verified with `az role definition list --name ...`)
var roles = {
  searchIndexDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  searchIndexDataReader: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  cognitiveServicesOpenAIUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
}

resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2026-05-01' = {
  parent: account
  name: embeddingModelName
  sku: {
    name: 'GlobalStandard'
    capacity: 50 // thousands of tokens per minute. Ingest sends a batch, so give it some headroom.
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      version: embeddingModelVersion
    }
  }
  dependsOn: [modelDeployment] // serialize writes on the account
}

// "Azure AI Search" (knowledge store) box in the diagram.
resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchName
  location: location
  sku: {
    name: searchSku
  }
  identity: {
    type: 'SystemAssigned' // used by the vectorizer to call the embedding model on Foundry
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    disableLocalAuth: true // keyless, like Foundry: every caller needs an Entra token plus a role
    semanticSearch: 'free' // semantic ranker on the free monthly allowance. Errors instead of billing when it runs out.
    publicNetworkAccess: lockDown ? 'disabled' : 'enabled' // the agent reaches it through its private endpoint
  }
}

// Query time: the agent's question arrives as text. The search service vectorizes it by calling
// the embedding deployment on Foundry, as itself (its managed identity).
resource searchCallsEmbeddings 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, search.id, roles.cognitiveServicesOpenAIUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.cognitiveServicesOpenAIUser)
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
  }
}


// You, running ingest.py and search.py locally: create the index, upload chunks, query.
resource userSearchData 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: search
  name: guid(search.id, userPrincipalId, roles.searchIndexDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.searchIndexDataContributor)
    principalId: userPrincipalId
    principalType: 'User'
  }
}

resource userSearchService 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: search
  name: guid(search.id, userPrincipalId, roles.searchServiceContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.searchServiceContributor)
    principalId: userPrincipalId
    principalType: 'User'
  }
}

// ---------------------------------------------------------------------------------------------
// Step 3: chat UI on App Service + Application Insights (diagram hop 1→2, monitoring box)
// ---------------------------------------------------------------------------------------------

@description('Agent version the web app pins to, in the standard-setup project (step 4). Version 1 there = grounded, tool_choice=required (same definition as v4 in the old basic project). See STACK.md.')
param agentVersion string = '1'

@description('App Service plan SKU. B1 is the cheapest tier that stays always-on enough for a demo (~$0.018/h Linux, Sweden Central).')
param appServiceSku string = 'B1'

var webAppName = 'app-${baseName}-${suffix}'
var monitoringRoles = {
  logAnalyticsReader: '73c42c96-874c-492b-b04d-ab87d138a893'
  privilegedMonitoringDataReader: 'dbc9c667-e97f-4491-aee6-90b9cf960190' // needed to read GenAI message content
}

resource logs 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: 'log-${baseName}-${suffix}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018' // pay per GB ingested. A demo produces megabytes.
    }
    retentionInDays: 30
  }
}

// "Application Insights" box in the diagram. Both the web app (client-side spans) and Foundry
// (server-side agent spans) write here, so one request can be followed end to end.
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${baseName}-${suffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
    // Ingestion still uses the connection string (instrumentation key). It's not a strong secret,
    // since it only allows *writing* telemetry, but Entra-only ingestion is a later hardening step.
    DisableLocalAuth: false
  }
}

// Connecting App Insights to the account and the project turns on Foundry's server-side tracing.
// The pattern follows microsoft-foundry/foundry-samples 01-connections/connection-application-insights.bicep.
resource accountAppInsightsConnection 'Microsoft.CognitiveServices/accounts/connections@2026-05-01' = {
  parent: account
  name: 'appinsights'
  properties: {
    category: 'AppInsights'
    target: appInsights.id
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: {
      key: appInsights.properties.ConnectionString
    }
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsights.id
    }
  }
}

// You can read traces (the project identity gets the same roles in the step 4 section).
resource traceReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for role in [monitoringRoles.logAnalyticsReader, monitoringRoles.privilegedMonitoringDataReader]: {
    scope: appInsights
    name: guid(appInsights.id, userPrincipalId, role)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
      principalId: userPrincipalId
      principalType: 'User'
    }
  }
]

resource plan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: 'asp-${baseName}-${suffix}'
  location: location
  kind: 'linux'
  sku: {
    name: appServiceSku
  }
  properties: {
    reserved: true // Linux
  }
}

// "App Service" box in the diagram. Still public, with no App Gateway in front. Step 6 adds that.
resource webApp 'Microsoft.Web/sites@2024-11-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  identity: {
    // System-assigned: the app's identity when it calls Foundry (no keys in config).
    // User-assigned (step 3b): used ONLY by App Service authentication, to prove itself to Entra ID
    // when signing users in. It replaces a client secret. Keep it off every other resource.
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${authIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    // Step 5: outbound calls leave through our VNet, so Foundry and the app's Cosmos DB are reached
    // through their private endpoints (resolved by the private DNS zones linked to the VNet).
    // INBOUND stays public: users reach the app on its normal URL (App Gateway + WAF come in step 6).
    virtualNetworkSubnetId: vnet::appServiceSubnet.id
    // Route ALL of the app's outbound traffic through the VNet (not just RFC 1918 destinations).
    // The older siteConfig.vnetRouteAllEnabled was silently ignored by this API version (observed: false).
    outboundVnetRouting: {
      applicationTraffic: true
    }
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.14'
      appCommandLine: 'gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8000 --timeout 180 main:app'
      alwaysOn: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      healthCheckPath: '/healthz'
      appSettings: [
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' } // pip install -r requirements.txt on deploy
        // Step 4: the app now talks to the standard-setup project, where agent state lives in our Cosmos DB.
        { name: 'FOUNDRY_PROJECT_ENDPOINT', value: 'https://${account.name}.services.ai.azure.com/api/projects/${stdProject.name}' }
        { name: 'FOUNDRY_AGENT_NAME', value: 'basic-chatbot' }
        { name: 'FOUNDRY_AGENT_VERSION', value: agentVersion }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'OTEL_SERVICE_NAME', value: 'chat-web' }
        // Step 3b: tells App Service authentication to use this managed identity's token as the
        // client assertion instead of a client secret. The value is the MI's *client* ID.
        { name: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID', value: authIdentity.properties.clientId }
        // Step 4b: the app's own data (sessions list), in a Cosmos account separate from Foundry's.
        { name: 'APP_COSMOS_ENDPOINT', value: appCosmos.properties.documentEndpoint }
        { name: 'APP_COSMOS_DATABASE', value: appCosmosDatabaseName }
      ]
    }
  }
}

// The app's managed identity replaces your `az login`: same role, different principal.
resource webAppFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, webApp.id, foundryUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------------------------
// Step 4: standard agent setup. Agent state lives in resources WE own (diagram hop 7, the
// "Foundry Agent Service dependencies" box).
// Docs: https://learn.microsoft.com/azure/foundry/agents/concepts/standard-agent-setup
// Pattern: Azure-Samples/microsoft-foundry-baseline (infra-as-code/bicep/ai-foundry-project.bicep).
//
// Why a NEW project: storage settings can't be changed on an existing project. proj-chatbot
// (basic setup, agents v1–v4) is kept for comparison.
// Decision (2026-11-17): REUSE the existing search service as the agent's vector store, a
// documented deviation from the baseline (which uses a dedicated one) to avoid ~$80/month.
// ---------------------------------------------------------------------------------------------

var stdProjectName = 'proj-chatbot-std'
var stdRoles = {
  cosmosDbOperator: '230815da-be43-4aae-9cb4-875f7bd000aa' // control plane: lets Foundry create the enterprise_memory database
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  cosmosDataContributor: '00000000-0000-0000-0000-000000000002' // Cosmos *data plane* role (not Azure RBAC)
  cosmosDataReader: '00000000-0000-0000-0000-000000000001'
}

// The project's identity is created BEFORE the project, so every role it needs can be granted
// before Foundry provisions the capability host (which fails if the roles are missing).
resource agentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${baseName}-agent-${suffix}'
  location: location
}

// "Azure Cosmos DB" box: agent definitions + conversations (thread storage).
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' = {
  name: 'cosmos-${baseName}-${suffix}'
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    capabilities: [{ name: 'EnableServerless' }] // pay per request, ~$0 idle (decision 2026-11-17)
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [{ locationName: location, failoverPriority: 0, isZoneRedundant: false }]
    disableLocalAuth: true // keyless: Entra + Cosmos data-plane roles only
    minimalTlsVersion: 'Tls12'
    publicNetworkAccess: publicAccess // reached through its private endpoint
  }
}

// "Azure Storage" box: files uploaded to agents (we don't use file upload yet, but standard setup requires it).
resource agentStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: take('st${baseName}${suffix}', 24) // storage names: max 24 chars, lowercase letters and digits
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowSharedKeyAccess: false // keyless
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: publicAccess // reached through its private endpoint
    networkAcls: { defaultAction: lockDown ? 'Deny' : 'Allow', bypass: 'AzureServices' }
  }
}

// ---- Roles the project identity needs BEFORE the capability host is provisioned ----

resource agentCosmosOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cosmos
  name: guid(cosmos.id, agentIdentity.id, stdRoles.cosmosDbOperator)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', stdRoles.cosmosDbOperator)
    principalId: agentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource agentStorageContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: agentStorage
  name: guid(agentStorage.id, agentIdentity.id, stdRoles.storageBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', stdRoles.storageBlobDataContributor)
    principalId: agentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Search is used twice by this project: as the agent's vector store (capability host) AND by the
// AI Search tool for the policies index. Both run as the project identity. (Step 2 finding: the
// tool needs Search Service Contributor, not just the Index Data role.)
resource agentSearchData 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: search
  name: guid(search.id, agentIdentity.id, roles.searchIndexDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.searchIndexDataContributor)
    principalId: agentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource agentSearchService 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: search
  name: guid(search.id, agentIdentity.id, roles.searchServiceContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.searchServiceContributor)
    principalId: agentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---- The standard-setup project ----

resource stdProject 'Microsoft.CognitiveServices/accounts/projects@2026-05-01' = {
  parent: account
  name: stdProjectName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${agentIdentity.id}': {}
    }
  }
  properties: {
    displayName: 'Basic chatbot (standard setup)'
    description: 'Agent state in our own Cosmos DB, Storage and AI Search'
  }
  dependsOn: [accountAppInsightsConnection, embeddingDeployment] // serialize writes on the account
}

// The project's internal ID names its Cosmos containers and blob containers. Used to scope roles.
#disable-next-line BCP053
var stdWorkspaceId = stdProject.properties.internalId
var stdWorkspaceGuid = '${substring(stdWorkspaceId, 0, 8)}-${substring(stdWorkspaceId, 8, 4)}-${substring(stdWorkspaceId, 12, 4)}-${substring(stdWorkspaceId, 16, 4)}-${substring(stdWorkspaceId, 20, 12)}'

// Blob Data Owner, but only on containers named after THIS project (ABAC condition, from the
// baseline). Another project sharing the storage account couldn't be touched by this identity.
resource agentStorageOwnerScoped 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: agentStorage
  name: guid(agentStorage.id, agentIdentity.id, stdRoles.storageBlobDataOwner)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', stdRoles.storageBlobDataOwner)
    principalId: agentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    conditionVersion: '2.0'
    condition: '((!(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write\'})) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase \'${stdWorkspaceGuid}\'))'
  }
}

// Connections, one at a time (parallel connection writes on a project tend to conflict).
resource stdCosmosConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-05-01' = {
  parent: stdProject
  name: 'cosmos'
  properties: {
    category: 'CosmosDb'
    target: cosmos.properties.documentEndpoint
    authType: 'AAD'
    metadata: { ApiType: 'Azure', ResourceId: cosmos.id, location: location }
  }
}

resource stdStorageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-05-01' = {
  parent: stdProject
  name: 'agent-storage'
  properties: {
    category: 'AzureStorageAccount'
    target: agentStorage.properties.primaryEndpoints.blob
    authType: 'AAD'
    metadata: { ApiType: 'Azure', ResourceId: agentStorage.id, location: location }
  }
  dependsOn: [stdCosmosConnection, agentStorageOwnerScoped]
}

// Connection names are unique across the whole Foundry ACCOUNT, not per project: reusing 'search'
// failed with "Connection search already exist, and can only be updated by the workspace that
// created it" (proj-chatbot). Hence the -std suffix.
resource stdSearchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-05-01' = {
  parent: stdProject
  name: 'search-std'
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${search.name}.search.windows.net'
    authType: 'AAD'
    metadata: { ApiType: 'Azure', ResourceId: search.id, location: location }
  }
  dependsOn: [stdStorageConnection]
}

resource stdAppInsightsConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-05-01' = {
  parent: stdProject
  name: 'appinsights-std'
  properties: {
    category: 'AppInsights'
    target: appInsights.id
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: { key: appInsights.properties.ConnectionString }
    metadata: { ApiType: 'Azure', ResourceId: appInsights.id }
  }
  dependsOn: [stdSearchConnection]
}

// Account-level capability host: NOT declared here. A network-injected account creates it itself,
// named '<account>@aml_aiagentservice' with customerSubnet = snet-agent (seen 2026-11-17). Declaring
// one ourselves failed twice: a different name conflicts ("existing Capability Host…"), and that name
// can't be PUT by us ("Resource name is invalid": '@'). The baseline repo doesn't declare it either.

// The switch from "basic" to "standard": tells Agent Service which connections hold
// conversations (Cosmos), files (Storage) and vector stores (Search) for this project.
// Immutable: changing it means deleting and recreating it, which orphans existing agent data.
resource stdCapabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-06-01' = {
  parent: stdProject
  name: 'agents'
  properties: {
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
    threadStorageConnections: [stdCosmosConnection.name]
    storageConnections: [stdStorageConnection.name]
    vectorStoreConnections: [stdSearchConnection.name]
  }
  dependsOn: [
    stdAppInsightsConnection
    agentCosmosOperator
    agentStorageContributor
    agentStorageOwnerScoped
    agentSearchData
    agentSearchService
  ]
}

// ---- Roles that can only be granted AFTER provisioning ----

// Provisioning creates the 'enterprise_memory' database. Cosmos data-plane roles are scoped to it.
resource agentCosmosData 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-15' = {
  parent: cosmos
  name: guid(cosmos.id, agentIdentity.id, stdRoles.cosmosDataContributor)
  properties: {
    principalId: agentIdentity.properties.principalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${stdRoles.cosmosDataContributor}'
    scope: '${cosmos.id}/dbs/enterprise_memory'
  }
  dependsOn: [stdCapabilityHost]
}

// You: read-only access to the conversation data, for experiments ("where does my chat live?").
resource userCosmosReader 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-15' = {
  parent: cosmos
  name: guid(cosmos.id, userPrincipalId, stdRoles.cosmosDataReader)
  properties: {
    principalId: userPrincipalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${stdRoles.cosmosDataReader}'
    scope: '${cosmos.id}/dbs/enterprise_memory'
  }
  dependsOn: [agentCosmosData] // Cosmos role assignments must not run in parallel
}

// Trace readers for the new project's identity (same as step 3 for the old project).
resource stdTraceReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for role in [monitoringRoles.logAnalyticsReader, monitoringRoles.privilegedMonitoringDataReader]: {
    scope: appInsights
    name: guid(appInsights.id, agentIdentity.id, role)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
      principalId: agentIdentity.properties.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

// ---------------------------------------------------------------------------------------------
// Step 4b: "My previous chats". The app's OWN data model, next to Foundry's.
// Foundry owns the conversation content (enterprise_memory, internal format). The app owns a
// small index of who has which conversations, so the UI can list and reopen them.
// Separate Cosmos account on purpose: the baseline keeps Foundry's dependency resources for
// Foundry only, and serverless costs ~$0 when idle.
// ---------------------------------------------------------------------------------------------

var appCosmosDatabaseName = 'chat'

resource appCosmos 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' = {
  name: 'cosmos-${baseName}-app-${suffix}'
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    capabilities: [{ name: 'EnableServerless' }]
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [{ locationName: location, failoverPriority: 0, isZoneRedundant: false }]
    disableLocalAuth: true
    minimalTlsVersion: 'Tls12'
    publicNetworkAccess: publicAccess // reached through its private endpoint
  }

  resource database 'sqlDatabases' = {
    name: appCosmosDatabaseName
    properties: { resource: { id: appCosmosDatabaseName } }

    // One document per conversation. Partitioned by the user's Entra object ID, so "list my
    // chats" is a single-partition query and can never touch another user's documents.
    resource sessions 'containers' = {
      name: 'sessions'
      properties: {
        resource: {
          id: 'sessions'
          partitionKey: { paths: ['/user_oid'], kind: 'Hash' }
          indexingPolicy: {
            indexingMode: 'consistent'
            includedPaths: [{ path: '/updated_at/?' }] // the only field we sort on
            excludedPaths: [{ path: '/*' }] // keep writes cheap: index nothing else
          }
        }
      }
    }
  }
}

// The web app reads and writes sessions (Cosmos data-plane role, scoped to the 'chat' database).
resource webAppSessionsData 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-15' = {
  parent: appCosmos
  name: guid(appCosmos.id, webApp.id, stdRoles.cosmosDataContributor)
  properties: {
    principalId: webApp.identity.principalId
    roleDefinitionId: '${appCosmos.id}/sqlRoleDefinitions/${stdRoles.cosmosDataContributor}'
    scope: '${appCosmos.id}/dbs/${appCosmosDatabaseName}'
  }
  dependsOn: [appCosmos::database]
}

// You, for running the app locally (until step 5 makes this account private).
resource userSessionsData 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-15' = {
  parent: appCosmos
  name: guid(appCosmos.id, userPrincipalId, stdRoles.cosmosDataContributor)
  properties: {
    principalId: userPrincipalId
    roleDefinitionId: '${appCosmos.id}/sqlRoleDefinitions/${stdRoles.cosmosDataContributor}'
    scope: '${appCosmos.id}/dbs/${appCosmosDatabaseName}'
  }
  dependsOn: [webAppSessionsData] // Cosmos role assignments must not run in parallel
}

// ---------------------------------------------------------------------------------------------
// Step 3b: Entra ID sign-in for the web app (App Service built-in authentication)
// Docs: https://learn.microsoft.com/azure/app-service/configure-authentication-provider-aad
// ---------------------------------------------------------------------------------------------

var webAppUrl = 'https://${webAppName}.azurewebsites.net'

// Dedicated identity for the sign-in flow. With a federated credential, Entra ID trusts tokens
// from this identity in place of a client secret, so there's nothing to leak, rotate or expire.
resource authIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${baseName}-auth-${suffix}'
  location: location
}

// The app registration: how Entra ID knows this web app. It is single-tenant (your org only),
// and only this app's /.auth callback may receive sign-in responses.
resource appRegistration 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: 'chatbot-web-${suffix}'
  displayName: 'Contoso Policy Chat (${webAppName})'
  signInAudience: 'AzureADMyOrg'
  web: {
    redirectUris: ['${webAppUrl}/.auth/login/aad/callback']
    implicitGrantSettings: {
      enableIdTokenIssuance: true // App Service auth uses the hybrid flow (code + id_token)
    }
  }
}

// "Trust tokens issued to authIdentity as this app's credential."
// Graph extension 1.0.0 requires the '{application uniqueName}/{credential name}' form here: the
// nested child-resource syntax from the docs failed with "resource key 'name' must be … '{parent}/{child}'".
resource federatedCredential 'Microsoft.Graph/applications/federatedIdentityCredentials@v1.0' = {
  name: '${appRegistration.uniqueName}/app-service-auth'
  description: 'App Service authentication signs in users with the web app user-assigned managed identity instead of a client secret.'
  audiences: ['api://AzureADTokenExchange']
  issuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
  subject: authIdentity.properties.principalId
}

// The service principal is the app's presence in this tenant. appRoleAssignmentRequired = true
// means Entra ID itself refuses sign-in to anyone who isn't explicitly assigned, before
// the request ever reaches App Service.
resource appServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: appRegistration.appId
  appRoleAssignmentRequired: true
}

// Assign you. Add more users or, better, a security group the same way.
resource userAppAssignment 'Microsoft.Graph/appRoleAssignedTo@v1.0' = {
  appRoleId: '00000000-0000-0000-0000-000000000000' // "default access": the app defines no custom roles
  principalId: userPrincipalId
  resourceId: appServicePrincipal.id
}

// Built-in authentication: App Service handles sign-in before requests reach the app, then
// passes the user's identity in X-MS-CLIENT-PRINCIPAL-* headers. Clients can't forge them.
resource webAppAuth 'Microsoft.Web/sites/config@2024-11-01' = {
  parent: webApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
      // /healthz: App Service health checks arrive without a user. /healthz/deps: step 5 private-path check (booleans only).
      excludedPaths: ['/healthz', '/healthz/deps']
    }
    httpSettings: {
      requireHttps: true
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
          clientId: appRegistration.appId
          clientSecretSettingName: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID' // magic name: use the MI, not a secret
        }
        validation: {
          allowedAudiences: [appRegistration.appId]
        }
      }
    }
    login: {
      tokenStore: {
        enabled: true
      }
    }
  }
  dependsOn: [federatedCredential, userAppAssignment]
}

// ---------------------------------------------------------------------------------------------
// Step 5: private networking (the "Virtual network" box and its subnets in the diagram)
// Docs: https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks
// Pattern: foundry-samples 15-private-network-standard-agent-setup
// ---------------------------------------------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${baseName}-${suffix}'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [vnetAddressPrefix] }
    subnets: [
      {
        // "Azure AI agent integration subnet": Foundry injects the agent runtime here, so the agent's
        // calls to Search, Cosmos DB and Storage start INSIDE our network.
        name: 'snet-agent'
        properties: {
          addressPrefix: agentSubnetPrefix
          delegations: [{ name: 'foundry-agents', properties: { serviceName: 'Microsoft.App/environments' } }]
          // New VNets default to private subnets (no internet egress). The agent still needs Entra ID
          // and the app needs Application Insights, so egress stays open until step 6's Azure Firewall.
          defaultOutboundAccess: true
        }
      }
      {
        // "Private endpoint subnet": one private IP per PaaS service.
        name: 'snet-pe'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          defaultOutboundAccess: false
        }
      }
      {
        // "App Service integration subnet": the web app's OUTBOUND traffic.
        name: 'snet-appsvc'
        properties: {
          addressPrefix: appServiceSubnetPrefix
          delegations: [{ name: 'app-service', properties: { serviceName: 'Microsoft.Web/serverFarms' } }]
          defaultOutboundAccess: true
        }
      }
    ]
  }

  resource agentSubnet 'subnets' existing = { name: 'snet-agent' }
  resource privateEndpointSubnet 'subnets' existing = { name: 'snet-pe' }
  resource appServiceSubnet 'subnets' existing = { name: 'snet-appsvc' }
}

// Private DNS: inside the VNet, e.g. srch-…search.windows.net resolves (via a CNAME to
// …privatelink.search.windows.net) to the private endpoint's 10.20.1.x address instead of the public IP.
// Getting DNS right is most of the work in private networking.
var privateDnsZoneNames = [
  'privatelink.cognitiveservices.azure.com' // Foundry
  'privatelink.openai.azure.com' // Foundry (OpenAI endpoint)
  'privatelink.services.ai.azure.com' // Foundry (project / agents endpoint)
  'privatelink.search.windows.net'
  'privatelink.documents.azure.com' // both Cosmos DB accounts
  'privatelink.blob.${environment().suffixes.storage}' // = privatelink.blob.core.windows.net in public Azure
]

resource dnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zone in privateDnsZoneNames: {
    name: zone
    location: 'global'
  }
]

resource dnsZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zone, i) in privateDnsZoneNames: {
    parent: dnsZones[i]
    name: 'link-${vnet.name}'
    location: 'global'
    properties: {
      virtualNetwork: { id: vnet.id }
      registrationEnabled: false
    }
  }
]

// One private endpoint per service. `zones` = indexes into privateDnsZoneNames.
var privateEndpoints = [
  { name: 'foundry', resourceId: account.id, groupId: 'account', zones: [0, 1, 2] }
  { name: 'search', resourceId: search.id, groupId: 'searchService', zones: [3] }
  { name: 'cosmos-agent', resourceId: cosmos.id, groupId: 'Sql', zones: [4] }
  { name: 'cosmos-app', resourceId: appCosmos.id, groupId: 'Sql', zones: [4] }
  { name: 'storage-blob', resourceId: agentStorage.id, groupId: 'blob', zones: [5] }
]

resource privateEndpointResources 'Microsoft.Network/privateEndpoints@2024-05-01' = [
  for pe in privateEndpoints: {
    name: 'pe-${pe.name}-${suffix}'
    location: location
    // After every other write on the Foundry account: connecting a private endpoint updates the account,
    // and concurrent account writes failed with "Account … in state Accepted".
    dependsOn: [stdCapabilityHost, agentCosmosData]
    properties: {
      subnet: { id: vnet::privateEndpointSubnet.id }
      privateLinkServiceConnections: [
        {
          name: pe.name
          properties: { privateLinkServiceId: pe.resourceId, groupIds: [pe.groupId] }
        }
      ]
    }
  }
]

// Registers each endpoint's private IP in the right DNS zone(s) automatically.
resource privateEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [
  for (pe, i) in privateEndpoints: {
    parent: privateEndpointResources[i]
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        for z in pe.zones: {
          name: replace(privateDnsZoneNames[z], '.', '-')
          properties: { privateDnsZoneId: dnsZones[z].id }
        }
      ]
    }
    dependsOn: [dnsZoneLinks]
  }
]

output foundryAccountName string = account.name
output modelDeploymentName string = modelDeployment.name
output embeddingDeploymentName string = embeddingDeployment.name
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output webAppName string = webApp.name
output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output appInsightsName string = appInsights.name
output stdProjectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${stdProject.name}'
output cosmosAccountName string = cosmos.name
output stdSearchConnectionName string = stdSearchConnection.name
output agentStorageName string = agentStorage.name
output appCosmosEndpoint string = appCosmos.properties.documentEndpoint
output vnetName string = vnet.name
output lockedDown bool = lockDown
