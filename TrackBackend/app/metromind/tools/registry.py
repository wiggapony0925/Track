"""Tool registry — maps tool names to schemas and executors."""

from __future__ import annotations

import json
from typing import Any, Awaitable, Callable

from app.metromind.logger import get_logger
from app.metromind.schemas import UserContext

from . import alerts, plan, stations
from .base import ToolError, ToolResult

logger = get_logger("tools")


# ── Registry ───────────────────────────────────────────────────────────

_ToolFn = Callable[[dict[str, Any], UserContext | None], Awaitable[ToolResult]]


_REGISTRY: dict[str, tuple[dict[str, Any], _ToolFn]] = {
    "plan_route": (plan.SCHEMA, plan.run),
    "get_service_alerts": (alerts.SCHEMA, alerts.run),
    "search_stations": (stations.SCHEMA, stations.run),
}


def tool_schemas() -> list[dict[str, Any]]:
    """Return the list of tool schemas in the OpenAI ``tools`` format."""
    return [
        {"type": "function", "function": schema}
        for (schema, _fn) in _REGISTRY.values()
    ]


async def dispatch(
    name: str,
    arguments_json: str,
    *,
    context: UserContext | None = None,
) -> ToolResult:
    """Execute the named tool with JSON-encoded arguments from the LLM."""
    entry = _REGISTRY.get(name)
    if entry is None:
        logger.warning("Unknown tool requested by LLM: %s", name)
        return ToolResult(
            name=name,
            content=json.dumps({"error": f"Unknown tool '{name}'."}),
            ok=False,
            ui_label="unknown tool",
        )

    schema, runner = entry
    try:
        arguments = json.loads(arguments_json) if arguments_json else {}
    except json.JSONDecodeError as exc:
        return ToolResult(
            name=name,
            content=json.dumps({"error": f"Malformed arguments: {exc}"}),
            ok=False,
            ui_label="bad arguments",
        )

    logger.info("Tool call: %s args=%s", name, arguments)
    try:
        return await runner(arguments, context)
    except ToolError as exc:
        logger.warning("Tool %s failed: %s", name, exc)
        return ToolResult(
            name=name,
            content=json.dumps({"error": str(exc)}),
            ok=False,
            ui_label=f"{schema.get('name', name)} failed",
        )
    except Exception as exc:  # noqa: BLE001 — never crash the chat loop
        logger.exception("Tool %s raised unexpectedly", name)
        return ToolResult(
            name=name,
            content=json.dumps({"error": f"Internal error: {exc}"}),
            ok=False,
            ui_label=f"{schema.get('name', name)} error",
        )


__all__ = ["ToolError", "ToolResult", "dispatch", "tool_schemas"]
