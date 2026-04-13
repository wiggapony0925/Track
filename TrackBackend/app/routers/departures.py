"""Unified departure board — all upcoming departures from a single stop.

``GET /departures/{stop_id}`` aggregates subway, bus, LIRR, and MNR
arrivals at (or near) the requested stop ID and returns them sorted by
time in a single flat list.

This mirrors the "departure board" UX found in Citymapper and Transit:
one glance shows every vehicle leaving from the station regardless of mode.
"""

from __future__ import annotations

import asyncio
import time as _time
from datetime import UTC, datetime

from fastapi import APIRouter, Query, Response

from app.clients.bus_client import get_realtime_arrivals
from app.clients.rail_client import fetch_rail_arrivals
from app.config import get_settings
from app.models import NearbyTransitArrival
from app.services.gtfs.realtime_parser import get_arrivals_for_line
from app.services.transit.station_lookup import get_stop_info
from app.utils.brand import (
    mode_color as _brand_mode_color,
    subway_color as _brand_subway_color,
)
from app.utils.logger import TrackLogger
from app.utils.transit_utils import (
    get_all_subway_lines,
    resolve_subway_feed_key,
)

router = APIRouter(tags=["departures"])

# ── Helpers ──────────────────────────────────────────────────────────────


def _subway_stop_base(stop_id: str) -> str:
    """Strip direction suffix (N/S) from a subway stop ID → parent station."""
    if stop_id and stop_id[-1] in {"N", "S"} and len(stop_id) >= 2:
        return stop_id[:-1]
    return stop_id


def _is_subway_stop(stop_id: str) -> bool:
    """Heuristic: subway stop IDs are numeric (e.g. '726', '120')."""
    base = _subway_stop_base(stop_id)
    return base.isdigit()


def _is_bus_stop(stop_id: str) -> bool:
    """Bus stop IDs start with digits and may have 'MTA_' prefix."""
    sid = stop_id.replace("MTA_", "")
    return sid[:1].isdigit() and not sid.isdigit()


# ── Departure board endpoint ────────────────────────────────────────────


