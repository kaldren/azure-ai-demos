"""The app's own record of "which conversations does this user have" (step 4b).

Division of responsibility:
- Foundry stores the conversation CONTENT (messages, tool calls) in its own format.
- This store keeps a small index per user: conversation ID, title, timestamps. It's what a
  "My previous chats" list needs, and it's in a schema we design and control.

Container `sessions` is partitioned by `user_oid`, so listing a user's chats is a single-partition
query that can never return another user's documents.
"""

import logging
from datetime import UTC, datetime

from azure.cosmos import exceptions
from azure.cosmos.aio import ContainerProxy

log = logging.getLogger("chatbot")
TITLE_CHARS = 60
LIST_LIMIT = 50


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


class SessionStore:
    def __init__(self, container: ContainerProxy):
        self.container = container

    async def record_turn(self, user_oid: str, conversation_id: str, first_message: str) -> None:
        """Create the session on its first turn, or bump updated_at on later turns.

        Best effort: the chat already succeeded, so a failure here is logged, not raised.
        """
        try:
            await self.container.patch_item(
                item=conversation_id,
                partition_key=user_oid,
                patch_operations=[{"op": "set", "path": "/updated_at", "value": _now()}],
            )
        except exceptions.CosmosResourceNotFoundError:
            title = " ".join(first_message.split())
            title = title if len(title) <= TITLE_CHARS else title[: TITLE_CHARS - 1] + "…"
            try:
                now = _now()
                await self.container.create_item(
                    {"id": conversation_id, "user_oid": user_oid, "title": title, "created_at": now, "updated_at": now}
                )
            except Exception:
                log.warning("Could not create session record for %s", conversation_id, exc_info=True)
        except Exception:
            log.warning("Could not update session record for %s", conversation_id, exc_info=True)

    async def list(self, user_oid: str) -> list[dict]:
        query = "SELECT c.id, c.title, c.updated_at FROM c ORDER BY c.updated_at DESC OFFSET 0 LIMIT @n"
        items = self.container.query_items(query, parameters=[{"name": "@n", "value": LIST_LIMIT}], partition_key=user_oid)
        return [{"conversation_id": i["id"], "title": i["title"], "updated_at": i["updated_at"]} async for i in items]
