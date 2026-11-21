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
// Step 6a, egress control: Azure Firewall (Basic) + route table; only allow-listed destinations get out.
// Step 6b, ingress control: Application Gateway + WAF as the only public entry; TLS cert in Key Vault.
// Step 7a, availability + safe deploys: zone-redundant App Service (Premium v3) with a staging slot.
//
// We use the *basic* agent setup here, so conversation state is kept in Microsoft-managed
// storage. Step 4 replaces it with your own Cosmos DB / Storage / AI Search ("standard setup").
//
// Step 7b, operator access: Azure Bastion + a jump box VM, Entra ID sign-in only (no SSH keys, no public IP).
// Deliberately NOT here yet: build agents inside the VNet.
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
// Default true (since step 6): a plain redeploy must never silently reopen public access.
param lockDown bool = true

@description('Address space of the workload VNet. Must be RFC 1918, not overlap peered networks, and not 192.168.0.0/24 for private endpoints (Foundry hosted-agent sandbox range).')
param vnetAddressPrefix string = '10.20.0.0/16'
param agentSubnetPrefix string = '10.20.0.0/24' // Foundry agent runtime. /27 minimum, /24 recommended.
param privateEndpointSubnetPrefix string = '10.20.1.0/24'
param appServiceSubnetPrefix string = '10.20.2.0/26' // App Service VNet integration. /26 recommended.
param firewallSubnetPrefix string = '10.20.3.0/26' // name fixed by Azure: AzureFirewallSubnet, /26 minimum
param firewallManagementSubnetPrefix string = '10.20.3.64/26' // AzureFirewallManagementSubnet, required by the Basic tier

@description('Step 6a. true: deploy Azure Firewall (Basic, ~$0.40/h) and route all internet-bound traffic from the agent and app subnets through it. false: empty the route table (direct, unrestricted egress). NOTE: false does not delete an existing firewall (incremental deployment); delete it separately to stop billing (README → Cleanup).')
param deployFirewall bool = true

param appGatewaySubnetPrefix string = '10.20.4.0/24' // Application Gateway v2: dedicated subnet, /24 recommended

@description('Step 6b. true: Application Gateway (WAF_v2, ~$0.45/h) is the only public entry; the web app main site denies direct public traffic. false: no gateway; the app is public again. Like the firewall, false does NOT delete an existing gateway.')
param deployAppGateway bool = true

// Step 7b: private access for people (operators), not for users.
param bastionSubnetPrefix string = '10.20.5.0/26' // name fixed by Azure: AzureBastionSubnet, /26 minimum
param jumpboxSubnetPrefix string = '10.20.5.64/28'
@description('Step 7b. Azure Bastion (Standard, ~$0.29/h) + jump box VM (B2s ~$0.043/h). false stops NEW deployments only; delete them to stop billing (see README Cleanup).')
param deployBastion bool = true
@description('Jump box size. VM quota is per family and new subscriptions often have 0 for some (Basv2, DSv5, DASv5 were 0 here): preflight with what-if and pick one that passes.')
param jumpboxVmSize string = 'Standard_B2s'
param jumpboxAdminUsername string = 'azureadmin'
@description('Local admin password nobody needs: SSH password login is disabled by cloud-init and people sign in with Entra ID. Random per deployment; VMs ignore password changes on redeploy.')
@secure()
param jumpboxAdminPassword string = newGuid()

@description('Step 6b, one-off. true: open the Key Vault to the internet (still Entra + RBAC) so the TLS certificate can be created from a laptop. Default false: vault reachable only via its private endpoint.')
param allowKeyVaultSetup bool = false

@description('Step 6b. true: the web app main site denies direct public traffic (users must come through the gateway). Set false while bringing up or debugging the gateway: open the new door before closing the old one.')
param closeDirectAppAccess bool = true

@description('Step 6a experiment: extra websites the APP subnet may reach through the firewall, e.g. ["example.com"]. Empty = only the platform allow-list.')
param experimentAllowedFqdns array = []

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

@description('App Service plan SKU. Step 7a: Premium v3 is the cheapest tier with availability zones AND deployment slots. P0v3 = $0.089/h per instance (Linux, Sweden Central, 2026-11). Was B1 (~$0.018/h) before step 7a.')
param appServiceSku string = 'P0v3'

@description('Step 7a. Spread instances across availability zones. Needs Premium v2+, at least 2 instances, a zone-capable scale unit, AND quota: new subscriptions often have 0 "P0v3 AZ App Service instances" (deploy fails with "Operation cannot be completed without additional quota"). Request it in the portal (Quotas → App Service), or deploy with false: slots still work.')
param appServiceZoneRedundant bool = false

@description('Instances. Zone redundancy needs at least 2 (the baseline diagram shows 3): pass appServiceInstances=3 with appServiceZoneRedundant=true. Without zones, 1 is enough for slots.')
@minValue(1)
param appServiceInstances int = 1

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
    capacity: appServiceInstances
  }
  properties: {
    reserved: true // Linux
    // Step 7a: instances are spread over availability zones (separate datacenters in the region), so one
    // zone failing doesn't take the app down. No extra charge beyond the instances themselves. Possible
    // in place because this plan's scale unit supports zones (properties.maximumNumberOfZones = 3).
    zoneRedundant: appServiceZoneRedundant
  }
}

