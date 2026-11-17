"""Chat web app: the "App Service" box in the diagram (steps 3 and 3b).

  browser ──(Entra sign-in by App Service)──▶ this app ──Responses API (managed identity)──▶ Foundry agent

Three identities are involved, and keeping them apart is the point of this file:
- **The end user** is signed in by App Service built-in authentication before the request reaches
  this code. App Service passes who they are in X-MS-CLIENT-PRINCIPAL-* headers. External
  clients can't set those headers, so the app can trust them.
- **The app** calls Foundry as its system-assigned managed identity. The user's identity is never
  forwarded to Foundry; the app decides what the user may do.
- **Authorization is ours**: a conversation is stamped with its owner's object ID (Foundry
  conversation metadata) and may only be resumed by that owner.

State: the server is stateless. The browser holds the current conversation ID, Foundry holds the
history, and the app's own Cosmos DB holds each user's list of conversations (step 4b, sessions.py).
Telemetry: OpenTelemetry → Application Insights, tagged with the user's object ID (enduser.id).
"""

import json
import logging
import os
import re
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path

# Configure telemetry before importing libraries that create HTTP clients, so they get instrumented.
if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor(logger_name="chatbot")

from agent_framework.foundry import FoundryAgent
from azure.ai.projects.aio import AIProjectClient
from azure.cosmos.aio import CosmosClient
from azure.identity.aio import AzureCliCredential, ManagedIdentityCredential
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from openai import BadRequestError, NotFoundError
from opentelemetry import trace
from pydantic import BaseModel, Field

from sessions import SessionStore

log = logging.getLogger("chatbot")
log.setLevel(logging.INFO)

RUNNING_IN_APP_SERVICE = bool(os.getenv("WEBSITE_SITE_NAME"))
# Foundry conversation IDs look like "conv_<alphanumerics>". Anything else is rejected before it
# reaches Foundry.
CONVERSATION_ID = re.compile(r"^conv_[A-Za-z0-9]{10,100}$")
MAX_MESSAGE_CHARS = 2000
OWNER_KEY = "owner_oid"  # conversation metadata key holding the owner's Entra object ID


# ---------------------------------------------------------------------------------------------
# Who is calling? (end-user identity, from App Service authentication)
# ---------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class User:
    oid: str  # Entra object ID: stable and unique. Use this for authorization, never the name.
    name: str  # display/UPN, for the UI and logs only


def current_user(request: Request) -> User:
    if RUNNING_IN_APP_SERVICE:
        oid = request.headers.get("x-ms-client-principal-id")
        if not oid:
            # Defense in depth: if built-in auth were ever switched off, fail closed instead of
            # serving anonymous users.
            raise HTTPException(status_code=401, detail="Not signed in")
        user = User(oid=oid, name=request.headers.get("x-ms-client-principal-name", oid))
    else:
        # Local development has no App Service in front, so there are no identity headers.
        user = User(oid=os.getenv("LOCAL_DEV_USER_OID", "local-dev"), name="local developer")
    # Tag the request's telemetry with the user (App Insights shows it as the authenticated user).
    trace.get_current_span().set_attribute("enduser.id", user.oid)
    return user


# ---------------------------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------------------------


def make_credential():
    # Explicit rather than DefaultAzureCredential: in Azure we want the managed identity and
    # nothing else (no accidental fallback to some other credential on the box).
    if RUNNING_IN_APP_SERVICE:
        return ManagedIdentityCredential()  # the *system-assigned* identity (no client ID given)
    return AzureCliCredential()  # local development: your `az login`


@asynccontextmanager
async def lifespan(app: FastAPI):
    credential = make_credential()
    # One project client per process, shared by the agent (runs) and by our conversation
    # management (create with owner metadata, look up owner on resume).
    project = AIProjectClient(endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"], credential=credential)
    app.state.openai = project.get_openai_client()
    app.state.agent = FoundryAgent(
        project_client=project,
        agent_name=os.environ["FOUNDRY_AGENT_NAME"],
        agent_version=os.environ["FOUNDRY_AGENT_VERSION"],
        timeout=120.0,
    )
    # The app's own data store (same managed identity, different Cosmos account from Foundry's).
    cosmos = CosmosClient(os.environ["APP_COSMOS_ENDPOINT"], credential=credential)
    container = cosmos.get_database_client(os.getenv("APP_COSMOS_DATABASE", "chat")).get_container_client("sessions")
    app.state.sessions = SessionStore(container)
    yield
    await cosmos.close()
    await project.close()
    await credential.close()


app = FastAPI(title="Contoso policy chatbot", lifespan=lifespan)


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=MAX_MESSAGE_CHARS)
    conversation_id: str | None = None


class ChatResponse(BaseModel):
    answer: str
    conversation_id: str
    agent: str
    searches: list[str]
    citations: list[str]
    input_tokens: int | None
    output_tokens: int | None


