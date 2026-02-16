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

from app.config import get_settings
from app.models import DirectionArrivals, GroupedNearbyTransit, NearbyTransitArrival
from app.services.bus_client import get_nearby_stops, get_realtime_arrivals
from app.services.data_cleaner import get_arrivals_for_line
from app.services.station_lookup import get_nearby_stop_ids, get_stop_info
from app.utils.logger import TrackLogger
from app.utils.transit_utils import get_subway_color
from app.services.schedule_service import schedule_service
from app.services.commuter_rail_shapes import (
    get_lirr_route_name,
    get_mnr_route_name,
    get_lirr_route_color,
    get_mnr_route_color,
)

# Default bus color (MTA blue) — used when bus routes don't provide one
_BUS_DEFAULT_COLOR = "#0039A6"

router = APIRouter(tags=["nearby"])


@router.get("/nearby", response_model=list[NearbyTransitArrival])
async def nearby_transit(
    lat: float = Query(..., description="User latitude"),
    lon: float = Query(..., description="User longitude"),
    radius: int | None = Query(None, description="Search radius in meters"),
) -> list[NearbyTransitArrival]:
    """Return the nearest buses and trains with live countdowns.

    Combines subway arrivals from GTFS-RT feeds and bus arrivals from
    SIRI, sorted by ``minutes_away``. No routing or trips — just a
    flat list of what's arriving soon nearby.
    """
    settings = get_settings()
    effective_radius = radius if radius is not None else settings.app_settings.search_radius_meters
    TrackLogger.location(lat, lon, "nearby")
    results = await _collect_all(lat, lon, effective_radius)
    results.sort(key=lambda a: a.minutes_away)
    return results[:settings.app_settings.max_nearby_results]


@router.get("/nearby/grouped", response_model=list[GroupedNearbyTransit])
async def nearby_transit_grouped(
    lat: float = Query(..., description="User latitude"),
    lon: float = Query(..., description="User longitude"),
    radius: int | None = Query(None, description="Search radius in meters"),
    mode: str | None = Query(None, description="Filter by transit mode: subway, bus, lirr, mnr"),
) -> list[GroupedNearbyTransit]:
    """Return nearby arrivals grouped by route with direction sub-groups.

    Instead of showing eight separate "A" train entries, this endpoint
    returns one card per route. Each card contains a ``directions``
    list the iOS app can render as swipeable tabs (e.g. Northbound /
    Southbound).  The first arrival's ``minutes_away`` is used to sort
    the groups so the soonest route appears first.
    
    The optional ``mode`` filter restricts results to a single transit mode
    (e.g. ``?mode=subway`` returns only subway groups, ``?mode=lirr`` for LIRR).
    """
    settings = get_settings()
    effective_radius = radius if radius is not None else settings.app_settings.search_radius_meters
    TrackLogger.location(lat, lon, "nearby/grouped")
    flat = await _collect_all(lat, lon, effective_radius, mode_filter=mode)
    return _group_arrivals(flat)


# ---------------------------------------------------------------------------
# Shared data collection
# ---------------------------------------------------------------------------


