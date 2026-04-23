"""Tool: ``get_user_places`` — surface the user's saved places & recent trips.

The data lives in ``UserContext`` (sent by the iOS client every turn).
This tool lets the LLM explicitly enumerate them when the user asks
"what places do I have saved?" or "what was my last trip?".
"""

from __future__ import annotations

import json
from typing import Any

from app.metromind.schemas import UserContext

from .base import ToolResult


SCHEMA: dict[str, Any] = {
    "name": "get_user_places",
    "description": (
        "List the user's saved places (Home, Work, custom) and recent trips. "
        "Call this when the user asks about their saved destinations, "
        "shortcuts, recent rides, or 'where did I go last'. "
        "Don't call this just to resolve 'home' or 'work' in a route question — "
        "those coordinates are already in your system context."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "include_recent_trips": {
                "type": "boolean",
                "default": True,
                "description": "Include recently planned trips alongside saved places.",
            },
            "limit_recent": {
                "type": "integer",
                "minimum": 1,
                "maximum": 20,
                "default": 6,
            },
        },
        "additionalProperties": False,
    },
}


async def run(
    arguments: dict[str, Any],
    context: UserContext | None,
) -> ToolResult:
    include_recent = bool(arguments.get("include_recent_trips", True))
    limit_recent = int(arguments.get("limit_recent", 6))

    saved = [
        {
            "label": p.label,
            "kind": p.kind,
            "lat": p.lat,
            "lon": p.lon,
            "address": p.address,
        }
        for p in (context.saved_places if context else [])
    ]
    recent = (
        [
            {
                "origin": t.origin_label,
                "destination": t.destination_label,
                "summary": t.summary,
                "requested_at": t.requested_at,
            }
            for t in (context.recent_trips if context else [])[:limit_recent]
        ]
        if include_recent
        else []
    )

    payload = {
        "saved_places": saved,
        "recent_trips": recent,
        "has_user_context": context is not None,
    }
    label_bits = []
    if saved:
        label_bits.append(f"{len(saved)} saved")
    if recent:
        label_bits.append(f"{len(recent)} recent")
    label = "Loading your places" if not label_bits else "Loaded " + ", ".join(label_bits)

    return ToolResult(
        name="get_user_places",
        content=json.dumps(payload),
        ok=True,
        ui_label=label,
    )


__all__ = ["SCHEMA", "run"]
