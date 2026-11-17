"""Terminal chat with the Foundry prompt agent. It stands in for the App Service chat UI.

This is hop 2 in the architecture diagram, without the network path: your `az login`
identity calls the Foundry project endpoint and references the agent by name and pinned
version. Foundry then runs hops 3, 6 and 7 server-side: it loads the agent definition, calls
the model, and stores the turn in the conversation.

Commands at the prompt:  /new  start a fresh conversation   /exit  quit
"""

import argparse
import asyncio
import json
import os

from agent_framework.foundry import FoundryAgent
from agent_framework.observability import configure_otel_providers
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

# Stops a runaway session: each turn is exactly one agent run, i.e. one paid model call.
MAX_TURNS = 20


def describe(result, session) -> str:
    """One line showing what came back across the service boundary."""
    usage = result.usage_details or {}
    return (
        f"   [conversation={session.service_session_id} response={result.response_id} "
        f"tokens in/out={usage.get('input_token_count')}/{usage.get('output_token_count')}]"
    )


def retrieval_trace(result) -> list[str]:
    """Show hop 4: did the agent search, with what query, and which chunks did it cite?

    The model *chooses* whether to call the search tool, so a missing [search] line is
    meaningful: the answer was produced without retrieval.
    """
    # AgentResponse -> ChatResponse -> the raw OpenAI Responses object with all output items
    openai_response = getattr(result.raw_representation, "raw_representation", None)
    lines = []
    for item in getattr(openai_response, "output", None) or []:
        if item.type == "azure_ai_search_call":
            try:
                query = json.loads(item.arguments or "{}").get("query", item.arguments)
            except json.JSONDecodeError:
                query = item.arguments
            lines.append(f"   [search] {query!r}")
    if not lines:
        lines.append("   [no search]")

    titles = []
    for message in result.messages:
        for content in message.contents:
            for annotation in getattr(content, "annotations", None) or []:
                title = annotation.get("title") if isinstance(annotation, dict) else getattr(annotation, "title", None)
                if title and title not in titles:
                    titles.append(title)
    lines += [f"   [cited] {t}" for t in titles]
    return lines


async def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--conversation", help="Resume an existing Foundry conversation ID.")
    parser.add_argument("--version", help="Override FOUNDRY_AGENT_VERSION for this run.")
    parser.add_argument(
        "--trace",
        action="store_true",
        help="Print OpenTelemetry spans to the console (set ENABLE_SENSITIVE_DATA=true to include message text).",
    )
    args = parser.parse_args()

    if args.trace:
        configure_otel_providers(enable_console_exporters=True)

    agent_name = os.environ["FOUNDRY_AGENT_NAME"]
    agent_version = args.version or os.environ["FOUNDRY_AGENT_VERSION"]

    # The client sends only a reference (name + version). Model, instructions and tools
    # all come from the definition stored in Foundry, so the client can't override them.
    agent = FoundryAgent(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        agent_name=agent_name,
        agent_version=agent_version,
        credential=DefaultAzureCredential(),
    )

    # create_conversation() makes a server-side Foundry conversation (hop 7). History lives
    # there, not in this process, which is why --conversation can resume it after a restart.
    if args.conversation:
        session = agent.get_session(args.conversation)
    else:
        session = await agent.create_conversation()

    print(f"Agent {agent_name} v{agent_version} | conversation {session.service_session_id}")
    print("Type a message, /new for a fresh conversation, /exit to quit.\n")

    for _ in range(MAX_TURNS):
        try:
            text = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not text:
            continue
        if text == "/exit":
            break
        if text == "/new":
            session = await agent.create_conversation()
            print(f"   [new conversation={session.service_session_id}]")
            continue

        result = await agent.run(text, session=session)
        print(f"agent> {result.text}")
        print("\n".join(retrieval_trace(result)))
        print(describe(result, session))
    else:
        print(f"Reached MAX_TURNS={MAX_TURNS}; exiting.")


if __name__ == "__main__":
    asyncio.run(main())