// Shared by the production site and the staging slot, so the two can't drift apart.
var siteAppSettings = [
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
  // Step 7a: before a slot swap completes, App Service calls this path on the staging instances
  // ("swap warm-up"). Any status other than 200 ABORTS the swap, so production never gets a build
  // that can't reach Foundry and Cosmos DB.
  { name: 'WEBSITE_SWAP_WARMUP_PING_PATH', value: '/healthz/deps' }
  { name: 'WEBSITE_SWAP_WARMUP_PING_STATUSES', value: '200' }
]

var siteBaseConfig = {
  scmIpSecurityRestrictionsUseMain: false
  scmIpSecurityRestrictionsDefaultAction: 'Allow'
  linuxFxVersion: 'PYTHON|3.14'
  appCommandLine: 'gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8000 --timeout 180 main:app'
  alwaysOn: true
  minTlsVersion: '1.2'
  ftpsState: 'Disabled'
  healthCheckPath: '/healthz'
  appSettings: siteAppSettings
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
    // Step 6b: "public access Enabled" + "main site: deny all" + "deployment (SCM) site: allow" means
    // users can only come in through the gateway (private endpoint traffic skips access restrictions),
    // while deploy_app.sh can still reach the SCM site from a laptop (Entra-authenticated).
    publicNetworkAccess: 'Enabled'
    siteConfig: union(siteBaseConfig, {
      ipSecurityRestrictionsDefaultAction: deployAppGateway && closeDirectAppAccess ? 'Deny' : 'Allow'
    })
  }
}

// Step 7a: the staging slot. A second copy of the app on the same instances, with its own host name and
// its own system-assigned identity. deploy_app.sh deploys HERE, then swaps (warm-up gated) into production.
// Never publicly reachable: main site denies all traffic, and swap warm-up runs inside the platform.
resource stagingSlot 'Microsoft.Web/sites/slots@2024-11-01' = {
  parent: webApp
  name: 'staging'
  location: location
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned' // its own principal: it needs the same roles as production (below)
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: vnet::appServiceSubnet.id // same outbound path as production
    outboundVnetRouting: { applicationTraffic: true }
    publicNetworkAccess: 'Enabled' // SCM (deploy) reachable; main site denied below
    siteConfig: union(siteBaseConfig, {
      ipSecurityRestrictionsDefaultAction: 'Deny'
    })
  }
}

// Identities don't move with a swap, so the staging identity needs what the code needs: Foundry + app Cosmos.
resource stagingFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, stagingSlot.id, foundryUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
    principalId: stagingSlot.identity.principalId
    principalType: 'ServicePrincipal'
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

resource stagingSessionsData 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-15' = {
  parent: appCosmos
  name: guid(appCosmos.id, stagingSlot.id, stdRoles.cosmosDataContributor)
  properties: {
    principalId: stagingSlot.identity.principalId
    roleDefinitionId: '${appCosmos.id}/sqlRoleDefinitions/${stdRoles.cosmosDataContributor}'
    scope: '${appCosmos.id}/dbs/${appCosmosDatabaseName}'
  }
  dependsOn: [userSessionsData] // Cosmos role assignments must not run in parallel
}

// ---------------------------------------------------------------------------------------------
// Step 6b: ingress control (diagram ①: Application Gateway + WAF, Key Vault for its certificate)
// Docs: https://learn.microsoft.com/azure/app-service/overview-app-gateway-integration
//       https://learn.microsoft.com/azure/application-gateway/key-vault-certs
// ---------------------------------------------------------------------------------------------

var appGatewayName = 'agw-${baseName}-${suffix}'
var appGatewayDnsLabel = '${baseName}-${suffix}'
// <label>.<region>.cloudapp.azure.com: the gateway's public name. No custom domain here, so the TLS
// certificate is self-signed (browser warning). Production: your own domain + a CA-issued certificate.
var appGatewayFqdn = '${appGatewayDnsLabel}.${location}.cloudapp.azure.com'
var tlsCertificateName = 'agw-tls'
var keyVaultRoles = {
  secretsUser: '4633458b-17de-408a-b874-0445c86b69e6' // read certificates (as secrets): the gateway
  certificatesOfficer: 'a4417e6f-fecd-4de8-b567-7b0420556985' // create certificates: you, once
}

// Key Vault box in the diagram: holds the gateway's TLS certificate (private key never leaves Azure).
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: take('kv-${baseName}-${suffix}', 24)
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true // Entra roles, no access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 7 // short for a learning build; production: longer + purge protection
    // Application Gateway v2 is NOT a Key Vault "trusted service" (troubleshooting docs), so it reads the
    // certificate through the vault's private endpoint. Open only while creating the certificate.
    publicNetworkAccess: allowKeyVaultSetup ? 'Enabled' : 'Disabled'
    networkAcls: { defaultAction: allowKeyVaultSetup ? 'Allow' : 'Deny', bypass: 'None' }
  }
}

resource userKeyVaultCertificates 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, userPrincipalId, keyVaultRoles.certificatesOfficer)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultRoles.certificatesOfficer)
    principalId: userPrincipalId
    principalType: 'User'
  }
}

