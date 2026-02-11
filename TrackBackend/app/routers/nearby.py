#
# nearby.py
# TrackBackend
#
# Router for the unified nearby transit endpoint.
# Returns the nearest buses and trains with live countdowns,
# sorted by minutes away. No trips or routing — just arrivals.
#
# The ``/nearby/grouped`` endpoint collapses duplicate routes into a
# single card with swipeable direction sub-groups — so the iOS app
# shows one entry per route instead of eight "A" trains.
#

from __future__ import annotations

import asyncio
from collections import defaultdict
from datetime import datetime

from fastapi import APIRouter, Query

from app.models import DirectionArrivals, GroupedNearbyTransit, NearbyTransitArrival
from app.services.bus_client import get_nearby_stops, get_realtime_arrivals
from app.services.data_cleaner import get_arrivals_for_line
from app.utils.logger import TrackLogger

# Subway line → hex color mapping (official MTA colors).
_SUBWAY_COLORS: dict[str, str] = {
    "1": "#EE352E", "2": "#EE352E", "3": "#EE352E",
    "4": "#00933C", "5": "#00933C", "6": "#00933C",
    "7": "#B933AD",
    "A": "#0039A6", "C": "#0039A6", "E": "#0039A6",
    "B": "#FF6319", "D": "#FF6319", "F": "#FF6319", "M": "#FF6319",
    "G": "#6CBE45",
    "J": "#996633", "Z": "#996633",
    "L": "#A7A9AC",
    "N": "#FCCC0A", "Q": "#FCCC0A", "R": "#FCCC0A", "W": "#FCCC0A",
    "S": "#808183", "SI": "#808183",
}

router = APIRouter(tags=["nearby"])


@router.get("/nearby", response_model=list[NearbyTransitArrival])
async def nearby_transit(
    lat: float = Query(..., description="User latitude"),
    lon: float = Query(..., description="User longitude"),
    radius: int = Query(500, description="Search radius in meters"),
) -> list[NearbyTransitArrival]:
    """Return the nearest buses and trains with live countdowns.

    Combines subway arrivals from GTFS-RT feeds and bus arrivals from
    SIRI, sorted by ``minutes_away``. No routing or trips — just a
    flat list of what's arriving soon nearby.
    """
    TrackLogger.location(lat, lon, "nearby")
    results = await _collect_all(lat, lon)
    results.sort(key=lambda a: a.minutes_away)
    return results[:20]


@router.get("/nearby/grouped", response_model=list[GroupedNearbyTransit])
async def nearby_transit_grouped(
    lat: float = Query(..., description="User latitude"),
    lon: float = Query(..., description="User longitude"),
    radius: int = Query(500, description="Search radius in meters"),
) -> list[GroupedNearbyTransit]:
    """Return nearby arrivals grouped by route with direction sub-groups.

    Instead of showing eight separate "A" train entries, this endpoint
    returns one card per route. Each card contains a ``directions``
    list the iOS app can render as swipeable tabs (e.g. Northbound /
    Southbound).  The first arrival's ``minutes_away`` is used to sort
    the groups so the soonest route appears first.
    """
    TrackLogger.location(lat, lon, "nearby/grouped")
    flat = await _collect_all(lat, lon)
    return _group_arrivals(flat)


# ---------------------------------------------------------------------------
# Shared data collection
# ---------------------------------------------------------------------------


async def _collect_all(lat: float, lon: float) -> list[NearbyTransitArrival]:
    """Gather subway + bus arrivals in parallel."""
    results: list[NearbyTransitArrival] = []

    subway_task = _fetch_nearby_subway()
    bus_task = _fetch_nearby_buses(lat, lon)

    subway_results, bus_results = await asyncio.gather(
        subway_task, bus_task, return_exceptions=True,
    )

    if isinstance(subway_results, list):
        results.extend(subway_results)
    elif isinstance(subway_results, Exception):
        TrackLogger.error(f"Subway feed failed: {subway_results}")

    if isinstance(bus_results, list):
        results.extend(bus_results)
    elif isinstance(bus_results, Exception):
        TrackLogger.error(f"Bus feed failed: {bus_results}")

    return results


# ---------------------------------------------------------------------------
# Grouping logic
# ---------------------------------------------------------------------------


def _display_name(route_id: str) -> str:
    """Strip ``MTA NYCT_`` prefix for display."""
    if route_id.startswith("MTA NYCT_"):
        return route_id[9:]
    return route_id


