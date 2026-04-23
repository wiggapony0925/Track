"""Tool: ``get_stop_info`` — full info for a single subway/bus/rail stop.

Returns the same data shown in the iOS Stop Detail sheet:

- station name + GTFS id
- ADA accessibility status (full / partial / none, per-direction flags)
- live elevator + escalator inventory with outage details
- next departures across every mode that serves this stop

The stop can be identified by exact GTFS ``stop_id`` or by name (which
falls back to ``search_stations`` style fuzzy match).
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

from app.metromind.logger import get_logger
from app.metromind.schemas import UserContext
from app.services.track_engine.integration import get_engine_service
from app.services.transit.ada_service import get_station_accessibility

from .base import ToolError, ToolResult

logger = get_logger("tools.stop_info")


SCHEMA: dict[str, Any] = {
    "name": "get_stop_info",
    "description": (
        "Get full details for one transit stop: ADA accessibility status, "
        "every elevator and escalator with current in-service / out-of-service "
        "status, and the next live departures across all modes (subway, bus, "
        "LIRR, Metro-North). Use this for any question about a specific "
        "station or stop — \"is X accessible\", \"are the escalators working at "
        "Y\", \"what's leaving from Z right now\", \"is the elevator at "
        "Lexington Av-53 St out\", etc."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "stop_id": {
                "type": "string",
                "description": (
                    "Exact GTFS stop_id (e.g. '127' for Times Sq-42 St, "
                    "'L08' for Bedford Av). Preferred when known."
                ),
            },
            "station_name": {
                "type": "string",
                "description": (
                    "Station name to fuzzy-match (e.g. 'Times Square', "
                    "'Bedford Av', '34 St-Penn'). Used when stop_id is "
                    "unknown."
                ),
            },
            "include_departures": {
                "type": "boolean",
                "description": (
                    "Whether to fetch live departures for this stop. "
                    "Defaults to true. Set false for accessibility-only "
                    "queries to keep the response small."
                ),
                "default": True,
            },
            "departures_limit": {
                "type": "integer",
                "minimum": 1,
                "maximum": 20,
                "default": 6,
            },
        },
        "additionalProperties": False,
    },
}


async def run(arguments: dict[str, Any], context: UserContext | None) -> ToolResult:
    del context

    stop_id = (arguments.get("stop_id") or "").strip()
    station_name = (arguments.get("station_name") or "").strip()
    include_departures = bool(arguments.get("include_departures", True))
    dep_limit = max(1, min(int(arguments.get("departures_limit") or 6), 20))

    if not stop_id and not station_name:
        raise ToolError("Provide either stop_id or station_name.")

    # ── Resolve a stop ──────────────────────────────────────────────────
    resolved_stop = None
    if not stop_id and station_name:
        engine = get_engine_service()
        stops = await engine.repository.search_stops(station_name, limit=1)
        if stops:
            resolved_stop = stops[0]
            stop_id = resolved_stop.stop_id

    # ── Fetch accessibility + departures in parallel ────────────────────
    stop_ids: list[str] = []
    if stop_id:
        stop_ids = [stop_id, f"{stop_id}N", f"{stop_id}S"]

    async def _accessibility() -> Any:
        try:
            return await get_station_accessibility(
                stop_ids=stop_ids or None,
                station_name=station_name or None,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("Accessibility lookup failed: %s", exc)
            return None

    async def _departures() -> list[dict[str, Any]]:
        if not include_departures or not stop_id:
            return []
        try:
            # Lazy import — avoids loading the router at module import time.
            from fastapi import Response
            from app.routers.departures import departure_board

            response = Response()
            arrivals = await asyncio.wait_for(
                departure_board(
                    stop_id=stop_id,
                    response=response,
                    limit=dep_limit,
                    modes=None,
                ),
                timeout=8.0,
            )
            return [
                {
                    "route_id": a.route_id,
                    "mode": a.mode,
                    "destination": a.destination or a.direction or "",
                    "minutes_away": a.minutes_away,
                    "status": a.status,
                    "is_real_time": a.is_real_time,
                    "is_cancelled": a.is_cancelled,
                }
                for a in arrivals[:dep_limit]
            ]
        except asyncio.TimeoutError:
            logger.warning("Departure board timed out for stop_id=%s", stop_id)
            return []
        except Exception as exc:  # noqa: BLE001
            logger.warning("Departures lookup failed: %s", exc)
            return []

    accessibility, departures = await asyncio.gather(_accessibility(), _departures())

    # ── Assemble payload ────────────────────────────────────────────────
    payload: dict[str, Any] = {
        "stop_id": stop_id or None,
        "station_name": (
            (accessibility.station_name if accessibility else None)
            or (resolved_stop.stop_name if resolved_stop else None)
            or station_name
            or None
        ),
    }

    if accessibility is not None:
        ada_text = {0: "not accessible", 1: "fully accessible", 2: "partially accessible"}.get(
            accessibility.ada_status, "unknown"
        )
        out_of_service = [
            {
                "equipment_id": e.equipment_id,
                "type": "elevator" if e.equipment_type == "EL" else "escalator",
                "description": e.short_description or e.serving,
                "is_ada": e.is_ada,
                "outage_reason": (e.outage.reason if e.outage else None),
                "outage_since": (e.outage.since if e.outage else None),
                "estimated_return": (e.outage.estimated_return if e.outage else None),
                "alternative": e.alternative_route or None,
            }
            for e in accessibility.equipment
            if not e.is_active
        ]
        payload["accessibility"] = {
            "ada_status": ada_text,
            "ada_status_code": accessibility.ada_status,
            "ada_notes": accessibility.ada_notes or None,
            "ada_northbound": accessibility.ada_northbound,
            "ada_southbound": accessibility.ada_southbound,
            "total_elevators": accessibility.total_elevators,
            "total_escalators": accessibility.total_escalators,
            "out_of_service_count": accessibility.outage_count,
            "out_of_service_equipment": out_of_service,
            "next_accessible_north": accessibility.next_accessible_north or None,
            "next_accessible_south": accessibility.next_accessible_south or None,
        }
    else:
        payload["accessibility"] = None

    if include_departures:
        payload["next_departures"] = departures

    label = (
        f"Looking up {payload['station_name']}"
        if payload.get("station_name")
        else "Looking up stop"
    )

    return ToolResult(
        name="get_stop_info",
        content=json.dumps(payload),
        ok=True,
        ui_label=label,
    )