// Application Gateway can only use a USER-assigned identity for Key Vault.
resource appGatewayIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${baseName}-agw-${suffix}'
  location: location
}

resource appGatewayReadsCertificate 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, appGatewayIdentity.id, keyVaultRoles.secretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultRoles.secretsUser)
    principalId: appGatewayIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource appGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployAppGateway) {
  name: 'pip-agw-${suffix}'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: appGatewayDnsLabel }
  }
}

// The WAF: inspects every request (OWASP-style attacks, known exploit patterns) before it reaches the app.
resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2024-05-01' = if (deployAppGateway) {
  name: 'waf-${baseName}-${suffix}'
  location: location
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: 'Prevention' // block, don't just log ('Detection')
      requestBodyCheck: true // the chat message is in the JSON body
      maxRequestBodySizeInKb: 128
      fileUploadLimitInMb: 1
    }
    managedRules: {
      managedRuleSets: [
        { ruleSetType: 'Microsoft_DefaultRuleSet', ruleSetVersion: '2.1' } // Microsoft's OWASP-based rules
      ]
      // False positives on the Entra ID sign-in callback (/.auth/login/aad/callback), found in the WAF log
      // 2026-11-19: Entra posts back `state` (URL-encoded redirect) and `code` (long opaque string), which
      // scored 6–11 and got blocked (949110) AFTER a successful sign-in. Per Microsoft's guidance: exclude
      // only the matched field VALUES, only from the rules that fired, never the scoring rule. Everything
      // else in these requests (and these fields for all other rules) is still inspected.
      // Docs: https://learn.microsoft.com/troubleshoot/azure/application-gateway/troubleshoot-waf-blocking-legitimate-requests-403
      exclusions: [
        {
          matchVariable: 'RequestArgValues'
          selectorMatchOperator: 'Equals'
          selector: 'state'
          exclusionManagedRuleSets: [
            {
              ruleSetType: 'Microsoft_DefaultRuleSet'
              ruleSetVersion: '2.1'
              ruleGroups: [{ ruleGroupName: 'PROTOCOL-ENFORCEMENT', rules: [{ ruleId: '920230' }] }] // multiple URL encoding
            }
          ]
        }
        {
          matchVariable: 'RequestArgValues'
          selectorMatchOperator: 'Equals'
          selector: 'code'
          exclusionManagedRuleSets: [
            {
              ruleSetType: 'Microsoft_DefaultRuleSet'
              ruleSetVersion: '2.1'
              ruleGroups: [{ ruleGroupName: 'SQLI', rules: [{ ruleId: '942430' }, { ruleId: '942440' }] }] // special chars, "--"
            }
          ]
        }
      ]
    }
  }
}

var agwId = resourceId('Microsoft.Network/applicationGateways', appGatewayName)

resource appGateway 'Microsoft.Network/applicationGateways@2024-05-01' = if (deployAppGateway) {
  name: appGatewayName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appGatewayIdentity.id}': {} }
  }
  properties: {
    sku: { name: 'WAF_v2', tier: 'WAF_v2' }
    autoscaleConfiguration: { minCapacity: 0, maxCapacity: 2 } // 0 = pay only the fixed hourly price when idle
    firewallPolicy: { id: wafPolicy.id }
    sslPolicy: { policyType: 'Predefined', policyName: 'AppGwSslPolicy20220101' } // TLS 1.2+
    gatewayIPConfigurations: [{ name: 'gateway', properties: { subnet: { id: vnet::appGatewaySubnet.id } } }]
    frontendIPConfigurations: [{ name: 'public', properties: { publicIPAddress: { id: appGatewayPublicIp.id } } }]
    frontendPorts: [{ name: 'https', properties: { port: 443 } }]
    sslCertificates: [
      {
        name: 'tls'
        // Versionless secret URI: a renewed certificate is picked up automatically.
        properties: { keyVaultSecretId: '${keyVault.properties.vaultUri}secrets/${tlsCertificateName}' }
      }
    ]
    httpListeners: [
      {
        name: 'https'
        properties: {
          frontendIPConfiguration: { id: '${agwId}/frontendIPConfigurations/public' }
          frontendPort: { id: '${agwId}/frontendPorts/https' }
          protocol: 'Https'
          sslCertificate: { id: '${agwId}/sslCertificates/tls' }
        }
      }
    ]
    // The backend is the web app's normal name. Inside the VNet it resolves (privatelink.azurewebsites.net)
    // to the app's PRIVATE endpoint, so gateway → app never touches the internet.
    backendAddressPools: [{ name: 'app', properties: { backendAddresses: [{ fqdn: '${webAppName}.azurewebsites.net' }] } }]
    probes: [
      {
        name: 'healthz'
        properties: {
          protocol: 'Https'
          path: '/healthz' // excluded from sign-in
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          match: { statusCodes: ['200-399'] }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'app-https'
        properties: {
          port: 443
          protocol: 'Https'
          // App Service routes by Host header, so it must be the app's own name; the original name travels
          // in X-Original-Host (see authsettingsV2 forwardProxy).
          pickHostNameFromBackendAddress: true
          requestTimeout: 180 // agent turns can take several seconds
          probe: { id: '${agwId}/probes/healthz' }
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'app'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: { id: '${agwId}/httpListeners/https' }
          backendAddressPool: { id: '${agwId}/backendAddressPools/app' }
          backendHttpSettings: { id: '${agwId}/backendHttpSettingsCollection/app-https' }
        }
      }
    ]
  }
  // Certificate access must work before the gateway reads it: role + the vault's private endpoint + DNS.
  dependsOn: [appGatewayReadsCertificate, privateEndpointDns]
}