def retrieval_trace(result) -> tuple[list[str], list[str]]:
    """Return (search queries the model issued, titles of the chunks it cited). Same logic as chat.py."""
    openai_response = getattr(result.raw_representation, "raw_representation", None)
    searches = []
    for item in getattr(openai_response, "output", None) or []:
        if item.type == "azure_ai_search_call":
            try:
                searches.append(json.loads(item.arguments or "{}").get("query", item.arguments))
            except json.JSONDecodeError:
                searches.append(item.arguments)
    citations: list[str] = []
    for message in result.messages:
        for content in message.contents:
            for annotation in getattr(content, "annotations", None) or []:
                title = annotation.get("title") if isinstance(annotation, dict) else getattr(annotation, "title", None)
                if title and title not in citations:
                    citations.append(title)
    return searches, citations


async def open_conversation(conversation_id: str | None, user: User) -> str:
    """Create a conversation owned by `user`, or return `conversation_id` if `user` owns it.

    Not-found and not-yours both return 404, so a caller can't probe which IDs exist.
    """
    openai = app.state.openai
    if not conversation_id:
        conversation = await openai.conversations.create(metadata={OWNER_KEY: user.oid})
        return conversation.id

    if not CONVERSATION_ID.match(conversation_id):
        raise HTTPException(status_code=400, detail="Invalid conversation_id")
    try:
        conversation = await openai.conversations.retrieve(conversation_id)
    except (NotFoundError, BadRequestError):
        # Foundry answers 400 "Malformed identifier" for IDs that pass our regex but aren't real IDs.
        raise HTTPException(status_code=404, detail="Conversation not found")
    if (conversation.metadata or {}).get(OWNER_KEY) != user.oid:
        log.warning("Denied conversation %s to user %s (not owner)", conversation_id, user.oid)
        raise HTTPException(status_code=404, detail="Conversation not found")
    return conversation.id


# ---------------------------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------------------------


@app.post("/api/chat", response_model=ChatResponse)
async def chat(request: ChatRequest, user: User = Depends(current_user)) -> ChatResponse:
    agent: FoundryAgent = app.state.agent
    try:
        conversation_id = await open_conversation(request.conversation_id, user)
        result = await agent.run(request.message, session=agent.get_session(conversation_id))
    except HTTPException:
        raise
    except Exception:
        # Every Foundry call is inside this block, including conversation creation and lookup.
        # Details go to the logs (App Insights); the client gets a generic message.
        log.exception("Chat turn failed (user=%s conversation=%s)", user.oid, request.conversation_id)
        raise HTTPException(status_code=502, detail="The assistant is unavailable. Try again shortly.")

    await app.state.sessions.record_turn(user.oid, conversation_id, request.message)
    searches, citations = retrieval_trace(result)
    usage = result.usage_details or {}
    log.info(
        "chat turn user=%s conversation=%s searches=%d citations=%d in_tokens=%s",
        user.oid, conversation_id, len(searches), len(citations), usage.get("input_token_count"),
    )
    return ChatResponse(
        answer=result.text,
        conversation_id=conversation_id,
        agent=f"{os.environ['FOUNDRY_AGENT_NAME']} v{os.environ['FOUNDRY_AGENT_VERSION']}",
        searches=searches,
        citations=citations,
        input_tokens=usage.get("input_token_count"),
        output_tokens=usage.get("output_token_count"),
    )


@app.get("/api/sessions")
async def list_sessions(user: User = Depends(current_user)) -> list[dict]:
    """The signed-in user's conversations, newest first (from the app's own Cosmos DB)."""
    return await app.state.sessions.list(user.oid)


@app.get("/api/sessions/{conversation_id}/messages")
async def session_messages(conversation_id: str, user: User = Depends(current_user)) -> list[dict]:
    """Reload a conversation's messages through Foundry's API (not by reading Foundry's Cosmos).

    The same ownership check as resuming: only the owner gets the messages.
    """
    try:
        await open_conversation(conversation_id, user)  # raises 400/404 unless the user owns it
        items = app.state.openai.conversations.items.list(conversation_id, order="asc", limit=100)
        messages = []
        async for item in items:
            if item.type == "message" and item.role in ("user", "assistant"):
                text = " ".join(getattr(part, "text", "") or "" for part in item.content)
                messages.append({"role": item.role, "text": text})
        return messages
    except HTTPException:
        raise
    except Exception:
        log.exception("Loading messages failed (user=%s conversation=%s)", user.oid, conversation_id)
        raise HTTPException(status_code=502, detail="Couldn't load that conversation. Try again shortly.")


@app.get("/api/me")
async def me(user: User = Depends(current_user)) -> dict:
    return {"name": user.name}


@app.get("/healthz")
async def healthz() -> dict:
    return {"status": "ok"}  # excluded from sign-in in the Bicep (globalValidation.excludedPaths)


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(Path(__file__).parent / "static" / "index.html")
