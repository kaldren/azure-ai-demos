"""Look inside the Cosmos DB that Foundry uses for agent state (step 4, standard setup).

In the basic setup this data lived in Microsoft-managed storage you couldn't see. Now it's in
your subscription: the 'enterprise_memory' database, which Foundry created when the capability
host was provisioned. This script is read-only (your user has the Cosmos Data Reader role).

  uv run inspect_cosmos.py                     # containers and document counts
  uv run inspect_cosmos.py conv_abc123...      # one conversation as a transcript, from Cosmos

Where to look: there is ONE database, 'enterprise_memory' (Foundry created it). Conversations live
in its container '<project-guid>-run-state-v1'. The other containers hold agent definitions or
belong to the classic runtime (empty).

GOTCHA: the conversation ID your app sees is NOT the Cosmos document id. Foundry moves the first
18 characters after 'conv_' into the partition key:
  app sees        conv_070ba58f600eb0d800h07btHx0UhIDyWwNHgiyLio2iuqNSE2k
  Cosmos doc id   conv_h07btHx0UhIDyWwNHgiyLio2iuqNSE2k
  partition key   <account>@<project>@AML/070ba58f600eb0d800
So searching Data Explorer for the app's ID finds nothing. Query by partition key instead, or
SELECT c.object.id (the full ID) from the conv_ documents.

How a conversation is stored (observed 2026-11-17, container <project-guid>-run-state-v1):
  partition key   = "<account>@<project>@AML/<first 18 chars after 'conv_'>"
  conv_…          the conversation (with its metadata, e.g. owner_oid from the web app)
  msg_…           each user message and each assistant answer (role + content)
  fc_… / fco_…    each search tool call / its results (the retrieved chunks)
  resp_…          each Responses API call: agent version, instructions, model, item references
  conv2item_…, item2conv_…   index documents linking items to the conversation

That layout is Foundry's internal format. Read it to learn, never build on it; use the APIs instead.
"""

import os
import sys
from urllib.parse import urlparse

from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

DATABASE = "enterprise_memory"


def run_state_container(database):
    return next(database.get_container_client(c["id"]) for c in database.list_containers() if c["id"].endswith("run-state-v1"))


def print_overview(database) -> None:
    for props in database.list_containers():
        container = database.get_container_client(props["id"])
        count = next(iter(container.query_items("SELECT VALUE COUNT(1) FROM c", enable_cross_partition_query=True)))
        print(f"{props['id']:<60} {count:>6} documents")


def print_transcript(database, conversation_id: str) -> None:
    # The project ID Foundry uses inside Cosmos: "<account>@<project>@AML".
    endpoint = urlparse(os.environ["FOUNDRY_PROJECT_ENDPOINT"])
    account, project = endpoint.hostname.split(".")[0], endpoint.path.rstrip("/").split("/")[-1]
    partition = f"{account}@{project}@AML/{conversation_id.removeprefix('conv_')[:18]}"

    docs = sorted(
        run_state_container(database).query_items("SELECT * FROM c", partition_key=partition),
        key=lambda d: (d["info"]["created_at"], d["id"]),
    )
    if not docs:
        print(f"No documents in partition {partition}. Wrong project, or not a conversation from this project?")
        return
    print(f"{len(docs)} documents in partition {partition}\n")
    for doc in docs:
        kind = doc["id"].split("_")[0]
        obj = doc["object"]
        item = obj.get("item_resource", {})
        if kind == "conv":
            print(f"conversation  metadata={obj.get('metadata') or doc.get('metadata')}")
        elif kind == "msg":
            text = " ".join(p.get("text", "") for p in item.get("content", []) if isinstance(p, dict))
            print(f"  {item.get('role', '?'):<9} │ {' '.join(text.split())[:150]}")
        elif kind == "fc":
            print(f"  {'search':<9} │ query: {item.get('arguments', '')[:140]}")
        elif kind == "fco":
            print(f"  {'results':<9} │ {len(str(item.get('output', '')))} chars of retrieved chunks")
        elif kind == "resp":
            agent = obj.get("agent", {})
            print(f"  {'response':<9} │ agent {agent.get('name')} v{agent.get('version')}, model {obj.get('model')}, status {obj.get('status')}")


def main() -> None:
    load_dotenv()
    account = os.environ["COSMOS_ACCOUNT_NAME"]
    client = CosmosClient(f"https://{account}.documents.azure.com:443/", credential=DefaultAzureCredential())
    database = client.get_database_client(DATABASE)
    if len(sys.argv) > 1:
        print_transcript(database, sys.argv[1])
    else:
        print_overview(database)


if __name__ == "__main__":
    main()