resource appGatewayLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployAppGateway) {
  name: 'to-log-analytics'
  scope: appGateway
  properties: {
    workspaceId: logs.id
    logAnalyticsDestinationType: 'Dedicated' // AGWAccessLogs, AGWFirewallLogs
    logs: [
      { category: 'ApplicationGatewayAccessLog', enabled: true }
      { category: 'ApplicationGatewayFirewallLog', enabled: true }
    ]
  }
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
    // Step 6b: users now sign in on the gateway's host name too.
    redirectUris: ['${webAppUrl}/.auth/login/aad/callback', 'https://${appGatewayFqdn}/.auth/login/aad/callback']
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
      excludedPaths: ['/healthz', '/healthz/deps', '/healthz/egress'] // egress: step 6a firewall experiment (fixed target)
    }
    httpSettings: {
      requireHttps: true
      // Step 6b: behind Application Gateway the Host header is the app's azurewebsites.net name. The gateway
      // passes the name the browser used in X-Original-Host; without this, sign-in redirects to the wrong host.
      forwardProxy: {
        convention: 'Custom'
        customHostHeaderName: 'X-Original-Host'
      }
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

// Step 6b: network security groups (NSGs), L4 allow/deny rules per subnet. Segmentation: a compromised
// subnet can only reach what its rules allow. Pattern: the baseline reference architecture.
// Rules use explicit Deny at priority 4000 to override Azure's default "allow all VNet traffic" rule.
resource nsgAgent 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-agent-${suffix}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'DenyAllInbound' // no legitimate inbound traffic to the agent runtime (baseline)
        properties: { priority: 4000, direction: 'Inbound', access: 'Deny', protocol: '*', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '*' }
      }
      {
        name: 'AllowPrivateEndpoints' // Search, Cosmos DB (all ports, per the baseline), Storage
        properties: { priority: 100, direction: 'Outbound', access: 'Allow', protocol: '*', sourceAddressPrefix: agentSubnetPrefix, sourcePortRange: '*', destinationAddressPrefix: privateEndpointSubnetPrefix, destinationPortRange: '*' }
      }
      {
        name: 'AllowHttpsInternet' // Entra ID, App Insights (and through the firewall when it's on)
        properties: { priority: 110, direction: 'Outbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: agentSubnetPrefix, sourcePortRange: '*', destinationAddressPrefix: 'Internet', destinationPortRange: '443' }
      }
      {
        name: 'DenyAllOutbound'
        properties: { priority: 4000, direction: 'Outbound', access: 'Deny', protocol: '*', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '*' }
      }
    ]
  }
}

resource nsgAppService 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-appsvc-${suffix}'
  location: location
  properties: {
    securityRules: [
      // Integration subnets carry only the app's OUTBOUND traffic; inbound rules wouldn't apply.
      {
        name: 'AllowPrivateEndpoints' // Foundry, app Cosmos DB
        properties: { priority: 100, direction: 'Outbound', access: 'Allow', protocol: '*', sourceAddressPrefix: appServiceSubnetPrefix, sourcePortRange: '*', destinationAddressPrefix: privateEndpointSubnetPrefix, destinationPortRange: '*' }
      }
      {
        name: 'AllowHttpsInternet' // Entra ID (sign-in), App Insights, PyPI during builds
        properties: { priority: 110, direction: 'Outbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: appServiceSubnetPrefix, sourcePortRange: '*', destinationAddressPrefix: 'Internet', destinationPortRange: '443' }
      }
      {
        name: 'DenyAllOutbound'
        properties: { priority: 4000, direction: 'Outbound', access: 'Deny', protocol: '*', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '*' }
      }
    ]
  }
}

resource nsgPrivateEndpoints 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-pe-${suffix}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowFromAgent'
        properties: { priority: 100, direction: 'Inbound', access: 'Allow', protocol: '*', sourceAddressPrefix: agentSubnetPrefix, sourcePortRange: '*', destinationAddressPrefix: privateEndpointSubnetPrefix, destinationPortRange: '*' }
      }
      {
        name: 'AllowFromAppService'
        properties: { priority: 110, direction: 'Inbound', access: 'Allow', protocol: '*', sourceAddressPrefix: appServiceSubnetPrefix, sourcePortRange: '*', destinationAddressPrefix: privateEndpointSubnetPrefix, destinationPortRange: '*' }
      }
      {
        name: 'AllowHttpsFromAppGateway' // gateway → web app endpoint, gateway → Key Vault endpoint
        properties: { priority: 120, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: appGatewaySubnetPrefix, sourcePortRange: '*', destinationAddressPrefix: privateEndpointSubnetPrefix, destinationPortRange: '443' }
      }
      {
        name: 'AllowFromJumpbox' // step 7b: operators run create_agent.py, ingest.py, evaluate.py from here
        properties: { priority: 130, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: jumpboxSubnetPrefix, sourcePortRange: '*', destinationAddressPrefix: privateEndpointSubnetPrefix, destinationPortRange: '443' }
      }
      {
        name: 'DenyOtherVNetInbound' // anything else in the VNet needs an explicit rule above
        properties: { priority: 4000, direction: 'Inbound', access: 'Deny', protocol: '*', sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '*' }
      }
    ]
  }
}

