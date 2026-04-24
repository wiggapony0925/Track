"""Tool: ``get_citibike_nearby`` — live Citi Bike availability.

Pulls the public, no-auth GBFS feeds:

* https://gbfs.citibikenyc.com/gbfs/en/station_information.json — names + coords
* https://gbfs.citibikenyc.com/gbfs/en/station_status.json     — bikes/docks now

Returns the closest N stations to the requested point, each annotated
with bikes available (split classic / e-bike), open docks, and how many
minutes to walk there at ~80 m/min.

Both feeds are cached for 60 s to be friendly to GBFS upstream.
"""

from __future__ import annotations

import json
import math
import time
from typing import Any

import httpx

from app.metromind.logger import get_logger
from app.metromind.schemas import UserContext

from .base import ToolError, ToolResult

logger = get_logger("tools.citibike")


_INFO_URL = "https://gbfs.citibikenyc.com/gbfs/en/station_information.json"
_STATUS_URL = "https://gbfs.citibikenyc.com/gbfs/en/station_status.json"
_TIMEOUT = httpx.Timeout(connect=4.0, read=6.0, write=4.0, pool=4.0)
_CACHE_TTL_S = 60.0
_DEFAULT_RADIUS_KM = 0.5
_DEFAULT_LIMIT = 6


# Module-level caches (one per process). GBFS data updates ~every 10 s
# upstream, but a 60 s cache is plenty for a chat use-case and shields
# the source from accidental hammering.
_info_cache: dict[str, Any] = {"ts": 0.0, "data": None}
_status_cache: dict[str, Any] = {"ts": 0.0, "data": None}


SCHEMA: dict[str, Any] = {
    "name": "get_citibike_nearby",
    "description": (
        "Find the closest Citi Bike stations to the user with live "
        "availability (classic bikes, e-bikes, open docks). Use for "
        "questions like 'any citi bikes near me?', 'where can I dock "
        "this bike?', 'is there an e-bike close by?'. Defaults to the "
        "user's bias point or GPS location."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "lat": {"type": "number"},
            "lon": {"type": "number"},
            "radius_km": {
                "type": "number",
                "minimum": 0.1,
                "maximum": 3.0,
                "default": _DEFAULT_RADIUS_KM,
            },
            "limit": {
                "type": "integer",
                "minimum": 1,
                "maximum": 12,
                "default": _DEFAULT_LIMIT,
            },
            "want": {
                "type": "string",
                "enum": ["bike", "ebike", "dock", "any"],
                "default": "any",
                "description": (
                    "Filter: 'bike' = needs ≥1 classic bike, 'ebike' = ≥1 "
                    "e-bike, 'dock' = ≥1 open dock, 'any' = no filter."
                ),
            },
        },
        "additionalProperties": False,
    },
}


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


async def _fetch(url: str, cache: dict[str, Any]) -> dict[str, Any]:
    now = time.monotonic()
    if cache["data"] is not None and now - cache["ts"] < _CACHE_TTL_S:
        return cache["data"]
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        r = await client.get(url)
        r.raise_for_status()
        data = r.json()
    cache["ts"] = now
    cache["data"] = data
    return data


def _resolve_coords(
    arguments: dict[str, Any], context: UserContext | None
) -> tuple[float, float] | None:
    lat = arguments.get("lat")
    lon = arguments.get("lon")
    if lat is not None and lon is not None:
        return float(lat), float(lon)
    if context is not None:
        if context.bias_lat is not None and context.bias_lon is not None:
            return context.bias_lat, context.bias_lon
        if context.lat is not None and context.lon is not None:
            return context.lat, context.lon
    return None


async def run(arguments: dict[str, Any], context: UserContext | None) -> ToolResult:
    coords = _resolve_coords(arguments, context)
    if coords is None:
        raise ToolError(
            "I need a location to find Citi Bikes — drop a pin on the map "
            "or share your location, then ask again."
        )
    lat, lon = coords

    radius_km = float(arguments.get("radius_km") or _DEFAULT_RADIUS_KM)
    radius_km = max(0.1, min(radius_km, 3.0))
    limit = int(arguments.get("limit") or _DEFAULT_LIMIT)
    limit = max(1, min(limit, 12))
    want = (arguments.get("want") or "any").lower()

    try:
        info_doc, status_doc = await _fetch(_INFO_URL, _info_cache), await _fetch(
            _STATUS_URL, _status_cache
        )
    except httpx.HTTPError as exc:
        logger.warning("Citi Bike GBFS fetch failed: %s", exc)
        raise ToolError(
            "Couldn't reach the Citi Bike feed right now. Tell the user the "
            "Citi Bike lookup is temporarily unavailable."
        ) from exc

    info_list = ((info_doc.get("data") or {}).get("stations") or [])
    status_list = ((status_doc.get("data") or {}).get("stations") or [])
    status_by_id: dict[str, dict[str, Any]] = {
        str(s.get("station_id")): s for s in status_list if s.get("station_id")
    }

    candidates: list[dict[str, Any]] = []
    for stn in info_list:
        s_lat = stn.get("lat")
        s_lon = stn.get("lon")
        if s_lat is None or s_lon is None:
            continue
        d_km = _haversine_km(lat, lon, float(s_lat), float(s_lon))
        if d_km > radius_km:
            continue
        st = status_by_id.get(str(stn.get("station_id"))) or {}
        if not st.get("is_renting", 1):
            continue
        bikes_available = int(st.get("num_bikes_available") or 0)
        ebikes = int(st.get("num_ebikes_available") or 0)
        classic = max(0, bikes_available - ebikes)
        docks = int(st.get("num_docks_available") or 0)

        if want == "bike" and classic < 1:
            continue
        if want == "ebike" and ebikes < 1:
            continue
        if want == "dock" and docks < 1:
            continue

        candidates.append(
            {
                "station_id": str(stn.get("station_id")),
                "name": stn.get("name") or "Citi Bike station",
                "lat": float(s_lat),
                "lon": float(s_lon),
                "distance_m": int(round(d_km * 1000.0)),
                "walk_minutes": round((d_km * 1000.0) / 80.0, 1),
                "classic_bikes": classic,
                "ebikes": ebikes,
                "bikes_available_total": bikes_available,
                "docks_available": docks,
                "is_returning": bool(st.get("is_returning", 1)),
            }
        )

    candidates.sort(key=lambda s: s["distance_m"])
    trimmed = candidates[:limit]

    payload = {
        "origin": {"lat": lat, "lon": lon},
        "radius_km": radius_km,
        "filter": want,
        "total_in_radius": len(candidates),
        "stations": trimmed,
    }
    return ToolResult(
        name="get_citibike_nearby",
        content=json.dumps(payload),
        ok=True,
        ui_label="Looking up nearby Citi Bikes",
    )
