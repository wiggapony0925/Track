"""Tool: ``get_equipment_outages`` — system-wide elevator + escalator outages.

Wraps the same MTA elevator/escalator outage feed used by the iOS
accessibility dashboard. Supports filtering by station name (substring),
equipment type (elevator vs escalator), and ADA-only.
"""

from __future__ import annotations

import json
from typing import Any

from app.metromind.logger import get_logger
from app.metromind.schemas import UserContext
from app.services.gtfs.realtime_parser import get_broken_elevators

from .base import ToolError, ToolResult

logger = get_logger("tools.equipment_outages")


SCHEMA: dict[str, Any] = {
    "name": "get_equipment_outages",
    "description": (
        "Fetch every elevator or escalator currently out of service across "
        "the MTA system. Use for any system-wide accessibility question — "
        "\"any escalators out of order\", \"are there elevator outages on the "
        "L line\", \"what's broken at Penn Station right now\". For a "
        "single specific station, prefer get_stop_info instead."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "station_filter": {
                "type": "string",
                "description": (
                    "Case-insensitive substring filter on station name "
                    "(e.g. 'Times', 'Penn', '42 St'). Omit to return the "
                    "whole system list."
                ),
            },
            "equipment_type": {
                "type": "string",
                "enum": ["elevator", "escalator", "both"],
                "default": "both",
            },
            "limit": {
                "type": "integer",
                "minimum": 1,
                "maximum": 50,
                "default": 15,
            },
        },
        "additionalProperties": False,
    },
}


_TYPE_MAP = {"EL": "elevator", "ES": "escalator"}


async def run(arguments: dict[str, Any], context: UserContext | None) -> ToolResult:
    del context

    station_filter = (arguments.get("station_filter") or "").strip().lower()
    eq_type = (arguments.get("equipment_type") or "both").lower()
    limit = max(1, min(int(arguments.get("limit") or 15), 50))

    if eq_type not in {"elevator", "escalator", "both"}:
        raise ToolError("equipment_type must be elevator, escalator, or both.")

    try:
        outages = await get_broken_elevators()
    except Exception as exc:  # noqa: BLE001
        raise ToolError(f"Couldn't reach the MTA equipment feed ({exc}).") from exc

    filtered: list[dict[str, Any]] = []
    for o in outages:
        kind = _TYPE_MAP.get(o.equipment_type, o.equipment_type.lower())
        if eq_type != "both" and kind != eq_type:
            continue
        if station_filter and station_filter not in (o.station or "").lower():
            continue
        filtered.append(
            {
                "station": o.station,
                "type": kind,
                "description": o.description,
                "outage_since": o.outage_since,
            }
        )

    total = len(filtered)
    truncated = total > limit
    filtered = filtered[:limit]

    payload = {
        "total_outages": total,
        "returned": len(filtered),
        "truncated": truncated,
        "filters": {
            "station_filter": station_filter or None,
            "equipment_type": eq_type,
        },
        "outages": filtered,
    }

    label = (
        f"Outages near '{station_filter}'"
        if station_filter
        else f"System {eq_type} outages"
    )

    return ToolResult(
        name="get_equipment_outages",
        content=json.dumps(payload),
        ok=True,
        ui_label=label,
    )
