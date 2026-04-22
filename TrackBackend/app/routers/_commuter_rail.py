"""Shared helpers for commuter rail routers (LIRR & Metro-North).

Eliminates duplication between lirr.py and mnr.py by extracting the
common shape-building and arrival-fetching logic into parameterised helpers.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import httpx
from fastapi import HTTPException, Response

from app.clients.rail_client import fetch_rail_arrivals, filter_fresh_arrivals
from app.models import (
    AllCommuterRailLinesResponse,
    BusStop,
    CommuterRailLineOverlay,
    CommuterRailStop,
    DirectionShape,
    RouteShape,
    TrackArrival,
)
from app.services.mapping.subway.shapes import enrich_stops_with_transfers
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import encode_polyline as _encode_polyline

if TYPE_CHECKING:
    from collections.abc import Callable


def build_all_lines(
    get_all_fn: Callable[[], list[dict]],
    mode: str,
) -> AllCommuterRailLinesResponse:
    """Build the AllCommuterRailLinesResponse for all branches/lines.

    Args:
        get_all_fn: Callable that returns the list of line dicts from
            commuter_rail_shapes.
        mode: Agency mode string (``"lirr"`` or ``"mnr"``).

    Returns:
        Fully populated response model with encoded polylines.
    """
    lines_data = get_all_fn()
    overlays: list[CommuterRailLineOverlay] = []
    for line in lines_data:
        encoded = [_encode_polyline(coords) for coords in line["polylines"]]
        stops = [
            CommuterRailStop(stop_id=s.stop_id, name=s.name, lat=s.lat, lon=s.lon)
            for s in line.get("stops", [])
        ]
        overlays.append(
            CommuterRailLineOverlay(
                route_id=line["route_id"],
                name=line["name"],
                color_hex=line["color_hex"],
                polylines=encoded,
                mode=mode,
                stops=stops,
            )
        )
    return AllCommuterRailLinesResponse(lines=overlays)


def build_single_line(
    route_id: str,
    *,
    prefix: str,
    get_all_fn: Callable[[], list[dict]],
    get_single_fn: Callable[[str], dict | None],
    name_normaliser: Callable[[str], str] | None = None,
) -> RouteShape:
    """Build the RouteShape for a single commuter rail branch/line.

    Args:
        route_id: Raw route identifier from the path parameter.
        prefix: Agency prefix (``"LIRR"`` or ``"MNR"``).
        get_all_fn: Callable returning all lines (used for name fallback).
        get_single_fn: Callable returning one line by numeric ID.
        name_normaliser: Optional callable to normalise names for fuzzy
            matching (e.g. stripping `` branch`` for LIRR).

    Returns:
        Fully populated RouteShape with encoded polylines and stops.

    Raises:
        HTTPException: 404 if the branch/line is not found.
    """
    numeric_id = route_id.removeprefix(f"{prefix}_")
    line_data = get_single_fn(numeric_id)

    # Fallback: resolve by branch/line name
    if line_data is None:
        norm = name_normaliser or (lambda s: s.lower().strip())
        query = norm(route_id)
        for line in get_all_fn():
            name = norm(line["name"])
            if name == query or name.startswith(query):
                numeric_id = line["route_id"].removeprefix(f"{prefix}_")
                line_data = get_single_fn(numeric_id)
                break

    if line_data is None:
        raise HTTPException(
            status_code=404,
            detail=f"{prefix} branch '{route_id}' not found",
        )

    encoded = [_encode_polyline(coords) for coords in line_data["polylines"]]
    route_prefix = f"{prefix}_{numeric_id}"

    all_stops = [
        BusStop(id=s.stop_id, name=s.name, lat=s.lat, lon=s.lon)
        for s in line_data.get("stops", [])
    ]
    enrich_stops_with_transfers(all_stops, current_route=route_prefix)

    directions: list[DirectionShape] = []
    for dd in line_data.get("directions", []):
        dir_encoded = [_encode_polyline(coords) for coords in dd["polylines"]]
        dir_stops = [
            BusStop(id=s.stop_id, name=s.name, lat=s.lat, lon=s.lon)
            for s in dd.get("stops", [])
        ]
        enrich_stops_with_transfers(dir_stops, current_route=route_prefix)
        directions.append(
            DirectionShape(
                direction_id=dd["direction_id"],
                headsign=dd.get("headsign", ""),
                polylines=dir_encoded,
                stops=dir_stops,
            )
        )

    return RouteShape(
        route_id=line_data["route_id"],
        polylines=encoded,
        stops=all_stops,
        directions=directions,
    )


async def fetch_arrivals(
    feed_name: str,
    *,
    tag: str,
    response: Response,
) -> list[TrackArrival]:
    """Fetch real-time commuter rail arrivals with multi-day GTFS backfill.

    For every distinct ``route_id`` that appears in the live feed, the
    static GTFS schedule is appended (deduplicated by trip_id and
    (station, arrival_ts)) so the client gets the same Transit-style
    schedule depth that subway and bus already offer.

    Args:
        feed_name: Feed identifier for ``fetch_rail_arrivals``
            (``"lirr"`` or ``"metro_north"``).
        tag: Logging tag (``"LIRR"`` or ``"MNR"``).
        response: FastAPI ``Response`` object for setting degraded headers.

    Returns:
        Live + scheduled arrivals merged & sorted by ``arrival_ts``.
        Returns an empty list on feed error.
    """
    try:
        live = filter_fresh_arrivals(await fetch_rail_arrivals(feed_name))
    except Exception as exc:
        TrackLogger.warning(
            f"[{tag}] arrivals: feed error ({exc}) — returning empty fallback",
            tag=tag,
        )
        response.headers["X-Track-Degraded"] = f"{tag.lower()}-arrivals-fallback"
        return []

    # ── Multi-day schedule backfill (mirrors subway / bus depth) ──
    try:
        from app.config import get_settings
        from app.services.transit.schedule_service import schedule_service

        settings = get_settings()
        max_sched = settings.app_settings.max_schedule_per_line
        days_ahead = settings.app_settings.max_schedule_days_ahead

        # Backfill per distinct route to keep the call shape identical
        # to the per-line subway endpoint.  GTFS stores LIRR/MNR routes
        # with bare numeric IDs — strip any agency prefix for the lookup.
        route_ids = {a.route_id for a in live if a.route_id}
        rt_trip_ids = {a.trip_id for a in live if a.trip_id}
        rt_keys = {(a.station, a.arrival_ts) for a in live if a.arrival_ts}

        merged: list[TrackArrival] = list(live)
        for rid in route_ids:
            lookup = rid
            for prefix in ("LIRR_", "MNR_"):
                if lookup.startswith(prefix):
                    lookup = lookup[len(prefix):]
                    break
            try:
                sched = await schedule_service.get_line_schedule_async(
                    lookup, limit=max_sched, days_ahead=days_ahead
                )
            except Exception as sched_exc:
                TrackLogger.warning(
                    f"[{tag}] schedule backfill ({rid}) failed: {sched_exc}",
                    tag=tag,
                )
                continue
            for s in sched:
                if s.trip_id and s.trip_id in rt_trip_ids:
                    continue
                if (s.station, s.arrival_ts) in rt_keys:
                    continue
                merged.append(s)

        merged.sort(key=lambda a: a.arrival_ts or 0)
        return merged
    except Exception as exc:
        TrackLogger.warning(
            f"[{tag}] backfill wrapper failed ({exc}) — returning live only",
            tag=tag,
        )
        return live
