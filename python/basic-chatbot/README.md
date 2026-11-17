# Basic chatbot (steps 1–4 of the baseline Foundry chat architecture)

**What it shows:** the core of the [baseline Microsoft Foundry chat architecture](https://learn.microsoft.com/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-chat)
([diagram](chatbot-architecture.jpg)), built one step at a time.
- **Step 1:** a terminal client calls a **prompt agent** in **Foundry Agent Service** by name and pinned version. The agent calls a model, and Foundry stores the conversation server-side.
- **Step 2:** the agent gets an **Azure AI Search tool** over an index of (fictional) Contoso policies, so it can answer with citations. Retrieval is forced (`tool_choice=required`) after measuring that the model sometimes skipped it.
- **Step 3:** a **web chat UI on App Service** calls the agent with its **managed identity**, and both the app and Foundry send traces to **Application Insights**.
- **Step 3b:** **Entra ID sign-in** (App Service built-in authentication, no client secret: a federated credential on a user-assigned managed identity). Only assigned users can sign in, and each conversation can only be resumed by the user who started it.
- **Step 4:** **standard agent setup**. A new project (`proj-chatbot-std`) stores agent definitions and conversations in **our own Cosmos DB**, files in **our own Storage account**, and vector stores in our AI Search service. The old basic project (`proj-chatbot`, agents v1–v4) is kept for comparison.
- **Step 4b:** **"Your chats" sidebar**. The app keeps its *own* index of each user's conversations (title, timestamps) in a **separate** serverless Cosmos account, partitioned by user. Reopening a chat loads its messages through Foundry's API.

Why it's built this way, and what we observed: [STACK.md](STACK.md).

> Status: steps 1–4 deployed and verified on 2026-11-15/17 (resource group `rg-basic-chatbot`, Sweden Central).
> Web app: `https://app-chatbot-5gq6mtdeqpdcw.azurewebsites.net`. **Entra sign-in is required, and only assigned users get in.**
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

## Deploy

```bash
az login
az group create -n rg-basic-chatbot -l swedencentral
az deployment group create -g rg-basic-chatbot -f infra/main.bicep \
  -p userPrincipalId=$(az ad signed-in-user show --query id -o tsv) \
  --query properties.outputs
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
- **Capability host provisioning fails**: roles must be in place *before* it's created (Cosmos DB Operator, Storage Blob Data Contributor/Owner, Search roles on the project identity). The Cosmos *data* role can only be granted *after* (it's scoped to `enterprise_memory`, which provisioning creates).
- **Web app returns 502 "assistant is unavailable"**: check App Insights → Failures, or `az webapp log tail`. A common cause after a fresh deploy is the web app's Foundry User role not having propagated yet.

## Cleanup

Stop the hourly cost but keep Foundry (your agents and conversations):

```bash
az search service delete -g rg-basic-chatbot -n <searchServiceName> --yes
az appservice plan delete -g rg-basic-chatbot -n <appServicePlanName> --yes   # also deletes the web app
# Later: re-run the Bicep deployment, `uv run ingest.py`, and `./deploy_app.sh`.
```

Remove everything:

```bash
az group delete -n rg-basic-chatbot --yes
az cognitiveservices account purge -g rg-basic-chatbot -l swedencentral -n <foundryAccountName>
# The Entra app registration lives in the tenant, not the resource group. Delete it separately:
az ad app delete --id $(az ad app list --filter "startswith(displayName,'Contoso Policy Chat')" --query "[0].appId" -o tsv)
```

## Notes / learnings

- See [STACK.md → What the demo showed](STACK.md#what-the-demo-showed).