@router.get(
    "/departures/{stop_id}",
    response_model=list[NearbyTransitArrival],
    summary="Unified departure board for a stop",
    description=(
        "Returns all upcoming departures from the given stop across subway, "
        "bus, LIRR, and MNR — sorted by time. Works with any GTFS stop ID."
    ),
)
async def departure_board(
    stop_id: str,
    response: Response,
    limit: int = Query(20, ge=1, le=100, description="Max departures to return."),
    modes: str | None = Query(
        None,
        description="Comma-separated mode filter (subway,bus,lirr,mnr). Omit for all.",
    ),
) -> list[NearbyTransitArrival]:
    """Build a unified departure board for *stop_id*."""
    t0 = _time.time()
    now_ts = int(t0)
    allowed_modes: set[str] | None = None
    if modes:
        allowed_modes = {m.strip().lower() for m in modes.split(",")}

    tasks: list[asyncio.Task] = []
    task_labels: list[str] = []

    # ── Subway ───────────────────────────────────────────────────────
    if (allowed_modes is None or "subway" in allowed_modes) and _is_subway_stop(stop_id):
        base = _subway_stop_base(stop_id)
        # Fetch all subway feeds in parallel and filter for this stop
        seen_feeds: set[str] = set()
        for line in get_all_subway_lines():
            feed_key = resolve_subway_feed_key(line)
            if feed_key and feed_key not in seen_feeds:
                seen_feeds.add(feed_key)
                tasks.append(asyncio.create_task(get_arrivals_for_line(line)))
                task_labels.append(f"subway:{line}")

    # ── Bus ───────────────────────────────────────────────────────────
    if allowed_modes is None or "bus" in allowed_modes:
        for prefix in ("MTA_", ""):
            bus_sid = f"{prefix}{stop_id}" if prefix else stop_id
            tasks.append(asyncio.create_task(get_realtime_arrivals(bus_sid)))
            task_labels.append(f"bus:{bus_sid}")

    # ── LIRR ──────────────────────────────────────────────────────────
    if allowed_modes is None or "lirr" in allowed_modes:
        tasks.append(asyncio.create_task(fetch_rail_arrivals("lirr")))
        task_labels.append("lirr")

    # ── MNR ───────────────────────────────────────────────────────────
    if allowed_modes is None or "mnr" in allowed_modes:
        tasks.append(asyncio.create_task(fetch_rail_arrivals("metro_north")))
        task_labels.append("mnr")

    if not tasks:
        return []

    results = await asyncio.gather(*tasks, return_exceptions=True)

    # ── Normalize into NearbyTransitArrival ──────────────────────────
    departures: list[NearbyTransitArrival] = []
    base = _subway_stop_base(stop_id)

    for label, result in zip(task_labels, results):
        if isinstance(result, Exception):
            TrackLogger.warning(
                f"[DEPARTURES] {label} failed: {result}", tag="DEPARTURES"
            )
            continue

        if label.startswith("subway:"):
            for arr in result:
                # Filter to this specific stop (base matches N/S suffixed)
                arr_base = _subway_stop_base(arr.station)
                if arr_base != base:
                    continue
                if arr.arrival_ts and arr.arrival_ts < now_ts:
                    continue
                color = _brand_subway_color(arr.route_id) or _brand_mode_color("subway")
                departures.append(NearbyTransitArrival(
                    route_id=arr.route_id,
                    stop_name=arr.station_name or stop_id,
                    direction=arr.direction,
                    destination=arr.destination,
                    minutes_away=max(0, arr.minutes_away),
                    arrival_ts=arr.arrival_ts,
                    status=arr.status,
                    mode="subway",
                    stop_lat=arr.stop_lat,
                    stop_lon=arr.stop_lon,
                    stop_id=arr.station,
                    trip_id=arr.trip_id,
                    is_real_time=True,
                    is_cancelled=arr.is_cancelled,
                    color_hex=color,
                ))

        elif label.startswith("bus:"):
            for arr in result:
                if hasattr(arr, "expected_arrival") and arr.expected_arrival:
                    arr_ts = int(arr.expected_arrival.timestamp())
                    if arr_ts < now_ts:
                        continue
                    mins = max(0, (arr_ts - now_ts) // 60)
                else:
                    arr_ts = None
                    mins = 0

                departures.append(NearbyTransitArrival(
                    route_id=arr.route_id,
                    stop_name=getattr(arr, "stop_name", None) or stop_id,
                    direction=getattr(arr, "destination_name", None) or "",
                    destination=getattr(arr, "destination_name", None),
                    minutes_away=mins,
                    arrival_ts=arr_ts,
                    status=getattr(arr, "status", "Live"),
                    mode="bus",
                    stop_id=getattr(arr, "stop_id", stop_id),
                    vehicle_id=getattr(arr, "vehicle_id", None),
                    is_real_time=getattr(arr, "is_realtime", True),
                    color_hex=_brand_mode_color("bus"),
                ))

        elif label in {"lirr", "mnr"}:
            mode = label
            for arr in result:
                arr_base = _subway_stop_base(arr.station)
                # Rail stop IDs can be strings — try exact + base match
                if arr.station != stop_id and arr_base != base:
                    continue
                if arr.arrival_ts and arr.arrival_ts < now_ts:
                    continue
                departures.append(NearbyTransitArrival(
                    route_id=arr.route_id,
                    stop_name=arr.station_name or stop_id,
                    direction=arr.direction,
                    destination=arr.destination,
                    minutes_away=max(0, arr.minutes_away),
                    arrival_ts=arr.arrival_ts,
                    status=arr.status,
                    mode=mode,
                    stop_lat=arr.stop_lat,
                    stop_lon=arr.stop_lon,
                    stop_id=arr.station,
                    trip_id=arr.trip_id,
                    is_real_time=True,
                    is_cancelled=arr.is_cancelled,
                    color_hex=_brand_mode_color(mode),
                ))

    # Sort by arrival time, then minutes_away
    departures.sort(key=lambda d: (d.arrival_ts or 9999999999, d.minutes_away))

    # Apply limit
    departures = departures[:limit]

    elapsed = _time.time() - t0
    TrackLogger.info(
        f"[DEPARTURES] stop={stop_id} modes={modes} → {len(departures)} departures in {elapsed:.2f}s",
        tag="DEPARTURES",
    )

    # Cache for 15 seconds (realtime data)
    response.headers["Cache-Control"] = "public, max-age=15"
    return departures
