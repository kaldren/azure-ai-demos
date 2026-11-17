"""Create a new version of the prompt agent in Foundry Agent Service (management plane).

This is kept separate from chat.py on purpose. In the reference architecture, agent
definitions are created and versioned by CI/CD or IaC. The chat app only *connects* to a
pinned version and never redefines the agent.

Each run creates a new immutable version. Earlier versions stay callable, which is what
lets chat.py pin one, or compare one version against another (README experiments).

  uv run create_agent.py                     # step 1: no knowledge, says "I don't know"
  uv run create_agent.py --grounded          # step 2: + Azure AI Search tool over the policy index
  uv run create_agent.py --grounded --query-type simple   # same, keyword-only retrieval
"""

import argparse
import os

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    AISearchIndexResource,
    AzureAISearchQueryType,
    AzureAISearchTool,
    AzureAISearchToolResource,
    PromptAgentDefinition,
)
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

# Step 1 has no knowledge source. These instructions tell the agent to say so rather than
# invent company policy.
UNGROUNDED_INSTRUCTIONS = """\
You are an internal assistant for Contoso employees.
Answer general questions concisely.
You do not yet have access to Contoso's internal documents. If a question depends on
Contoso-specific policy or data, say that you don't have that information. Don't guess.
"""

# Step 2: the model decides when to call the search tool. The instructions are what push it to
# search for policy questions, cite, and refuse when the index has nothing relevant.
GROUNDED_INSTRUCTIONS = """\
You are an internal assistant for Contoso employees.
For any question about Contoso policies, rules, limits or procedures, always search the
policy index first and answer only from what it returns. Cite the source of every fact.
If the search results don't contain the answer, say you couldn't find it in Contoso's
policies. Don't fill gaps from general knowledge.
Answer general, non-Contoso questions concisely without searching.
"""


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--grounded", action="store_true", help="Attach the Azure AI Search tool (step 2).")
    parser.add_argument(
        "--query-type",
        choices=[q.value for q in AzureAISearchQueryType],
        default=AzureAISearchQueryType.VECTOR_SEMANTIC_HYBRID.value,
        help="How the tool queries the index (default: vector_semantic_hybrid).",
    )
    parser.add_argument("--top-k", type=int, default=5, help="Chunks the tool returns to the model.")
    parser.add_argument(
        "--tool-choice",
        choices=["auto", "required"],
        default="auto",
        help="auto: the model decides whether to search. required: it must call a tool every turn.",
    )
    parser.add_argument("--instructions", help="Override the system instructions for this version.")
    args = parser.parse_args()

    endpoint = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
    agent_name = os.environ["FOUNDRY_AGENT_NAME"]
    model = os.environ["FOUNDRY_MODEL_DEPLOYMENT"]

    with (
        DefaultAzureCredential() as credential,
        AIProjectClient(endpoint=endpoint, credential=credential) as project,
    ):
        tools = []
        if args.grounded:
            # The agent stores only the connection ID and index name. The endpoint and the auth
            # method (managed identity) live on the project connection created in Bicep.
            connection = project.connections.get(os.environ["SEARCH_CONNECTION_NAME"])
            tools.append(
                AzureAISearchTool(
                    azure_ai_search=AzureAISearchToolResource(
                        indexes=[
                            AISearchIndexResource(
                                project_connection_id=connection.id,
                                index_name=os.environ["SEARCH_INDEX_NAME"],
                                query_type=AzureAISearchQueryType(args.query_type),
                                top_k=args.top_k,
                            )
                        ]
                    )
                )
            )

        default_instructions = GROUNDED_INSTRUCTIONS if args.grounded else UNGROUNDED_INSTRUCTIONS
        # A prompt agent is purely declarative: model + instructions + tools. Foundry stores it,
        # and the Agent Service runtime executes it on each request.
        agent = project.agents.create_version(
            agent_name=agent_name,
            definition=PromptAgentDefinition(
                model=model,
                instructions=args.instructions or default_instructions,
                tools=tools or None,
                # Stored on the agent, because FoundryAgent clients can't override tool_choice per call.
                tool_choice=args.tool_choice if tools else None,
            ),
        )

    kind = (
        f"grounded, AI Search {args.query_type}, top_k={args.top_k}, tool_choice={args.tool_choice}"
        if args.grounded
        else "ungrounded"
    )
    print(f"Created agent '{agent.name}' version {agent.version} ({kind}, model: {model})")
    print(f"Pin chat.py to it with: FOUNDRY_AGENT_VERSION={agent.version}")


if __name__ == "__main__":
    main()
