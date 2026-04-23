"""Tool: ``get_live_arrivals`` — real-time train arrivals for a route.

Returns the next N upcoming arrivals for a given subway route (and
optional direction) with live ETAs, status (On Time / Delayed / Skipped),
and live train GPS positions if requested.

Use this for questions like:
- "Where's the next northbound 6 train?"
- "When's the next L to Manhattan?"
- "Are there any A trains running right now?"
- "Show me live positions of every Q train"

For arrivals at *one specific stop*, prefer ``get_stop_info``.
"""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any

from app.metromind.logger import get_logger
from app.metromind.schemas import UserContext
from app.services.gtfs.realtime_parser import (
    get_arrivals_for_line,
    get_vehicle_positions_for_line,
)

from .base import ToolError, ToolResult

logger = get_logger("tools.live_arrivals")


SCHEMA: dict[str, Any] = {
    "name": "get_live_arrivals",
    "description": (
        "Fetch real-time subway arrival predictions for one route. Returns the "
        "next upcoming trains across the line, optionally filtered by direction "
        "(north/south) and stop name. Optionally includes live train GPS "
        "positions. Use for questions like 'where's the next northbound 6', "
        "'when's the next L', 'are A trains running right now', or 'show me "
        "live Q train positions'."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "route_id": {
                "type": "string",
                "description": (
                    "GTFS route ID, single letter or number (e.g. 'A', 'L', "
                    "'6', '7', 'Q'). Case-sensitive."
                ),
            },
            "direction": {
                "type": "string",
                "enum": ["north", "south", "both"],
                "default": "both",
                "description": (
                    "Filter arrivals by direction. Subway 'north' = uptown / "
                    "Bronx / Queens-bound depending on line."
                ),
            },
            "station_filter": {
                "type": "string",
                "description": (
                    "Optional case-insensitive substring of station name "
                    "(e.g. 'Times', '14 St'). Filters to arrivals at "
                    "matching stations only."
                ),
            },
            "limit": {
                "type": "integer",
                "minimum": 1,
                "maximum": 20,
                "default": 6,
            },
            "include_vehicle_positions": {
                "type": "boolean",
                "default": False,
                "description": (
                    "When true, also returns live GPS coordinates for every "
                    "active train on this route. Adds latency."
                ),
            },
        },
        "required": ["route_id"],
        "additionalProperties": False,
    },
}


_DIRECTION_TO_SUFFIX = {"north": "N", "south": "S"}


async def run(arguments: dict[str, Any], context: UserContext | None) -> ToolResult:
    del context

    route_id = (arguments.get("route_id") or "").strip()
    if not route_id:
        raise ToolError("route_id is required (e.g. 'A', 'L', '6').")

    direction = (arguments.get("direction") or "both").lower()
    if direction not in {"north", "south", "both"}:
        raise ToolError("direction must be north, south, or both.")

    station_filter = (arguments.get("station_filter") or "").strip().lower()
    limit = max(1, min(int(arguments.get("limit") or 6), 20))
    want_positions = bool(arguments.get("include_vehicle_positions", False))

    # ── Fetch arrivals + (optionally) vehicle positions in parallel ─────
    async def _arrivals() -> list[Any]:
        try:
            return await get_arrivals_for_line(route_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("Arrivals fetch failed for %s: %s", route_id, exc)
            return []

    async def _positions() -> list[Any]:
        if not want_positions:
            return []
        try:
            return await get_vehicle_positions_for_line(route_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("Vehicle positions failed for %s: %s", route_id, exc)
            return []

    arrivals, vehicles = await asyncio.gather(_arrivals(), _positions())

    # ── Filter ──────────────────────────────────────────────────────────
    now_ts = int(time.time())
    suffix = _DIRECTION_TO_SUFFIX.get(direction)

    filtered = [
        a
        for a in arrivals
        if a.route_id == route_id
        and (a.arrival_ts or 0) >= now_ts - 30  # drop already-departed
        and (suffix is None or (a.station or "").upper().endswith(suffix))
        and (
            not station_filter
            or station_filter in (a.station_name or "").lower()
        )
    ]

    # Sort by ETA, take N
    filtered.sort(key=lambda a: a.arrival_ts or 0)
    filtered = filtered[:limit]

    # ── Serialise ───────────────────────────────────────────────────────
    arrivals_payload = [
        {
            "station_name": a.station_name,
            "station_id": a.station,
            "direction": a.direction,
            "destination": a.destination,
            "minutes_away": a.minutes_away,
            "arrival_ts": a.arrival_ts,
            "status": a.status,
            "is_cancelled": a.is_cancelled,
            "is_skipped": a.is_skipped,
            "delay_seconds": a.delay_seconds,
        }
        for a in filtered
    ]

    payload: dict[str, Any] = {
        "route_id": route_id,
        "direction_filter": direction,
        "station_filter": station_filter or None,
        "now_ts": now_ts,
        "total_returned": len(arrivals_payload),
        "arrivals": arrivals_payload,
    }

    if want_positions:
        payload["vehicles"] = [
            {
                "vehicle_id": v.vehicle_id,
                "trip_id": v.trip_id,
                "lat": round(v.lat, 5),
                "lon": round(v.lon, 5),
                "bearing": v.bearing,
                "speed_mph": v.speed_mph,
                "current_stop_name": v.current_stop_name,
                "status": v.status,
            }
            for v in vehicles
            if v.route_id == route_id
        ]
        payload["vehicle_count"] = len(payload["vehicles"])

    direction_label = {"north": "northbound", "south": "southbound", "both": ""}[direction]
    label_bits = [f"Live {route_id}"]
    if direction_label:
        label_bits.append(direction_label)
    label_bits.append("arrivals")
    label = " ".join(label_bits)

    return ToolResult(
        name="get_live_arrivals",
        content=json.dumps(payload),
        ok=True,
        ui_label=label,
    )