resource nsgAppGateway 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-appgw-${suffix}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsFromInternet' // the users
        properties: { priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'Internet', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '443' }
      }
      {
        name: 'AllowGatewayManager' // required by Application Gateway v2 (Azure's management of the gateway)
        properties: { priority: 110, direction: 'Inbound', access: 'Allow', protocol: '*', sourceAddressPrefix: 'GatewayManager', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '65200-65535' }
      }
      {
        name: 'AllowAzureLoadBalancer' // required (health of the gateway instances)
        properties: { priority: 120, direction: 'Inbound', access: 'Allow', protocol: '*', sourceAddressPrefix: 'AzureLoadBalancer', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '*' }
      }
    ]
  }
}

// Step 7b: Bastion requires ALL of these rules if its subnet has an NSG (else no platform updates/sessions).
// Source: https://learn.microsoft.com/azure/bastion/bastion-nsg
resource nsgBastion 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-bastion-${suffix}'
  location: location
  properties: {
    securityRules: [
      { name: 'AllowHttpsInbound', properties: { priority: 120, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'Internet', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '443' } }
      { name: 'AllowGatewayManagerInbound', properties: { priority: 130, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'GatewayManager', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '443' } }
      { name: 'AllowAzureLoadBalancerInbound', properties: { priority: 140, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'AzureLoadBalancer', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '443' } }
      { name: 'AllowBastionHostCommunication', properties: { priority: 150, direction: 'Inbound', access: 'Allow', protocol: '*', sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*', destinationAddressPrefix: 'VirtualNetwork', destinationPortRanges: ['8080', '5701'] } }
      // Exactly as documented: Azure VALIDATES this rule set, and narrowing the destination to the jump box
      // subnet was rejected ("NetworkSecurityGroupNotCompliantForAzureBastionSubnet", 2026-11-19).
      // The jump box's own NSG does the narrowing instead (SSH only from this subnet).
      { name: 'AllowSshRdpOutbound', properties: { priority: 100, direction: 'Outbound', access: 'Allow', protocol: '*', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: 'VirtualNetwork', destinationPortRanges: ['22', '3389'] } }
      { name: 'AllowAzureCloudOutbound', properties: { priority: 110, direction: 'Outbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: 'AzureCloud', destinationPortRange: '443' } }
      { name: 'AllowBastionCommunication', properties: { priority: 120, direction: 'Outbound', access: 'Allow', protocol: '*', sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*', destinationAddressPrefix: 'VirtualNetwork', destinationPortRanges: ['8080', '5701'] } }
      { name: 'AllowHttpOutbound', properties: { priority: 130, direction: 'Outbound', access: 'Allow', protocol: '*', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: 'Internet', destinationPortRange: '80' } }
    ]
  }
}

resource nsgJumpbox 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-jumpbox-${suffix}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSshFromBastion' // the ONLY way in: no public IP, and only Bastion's subnet may open port 22
        properties: { priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: bastionSubnetPrefix, sourcePortRange: '*', destinationAddressPrefix: jumpboxSubnetPrefix, destinationPortRange: '22' }
      }
      {
        name: 'DenyAllInbound'
        properties: { priority: 4000, direction: 'Inbound', access: 'Deny', protocol: '*', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '*' }
      }
      {
        name: 'AllowPrivateEndpoints' // Foundry, Search, Cosmos DB, Storage, Key Vault: all HTTPS
        properties: { priority: 100, direction: 'Outbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: jumpboxSubnetPrefix, sourcePortRange: '*', destinationAddressPrefix: privateEndpointSubnetPrefix, destinationPortRange: '443' }
      }
      {
        name: 'AllowWebInternet' // tools: az CLI + Azure Resource Manager, Entra ID, uv/PyPI (443), Ubuntu packages (80)
        properties: { priority: 110, direction: 'Outbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: jumpboxSubnetPrefix, sourcePortRange: '*', destinationAddressPrefix: 'Internet', destinationPortRanges: ['80', '443'] }
      }
      {
        name: 'DenyAllOutbound' // e.g. the jump box can't reach the agent or app subnets
        properties: { priority: 4000, direction: 'Outbound', access: 'Deny', protocol: '*', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '*' }
      }
    ]
  }
}

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
          // Step 6a: internet-bound traffic goes to the firewall (route table). defaultOutboundAccess stays
          // true only as the fallback path when deployFirewall=false (then the route table is empty).
          defaultOutboundAccess: true
          routeTable: { id: egressRoutes.id }
          networkSecurityGroup: { id: nsgAgent.id }
        }
      }
      {
        // "Private endpoint subnet": one private IP per PaaS service.
        name: 'snet-pe'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          defaultOutboundAccess: false
          networkSecurityGroup: { id: nsgPrivateEndpoints.id }
          // Off by default: without this, NSG rules are NOT enforced on private endpoints.
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        // "App Service integration subnet": the web app's OUTBOUND traffic.
        name: 'snet-appsvc'
        properties: {
          addressPrefix: appServiceSubnetPrefix
          delegations: [{ name: 'app-service', properties: { serviceName: 'Microsoft.Web/serverFarms' } }]
          defaultOutboundAccess: true
          routeTable: { id: egressRoutes.id }
          networkSecurityGroup: { id: nsgAppService.id }
        }
      }
      {
        name: 'AzureFirewallSubnet' // exact name required by Azure Firewall
        properties: { addressPrefix: firewallSubnetPrefix }
      }
      {
        name: 'AzureFirewallManagementSubnet' // exact name; Basic tier keeps its management traffic here
        properties: { addressPrefix: firewallManagementSubnetPrefix }
      }
      {
        // "Application Gateway subnet": the only public entry point (step 6b).
        name: 'snet-appgw'
        properties: {
          addressPrefix: appGatewaySubnetPrefix
          networkSecurityGroup: { id: nsgAppGateway.id }
        }
      }
      {
        // "Azure Bastion subnet" (step 7b): the managed SSH/RDP broker lives here.
        name: 'AzureBastionSubnet' // exact name required by Azure Bastion
        properties: {
          addressPrefix: bastionSubnetPrefix
          networkSecurityGroup: { id: nsgBastion.id }
        }
      }
      {
        // "Jump box subnet" (step 7b): an operator VM inside the network, reachable only through Bastion.
        name: 'snet-jumpbox'
        properties: {
          addressPrefix: jumpboxSubnetPrefix
          defaultOutboundAccess: true // fallback path when the firewall is off (like the other workload subnets)
          routeTable: { id: egressRoutes.id }
          networkSecurityGroup: { id: nsgJumpbox.id }
        }
      }
    ]
  }

  resource agentSubnet 'subnets' existing = { name: 'snet-agent' }
  resource privateEndpointSubnet 'subnets' existing = { name: 'snet-pe' }
  resource appServiceSubnet 'subnets' existing = { name: 'snet-appsvc' }
  resource firewallSubnet 'subnets' existing = { name: 'AzureFirewallSubnet' }
  resource firewallManagementSubnet 'subnets' existing = { name: 'AzureFirewallManagementSubnet' }
  resource appGatewaySubnet 'subnets' existing = { name: 'snet-appgw' }
  resource bastionSubnet 'subnets' existing = { name: 'AzureBastionSubnet' }
  resource jumpboxSubnet 'subnets' existing = { name: 'snet-jumpbox' }
}

