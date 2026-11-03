"""Tools the agent may call.

Guardrails applied here (not just in the prompt):
* An explicit allow-list of tools. Unknown tool names are rejected.
* Inputs are validated and length-limited before any side effect.
* ``create_support_ticket`` can only INSERT a new item (DynamoDB PutItem with a
  not-exists condition). The IAM task role allows dynamodb:PutItem on one
  table and nothing else, so even a prompt-injected model cannot read, update
  or delete customer data.
"""

from __future__ import annotations

import logging
import re
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

from app.config import Settings

log = logging.getLogger(__name__)

KNOWLEDGE_DIR = Path(__file__).parent / "knowledge"
_WORD = re.compile(r"[a-z0-9]+")
ALLOWED_PRIORITIES = {"low", "medium", "high"}


class ToolInputError(ValueError):
    pass


# ---------------------------------------------------------------- knowledge base
class KnowledgeBase:
    def __init__(self, directory: Path = KNOWLEDGE_DIR) -> None:
        self._docs: dict[str, str] = {}
        for path in sorted(directory.glob("*.md")):
            self._docs[path.stem] = path.read_text(encoding="utf-8")

    def search(self, query: str, top_k: int = 2) -> list[dict[str, str]]:
        terms = set(_WORD.findall(query.lower()))
        if not terms:
            return []
        scored = []
        for name, text in self._docs.items():
            words = _WORD.findall(text.lower())
            score = sum(words.count(t) for t in terms)
            if score:
                scored.append((score, name, text))
        scored.sort(reverse=True)
        return [{"article": name, "content": text[:2000]} for _, name, text in scored[:top_k]]


# ---------------------------------------------------------------- ticket stores
class MemoryTicketStore:
    def __init__(self) -> None:
        self.items: list[dict[str, Any]] = []

    def put(self, item: dict[str, Any]) -> None:
        self.items.append(item)


class DynamoTicketStore:
    def __init__(self, table_name: str, region: str, client=None) -> None:
        if client is None:
            import boto3

            client = boto3.client("dynamodb", region_name=region)
        self._client = client
        self._table = table_name

    def put(self, item: dict[str, Any]) -> None:
        self._client.put_item(
            TableName=self._table,
            Item={k: {"S": str(v)} for k, v in item.items()},
            ConditionExpression="attribute_not_exists(ticket_id)",
        )


def build_ticket_store(settings: Settings):
    if settings.tickets_backend == "dynamodb":
        return DynamoTicketStore(settings.tickets_table_name, settings.aws_region)
    return MemoryTicketStore()


# ---------------------------------------------------------------- tool registry
TOOL_SCHEMAS: list[dict[str, Any]] = [
    {
        "name": "search_knowledge_base",
        "description": "Search the product help-center articles. Use this before answering any product question.",
        "input_schema": {
            "type": "object",
            "properties": {"query": {"type": "string", "description": "Search terms, max 200 chars"}},
            "required": ["query"],
        },
    },
    {
        "name": "create_support_ticket",
        "description": (
            "Open a support ticket for a human agent. Use only when the knowledge base cannot resolve "
            "the issue or the customer explicitly asks for a human."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "summary": {"type": "string", "description": "One-line summary, max 200 chars"},
                "details": {"type": "string", "description": "Relevant details, max 2000 chars"},
                "priority": {"type": "string", "enum": sorted(ALLOWED_PRIORITIES)},
            },
            "required": ["summary", "details", "priority"],
        },
    },
]


class ToolRunner:
    def __init__(self, kb: KnowledgeBase, ticket_store) -> None:
        self._kb = kb
        self._tickets = ticket_store
        self._handlers: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
            "search_knowledge_base": self._search,
            "create_support_ticket": self._create_ticket,
        }

    def run(self, name: str, args: dict[str, Any]) -> dict[str, Any]:
        handler = self._handlers.get(name)
        if handler is None:
            log.warning("tool_call", extra={"tool": name, "outcome": "rejected_unknown_tool"})
            return {"error": f"unknown tool '{name}'"}
        try:
            result = handler(args or {})
            log.info("tool_call", extra={"tool": name, "outcome": "ok"})
            return result
        except ToolInputError as exc:
            log.warning("tool_call", extra={"tool": name, "outcome": "invalid_input"})
            return {"error": str(exc)}
        except Exception as exc:  # noqa: BLE001
            log.error("tool_call", extra={"tool": name, "outcome": "error", "error": type(exc).__name__})
            return {"error": "tool failed; tell the user a ticket could not be created and to try again later"}

    def _search(self, args: dict[str, Any]) -> dict[str, Any]:
        query = _str(args, "query", 200)
        return {"results": self._kb.search(query)}

    def _create_ticket(self, args: dict[str, Any]) -> dict[str, Any]:
        priority = _str(args, "priority", 10).lower()
        if priority not in ALLOWED_PRIORITIES:
            raise ToolInputError("priority must be low, medium or high")
        ticket_id = f"TKT-{uuid.uuid4().hex[:10].upper()}"
        self._tickets.put(
            {
                "ticket_id": ticket_id,
                "summary": _str(args, "summary", 200),
                "details": _str(args, "details", 2000),
                "priority": priority,
                "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "source": "ai-agent",
            }
        )
        return {"ticket_id": ticket_id, "status": "created"}


def _str(args: dict[str, Any], key: str, max_len: int) -> str:
    value = args.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ToolInputError(f"'{key}' is required")
    if len(value) > max_len:
        raise ToolInputError(f"'{key}' exceeds {max_len} characters")
    return value.strip()