async def _collect_all(
    lat: float, lon: float, radius: int | None = None,
    *, mode_filter: str | None = None,
) -> list[NearbyTransitArrival]:
    """Gather subway + bus arrivals in parallel.
    
    When *mode_filter* is provided (e.g. ``"subway"``, ``"bus"``, ``"lirr"``,
    ``"mnr"``), only that mode is fetched — skipping unnecessary network
    calls for the other feeds.
    """
    settings = get_settings()
    effective_radius = radius if radius is not None else settings.app_settings.search_radius_meters
    results: list[NearbyTransitArrival] = []

    # Build task list based on mode filter
    tasks: dict[str, asyncio.Task] = {}
    if mode_filter is None or mode_filter == "subway":
        tasks["subway"] = asyncio.ensure_future(_fetch_nearby_subway(lat, lon, effective_radius))
    if mode_filter is None or mode_filter == "bus":
        tasks["bus"] = asyncio.ensure_future(_fetch_nearby_buses(lat, lon, effective_radius))
    if mode_filter is None or mode_filter == "lirr":
        tasks["lirr"] = asyncio.ensure_future(_fetch_nearby_rail(lat, lon, effective_radius, "lirr"))
    if mode_filter is None or mode_filter == "mnr":
        tasks["mnr"] = asyncio.ensure_future(_fetch_nearby_rail(lat, lon, effective_radius, "mnr"))

    task_results = await asyncio.gather(*tasks.values(), return_exceptions=True)
    
    for label, result in zip(tasks.keys(), task_results):
        if isinstance(result, list):
            results.extend(result)
        elif isinstance(result, Exception):
            TrackLogger.error(f"{label.upper()} feed failed: {result}")

    return results


# ---------------------------------------------------------------------------
# Grouping logic
# ---------------------------------------------------------------------------


def _display_name(route_id: str) -> str:
    """Build a user-facing display name for a route_id.
    
    Strips ``MTA NYCT_`` prefix for subway/bus and resolves LIRR/MNR
    numeric IDs to human-readable branch names.
    """
    if route_id.startswith("MTA NYCT_"):
        return route_id[9:]
    if route_id.startswith("LIRR_"):
        numeric = route_id[5:]
        return get_lirr_route_name(numeric)
    if route_id.startswith("MNR_"):
        numeric = route_id[4:]
        return get_mnr_route_name(numeric)
    return route_id


# Compass code → human-readable direction label
_DIRECTION_LABELS: dict[str, str] = {
    "N": "Northbound",
    "S": "Southbound",
    "E": "Eastbound",
    "W": "Westbound",
    "NE": "Northeast",
    "NW": "Northwest",
    "SE": "Southeast",
    "SW": "Southwest",
    "INBOUND": "Inbound",
    "OUTBOUND": "Outbound",
}


def _direction_label(direction: str) -> str:
    """Convert a raw direction code to a human-readable label.

    Returns the long-form label for known compass codes (e.g. "N" → "Northbound"),
    or the original string for destination names like "Far Rockaway".
    """
    return _DIRECTION_LABELS.get(direction.upper(), direction)


