# Basic chatbot (steps 1–6b of the baseline Foundry chat architecture)

> **New here? Start with [ARCHITECTURE.md](ARCHITECTURE.md):** the diagram, one request end to end, and what's built.

**What it shows:** the core of the [baseline Microsoft Foundry chat architecture](https://learn.microsoft.com/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-chat)
([diagram](chatbot-architecture.jpg)), built one step at a time.
- **Step 1:** a terminal client calls a **prompt agent** in **Foundry Agent Service** by name and pinned version. The agent calls a model, and Foundry stores the conversation server-side.
- **Step 2:** the agent gets an **Azure AI Search tool** over an index of (fictional) Contoso policies, so it can answer with citations. Retrieval is forced (`tool_choice=required`) after measuring that the model sometimes skipped it.
- **Step 3:** a **web chat UI on App Service** calls the agent with its **managed identity**, and both the app and Foundry send traces to **Application Insights**.
- **Step 3b:** **Entra ID sign-in** (App Service built-in authentication, no client secret: a federated credential on a user-assigned managed identity). Only assigned users can sign in, and each conversation can only be resumed by the user who started it.
- **Step 4:** **standard agent setup**. A new project (`proj-chatbot-std`) stores agent definitions and conversations in **our own Cosmos DB**, files in **our own Storage account**, and vector stores in our AI Search service. The old basic project (`proj-chatbot`, agents v1–v4) is kept for comparison.
- **Step 4b:** **"Your chats" sidebar**. The app keeps its *own* index of each user's conversations (title, timestamps) in a **separate** serverless Cosmos account, partitioned by user. Reopening a chat loads its messages through Foundry's API.
- **Step 5:** **private networking**. A VNet with private endpoints and private DNS for Foundry, AI Search, both Cosmos DB accounts and Storage; the agent runs **inside** the VNet (network injection); the web app's outbound traffic goes through the VNet. **Public network access is disabled on everything except the web app.** This required a new Foundry resource; the step 1–4 one was deleted and purged.
- **Step 6a:** **egress control**. Azure Firewall (Basic) with a route table on the agent and app subnets: internet-bound traffic must pass a **default-deny** allow-list, and every attempt is logged. It can be switched off between sessions (`deployFirewall=false`).
- **Step 6b:** **ingress control**. **Application Gateway + WAF** is the only public entry point (TLS certificate in Key Vault); the web app's own URL denies direct traffic and the gateway reaches it through a private endpoint. **NSGs** segment every subnet.

Why it's built this way, and what we observed: [STACK.md](STACK.md).

> Status: steps 1–6b deployed and verified on 2026-11-15/19 (resource group `rg-basic-chatbot`, Sweden Central).
> Entry point: `https://<baseName>-<suffix>.<region>.cloudapp.azure.com` (Bicep output `appGatewayUrl`) (Application Gateway + WAF, **self-signed certificate: expect a browser warning**). The app's own `azurewebsites.net` URL returns 403. **Entra sign-in is required, and only assigned users get in.**
> **Hourly billing while it exists:** AI Search Basic ~$0.11/h + App Service B1 ~$0.018/h. See [Cleanup](#cleanup).

## Azure resources

Defined in [`infra/main.bicep`](infra/main.bicep), region Sweden Central:

| Resource | Step | Billing |
|---|---|---|
| Foundry resource (`AIServices`, S0, API keys disabled) + project | 1 | none at idle |
| Model `gpt-5.4-mini` (GlobalStandard, 50K TPM cap) | 1 | per token |
| Model `text-embedding-3-small` (GlobalStandard) | 2 | per token |
| Azure AI Search, **Basic**, keyless, semantic ranker on the free plan | 2 | **~$0.11/hour** |
| Project connection `search` (Entra auth) | 2 | none |
| Log Analytics workspace + Application Insights, connected to Foundry (`appinsights`, `appinsights-project`) | 3 | per GB ingested (tiny) |
| App Service plan **B1** Linux + web app (Python 3.14, system managed identity) | 3 | **~$0.018/hour** |
| User-assigned managed identity `id-chatbot-auth-…` (used only for sign-in) | 3b | none |
| **Entra ID** app registration + federated credential + service principal (assignment required) + your assignment, created with the Microsoft Graph Bicep extension | 3b | none. **Not in the resource group**, see Cleanup |
| App Service built-in authentication (`authsettingsV2`) | 3b | none |
| Project `proj-chatbot-std` with a **user-assigned identity** `id-chatbot-agent-…`, account + project **capability hosts** | 4 | none |
| **Cosmos DB for NoSQL, serverless**, keyless (`enterprise_memory` database is created by Foundry) | 4 | per request, ~$0 idle |
| **Storage account** (Standard_LRS, no shared keys) for agent files | 4 | per GB, ~$0 |
| Project connections `cosmos`, `agent-storage`, `search-std`, `appinsights-std` | 4 | none |
| **App Cosmos DB** `cosmos-chatbot-app-…` (serverless): database `chat`, container `sessions` partitioned by `/user_oid` | 4b | per request, ~$0 idle |
| **VNet** `10.20.0.0/16`: `snet-agent` (/24, delegated to `Microsoft.App/environments`), `snet-pe` (/24), `snet-appsvc` (/26, delegated to `Microsoft.Web/serverFarms`) | 5 | free |
| **5 private endpoints** (Foundry, Search, Cosmos ×2, Storage blob) + **6 private DNS zones** linked to the VNet | 5 | ~$36 + ~$3 / month |
| **Foundry resource `fdy-chatbot-vnet-…`** with network injection into `snet-agent`; replaces the step 1–4 resource | 5 | none at idle |
| **Azure Firewall (Basic)** `afw-chatbot-…` in `AzureFirewallSubnet` (10.20.3.0/26, private IP 10.20.3.4) + `AzureFirewallManagementSubnet` (10.20.3.64/26), 2 public IPs, firewall policy `egress-allow-list`, logs to Log Analytics | 6a | **~$0.40/hour** + $0.065/GB; switch off with `deployFirewall=false` |
| Route table `rt-egress-…` on `snet-agent` + `snet-appsvc`: `0.0.0.0/0 → 10.20.3.4` (empty when the firewall is off) | 6a | free |
| **Application Gateway WAF_v2** `agw-chatbot-…` in `snet-appgw` (10.20.4.0/24), public IP with DNS label, WAF policy (Microsoft Default Rule Set 2.1, **Prevention**), autoscale 0–2, logs to Log Analytics | 6b | **~$0.45/hour**; switch off like the firewall |
| **Key Vault** `kv-chatbot-…` (RBAC, private endpoint) holding the gateway's TLS certificate `agw-tls`; user-assigned identity for the gateway | 6b | ~free |
| **Web app private endpoint** (`sites`) + DNS zones `privatelink.azurewebsites.net`, `privatelink.vaultcore.azure.net` | 6b | ~$15/month (2 endpoints) |
| **NSGs** on `snet-agent`, `snet-pe` (private endpoint network policies enabled), `snet-appsvc`, `snet-appgw` | 6b | free |

Role assignments (all keyless):

| Who | Role | On | Why |
|---|---|---|---|
| You | Foundry User | Foundry | create and call agents |
| You | Search Index Data Contributor + Search Service Contributor | Search | `ingest.py`, `search.py` |
| Search service identity | Cognitive Services OpenAI User | Foundry | vectorizer embeds questions at query time |
| **Foundry project** identity | Search Index Data Reader + Search Service Contributor | Search | the agent's AI Search tool ([why the project and not the account](STACK.md#what-the-demo-showed)) |
| **Web app** identity | Foundry User | Foundry | the app calls the agent, replacing your `az login` |
| Foundry project identity, you | Log Analytics Reader + Privileged Monitoring Data Reader | App Insights | read traces, including GenAI message content |
| **End users** | assignment to the Entra app (default access) | Entra app `Contoso Policy Chat (…)` | sign in to the web app. Unassigned users are refused by Entra ID itself. |
| App Service auth (user-assigned MI) | federated credential | the Entra app | proves the app's identity during sign-in, **instead of a client secret** |
| **Standard project** identity (user-assigned) | Cosmos DB Operator | Cosmos account | provisioning: create `enterprise_memory` (granted *before* the capability host) |
| Standard project identity | Cosmos DB Built-in Data Contributor (data plane) | `enterprise_memory` database | read/write conversations (granted *after* provisioning) |
| Standard project identity | Storage Blob Data Contributor + Blob Data Owner **limited by an ABAC condition to containers named after this project** | Storage | agent files |
| Standard project identity | Search Index Data Contributor + Search Service Contributor | Search | vector store + the AI Search tool |
| You | Cosmos DB Built-in Data Reader | `enterprise_memory` | `inspect_cosmos.py`: look at your own conversation data |
| Web app identity, you | Cosmos DB Built-in Data Contributor | app Cosmos, database `chat` | read/write the sessions list (you: for running the app locally) |

## Access after step 5 (read this first)

Only the **web app** is reachable from the internet. Foundry, Search, both Cosmos DB accounts and Storage
refuse public calls, **even with a valid token** (403 / Forbidden). From your laptop, `create_agent.py`,
`ingest.py`, `search.py`, `evaluate.py`, `inspect_cosmos.py`, `chat.py`, Data Explorer and the Foundry
portal's agent pages no longer work. That's the point. Private developer access (Bastion + jump box) is step 7.
To work from a laptop temporarily, redeploy with `-p lockDown=false`, then redeploy without it. `lockDown` **defaults to `true`**, so a plain redeploy never reopens public access by accident.

Verify the private path and the firewall without signing in:

```bash
curl https://<webAppName>.azurewebsites.net/healthz/deps
# {"foundry":{"private_ip":true,"ok":true},"app_cosmos":{"private_ip":true,"ok":true}}
curl https://<webAppName>.azurewebsites.net/healthz/egress     # fixed target: https://example.com/
# firewall on, not allowed:  {"reachable":false,"error":"ConnectError",…}
# allowed (experimentAllowedFqdns='["example.com"]') or firewall off:  {"reachable":true,"status":200,…}
```

Firewall switches (Bicep parameters, all default to the safe value):

| Parameter | Default | Effect |
|---|---|---|
| `lockDown` | `true` | `false` reopens public access on data services (temporary laptop work) |
| `deployFirewall` | `true` | `false` empties the route table (egress goes direct, unrestricted). It does **not** delete the firewall: delete it separately to stop billing (see Cleanup). |
| `experimentAllowedFqdns` | `[]` | extra hostnames the **app** subnet may reach, e.g. `'["example.com"]'` |
| `deployAppGateway` | `true` | `false`: no gateway, app public again. Like the firewall, it doesn't delete an existing gateway. |
| `closeDirectAppAccess` | `true` | `false` keeps the app's own URL open (use while bringing up or debugging the gateway) |
| `allowKeyVaultSetup` | `false` | `true` opens Key Vault to the internet (still RBAC). Needed to **create the certificate** and for the gateway's **first creation**. |

## Deploy

```bash
az login
az group create -n rg-basic-chatbot -l swedencentral
az deployment group create -g rg-basic-chatbot -f infra/main.bicep \
  -p userPrincipalId=$(az ad signed-in-user show --query id -o tsv) lockDown=false \
  --query properties.outputs
# …create the agent, ingest, deploy the app and test (everything below), then lock down:
az deployment group create -g rg-basic-chatbot -f infra/main.bicep \
  -p userPrincipalId=$(az ad signed-in-user show --query id -o tsv) lockDown=true
cp .env.example .env   # fill in FOUNDRY_PROJECT_ENDPOINT and SEARCH_ENDPOINT from the outputs
uv sync
```

Role assignments can take a few minutes to propagate. A 403, a `tool_user_error`, or `ingest.py`
hanging at "Uploaded…" right after a deploy usually means: wait and retry.

## Run

```bash
# Step 1: ungrounded agent
uv run create_agent.py                 # prints "version N"
uv run chat.py --version N

# Step 2: grounding
uv run ingest.py                       # chunk data/*.md → embed → create index → upload
uv run search.py "hotel limit in London"          # retrieval only, no agent
uv run create_agent.py --grounded      # new version with the AI Search tool
uv run chat.py --version M             # or set FOUNDRY_AGENT_VERSION=M in .env
```

Each turn in `chat.py` prints what crossed the service boundary:

```
you> What's the hotel limit in Stockholm?
agent> In Stockholm, the nightly hotel limit is EUR 220 per night, excluding taxes【7:0†source】.
   [search] 'hotel limit Stockholm policy'          ← the query the model wrote
   [cited] Contoso Business Travel Policy: Hotels   ← the chunk it cited
   [conversation=conv_… response=resp_… tokens in/out=1278/57]
```

`[no search]` means the model answered **without** calling the tool. With v2 (`auto`) that
happened on some policy questions (experiment 6), which is why v4 forces search.

```bash
# Measure versions on a fixed question set: searched? correct? tokens? latency?
uv run evaluate.py 2 4                 # see the results in STACK.md
uv run create_agent.py --grounded --tool-choice required   # how v4 was made

# Step 4: standard setup. Same tools, new project (FOUNDRY_PROJECT_ENDPOINT → proj-chatbot-std)
uv run create_agent.py --grounded --tool-choice required   # agent v1 in the new project (the web app pins it)
uv run inspect_cosmos.py                    # Foundry's containers in OUR Cosmos DB
uv run inspect_cosmos.py conv_…             # the documents behind one conversation

# Step 3: the web app
uv run --directory app python -m uvicorn main:app --port 8000 --env-file ../.env   # local, uses your az login
./deploy_app.sh                        # zip-deploy app/ to App Service, wait for success + /healthz
```

Locally there's no App Service in front, so there's no sign-in: the app acts as the user in
`LOCAL_DEV_USER_OID` (default `local-dev`). Run two instances with different values to test
conversation ownership (experiment 12).

**What success looks like:** policy answers quote the right number and cite the right section,
answers to missing topics say "couldn't find", and every turn in a conversation shows the same conversation ID.
In the web UI each answer shows its searches, citations, agent version and token counts.

## Key files

| File | Role | Diagram |
|------|------|---------|
| [`infra/main.bicep`](infra/main.bicep) | All resources and RBAC | Foundry boxes, AI Search |
| [`data/`](data/) | 3 fictional Contoso policies (16 sections) | knowledge |
| [`ingest.py`](ingest.py) | Chunk, embed, index, upload (offline path) | → AI Search |
| [`search.py`](search.py) | Query the index directly in 4 modes | hop 4 in isolation |
| [`create_agent.py`](create_agent.py) | Create an agent version, optionally with the search tool | Agent Service (3) |
| [`chat.py`](chat.py) | Terminal client (steps 1–2) | hop 2 → 3, 4, 6, 7 |
| [`evaluate.py`](evaluate.py) | Fixed question set: searched / correct / tokens / latency per version | evaluation |
| [`app/main.py`](app/main.py) | FastAPI chat API: managed identity, OpenTelemetry | App Service (1→2) |
| [`app/sessions.py`](app/sessions.py) | The app's own sessions index (Cosmos, partitioned by user) | app data |
| [`app/static/index.html`](app/static/index.html) | Chat page. Holds the conversation ID in `sessionStorage`. | user |
| [`deploy_app.sh`](deploy_app.sh) | Zip deploy; App Service runs `pip install` | build/deploy |
| [`inspect_cosmos.py`](inspect_cosmos.py) | Read-only view of agent state in our Cosmos DB | hop 7 (Cosmos DB) |
| [`infra/bicepconfig.json`](infra/bicepconfig.json) | Pins the Microsoft Graph Bicep extension (Entra objects in IaC) | Entra ID |

## Experiments

### Step 1

**1. Where does chat memory live?**
- *Predict:* if you quit `chat.py` and restart it, will the agent remember your name?
- *Change:* say "My name is Sam", note the conversation ID, `/exit`, then run `uv run chat.py --conversation <id>` and ask "What's my name?". Then `/new` and ask again.
- *Observe:* the resumed conversation remembers, and `/new` doesn't.
- *Explain:* history is server-side state (hop 7). In step 4 you'll see these items in your own Cosmos DB.

**2. Agent version vs app code**
- *Predict:* if you publish new instructions, does a running app change behavior?
- *Change:* `uv run create_agent.py --instructions "Answer only in pirate speak."`, then chat with the new version and with the old one.
- *Observe:* behavior follows the version, and `chat.py` is unchanged.
- *Explain:* the agent definition is a deployable artifact with its own lifecycle, so pin versions.

**3. Identity is the perimeter (for now)**
- *Change:* remove your `Foundry User` role (`az role assignment delete …`), wait, run `chat.py`. Re-run the Bicep deployment to restore it.
- *Observe:* 401/403. The endpoint is public, but your token isn't authorized. Step 5 adds the network layer.

### Step 2

**4. Grounded vs ungrounded**
- *Predict:* what does the step 1 agent say about "hotel limit in Stockholm", and what does the grounded one say?
- *Change:* ask the same question with `--version 1` and with your grounded version.
- *Observe:* v1 says "I don't have that information". The grounded version says EUR 220 and cites *Travel Policy: Hotels*.
- *Explain:* same model and app code. Only the agent definition (tool + instructions) changed.

**5. Which retrieval mode finds the right chunk?**
- *Predict:* the policy never uses the word "accommodation". Will keyword search still find the Hotels section?
- *Change:* `uv run search.py "how much can I spend on accommodation in Stockholm" --mode keyword`, then `vector`, `hybrid`, `semantic-hybrid`.
- *Observe (2026-11-16):* all four rank *Hotels* first. Keyword matched on "Stockholm", and its runner-up was unrelated (*Hybrid schedule*). Vector's runner-up was *Per diem*. Semantic gave *Hotels* a reranker score of 2.57 against 1.75.
- *Explain:* on 16 chunks every mode looks fine. Differences show up with paraphrases and bigger corpora. Try a question with no shared keywords, like "Can I stay in a fancy hotel in Zurich?".

**6. Does the agent actually search?**
- *Predict:* the instructions say "always search the policy index first". Will it?
- *Change:* ask a few policy questions in fresh conversations (`/new` between them) and watch for `[no search]`.
- *Observe (2026-11-16, v2, 4 runs each):* the hotel question searched 3/4 times, the receipt question only 1/4. Without a search, it answered "I couldn't find it".
- *Explain:* with `tool_choice=auto` the *model* decides, and instructions are only a nudge. Options: force it with `tool_choice` in the agent definition (searches on every turn, including small talk), sharpen the instructions, or accept it. That's the architecture decision for this step.

**7. Retrieved chunks live in the conversation**
- *Change:* ask "hotel limit in Stockholm?", then "do I need pre-approval for a trip there from Berlin?".
- *Observe:* the second turn often shows `[no search]` but answers correctly from the *Pre-approval* chunk, uncited. Input tokens grow quickly (738 → 1278 → 1886).
- *Explain:* the tool's top 5 chunks are stored as conversation items (hop 7) and re-sent every turn. That makes follow-ups cheap, but answers lose their citations and every turn gets more expensive.
- *Then:* repeat with v4 (`tool_choice=required`). The follow-up searches again and cites. The cost is 5 more chunks in the history per turn (input tokens 1256 → 2359 on turn 2).

### Step 3

**8. Who is calling Foundry now?**
- *Predict:* the web app has no keys and no `az login`. How does Foundry know it's allowed?
- *Change:* in the portal, open the web app → Identity, and note the object ID. Then Foundry resource → Access control → Role assignments → find it under *Foundry User*.
- *Observe:* in App Insights, a `GET /msi/token` dependency from `chat-web`. That's the app fetching a token for its managed identity.
- *Explain:* same RBAC model as your user. Only the principal changed. Remove that role assignment and the app returns 502.

**9. One request, two sides of the trace**
- *Change:* send a message in the web UI, wait 2–5 minutes, then in Application Insights → Transaction search, open the `POST /api/chat` request.
- *Observe:* `chat-web` spans (your app) and `responsesapi` spans like `invoke_agent basic-chatbot:4` (Foundry, server-side). The Foundry portal also shows them under Agents → basic-chatbot → Traces.
- *Explain:* the app sends client-side spans with OpenTelemetry, and Foundry sends server-side spans because the project has an App Insights connection. They share one operation ID because the app propagates trace context. Observed: `execute_tool remote_functions.azure_ai_search` took 0.2–0.8 s inside a 1.7–2.3 s warm request.
- *Query it:* `az monitor app-insights query -g rg-basic-chatbot -a <appInsightsName> --analytics-query "union requests, dependencies | where timestamp > ago(1h) | project operation_Id, cloud_RoleName, name, duration | order by operation_Id"`

**10. Stateless server, stateful conversation**
- *Predict:* if App Service restarts mid-conversation, is the conversation lost?
- *Change:* chat, then `az webapp restart -g rg-basic-chatbot -n <webAppName>`, then continue chatting in the same tab.
- *Observe:* the conversation continues.
- *Explain:* the browser holds the conversation ID and Foundry holds the history. Before step 3b, that was also a security gap: anyone with an ID could resume it.

### Step 3b

**11. Can a caller fake being signed in?**
- *Predict:* the app trusts the `X-MS-CLIENT-PRINCIPAL-ID` header. What if a caller sets it themselves?
- *Change:* `curl -X POST <url>/api/chat -H "X-MS-CLIENT-PRINCIPAL-ID: <any object id>" -H 'Content-Type: application/json' -d '{"message":"hi"}'`
- *Observe (2026-11-17):* `401`. Anonymous `/` and `/api/me` are also `401` (a browser gets a `302` to Entra), and `/healthz` is `200`.
- *Explain:* App Service authentication runs *in front of* your code and owns those headers. That's why the app can trust them, and why the app also refuses requests without them (fail closed if auth is ever turned off).

**12. Can one user read another user's conversation?**
- *Change (locally):* start two instances with `LOCAL_DEV_USER_OID=alice` (port 8771) and `bob` (port 8772). Chat as Alice, then POST Alice's `conversation_id` to Bob's instance.
- *Observe (2026-11-17):* Alice resumes normally. Bob gets `404 Conversation not found`, and the log shows `Denied conversation … to user bob (not owner)`. A made-up ID also gets `404`, so a caller can't tell "doesn't exist" from "not yours".
- *Explain:* authentication says *who* you are. This ownership check (the owner's object ID stored as Foundry conversation metadata) is the *authorization*. Networks and managed identities can't provide it; only the app can.

**13. Who can sign in at all?**
- *Change:* sign in with a different account from your tenant that isn't assigned to the app.
- *Observe:* Entra ID refuses with `AADSTS50105` before the app is reached.
- *Explain:* `appRoleAssignmentRequired: true` on the service principal. To grant access, assign a user, or preferably a group (Enterprise applications → the app → Users and groups, or a `Microsoft.Graph/appRoleAssignedTo` resource in Bicep).

### Step 4b

**17. Two data stores, two owners**
- *Predict:* where is the *title* of a chat stored, and where are its *messages*?
- *Change:* chat in the web app, then look at both: app Cosmos → `chat` → `sessions` (one small document per chat, in *your* schema), and Foundry's Cosmos → `enterprise_memory` → `…-run-state-v1` (the content, in *Foundry's* schema).
- *Observe (2026-11-17, local, two simulated users):* Alice's list showed her 2 chats, newest activity first. Reopening one returned all 4 messages (from Foundry's API). Bob's list was empty, and Bob loading Alice's chat got `404`.
- *Explain:* the app never reads Foundry's containers. It stores **references** (conversation IDs) in its own model and asks Foundry for content. Partitioning by `user_oid` means "list my chats" can't return someone else's, by construction.

### Step 4

**14. Where does my conversation live now?**
- *Predict:* in step 1, conversations lived in "Microsoft-managed storage". Where are they now, and what do they look like?
- *Change:* chat with `uv run chat.py`, copy the conversation ID, then `uv run inspect_cosmos.py <conversation id>`.
- *Observe (2026-11-17):* in container `<project-guid>-run-state-v1`: the conversation (`conv_…`), its item index (`conv2item_…`), and **one document per response** (`resp_…`). Agent definitions are in `<project-guid>-agent-definitions-v1`. The `thread-message-store` / `agent-entity-store` containers stay **empty**; they're for the *classic* agent runtime.
- *Explain:* this is the data-ownership step. Backup, retention, encryption keys, auditing and region are now **your** decisions on **your** resource. The containers' internal format is Foundry's, though: read it, but build on the Foundry APIs.
- *In the portal:* Cosmos account → Data Explorer → `enterprise_memory` (the **only** database) → `<project-guid>-run-state-v1` → **New SQL Query**. Key-based auth is disabled, so switch Data Explorer to Entra ID authentication in its settings.
  ```sql
  -- latest conversations (object.id is the full ID the app shows)
  SELECT TOP 10 c.object.id AS conversation_id, c.info.created_at, c.object.metadata.owner_oid
  FROM c WHERE STARTSWITH(c.id, 'conv_') ORDER BY c.info.created_at DESC

  -- messages of one conversation: the partition ends with the 18 chars after "conv_"
  SELECT c.object.item_resource.role, c.object.item_resource.content FROM c
  WHERE c.partition_id = '<account>@proj-chatbot-std@AML/<18 chars>' AND STARTSWITH(c.id, 'msg_')
  ```
- **Gotcha:** the conversation ID the app shows (`conv_070ba58f600eb0d800h07bt…`) is **not** the Cosmos document id (`conv_h07bt…`). Foundry moves the first 18 characters into the partition key, so all of a conversation's documents share one partition. Searching Data Explorer for the app's ID finds nothing.

**15. What does standard setup cost in latency?**
- *Change:* `uv run evaluate.py 1 --runs 4` here, and the same against the old project (point `FOUNDRY_PROJECT_ENDPOINT` at `…/proj-chatbot`, version 4).
- *Observe (2026-11-17, n=2):* same correctness (10/10) and tokens, but 2.8–4.4 s per call vs 2.1–2.5 s in the basic project.
- *Explain:* every turn now reads and writes *your* serverless Cosmos DB. Check the spans in App Insights before concluding. Provisioned throughput or a closer region are the levers.

**16. Why can't we "switch" the old project to standard?**
- *Explain:* capability hosts are immutable, and a project's storage can't be changed after creation. Moving means a new project, recreating agents from source (that's why `create_agent.py` exists), and accepting that old conversations stay behind. Treat agent definitions as code from day one.

### Step 5

**18. Two locks: is a valid token enough?**
- *Predict:* with public access disabled, does a request with a valid Entra token and the right role still work from your laptop?
- *Change:* `curl -H "Authorization: Bearer $(az account get-access-token --scope https://search.azure.com/.default --query accessToken -o tsv)" "https://<search>.search.windows.net/indexes/policies/docs?api-version=2025-09-01&search=hotel"`
- *Observe (2026-11-17):* `403` from Foundry and Search, `Forbidden` from Cosmos DB, while `/healthz/deps` (from inside App Service) reports all dependencies reachable.
- *Explain:* network and identity are independent layers and a request must pass both. A leaked token no longer works from the internet.

**19. The same hostname, two answers (private DNS)**
- *Predict:* the app still calls `fdy-…services.ai.azure.com`. How does it end up at a private IP?
- *Observe:* `az network private-dns record-set a list -g rg-basic-chatbot -z privatelink.search.windows.net` shows `10.20.1.9`. From your laptop, `nslookup <search>.search.windows.net` shows a CNAME to `…privatelink.search.windows.net` and a **public** IP. `/healthz/deps` reports `private_ip: true` from inside.
- *Explain:* the public name CNAMEs to a `privatelink` name. Inside the VNet a linked private DNS zone answers with the private endpoint's IP, and outside, public DNS answers. No code or connection string changed. DNS mistakes are the #1 private-networking failure.

**20. Inbound vs outbound**
- *Explain:* private endpoints secure **inbound** (who can reach a service). VNet integration (App Service) and network injection (Foundry agent) secure **outbound** (how a component reaches others). The web app's *inbound* is still public; step 6's App Gateway + WAF changes that.

**21. The one hop without a private endpoint**
- *Observe (2026-11-18):* after lockdown, App Insights shows `execute_tool remote_functions.azure_ai_search` succeeding. The tool uses vector search, so Search reached Foundry's embedding model.
- *Explain:* Search Basic can't use a shared private link to Foundry, so Foundry keeps `networkAcls.bypass: AzureServices` (trusted Azure services, authenticated by managed identity + RBAC). Narrower than public, broader than private. Search S1+ with a shared private link would close it.

**22. What's still open: egress**
- *Explain:* `snet-agent` and `snet-appsvc` have default outbound internet access (the agent needs Entra ID, the app needs App Insights). A compromised component could still send data to any internet address. Step 6's Azure Firewall (route table `0.0.0.0/0 → firewall`, FQDN allow-list) closes it.

### Step 6a

**23. Default deny, then allow-list (the firewall experiment)**
- *Predict:* the app tries `https://example.com/` from inside the VNet. What happens before and after adding one rule?
- *Change:* `curl <app>/healthz/egress`, then redeploy with `-p experimentAllowedFqdns='["example.com"]'` (~6 min), then curl again. Redeploy without it to remove the rule.
- *Observe (2026-11-18):* before: `reachable:false, ConnectError` in 291 ms. After: `reachable:true, status 200`. The firewall log (`AZFWApplicationRule`) shows `Deny 10.20.2.62 → example.com "No rule matched. Proceeding with default action"` three times, then `Allow … rule=experiment-allowed-sites`.
- *Explain:* nothing leaves unless a rule names it. A new outbound dependency (a public API, an MCP server for the agent) is a reviewed, versioned rule, scoped by source subnet, protocol and hostname. Every attempt is auditable.

**24. The firewall finds dependencies you didn't know about**
- *Observe (2026-11-18):* the first app deploy through the firewall failed. The build log showed `Could not fetch URL https://pypi.org/simple/pip/: … SSL: UNEXPECTED_EOF`, which is what a firewall reset looks like from the client side. The firewall log also shows a steady `Deny … dc.services.visualstudio.com` (legacy App Insights endpoint) from the App Service platform. Our own telemetry uses `*.in.applicationinsights.azure.com` and is allowed.
- *Also observed:* from the **agent** subnet, the only internet traffic was App Insights (allowed), Entra ID (allowed via the service tag) and 3 denied calls to `il-<tenant-id>.<nn>.tenant.api.powerplatform.com`, a Power Platform tenant API. Its purpose isn't in the Foundry allow-list docs, and chats work with it blocked, so it **stays blocked** (open question). The agent's real work (Search, Cosmos DB, Storage) never touches the firewall: it goes through private endpoints.
- *Explain:* egress control turns implicit dependencies into explicit ones. PyPI is now allowed for the app subnet only. The unexplained calls stay blocked: the default for egress is "deny until you can justify it".

**25. A blocked build took the app down (and nobody noticed)**
- *Observe:* App Service platform metrics: from 09:23 to 13:53 almost every request was 5xx. The failed on-server build left the app unable to start until the next successful deploy.
- *Explain:* zip deploy with an on-server build (`SCM_DO_BUILD_DURING_DEPLOYMENT`) isn't atomic. Fixes: deployment slots + swap (Standard tier or higher), building in CI and shipping a finished package, and a post-deploy health gate. `deploy_app.sh` now restarts the app and requires `/healthz/deps` to return 200.

**26. One public IP for everything that leaves**
- *Observe:* all allowed egress from the agent and app subnets leaves from the firewall's public IP (`az network public-ip show -g rg-basic-chatbot -n pip-fw-<suffix> --query ipAddress`).
- *Explain:* external partners can allow-list a single, stable address. Without the firewall, outbound IPs are shared and change.

### Step 6b

**27. One door in, and it inspects what comes through**
- *Observe (2026-11-19):* via the gateway, a normal request gets `200`; `?q=1' OR '1'='1' --` (SQL injection) **403**; `?q=<script>alert(1)</script>` (XSS) **403**; a `<script>` payload inside the chat **JSON body** **403**. The direct app URL returns **403**, and the gateway reports the backend **Healthy** via the app's private endpoint (`10.20.1.14`).
- *Explain:* the WAF blocks known attack patterns before they reach the app, and before sign-in even runs. Access restrictions ("main site: deny") close the old door, and private-endpoint traffic isn't subject to them, which is how the gateway gets in.

**28. Sign-in behind a reverse proxy**
- *Predict:* the gateway sends `Host: app-….azurewebsites.net` to the app. Where does Entra send the user back after sign-in?
- *Observe:* with `forwardProxy: Custom / X-Original-Host`, the `redirect_uri` sent to Entra is `https://chatbot-….cloudapp.azure.com/.auth/login/aad/callback` (the gateway's name).
- *Explain:* without it, the user would be sent to the app's own URL, which now returns 403. Production fix: a custom domain on both gateway and app, so the host name never changes.

**29. The certificate chicken-and-egg (not in the docs)**
- *Observe:* creating the gateway with Key Vault private-only failed: `ApplicationGatewayKeyVaultSecretAccessDenied`, gateway **Stopped**, although role, private endpoint and DNS were all correct. With the vault temporarily open it was created; afterwards **updates with the vault closed succeeded**.
- *Explain:* a new gateway validates the certificate before its instances run inside the VNet, so it can't use the private endpoint yet. Once running, it can. Also: the failed attempt had already closed the app's direct URL, so **users were locked out** until it was reopened. Hence `closeDirectAppAccess`: open the new door before closing the old one.

**30. NSGs: segmentation inside the network**
- *Explain:* the private endpoint subnet only accepts traffic from the agent, app and gateway subnets (everything else in the VNet is denied), the agent subnet accepts no inbound traffic at all, and agent/app outbound is limited to private endpoints + HTTPS. NSG rules only apply to private endpoints when the subnet's *private endpoint network policies* are enabled (off by default).

## Troubleshooting

- **`tool_user_error` (400) from a grounded agent**: the *project* identity lacks roles on Search (see the RBAC table), or a new role hasn't propagated yet.
- **429 rate limit**: grounded turns use roughly 10× more tokens and several model calls each. Raise `modelCapacity` in the Bicep (it's a cap, not a cost).
- **`ingest.py` hangs after "Index … ready"**: your *Search Index Data Contributor* role hasn't propagated. Ctrl-C, wait a few minutes, retry.
- **`DefaultAzureCredential failed`**: run `az login` and check `az account show`.
- **`Connection appinsights already exist`** during deploy: account-level connections are visible in the project, so project connections need different names.
- **`deploy_app.sh` timing out**: it now uploads asynchronously and polls the deployment log (status 4 = success) plus `/healthz`. `--track-status` used to hang for 10+ minutes after success. If it times out, run `az webapp log deployment show -g rg-basic-chatbot -n <webAppName>`.
- **`AADSTS50105` at sign-in**: the account isn't assigned to the app (experiment 13).
- **`AADSTS70021` / sign-in fails after redirect**: the federated credential's subject must be the auth identity's **principal (object) ID**, and `OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID` must be its **client ID**. Mixing them up is the usual cause.
- **`resource key 'name' must be a string of the form '{parent}/{child}'`** when deploying: Graph extension 1.0.0 needs federated credentials as a top-level resource named `'{app uniqueName}/{name}'`.
- **"Your sign-in has expired" in the UI**: App Service redirected an API call to Entra. Reload the page.
- **`Connection <name> already exist, and can only be updated by the workspace that created it`**: connection names are unique across the whole Foundry **account**, not per project. Give the new project's connections different names (`search-std`, …).
- **`Foundry Account capabilityHost Not Found`**: a project capability host needs an account-level one first (`capabilityHostKind: Agents`, no connections).
- **`There is an existing Capability Host with name: <account>@aml_aiagentservice`**: a network-injected Foundry resource creates its own account capability host (with `customerSubnet`). Don't declare another one.
- **`Resource name is invalid … alphanumeric characters, dashes, and underscores`** on the account capability host: the platform's name contains `@`, so you can't PUT it yourself. Leave it to the platform.
- **`Account … in state Accepted`**: connecting the Foundry private endpoint updates the account and collides with other account writes. Create the Foundry private endpoint last (`dependsOn`).
- **The app's outbound traffic isn't routed through the VNet**: `siteConfig.vnetRouteAllEnabled` is silently ignored by `Microsoft.Web/sites@2024-11-01`. Use `properties.outboundVnetRouting.applicationTraffic: true` and check the deployed value.
- **New app code deployed but the old code still answers**: the zip deploy succeeded, but the process wasn't restarted. Run `az webapp restart` and verify a new route.
- **App Insights query returns nothing for older data**: `az monitor app-insights query` searches only the **last hour** unless you pass `--offset` (e.g. `--offset 2d`), whatever the query's `ago()` says.
- **Gateway fails with `ApplicationGatewayKeyVaultSecretAccessDenied` and is Stopped**: on FIRST creation the vault must be reachable: redeploy with `allowKeyVaultSetup=true closeDirectAppAccess=false`, then again with the defaults.
- **Users get 403 everywhere**: the app's direct URL is closed but the gateway isn't working. Reopen it: `az resource update -g rg-basic-chatbot -n <webAppName> --resource-type Microsoft.Web/sites --set properties.siteConfig.ipSecurityRestrictionsDefaultAction=Allow`.
- **Sign-in sends you to `azurewebsites.net` (403) after login**: `forwardProxy` isn't set to `Custom` + `X-Original-Host`, or the gateway callback URL is missing from the app registration.
- **Browser warning on the gateway URL**: expected, because the certificate is self-signed. Use a custom domain + CA certificate for real users.
- **App build fails with `SSL: UNEXPECTED_EOF_WHILE_READING` / `Could not fetch URL https://pypi.org…`**: the firewall blocks PyPI. Allow `pypi.org` + `files.pythonhosted.org` for `snet-appsvc` (done in Bicep), or build in CI.
- **App returns 5xx after a failed deploy**: the on-server build broke the running app. Fix the cause and redeploy. `deploy_app.sh` now fails loudly if `/healthz/deps` isn't 200 after the deploy.
- **New route returns 404 after a successful deploy**: the old process kept running (seen twice). `deploy_app.sh` now restarts the app after every deployment.
- **Firewall log tables (`AZFWApplicationRule`, `AZFWNetworkRule`) are empty**: the first rows take 10–20 minutes after enabling diagnostics. Use the firewall metrics (`ApplicationRuleHit`, `NetworkRuleHit`, split by `Status`) for near-real-time numbers.
- **Redeploying silently reopened public access**: only possible before `lockDown` defaulted to `true`. Check with `az search service show … --query publicNetworkAccess`.
- **`/healthz/deps` shows `private_ip: false` from App Service**: the private DNS zone isn't linked to the VNet, or outbound routing isn't on.
- **Capability host provisioning fails**: roles must be in place *before* it's created (Cosmos DB Operator, Storage Blob Data Contributor/Owner, Search roles on the project identity). The Cosmos *data* role can only be granted *after* (it's scoped to `enterprise_memory`, which provisioning creates).
- **Web app returns 502 "assistant is unavailable"**: check App Insights → Failures, or `az webapp log tail`. A common cause after a fresh deploy is the web app's Foundry User role not having propagated yet.

## Cleanup

Stop the firewall's hourly cost. **Order matters**, and **`deployFirewall=false` alone does NOT delete
the firewall**: deployments are incremental, so undeclared resources are left in place (and keep billing).

```bash
# 1. Empty the route table first, so the subnets stop sending traffic to the firewall (egress goes direct).
az deployment group create -g rg-basic-chatbot -f infra/main.bicep \
  -p userPrincipalId=$(az ad signed-in-user show --query id -o tsv) deployFirewall=false
# 2. Then delete the firewall and its public IPs (the free firewall policy stays and is reused).
az network firewall delete -g rg-basic-chatbot -n afw-chatbot-<suffix>
az network public-ip delete -g rg-basic-chatbot -n pip-fw-<suffix>
az network public-ip delete -g rg-basic-chatbot -n pip-fw-mgmt-<suffix>
# Bring it back later: redeploy with the default deployFirewall=true (~10 min).
```

Stop the Application Gateway (~$0.45/h). Same pattern: reopen the app first, then delete:

```bash
az deployment group create -g rg-basic-chatbot -f infra/main.bicep \
  -p userPrincipalId=$(az ad signed-in-user show --query id -o tsv) deployFirewall=false deployAppGateway=false
az network application-gateway delete -g rg-basic-chatbot -n agw-chatbot-<suffix>
az network public-ip delete -g rg-basic-chatbot -n pip-agw-<suffix>
# Bring it back: allowKeyVaultSetup=true closeDirectAppAccess=false (first creation), then the defaults.
```

While the firewall is off, **egress from the agent and app subnets is unrestricted**.

Stop the other hourly costs but keep Foundry (your agents and conversations):

```bash
az search service delete -g rg-basic-chatbot -n <searchServiceName> --yes
az appservice plan delete -g rg-basic-chatbot -n <appServicePlanName> --yes   # also deletes the web app
# Later: re-run the Bicep deployment, `uv run ingest.py`, and `./deploy_app.sh`.
```

Remove everything:

```bash
# A Foundry resource with projects can't be deleted directly ("nested resources exist"). Order:
#   project capability host → projects → account (its capability host goes with it) → purge.
# Delete AND purge a network-injected Foundry resource BEFORE deleting the VNet, or the agent
# subnet stays locked by a service association link.
az group delete -n rg-basic-chatbot --yes
az cognitiveservices account purge -g rg-basic-chatbot -l swedencentral -n <foundryAccountName>
# The Entra app registration lives in the tenant, not the resource group. Delete it separately:
az ad app delete --id $(az ad app list --filter "startswith(displayName,'Contoso Policy Chat')" --query "[0].appId" -o tsv)
```

## Notes / learnings

- See [STACK.md → What the demo showed](STACK.md#what-the-demo-showed).
