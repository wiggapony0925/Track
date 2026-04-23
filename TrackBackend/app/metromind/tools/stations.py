"""Tool: ``search_stations`` — find GTFS stops by fuzzy name match."""

from __future__ import annotations

import json
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
        "place name into a precise stop_id before calling plan_route."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": (
                    "Free-text query. Examples: 'Times Square', 'Bedford Av', "
                    "'Union Square', 'JFK'."
                ),
            },
            "limit": {
                "type": "integer",
                "minimum": 1,
                "maximum": 15,
                "default": 8,
            },
        },
        "required": ["query"],
        "additionalProperties": False,
    },
}


async def run(arguments: dict[str, Any], context: UserContext | None) -> ToolResult:
    del context
    query = (arguments.get("query") or "").strip()
    if not query:
        raise ToolError("Query is required.")

    limit = int(arguments.get("limit") or 8)
    limit = max(1, min(limit, 15))

    engine = get_engine_service()

    # Try the verbatim query first, then progressively looser variants
    # (e.g. "Times Square" → "Times Sq" → "Times") to handle the GTFS
    # catalogue's heavy abbreviations.
    stops: list[Any] = []
    matched_variant = query
    for variant in _query_variants(query):
        stops = await engine.repository.search_stops(variant, limit=limit)
        if stops:
            matched_variant = variant
            break

    results = [
        {
            "stop_id": s.stop_id,
            "stop_name": s.stop_name,
            "lat": round(s.lat, 6),
            "lon": round(s.lon, 6),
        }
        for s in stops
    ]

    return ToolResult(
        name="search_stations",
        content=json.dumps(
            {"query": query, "matched_query": matched_variant, "stops": results}
        ),
        ok=True,
        ui_label=f"Finding stations for '{query}'",
    )


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