// ---------------------------------------------------------------------------------------------
// Step 6a: egress control (the "Azure Firewall" box, diagram ⑤)
// Everything leaving snet-agent / snet-appsvc for the internet is routed to the firewall, which
// allows only listed destinations and DENIES the rest (that's the default). Private-endpoint traffic
// (10.20.x) never goes there: the VNet's own routes are more specific than 0.0.0.0/0.
// ---------------------------------------------------------------------------------------------

// The firewall's private IP is the first usable address in AzureFirewallSubnet (Azure reserves .0–.3).
// Computed instead of read from the firewall to avoid a dependency cycle (VNet → routes → firewall → VNet).
var firewallPrivateIp = cidrHost(firewallSubnetPrefix, 3)
// Entra ID sign-in host for this cloud (login.microsoftonline.com in public Azure).
var entraLoginHost = replace(replace(environment().authentication.loginEndpoint, 'https://', ''), '/', '')

resource egressRoutes 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-egress-${suffix}'
  location: location
  properties: {
    // false: Azure won't add routes learned from gateways, so 0.0.0.0/0 really means "the firewall".
    disableBgpRoutePropagation: true
    routes: deployFirewall
      ? [
          {
            name: 'internet-via-firewall'
            properties: { addressPrefix: '0.0.0.0/0', nextHopType: 'VirtualAppliance', nextHopIpAddress: firewallPrivateIp }
          }
        ]
      : []
  }
}