def _group_arrivals(flat: list[NearbyTransitArrival]) -> list[GroupedNearbyTransit]:
    """Collapse a flat arrival list into one entry per route.

    Each route gets direction buckets (e.g. "N" / "S" for subway,
    or compass directions like "SW" / "NE" for buses).  Arrivals
    inside each direction are sorted by ``minutes_away``.
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
        # Assign color: subway lines use the official palette,
        # LIRR/MNR use per-branch colors from routes.txt,
        # bus routes get the default MTA blue
        if mode == "subway":
            color = get_subway_color(display)
        elif mode == "lirr":
            # Extract numeric part from "LIRR_9" → "9"
            numeric_id = route_id[5:] if route_id.startswith("LIRR_") else route_id
            color = get_lirr_route_color(numeric_id)
        elif mode == "mnr":
            numeric_id = route_id[4:] if route_id.startswith("MNR_") else route_id
            color = get_mnr_route_color(numeric_id)
        else:
            color = _BUS_DEFAULT_COLOR

        directions: list[DirectionArrivals] = []
        for direction, arrivals in dir_map.items():
            arrivals.sort(key=lambda a: a.minutes_away)
            directions.append(DirectionArrivals(
                direction=direction,
                direction_label=_direction_label(direction),
                arrivals=arrivals,
            ))

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


async def _fetch_nearby_subway(
    lat: float, lon: float, radius: int,
) -> list[NearbyTransitArrival]:
    """Fetch arrivals from all subway feeds, filtered to nearby stations.

    Uses the GTFS stops.txt station database to determine which stop_ids
    are within the user's search radius, so we only return trains that
    are actually arriving at stations the user could walk to.
    """
    settings = get_settings()
    results: list[NearbyTransitArrival] = []

    # Pre-compute which stop_ids are within range of the user
    nearby_stops = get_nearby_stop_ids(lat, lon, float(radius))
    if not nearby_stops:
        TrackLogger.info(
            f"No subway stations within {radius}m of ({lat:.5f}, {lon:.5f})"
        )
        return results

    TrackLogger.info(
        f"Found {len(nearby_stops)} subway stop_ids within {radius}m"
    )

    # Pick representative lines (one per feed) to avoid duplicate fetches
    feed_lines = ["A", "G", "N", "1", "B", "J", "L"]

    tasks = [get_arrivals_for_line(line) for line in feed_lines]
    feed_results = await asyncio.gather(*tasks, return_exceptions=True)

    success_count = 0
    total_raw = 0
    total_kept = 0
    for line, arrivals in zip(feed_lines, feed_results):
        if isinstance(arrivals, Exception):
            TrackLogger.error(f"Subway feed '{line}' failed: {arrivals}")
            continue
        if not isinstance(arrivals, list):
            continue
        success_count += 1
        total_raw += len(arrivals)
        for arrival in arrivals:
            # Skip stale arrivals (already at station)
            if arrival.minutes_away <= 0:
                continue
            # Only keep arrivals at stops within range
            if arrival.station not in nearby_stops:
                continue

            # Resolve the human-readable station name and coordinates
            stop_info = get_stop_info(arrival.station)
            stop_name = stop_info.name if stop_info else arrival.station
            stop_lat = stop_info.lat if stop_info else None
            stop_lon = stop_info.lon if stop_info else None

            # Use the actual route_id from the GTFS-RT trip, not the feed line
            total_kept += 1
            
            # Use destination (e.g. "Wakefield-241 St") for direction label if available.
            # Otherwise fallback to "N"/"S" which frontend maps to North/Southbound.
            display_dir = arrival.destination if arrival.destination else arrival.direction
            
            results.append(
                NearbyTransitArrival(
                    route_id=arrival.route_id or line,
                    stop_name=stop_name,
                    direction=display_dir,
                    destination=arrival.destination,
                    minutes_away=arrival.minutes_away,
                    arrival_ts=arrival.arrival_ts,
                    status=arrival.status,
                    mode="subway",
                    stop_lat=stop_lat,
                    stop_lon=stop_lon,
                    stop_id=arrival.station,
                    trip_id=arrival.trip_id,
                )
            )

    if success_count == 0 and len(feed_lines) > 0:
        TrackLogger.error(
            f"All {len(feed_lines)} subway feeds failed — check MTA API key and network"
        )
    elif success_count > 0:
        TrackLogger.info(
            f"Subway: {success_count}/{len(feed_lines)} feeds OK, "
            f"{total_raw} raw → {total_kept} kept (nearby)"
        )

    # --- NEW: Fallback for stops with no live arrivals ---
    stops_with_live = {a.stop_id for a in results}
    missing_stops = nearby_stops - stops_with_live
    
    if missing_stops:
        TrackLogger.info(f"Filling in schedules for {len(missing_stops)} stops with no live data")
        for stop_id in missing_stops:
            scheduled = schedule_service.get_scheduled_arrivals(stop_id, limit=4)
            for s in scheduled:
                # Get stop coordinates for the model
                stop_info = get_stop_info(s.station)
                results.append(NearbyTransitArrival(
                    route_id=s.route_id,
                    stop_name=stop_info.name if stop_info else s.station,
                    direction=s.destination or s.direction,
                    destination=s.destination,
                    minutes_away=s.minutes_away,
                    arrival_ts=s.arrival_ts,
                    status="Scheduled",
                    mode="subway",
                    stop_lat=stop_info.lat if stop_info else None,
                    stop_lon=stop_info.lon if stop_info else None,
                    stop_id=s.station,
                    trip_id=s.trip_id
                ))

    return results


# ---------------------------------------------------------------------------
# Bus helpers
# ---------------------------------------------------------------------------


async def _fetch_nearby_buses(
    lat: float, lon: float, radius: int | None = None,
) -> list[NearbyTransitArrival]:
    """Fetch live bus arrivals from nearby stops."""
    settings = get_settings()
    effective_radius = radius if radius is not None else settings.app_settings.search_radius_meters
    results: list[NearbyTransitArrival] = []

    try:
        stops = await get_nearby_stops(lat, lon, radius_m=effective_radius)
    except Exception as exc:
        TrackLogger.error(f"Bus stops fetch failed: {exc}")
        return results

    if not stops:
        TrackLogger.info("No bus stops found within search radius")
        return results

    tasks = [get_realtime_arrivals(stop.id) for stop in stops[: settings.app_settings.max_nearby_results]]
    stop_results = await asyncio.gather(*tasks, return_exceptions=True)

    for i, result in enumerate(stop_results):
        stop = stops[i]
        if isinstance(result, Exception):
            TrackLogger.error(f"Bus arrivals for {stop.name} failed: {result}")
            continue
        
        # result is a list[BusArrival]
        for arrival in result:
            minutes = _bus_minutes_away(arrival.expected_arrival)
            results.append(
                NearbyTransitArrival(
                    route_id=arrival.route_id,
                    stop_name=stop.name,
                    arrival_ts=int(arrival.expected_arrival.timestamp()) if arrival.expected_arrival else None,
                    direction=stop.direction or "Loop",
                    minutes_away=minutes,
                    status=arrival.status_text,
                    mode="bus",
                    stop_lat=stop.lat,
                    stop_lon=stop.lon,
                    stop_id=stop.id,
                    vehicle_id=arrival.vehicle_id,
                    destination=arrival.status_text # Use status as destination for now
                )
            )

    return results



# ---------------------------------------------------------------------------
# Rail helpers
# ---------------------------------------------------------------------------


async def _fetch_nearby_rail(
    lat: float, lon: float, radius: int, agency: str
) -> list[NearbyTransitArrival]:
    """Fetch arrivals for LIRR or Metro-North, filtered to nearby stations."""
    from app.services.rail_client import fetch_rail_arrivals
    
    results: list[NearbyTransitArrival] = []
    
    # Map agency parameter to the feed name used by rail_client
    feed_agency = agency
    if agency == "mnr":
        feed_agency = "metro_north"
    
    # Determine prefix for route_id namespacing (e.g. "LIRR_9", "MNR_1")
    prefix = "LIRR_" if agency == "lirr" else "MNR_"
    
    # Pre-compute which stop_ids are within range of the user for this agency
    nearby_stops = get_nearby_stop_ids(lat, lon, float(radius), agency=agency)
    if not nearby_stops:
        return results

    try:
        arrivals = await fetch_rail_arrivals(feed_agency)
    except Exception as exc:
        TrackLogger.error(f"{agency.upper()} feed failed: {exc}")
        return results

    for arrival in arrivals:
        if arrival.station not in nearby_stops:
            continue
            
        stop_info = get_stop_info(arrival.station)
        
        # Prefix route_id so client can distinguish LIRR "9" from subway "9"
        prefixed_route_id = f"{prefix}{arrival.route_id}"
        
        results.append(
            NearbyTransitArrival(
                route_id=prefixed_route_id,
                stop_name=stop_info.name if stop_info else arrival.station,
                direction=arrival.destination or arrival.direction,
                destination=arrival.destination,
                minutes_away=arrival.minutes_away,
                arrival_ts=arrival.arrival_ts,
                status=arrival.status,
                mode=agency,
                stop_lat=stop_info.lat if stop_info else None,
                stop_lon=stop_info.lon if stop_info else None,
                stop_id=arrival.station,
                trip_id=arrival.trip_id,
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
