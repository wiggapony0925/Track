"""Tool: ``search_stations`` — find GTFS stops by fuzzy name match."""

from __future__ import annotations

import json
import math
from typing import Any

from app.metromind.logger import get_logger
from app.metromind.schemas import UserContext
from app.services.track_engine.integration import get_engine_service

from .base import ToolError, ToolResult

logger = get_logger("tools.stations")


SCHEMA: dict[str, Any] = {
    "name": "search_stations",
    "description": (
        "Search the GTFS stops catalogue by name or stop_id. Returns up to 10 "
        "matching stops with coordinates. Use this to resolve a user-provided "
        "place name into a precise stop_id before calling plan_route. Pass "
        "`lat`/`lon`/`radius_km` (or rely on the bias point in context) to "
        "answer 'what stations are near me' / 'closest stop to here' — in that "
        "case `query` may be empty."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": (
                    "Free-text query. Examples: 'Times Square', 'Bedford Av', "
                    "'Union Square', 'JFK'. Optional when proximity search is used."
                ),
            },
            "limit": {
                "type": "integer",
                "minimum": 1,
                "maximum": 15,
                "default": 8,
            },
            "lat": {
                "type": "number",
                "description": "Latitude for proximity search.",
            },
            "lon": {
                "type": "number",
                "description": "Longitude paired with `lat`.",
            },
            "radius_km": {
                "type": "number",
                "minimum": 0.05,
                "maximum": 10,
                "default": 1.0,
                "description": "Radius (km) used when `lat`/`lon` are supplied.",
            },
        },
        "additionalProperties": False,
    },
}


async def run(arguments: dict[str, Any], context: UserContext | None) -> ToolResult:
    query = (arguments.get("query") or "").strip()
    limit = int(arguments.get("limit") or 8)
    limit = max(1, min(limit, 15))

    lat_arg = arguments.get("lat")
    lon_arg = arguments.get("lon")
    if (lat_arg is None or lon_arg is None) and context is not None:
        lat_arg = context.bias_lat if lat_arg is None else lat_arg
        lon_arg = context.bias_lon if lon_arg is None else lon_arg
    radius_km = float(arguments.get("radius_km") or 1.0)
    radius_km = max(0.05, min(radius_km, 10.0))

    proximity_only = not query and lat_arg is not None and lon_arg is not None
    if not query and not proximity_only:
        raise ToolError("Query is required (or supply lat/lon for proximity search).")

    engine = get_engine_service()
    matched_variant = query

    if proximity_only:
        stops = await engine.repository.nearby_stops(
            float(lat_arg), float(lon_arg), radius_km, limit=400
        )
    else:
        # Try the verbatim query first, then progressively looser variants.
        stops = []
        for variant in _query_variants(query):
            stops = await engine.repository.search_stops(variant, limit=max(limit, 50) if lat_arg is not None else limit)
            if stops:
                matched_variant = variant
                break

    results: list[dict[str, Any]] = []
    for s in stops:
        entry: dict[str, Any] = {
            "stop_id": s.stop_id,
            "stop_name": s.stop_name,
            "lat": round(s.lat, 6),
            "lon": round(s.lon, 6),
        }
        if lat_arg is not None and lon_arg is not None:
            d = _haversine_km(float(lat_arg), float(lon_arg), s.lat, s.lon)
            if d > radius_km:
                continue
            entry["distance_km"] = round(d, 3)
        results.append(entry)

    if lat_arg is not None and lon_arg is not None:
        results.sort(key=lambda e: e.get("distance_km") or 1e9)
    results = results[:limit]

    if proximity_only:
        ui_label = f"Stops within {radius_km:g} km"
    elif lat_arg is not None and lon_arg is not None:
        ui_label = f"'{query}' within {radius_km:g} km"
    else:
        ui_label = f"Finding stations for '{query}'"

    return ToolResult(
        name="search_stations",
        content=json.dumps(
            {
                "query": query,
                "matched_query": matched_variant,
                "bias": (
                    {"lat": lat_arg, "lon": lon_arg, "radius_km": radius_km}
                    if lat_arg is not None and lon_arg is not None
                    else None
                ),
                "stops": results,
            }
        ),
        ok=True,
        ui_label=ui_label,
    )


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlam / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def _query_variants(query: str) -> list[str]:
    """Generate fallback search variants for fuzzier matching."""
    base = query.strip()
    if not base:
        return []
    abbrev = (
        base.replace("Square", "Sq")
        .replace("Street", "St")
        .replace("Avenue", "Av")
        .replace("Boulevard", "Blvd")
        .replace("Center", "Ctr")
    )
    seen: set[str] = set()
    variants: list[str] = []
    for candidate in (base, abbrev):
        words = candidate.split()
        for end in range(len(words), 0, -1):
            v = " ".join(words[:end]).strip()
            key = v.lower()
            if v and key not in seen:
                seen.add(key)
                variants.append(v)
    return variants