def _group_arrivals(flat: list[NearbyTransitArrival]) -> list[GroupedNearbyTransit]:
    """Collapse a flat arrival list into one entry per route.

    Each route gets two direction buckets (e.g. "N" / "S" for subway,
    or the SIRI status text for buses).  Arrivals inside each direction
    are sorted by ``minutes_away``.
    """
    by_route: dict[str, dict[str, list[NearbyTransitArrival]]] = defaultdict(
        lambda: defaultdict(list),
    )
    route_meta: dict[str, tuple[str, str]] = {}  # route_id → (mode, display_name)

    for a in flat:
        by_route[a.route_id][a.direction].append(a)
        if a.route_id not in route_meta:
            route_meta[a.route_id] = (a.mode, _display_name(a.route_id))

    groups: list[GroupedNearbyTransit] = []
    for route_id, dir_map in by_route.items():
        mode, display = route_meta[route_id]
        color = _SUBWAY_COLORS.get(display.upper()) if mode == "subway" else None

        directions: list[DirectionArrivals] = []
        for direction, arrivals in dir_map.items():
            arrivals.sort(key=lambda a: a.minutes_away)
            directions.append(DirectionArrivals(direction=direction, arrivals=arrivals))

        # Sort directions alphabetically for consistency
        directions.sort(key=lambda d: d.direction)

        groups.append(
            GroupedNearbyTransit(
                route_id=route_id,
                display_name=display,
                mode=mode,
                color_hex=color,
                directions=directions,
            )
        )

    # Sort groups by the soonest arrival across all directions
    groups.sort(key=_soonest_minutes)

    return groups


def _soonest_minutes(group: GroupedNearbyTransit) -> int:
    """Return the smallest ``minutes_away`` across all directions."""
    mins = [
        a.minutes_away
        for d in group.directions
        for a in d.arrivals
    ]
    return min(mins) if mins else 999


# ---------------------------------------------------------------------------
# Subway helpers
# ---------------------------------------------------------------------------


async def _fetch_nearby_subway() -> list[NearbyTransitArrival]:
    """Fetch arrivals from all subway feeds and return as NearbyTransitArrival.

    Filters out arrivals with ``minutes_away == 0`` (already arrived /
    stale data) to avoid the "all times are 0" display bug.
    """
    results: list[NearbyTransitArrival] = []

    # Pick representative lines (one per feed) to avoid duplicate fetches
    feed_lines = ["A", "G", "N", "1", "B", "J", "L"]

    tasks = [get_arrivals_for_line(line) for line in feed_lines]
    feed_results = await asyncio.gather(*tasks, return_exceptions=True)

    success_count = 0
    for line, arrivals in zip(feed_lines, feed_results):
        if isinstance(arrivals, Exception):
            TrackLogger.error(f"Subway feed '{line}' failed: {arrivals}")
            continue
        if not isinstance(arrivals, list):
            continue
        success_count += 1
        for arrival in arrivals[:5]:  # Top 5 per feed
            # Skip stale arrivals that show 0 minutes (already arrived)
            if arrival.minutes_away <= 0:
                continue
            results.append(
                NearbyTransitArrival(
                    route_id=line,
                    stop_name=arrival.station,
                    direction=arrival.direction,
                    minutes_away=arrival.minutes_away,
                    status=arrival.status,
                    mode="subway",
                )
            )

    if success_count == 0 and len(feed_lines) > 0:
        TrackLogger.error(
            f"All {len(feed_lines)} subway feeds failed — check MTA API key and network"
        )

    return results


# ---------------------------------------------------------------------------
# Bus helpers
# ---------------------------------------------------------------------------


async def _fetch_nearby_buses(lat: float, lon: float) -> list[NearbyTransitArrival]:
    """Fetch live bus arrivals from nearby stops."""
    results: list[NearbyTransitArrival] = []

    try:
        stops = await get_nearby_stops(lat, lon)
    except Exception as exc:
        TrackLogger.error(f"Bus stops fetch failed: {exc}")
        return results

    if not stops:
        TrackLogger.info("No bus stops found within search radius")
        return results

    # Fetch arrivals for up to 3 nearest stops
    tasks = [get_realtime_arrivals(stop.id) for stop in stops[:3]]
    stop_results = await asyncio.gather(*tasks, return_exceptions=True)

    for i, arrivals in enumerate(stop_results):
        if isinstance(arrivals, Exception):
            stop_name = stops[i].name if i < len(stops) else "unknown"
            TrackLogger.error(f"Bus arrivals for stop '{stop_name}' failed: {arrivals}")
            continue
        if not isinstance(arrivals, list):
            continue
        stop = stops[i] if i < len(stops) else None
        stop_name = stop.name if stop else "Bus Stop"
        stop_lat = stop.lat if stop else None
        stop_lon = stop.lon if stop else None
        for arrival in arrivals:
            minutes = _bus_minutes_away(arrival.expected_arrival)
            results.append(
                NearbyTransitArrival(
                    route_id=arrival.route_id,
                    stop_name=stop_name,
                    direction=arrival.status_text,
                    minutes_away=minutes,
                    status=arrival.status_text,
                    mode="bus",
                    stop_lat=stop_lat,
                    stop_lon=stop_lon,
                )
            )

    return results


def _bus_minutes_away(expected: datetime | None) -> int:
    """Calculate minutes until a bus arrival."""
    if expected is None:
        return 99
    from datetime import timezone

    now = datetime.now(timezone.utc)
    if expected.tzinfo is None:
        expected = expected.replace(tzinfo=timezone.utc)
    diff = (expected - now).total_seconds()
    return max(0, int(diff // 60))
