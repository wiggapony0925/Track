"""Tool: ``get_equipment_outages`` — system-wide elevator + escalator outages.

Wraps the same MTA elevator/escalator outage feed used by the iOS
accessibility dashboard. Supports filtering by station name (substring),
equipment type (elevator vs escalator), and ADA-only.
"""

from __future__ import annotations

import json
import math
from typing import Any

from app.metromind.logger import get_logger
from app.metromind.schemas import UserContext
from app.services.gtfs.realtime_parser import get_broken_elevators
from app.services.track_engine.integration import get_engine_service

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
            "lat": {
                "type": "number",
                "description": (
                    "Latitude for proximity filtering. Pair with `lon` and "
                    "`radius_km` to answer 'near me' / 'around here' questions."
                ),
            },
            "lon": {
                "type": "number",
                "description": "Longitude paired with `lat`.",
            },
            "radius_km": {
                "type": "number",
                "minimum": 0.1,
                "maximum": 25,
                "default": 1.0,
                "description": "Radius (km) used when `lat`/`lon` are supplied.",
            },
        },
        "additionalProperties": False,
    },
}


_TYPE_MAP = {"EL": "elevator", "ES": "escalator"}


async def run(arguments: dict[str, Any], context: UserContext | None) -> ToolResult:
    station_filter = (arguments.get("station_filter") or "").strip().lower()
    eq_type = (arguments.get("equipment_type") or "both").lower()
    limit = max(1, min(int(arguments.get("limit") or 15), 50))

    # Proximity bias — explicit args win, otherwise fall back to context bias.
    lat_arg = arguments.get("lat")
    lon_arg = arguments.get("lon")
    if (lat_arg is None or lon_arg is None) and context is not None:
        lat_arg = context.bias_lat if lat_arg is None else lat_arg
        lon_arg = context.bias_lon if lon_arg is None else lon_arg
    radius_km = float(arguments.get("radius_km") or 1.0)
    radius_km = max(0.1, min(radius_km, 25.0))

    if eq_type not in {"elevator", "escalator", "both"}:
        raise ToolError("equipment_type must be elevator, escalator, or both.")

    try:
        outages = await get_broken_elevators()
    except Exception as exc:  # noqa: BLE001
        raise ToolError(f"Couldn't reach the MTA equipment feed ({exc}).") from exc

    # Resolve station coordinates once if proximity filtering is requested.
    station_coords: dict[str, tuple[float, float]] = {}
    if lat_arg is not None and lon_arg is not None:
        try:
            engine = get_engine_service()
            uniq_stations = {(o.station or "").strip() for o in outages if o.station}
            for name in uniq_stations:
                stops = await engine.repository.search_stops(name, limit=1)
                if stops:
                    station_coords[name.lower()] = (stops[0].lat, stops[0].lon)
        except Exception as exc:  # noqa: BLE001
            logger.warning("proximity lookup failed: %s", exc)

    filtered: list[dict[str, Any]] = []
    for o in outages:
        kind = _TYPE_MAP.get(o.equipment_type, o.equipment_type.lower())
        if eq_type != "both" and kind != eq_type:
            continue
        if station_filter and station_filter not in (o.station or "").lower():
            continue
        distance_km: float | None = None
        if lat_arg is not None and lon_arg is not None:
            coords = station_coords.get((o.station or "").lower())
            if not coords:
                continue
            distance_km = _haversine_km(float(lat_arg), float(lon_arg), coords[0], coords[1])
            if distance_km > radius_km:
                continue
        entry: dict[str, Any] = {
            "station": o.station,
            "type": kind,
            "description": o.description,
            "outage_since": o.outage_since,
        }
        if distance_km is not None:
            entry["distance_km"] = round(distance_km, 3)
        filtered.append(entry)

    if lat_arg is not None and lon_arg is not None:
        filtered.sort(key=lambda e: e.get("distance_km") or 1e9)

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
            "lat": lat_arg,
            "lon": lon_arg,
            "radius_km": radius_km if lat_arg is not None else None,
        },
        "outages": filtered,
    }

    if lat_arg is not None and lon_arg is not None:
        label = f"{eq_type.capitalize()} outages within {radius_km:g} km"
    elif station_filter:
        label = f"Outages near '{station_filter}'"
    else:
        label = f"System {eq_type} outages"

    return ToolResult(
        name="get_equipment_outages",
        content=json.dumps(payload),
        ok=True,
        ui_label=label,
    )


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlam / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))