resource firewallPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployFirewall) {
  name: 'pip-fw-${suffix}'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource firewallManagementPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployFirewall) {
  name: 'pip-fw-mgmt-${suffix}'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// The policy holds the rules. Anything not matched by an Allow rule is denied.
resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-05-01' = if (deployFirewall) {
  name: 'afwp-${baseName}-${suffix}'
  location: location
  properties: {
    sku: { tier: 'Basic' }
  }

  resource rules 'ruleCollectionGroups' = {
    name: 'egress-allow-list'
    properties: {
      priority: 200
      ruleCollections: [
        {
          // Network rules = L4 (IP/port). Service tags let Azure maintain the IP list for Entra ID.
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'platform-network'
          priority: 200
          action: { type: 'Allow' }
          rules: [
            {
              ruleType: 'NetworkRule'
              name: 'entra-id'
              description: 'Agent runtime and app authenticate with Microsoft Entra ID (docs: AzureActiveDirectory service tag).'
              ipProtocols: ['TCP']
              sourceAddresses: [agentSubnetPrefix, appServiceSubnetPrefix, jumpboxSubnetPrefix]
              destinationAddresses: ['AzureActiveDirectory']
              destinationPorts: ['443']
            }
          ]
        }
        {
          // Application rules = L7 (FQDN over HTTPS, read from the TLS SNI; no TLS inspection).
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'platform-fqdns'
          priority: 300
          action: { type: 'Allow' }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'agent-runtime'
              description: 'Foundry agent subnet (Container Apps delegation): identity, Entra ID, container images. Source: Foundry network-isolation docs.'
              sourceAddresses: [agentSubnetPrefix]
              protocols: [{ protocolType: 'Https', port: 443 }]
              targetFqdns: [
                '*.identity.azure.net'
                entraLoginHost
                '*.${entraLoginHost}'
                '*.login.microsoft.com'
                'mcr.microsoft.com'
                '*.data.mcr.microsoft.com'
              ]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'telemetry'
              description: 'Application Insights ingestion for the app (OpenTelemetry) and agent traces.'
              sourceAddresses: [agentSubnetPrefix, appServiceSubnetPrefix]
              protocols: [{ protocolType: 'Https', port: 443 }]
              targetFqdns: [
                '*.in.applicationinsights.azure.com'
                '*.livediagnostics.monitor.azure.com'
                'settings.sdk.monitor.azure.com'
              ]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'app-sign-in'
              description: 'App Service built-in authentication redeems sign-in codes with Entra ID.'
              sourceAddresses: [appServiceSubnetPrefix]
              protocols: [{ protocolType: 'Https', port: 443 }]
              targetFqdns: [entraLoginHost, '*.login.microsoft.com', '*.identity.azure.net']
            }
            {
              ruleType: 'ApplicationRule'
              name: 'app-build-packages'
              // Found by the deny log (2026-11-18): zip deploy runs `pip install` on the app's build
              // container, which egresses through snet-appsvc. Blocked → "SSL: UNEXPECTED_EOF" from pip.
              // Production alternative: build in CI and deploy a pre-built package (no egress needed),
              // or use a private feed (e.g. Azure Artifacts) to control the supply chain.
              description: 'Python package downloads during App Service (Oryx) builds.'
              sourceAddresses: [appServiceSubnetPrefix]
              protocols: [{ protocolType: 'Https', port: 443 }]
              targetFqdns: ['pypi.org', 'files.pythonhosted.org']
            }
            {
              ruleType: 'ApplicationRule'
              name: 'jumpbox-tools'
              // Step 7b. An operator box needs far more egress than a workload: that's a reason to keep it
              // separate and switch it off. NOT yet verified with the firewall on (it was off during step 7b).
              description: 'Jump box: Entra SSH login (packages, pas.windows.net), az CLI + ARM, uv/Python packages.'
              sourceAddresses: [jumpboxSubnetPrefix]
              protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
              targetFqdns: [
                entraLoginHost
                '*.login.microsoft.com'
                'pas.windows.net'
                'packages.microsoft.com'
                'aka.ms'
                'azurecliprod.blob.${environment().suffixes.storage}'
                replace(replace(environment().resourceManager, 'https://', ''), '/', '')
                '*.ubuntu.com'
                'astral.sh'
                'github.com'
                '*.githubusercontent.com'
                'pypi.org'
                'files.pythonhosted.org'
              ]
            }
          ]
        }
        {
          // Separate collection so the experiment can be added and removed without touching the platform rules.
          // An Allow collection can't be empty, so with no FQDNs it holds a rule that matches nothing real.
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'experiment'
          priority: 400
          action: { type: 'Allow' }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'experiment-allowed-sites'
              description: 'Websites allowed for the /healthz/egress experiment (param experimentAllowedFqdns).'
              sourceAddresses: [appServiceSubnetPrefix]
              protocols: [{ protocolType: 'Https', port: 443 }]
              targetFqdns: empty(experimentAllowedFqdns) ? ['nothing-allowed.invalid'] : experimentAllowedFqdns
            }
          ]
        }
      ]
    }
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = if (deployFirewall) {
  name: 'afw-${baseName}-${suffix}'
  location: location
  properties: {
    sku: { name: 'AZFW_VNet', tier: 'Basic' }
    firewallPolicy: { id: firewallPolicy.id }
    ipConfigurations: [
      {
        name: 'data'
        properties: {
          subnet: { id: vnet::firewallSubnet.id }
          publicIPAddress: { id: firewallPublicIp.id } // allowed traffic leaves to the internet from this IP
        }
      }
    ]
    managementIpConfiguration: {
      name: 'management'
      properties: {
        subnet: { id: vnet::firewallManagementSubnet.id }
        publicIPAddress: { id: firewallManagementPublicIp.id }
      }
    }
  }
  dependsOn: [firewallPolicy::rules]
}

// Every allowed AND denied connection is logged, so the allow-list can be built from evidence.
resource firewallLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployFirewall) {
  name: 'to-log-analytics'
  scope: firewall
  properties: {
    workspaceId: logs.id
    logAnalyticsDestinationType: 'Dedicated' // resource-specific tables: AZFWApplicationRule, AZFWNetworkRule
    logs: [
      { category: 'AZFWApplicationRule', enabled: true }
      { category: 'AZFWNetworkRule', enabled: true }
      { category: 'AZFWFqdnResolveFailure', enabled: true }
    ]
  }
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
  'privatelink.vaultcore.azure.net' // step 6b: Key Vault (the gateway's TLS certificate)
  'privatelink.azurewebsites.net' // step 6b: the web app's inbound private endpoint (gateway → app)
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
  { name: 'keyvault', resourceId: keyVault.id, groupId: 'vault', zones: [6] }
  { name: 'webapp', resourceId: webApp.id, groupId: 'sites', zones: [7] }
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

// ---------------------------------------------------------------------------------------------
// Step 7b: operator access (the "Azure Bastion" and "Jump box" boxes in the diagram)
// People who run setup scripts (create_agent.py, ingest.py, evaluate.py) sign in to a VM INSIDE the
// network through Bastion, instead of reopening public access with lockDown=false. Nothing has a public
// SSH port: Bastion has the only public IP, and it's a TLS endpoint that requires Azure sign-in + RBAC.
// ---------------------------------------------------------------------------------------------

var vmRoles = {
  administratorLogin: '1c0163c0-47e6-4577-8991-ea5c82e286e4' // Entra SSH login with sudo
}

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployBastion) {
  name: 'pip-bastion-${suffix}'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// Standard, not Basic: native client support (az network bastion ssh/tunnel from a terminal, Entra sign-in,
// file copy over the tunnel). Basic = browser sessions only. Developer (free) = no Entra sign-in.
resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = if (deployBastion) {
  name: 'bas-${baseName}-${suffix}'
  location: location
  sku: { name: 'Standard' }
  properties: {
    enableTunneling: true // "native client support"
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: vnet::bastionSubnet.id }
          publicIPAddress: { id: bastionPublicIp.id }
        }
      }
    ]
  }
}

resource jumpboxNic 'Microsoft.Network/networkInterfaces@2024-05-01' = if (deployBastion) {
  name: 'nic-jumpbox-${suffix}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: vnet::jumpboxSubnet.id }
          privateIPAllocationMethod: 'Dynamic' // private only: no public IP on the VM
        }
      }
    ]
  }
}

// First boot: no SSH passwords, then the tools the setup scripts need. People sign in as THEMSELVES
// (`az login` on the VM), so actions are audited per person and the VM itself has no data roles.
var jumpboxCloudInit = '''#cloud-config
ssh_pwauth: false
package_update: true
packages: [git, jq, unzip]
runcmd:
  # Retry: on first boot the Entra login extension runs apt at the same time, and the CLI installer
  # failed on the dpkg lock (observed 2026-11-19: "Could not get lock /var/lib/dpkg/lock-frontend").
  - for i in $(seq 1 20); do curl -sL https://aka.ms/InstallAzureCLIDeb | bash && break; sleep 15; done
  - curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL=/usr/local/bin sh
'''
// customData only runs at creation and can't be changed afterwards: to change it, delete the VM and redeploy.

resource jumpbox 'Microsoft.Compute/virtualMachines@2024-07-01' = if (deployBastion) {
  name: 'vm-jumpbox-${suffix}'
  location: location
  identity: { type: 'SystemAssigned' } // required by the Entra login extension; NO roles assigned to it
  properties: {
    hardwareProfile: { vmSize: jumpboxVmSize }
    osProfile: {
      computerName: 'jumpbox'
      adminUsername: jumpboxAdminUsername
      adminPassword: jumpboxAdminPassword
      customData: base64(jumpboxCloudInit)
      linuxConfiguration: { disablePasswordAuthentication: false } // ARM needs one method; cloud-init turns SSH passwords off
    }
    storageProfile: {
      imageReference: { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
      osDisk: { createOption: 'FromImage', deleteOption: 'Delete', managedDisk: { storageAccountType: 'StandardSSD_LRS' } }
    }
    networkProfile: {
      networkInterfaces: [{ id: jumpboxNic.id, properties: { deleteOption: 'Delete' } }]
    }
    securityProfile: { securityType: 'TrustedLaunch', uefiSettings: { secureBootEnabled: true, vTpmEnabled: true } }
  }
}

// Lets Entra ID users sign in with SSH (short-lived certificates instead of keys).
// Docs: https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-linux
resource jumpboxEntraLogin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = if (deployBastion) {
  parent: jumpbox
  name: 'AADSSHLoginForLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

// Who may sign in to the jump box at all (here: you). Without this role, Bastion connects but login fails.
resource jumpboxLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployBastion) {
  scope: jumpbox
  name: guid(jumpbox.id, userPrincipalId, vmRoles.administratorLogin)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmRoles.administratorLogin)
    principalId: userPrincipalId
    principalType: 'User'
  }
}

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
output firewallDeployed bool = deployFirewall
output firewallPrivateIp string = firewallPrivateIp
output appGatewayUrl string = 'https://${appGatewayFqdn}'
output keyVaultName string = keyVault.name
output bastionName string = deployBastion ? bastion.name : ''
output jumpboxId string = deployBastion ? jumpbox.id : ''
