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
import csv
from collections import defaultdict
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

from fastapi import APIRouter, Query

from app.cache_config import (
    BUS_MAX_SIRI_STOPS,
    NEARBY_GPS_DECIMALS,
    NEARBY_RESPONSE_FRESH_TTL,
    NEARBY_RESPONSE_MAX_SIZE,
    NEARBY_RESPONSE_STALE_TTL,
)
from app.config import get_settings
from app.models import BusStop, DirectionArrivals, GroupedNearbyTransit, NearbyTransitArrival
from app.services.bus_client import (
    get_nearby_stops,
    get_realtime_arrivals,
    get_routes as get_all_bus_routes,
    get_stops as get_bus_route_stops,
    BUS_AGENCY_PREFIXES,
)
from app.services.data_cleaner import get_arrivals_for_line
from app.services.station_lookup import get_nearby_stop_ids, get_stop_info
from app.utils.geo_utils import haversine_m
from app.utils.logger import TrackLogger
from app.utils.transit_utils import get_subway_color
from app.services.schedule_service import schedule_service
from app.services.rail_client import fetch_rail_arrivals
from app.services.subway_shapes import get_stops_for_route as get_subway_stops_for_route
from app.services.commuter_rail_shapes import (
    get_lirr_route_name,
    get_mnr_route_name,
    get_lirr_route_color,
    get_mnr_route_color,
)

# Default bus color (MTA blue) — used when bus routes don't provide one
_BUS_DEFAULT_COLOR = "#0039A6"

# Placeholder minutes_away value — sorts to the bottom within its distance tier
_PLACEHOLDER_MINUTES = 99

_BUS_STATIC_GTFS_ROOT = Path(__file__).resolve().parent.parent / "data" / "bus"


def _canonical_bus_stop_id(stop_id: str) -> str:
    sid = (stop_id or "").strip()
    if sid.startswith("MTA_"):
        sid = sid[4:]
    return sid


@lru_cache(maxsize=1)
def _load_static_bus_route_stop_index() -> dict[str, tuple[float, float, str, set[str]]]:
    """Load local GTFS bus files into stop_id -> (lat, lon, name, {route_short})."""
    index: dict[str, tuple[float, float, str, set[str]]] = {}
    if not _BUS_STATIC_GTFS_ROOT.exists():
        return index

    for borough_dir in _BUS_STATIC_GTFS_ROOT.iterdir():
        if not borough_dir.is_dir():
            continue

        routes_path = borough_dir / "routes.txt"
        trips_path = borough_dir / "trips.txt"
        stops_path = borough_dir / "stops.txt"
        stop_times_path = borough_dir / "stop_times.txt"
        if not (routes_path.exists() and trips_path.exists() and stops_path.exists() and stop_times_path.exists()):
            continue

        route_id_to_short: dict[str, str] = {}
        with open(routes_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                route_id = (row.get("route_id") or "").strip()
                route_short = (row.get("route_short_name") or route_id).strip()
                if route_id:
                    route_id_to_short[route_id] = route_short

        trip_to_route_short: dict[str, str] = {}
        with open(trips_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                trip_id = (row.get("trip_id") or "").strip()
                route_id = (row.get("route_id") or "").strip()
                if trip_id and route_id:
                    short = route_id_to_short.get(route_id, route_id)
                    trip_to_route_short[trip_id] = short

        stop_meta: dict[str, tuple[float, float, str]] = {}
        with open(stops_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                stop_id = _canonical_bus_stop_id((row.get("stop_id") or "").strip())
                if not stop_id:
                    continue
                try:
                    lat = float(row.get("stop_lat") or 0.0)
                    lon = float(row.get("stop_lon") or 0.0)
                except ValueError:
                    continue
                stop_name = (row.get("stop_name") or stop_id).strip()
                stop_meta[stop_id] = (lat, lon, stop_name)

        stop_routes: dict[str, set[str]] = defaultdict(set)
        with open(stop_times_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                stop_id = _canonical_bus_stop_id((row.get("stop_id") or "").strip())
                trip_id = (row.get("trip_id") or "").strip()
                if not stop_id or not trip_id:
                    continue
                route_short = trip_to_route_short.get(trip_id)
                if route_short:
                    stop_routes[stop_id].add(route_short)

        for stop_id, routes in stop_routes.items():
            meta = stop_meta.get(stop_id)
            if not meta:
                continue
            lat, lon, name = meta
            if stop_id in index:
                existing_lat, existing_lon, existing_name, existing_routes = index[stop_id]
                existing_routes.update(routes)
                index[stop_id] = (existing_lat, existing_lon, existing_name, existing_routes)
            else:
                index[stop_id] = (lat, lon, name, set(routes))

    TrackLogger.bus(f"Static bus fallback index loaded: {len(index)} stops")
    return index


def _nearby_static_bus_routes(lat: float, lon: float, radius_m: int) -> dict[str, tuple[str, float, float, str]]:
    """Return route_short -> (stop_name, stop_lat, stop_lon, stop_id) for nearest nearby static stop."""
    index = _load_static_bus_route_stop_index()
    if not index:
        return {}

    _METERS_PER_DEG_LAT = 111_000
    _METERS_PER_DEG_LON_NYC = 85_000
    lat_span = radius_m / _METERS_PER_DEG_LAT
    lon_span = radius_m / _METERS_PER_DEG_LON_NYC

    best_by_route: dict[str, tuple[float, tuple[str, float, float, str]]] = {}
    for stop_id, (s_lat, s_lon, s_name, routes) in index.items():
        if abs(s_lat - lat) > lat_span or abs(s_lon - lon) > lon_span:
            continue
        distance = haversine_m(lat, lon, s_lat, s_lon)
        if distance > radius_m:
            continue
        for route in routes:
            current = best_by_route.get(route)
            payload = (s_name, s_lat, s_lon, stop_id)
            if current is None or distance < current[0]:
                best_by_route[route] = (distance, payload)

    return {route: data for route, (_distance, data) in best_by_route.items()}


def _route_prefix(route_id: str) -> str:
    chars: list[str] = []
    for ch in route_id:
        if ch.isalpha():
            chars.append(ch.upper())
        else:
            break
    return "".join(chars)


# ---------------------------------------------------------------------------
# Response-level cache for /nearby/grouped
# ---------------------------------------------------------------------------
# Caches the final assembled list[GroupedNearbyTransit] so that repeat
# requests from the same ~111m GPS grid cell skip ALL upstream calls
# and processing.  Uses stale-while-revalidate: serve stale instantly
# and kick a background refresh so the next request gets fresh data.

_nearby_resp_cache: dict[
    tuple[float, float, int, str | None],  # (rounded_lat, rounded_lon, radius, mode)
    tuple[float, list["GroupedNearbyTransit"]],  # (timestamp, result)
] = {}
_nearby_resp_inflight: dict[tuple, asyncio.Task] = {}


def clear_nearby_cache() -> int:
    """Clear the response-level cache. Returns number of entries cleared."""
    count = len(_nearby_resp_cache)
    _nearby_resp_cache.clear()
    _nearby_resp_inflight.clear()
    return count


def _nearby_cache_key(
    lat: float, lon: float, radius: int, mode: str | None
) -> tuple[float, float, int, str | None]:
    """Round GPS to ~111m grid cells for cache bucketing."""
    factor = 10 ** NEARBY_GPS_DECIMALS
    return (round(lat * factor) / factor, round(lon * factor) / factor, radius, mode)


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
    return results


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
    import time as _time

    settings = get_settings()
    effective_radius = radius if radius is not None else settings.app_settings.search_radius_meters
    TrackLogger.location(lat, lon, "nearby/grouped")

    key = _nearby_cache_key(lat, lon, effective_radius, mode)
    now = _time.time()

    # 1. Check cache
    cached = _nearby_resp_cache.get(key)
    if cached is not None:
        ts, data = cached
        age = now - ts
        if age < NEARBY_RESPONSE_FRESH_TTL:
            TrackLogger.cache(f"RESP HIT (fresh {age:.1f}s) /nearby/grouped")
            return data
        if age < NEARBY_RESPONSE_STALE_TTL:
            TrackLogger.cache(f"RESP HIT (stale {age:.1f}s) /nearby/grouped — bg refresh")
            # Kick background refresh if not already in-flight
            if key not in _nearby_resp_inflight:
                async def _bg_refresh(k: tuple, r: int, m: str | None) -> None:
                    try:
                        flat = await _collect_all(k[0], k[1], r, mode_filter=m)
                        grouped = _group_arrivals(flat)
                        _nearby_resp_cache[k] = (_time.time(), grouped)
                    except Exception as exc:
                        TrackLogger.error(f"BG refresh /nearby/grouped failed: {exc}")
                    finally:
                        _nearby_resp_inflight.pop(k, None)
                task = asyncio.create_task(_bg_refresh(key, effective_radius, mode))
                _nearby_resp_inflight[key] = task
            return data

    # 2. Cache miss — full fetch
    flat = await _collect_all(lat, lon, effective_radius, mode_filter=mode)
    grouped = _group_arrivals(flat)

    # Evict if over size
    if len(_nearby_resp_cache) >= NEARBY_RESPONSE_MAX_SIZE:
        oldest_key = min(_nearby_resp_cache, key=lambda k: _nearby_resp_cache[k][0])
        del _nearby_resp_cache[oldest_key]

    _nearby_resp_cache[key] = (now, grouped)
    return grouped


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
    import time as _t
    _t0 = _t.perf_counter()
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
    _elapsed = _t.perf_counter() - _t0
    
    _mode_times: dict[str, str] = {}
    for label, result in zip(tasks.keys(), task_results):
        if isinstance(result, list):
            results.extend(result)
            _mode_times[label] = f"{len(result)} items"
        elif isinstance(result, Exception):
            TrackLogger.error(f"{label.upper()} feed failed: {result}")
            _mode_times[label] = f"FAILED"
    
    TrackLogger.info(
        f"⏱ _collect_all wall={_elapsed:.3f}s radius={effective_radius}m "
        f"mode={mode_filter or 'all'} → {_mode_times}"
    )

    # Guardrail: never return empty route IDs to clients.
    # Keep canonical IDs for rail/subway; only strip bus agency prefixes.
    sanitised: list[NearbyTransitArrival] = []
    dropped_empty_route_id = 0
    for arrival in results:
        raw_route = (arrival.route_id or "").strip()
        if not raw_route:
            dropped_empty_route_id += 1
            continue
        if arrival.mode == "bus":
            normalised_route = _display_name(raw_route).strip()
            if not normalised_route:
                dropped_empty_route_id += 1
                continue
            arrival.route_id = normalised_route
        else:
            arrival.route_id = raw_route
        sanitised.append(arrival)
    results = sanitised

    if dropped_empty_route_id:
        TrackLogger.warning(
            f"Dropped {dropped_empty_route_id} nearby arrivals with empty route_id"
        )

    # Populate distance_m (haversine from user to each stop) so the iOS
    # client can sort/bucket by accurate distance without recomputing.
    for r in results:
        if r.stop_lat is not None and r.stop_lon is not None:
            r.distance_m = round(haversine_m(lat, lon, r.stop_lat, r.stop_lon), 1)

    return results


# ---------------------------------------------------------------------------
# Grouping logic
# ---------------------------------------------------------------------------


def _display_name(route_id: str) -> str:
    """Build a user-facing display name for a route_id.
    
    Strips agency prefixes for subway/bus using the data-driven
    ``BUS_AGENCY_PREFIXES`` set (built from early_2026_buses_tag.json
    at import time).  This automatically supports any new agency
    prefix the MTA introduces without code changes.
    
    Currently known bus prefixes: ``MTA NYCT_``, ``MTABC_``, ``MTA BUS_``.
    LIRR/MNR numeric IDs are resolved to human-readable branch names.
    """
    # Bus / subway: strip any known agency prefix
    for prefix in BUS_AGENCY_PREFIXES:
        if route_id.startswith(prefix):
            return route_id[len(prefix):]

    # LIRR / MNR: resolve numeric branch IDs
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
    "0": "Direction A",
    "1": "Direction B",
    "2": "Direction C",
    "3": "Direction D",
    "N/A": "All Directions",
    "LOOP": "Loop",
    "OPPOSITE": "Opposite Direction",
}

# SIRI numeric direction keys (DirectionRef: 0/1 live, 2/3 backfill branches)
_NUMERIC_DIR_KEYS = {"0", "1", "2", "3"}

# Fallback direction key for Phase C when no terminal/compass can be inferred
# (requested UX: use Inbound/Outbound terminology, not "Opposite").
_OPPOSITE_DIRECTION = "Outbound"


def _is_fallback_direction_key(direction: str) -> bool:
    """True when a direction key is compass/numeric/generic fallback.

    Destination-name keys (e.g. "JFK AIRPORT TRAVEL PLAZA via ROCKAWAY BL")
    return False.
    """
    upper = direction.upper()
    return (
        upper in _DIRECTION_LABELS
        or upper in _NUMERIC_DIR_KEYS
        or upper == _OPPOSITE_DIRECTION.upper()
    )


def _direction_label(direction: str, arrivals: list[NearbyTransitArrival] | None = None) -> str:
    """Convert a raw direction code to a human-readable label.

    Returns the long-form label for known compass codes (e.g. "N" → "Northbound"),
    or the original string for destination names like "Far Rockaway".
    
    For subway routes grouped by "N"/"S", appends unique destination names
    (e.g. "Northbound → Inwood-207 St") so the user sees where trains go.

    For bus routes the direction key is now the SIRI DestinationName
    (e.g. "KINGS PLAZA", "AV H"), so it already carries meaning.
    We title-case it for a clean display label.

    Legacy numeric keys ("0"/"1" from DirectionRef) are still handled
    when DestinationName was unavailable; in that case we try to pull
    the destination from the first arrival in the group.
    """
    # Best-effort terminal name for this direction bucket.
    # Prefer the soonest arrival's destination because it reflects what the
    # user sees as "where this direction goes".
    def _primary_destination(items: list[NearbyTransitArrival] | None) -> str | None:
        if not items:
            return None
        ordered = sorted(items, key=lambda a: a.minutes_away)
        for a in ordered:
            if a.destination and a.destination.strip() and a.destination.strip().lower() != "unknown":
                return a.destination.strip()
        return None

    terminal = _primary_destination(arrivals)
    mode = arrivals[0].mode if arrivals else None

    # For legacy numeric direction keys (DirectionRef fallback),
    # try to get the destination from the first arrival.
    if direction in _NUMERIC_DIR_KEYS and arrivals:
        if terminal:
            return terminal
        return _DIRECTION_LABELS.get(direction, f"Direction {direction}")

    upper = direction.upper()

    # Known compass / special codes → canonical label
    if upper in _DIRECTION_LABELS:
        base_label = _DIRECTION_LABELS[upper]
        if mode == "bus":
            return base_label
        if terminal:
            return f"{base_label} → {terminal}"
        return base_label

    # Destination-name keys (e.g. "KINGS PLAZA") → title-case for display
    return direction.title()


def _opposite_direction_key(mode: str, direction: str) -> str | None:
    """Infer the opposite direction key for placeholder backfill.

    Used when a grouped route currently has only one direction bucket.
    This keeps route cards swipeable and avoids transient one-direction
    cards when one side has no immediate arrivals.
    """
    upper = direction.upper()

    # Compass and commuter-rail canonical pairs
    opposite_map = {
        "N": "S", "S": "N", "E": "W", "W": "E",
        "NE": "SW", "SW": "NE", "NW": "SE", "SE": "NW",
        "INBOUND": "Outbound", "OUTBOUND": "Inbound",
        "0": "1", "1": "0", "2": "3", "3": "2",
    }
    if upper in opposite_map:
        return opposite_map[upper]

    # Destination-name direction keys (common on bus branches)
    if mode == "bus":
        return _OPPOSITE_DIRECTION

    # Subway / rail fallback if no canonical opposite can be inferred
    if mode in {"subway", "lirr", "mnr"}:
        return _OPPOSITE_DIRECTION

    return None


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
    single_direction_before = 0
    single_direction_after = 0

    def _has_live_arrivals(direction_group: DirectionArrivals) -> bool:
        return any(a.minutes_away < _PLACEHOLDER_MINUTES for a in direction_group.arrivals)

    def _direction_sort_key(direction_group: DirectionArrivals) -> tuple[int, int, int, str]:
        direction = direction_group.direction
        has_live = _has_live_arrivals(direction_group)
        is_fallback = _is_fallback_direction_key(direction)
        return (
            0 if not is_fallback else 1,
            0 if has_live else 1,
            0,
            direction.upper(),
        )

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
                direction_label=_direction_label(direction, arrivals),
                arrivals=arrivals,
            ))

        if len(directions) == 1:
            single_direction_before += 1

            primary = directions[0]
            allow_opposite_placeholder = True

            opposite = _opposite_direction_key(mode, primary.direction)
            if (
                allow_opposite_placeholder
                and opposite
                and opposite != primary.direction
                and opposite not in dir_map
            ):
                exemplar = primary.arrivals[0] if primary.arrivals else None
                placeholder = NearbyTransitArrival(
                    route_id=route_id,
                    stop_name=exemplar.stop_name if exemplar else display,
                    direction=opposite,
                    destination=None,
                    minutes_away=_PLACEHOLDER_MINUTES,
                    arrival_ts=None,
                    status="Scheduled",
                    mode=mode,
                    stop_lat=exemplar.stop_lat if exemplar else None,
                    stop_lon=exemplar.stop_lon if exemplar else None,
                    stop_id=exemplar.stop_id if exemplar else None,
                    vehicle_id=None,
                    trip_id=None,
                    distance_m=exemplar.distance_m if exemplar else None,
                )
                directions.append(DirectionArrivals(
                    direction=opposite,
                    direction_label=_direction_label(opposite, [placeholder]),
                    arrivals=[placeholder],
                ))

        if len(directions) == 1:
            single_direction_after += 1

        # Prioritise terminal/live directions before fallback placeholders
        # (prevents transient "Outbound" tabs from becoming the default tab).
        directions.sort(key=_direction_sort_key)

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

    if single_direction_before:
        TrackLogger.info(
            f"Grouped routes with 1 direction: before={single_direction_before}, after={single_direction_after}"
        )

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
    # agency="subway" ensures LIRR/MNR stops are excluded at the source
    nearby_stops = get_nearby_stop_ids(lat, lon, float(radius), agency="subway")
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
            
            # For subway, keep the compass direction ("N"/"S") as the grouping
            # key only as fallback. Prefer destination to preserve branch-specific
            # direction tabs (supports 3+ direction cases naturally).
            # If destination is missing, fall back to compass direction.
            direction_key = arrival.destination or arrival.direction
            
            results.append(
                NearbyTransitArrival(
                    route_id=arrival.route_id or line,
                    stop_name=stop_name,
                    direction=direction_key,
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

    # --- Fallback for stops with no live arrivals ---
    # IMPORTANT: only backfill subway stops — skip LIRR/MNR stops that
    # may share numeric stop_ids (e.g. "183" is both subway and LIRR).
    # LIRR/MNR have their own dedicated _fetch_nearby_rail() path.
    stops_with_live = {a.stop_id for a in results}
    missing_stops = nearby_stops - stops_with_live
    
    if missing_stops:
        backfill_count = 0
        for stop_id in missing_stops:
            # Check if this is actually a subway stop (not LIRR/MNR)
            stop_info = get_stop_info(stop_id)
            if stop_info and stop_info.agency in ("lirr", "mnr"):
                continue  # Skip — handled by _fetch_nearby_rail

            scheduled = schedule_service.get_scheduled_arrivals(stop_id, limit=4)
            for s in scheduled:
                # Extra guard: skip if trip_id hints at commuter rail
                if s.trip_id and ("GO103" in s.trip_id or "METS" in s.trip_id):
                    continue
                # Skip numeric-only route_ids — subway routes are letters/letter-combos
                # (A, 1, 7, GS, SI, FS) not multi-digit branch numbers like "8", "9"
                if s.route_id.isdigit() and int(s.route_id) > 7:
                    continue

                sinfo = get_stop_info(s.station)
                # For subway scheduled arrivals, use compass direction ("N"/"S")
                # as fallback key; prefer destination when present.
                sched_dir = s.destination or s.direction
                results.append(NearbyTransitArrival(
                    route_id=s.route_id,
                    stop_name=sinfo.name if sinfo else s.station,
                    direction=sched_dir,
                    destination=s.destination,
                    minutes_away=s.minutes_away,
                    arrival_ts=s.arrival_ts,
                    status="Scheduled",
                    mode="subway",
                    stop_lat=sinfo.lat if sinfo else None,
                    stop_lon=sinfo.lon if sinfo else None,
                    stop_id=s.station,
                    trip_id=s.trip_id
                ))
                backfill_count += 1

        if backfill_count:
            TrackLogger.info(f"Backfilled {backfill_count} subway schedule entries for {len(missing_stops)} stops")

    # -----------------------------------------------------------------
    # Nearest-stop anchor (same concept as bus Phase D)
    #
    # Ensures every subway route has at least one entry at the closest
    # nearby stop it serves — even when no train is arriving there.
    # Without this, `groupMinDistance` on the client measures distance
    # to a farther stop where a train happens to be arriving, causing
    # the route to appear in the wrong distance tier.
    # -----------------------------------------------------------------
    # Track which stop_ids each route already has entries for
    route_stop_ids: dict[str, set[str]] = defaultdict(set)
    nearest_entry_dist: dict[str, float] = {}
    for r in results:
        if r.stop_id:
            route_stop_ids[r.route_id].add(r.stop_id)
        if r.stop_lat is not None and r.stop_lon is not None:
            d = haversine_m(lat, lon, r.stop_lat, r.stop_lon)
            if r.route_id not in nearest_entry_dist or d < nearest_entry_dist[r.route_id]:
                nearest_entry_dist[r.route_id] = d

    anchor_count = 0
    route_ids_in_results = set(nearest_entry_dist.keys())
    for route_id in route_ids_in_results:
        # Get ALL stop_ids this subway route serves
        all_route_stops = get_subway_stops_for_route(route_id)
        if not all_route_stops:
            continue

        # Find the nearest stop on this route that's within the search radius
        best_stop_id: str | None = None
        best_dist = nearest_entry_dist.get(route_id, float("inf"))

        for stop_id in all_route_stops:
            # Skip if already represented
            if stop_id in route_stop_ids[route_id]:
                continue
            info = get_stop_info(stop_id)
            if info is None:
                continue
            d = haversine_m(lat, lon, info.lat, info.lon)
            if d <= radius and d < best_dist:
                best_dist = d
                best_stop_id = stop_id

        if best_stop_id is not None:
            info = get_stop_info(best_stop_id)
            if info:
                # Determine direction from stop_id suffix (N/S)
                direction = "N" if best_stop_id.endswith("N") else "S"
                results.append(NearbyTransitArrival(
                    route_id=route_id,
                    stop_name=info.name,
                    direction=direction,
                    destination=None,
                    minutes_away=_PLACEHOLDER_MINUTES,
                    arrival_ts=None,
                    status="Scheduled",
                    mode="subway",
                    stop_lat=info.lat,
                    stop_lon=info.lon,
                    stop_id=best_stop_id,
                    trip_id=None,
                ))
                route_stop_ids[route_id].add(best_stop_id)
                anchor_count += 1

    if anchor_count:
        TrackLogger.info(
            f"Subway: Added {anchor_count} nearest-stop anchors "
            f"(routes had arrivals only at farther stops)"
        )

    return results


# ---------------------------------------------------------------------------
# Bus helpers
# ---------------------------------------------------------------------------


async def _fetch_nearby_buses(
    lat: float, lon: float, radius: int | None = None,
) -> list[NearbyTransitArrival]:
    """Fetch bus arrivals from nearby stops.

    First collects live SIRI arrivals for every nearby stop.  Then,
    for any route that serves a nearby stop but has **no** live data,
    creates a placeholder entry so the route still appears in the
    dashboard (categorised by distance tier).  This ensures the user
    sees *all* bus service in their area, not just buses that happen to
    be approaching right now.
    """
    settings = get_settings()
    effective_radius = radius if radius is not None else settings.app_settings.search_radius_meters
    results: list[NearbyTransitArrival] = []

    def _add_static_only_placeholders(reason: str) -> list[NearbyTransitArrival]:
        static_routes = _nearby_static_bus_routes(lat, lon, effective_radius)
        placeholders: list[NearbyTransitArrival] = []
        for route_id, (stop_name, stop_lat, stop_lon, stop_id) in static_routes.items():
            placeholders.append(
                NearbyTransitArrival(
                    route_id=route_id,
                    stop_name=stop_name,
                    arrival_ts=None,
                    direction="N/A",
                    minutes_away=_PLACEHOLDER_MINUTES,
                    status="Scheduled",
                    mode="bus",
                    stop_lat=stop_lat,
                    stop_lon=stop_lon,
                    stop_id=f"MTA_{stop_id}",
                    vehicle_id=None,
                    destination=None,
                )
            )

        TrackLogger.bus(
            f"Bus static fallback: added {len(placeholders)} routes ({reason})"
        )
        return placeholders

    import time as _t
    _t_oba = _t.perf_counter()
    try:
        stops = await get_nearby_stops(lat, lon, radius_m=effective_radius)
    except Exception as exc:
        TrackLogger.error(f"Bus stops fetch failed: {exc}")
        return _add_static_only_placeholders("nearby-stop lookup failed")
    _oba_ms = (_t.perf_counter() - _t_oba) * 1000

    if not stops:
        TrackLogger.info("No bus stops found within search radius")
        return _add_static_only_placeholders("no nearby OBA stops")

    # -----------------------------------------------------------------
    # 0. Sort stops by distance so nearest are queried first / within cap
    # -----------------------------------------------------------------
    # OBA's stops-for-location does NOT guarantee distance ordering.
    # Sorting ensures the _MAX_SIRI_STOPS cap always keeps the closest
    # stops and that `closest_stops_by_route` picks the truly nearest one.
    stops.sort(key=lambda s: haversine_m(lat, lon, s.lat, s.lon))
    TrackLogger.info(
        f"⏱ BUS OBA stops: {len(stops)} found in {_oba_ms:.0f}ms "
        f"(querying {min(len(stops), BUS_MAX_SIRI_STOPS)} via SIRI)"
    )

    # -----------------------------------------------------------------
    # 1. Fetch live SIRI arrivals for every nearby stop
    # -----------------------------------------------------------------
    # Query ALL nearby stops (not truncated by max_nearby_results) so that
    # both directions of a route are captured even when the opposite-direction
    # stop is farther away in the sorted list.
    # Safety cap to avoid hammering the MTA API in extremely
    # dense areas; generous enough to cover both sides of a street
    # for all routes in the search radius.
    stops_to_query = stops[:BUS_MAX_SIRI_STOPS]
    tasks = [get_realtime_arrivals(stop.id) for stop in stops_to_query]
    _t_siri = _t.perf_counter()
    stop_results = await asyncio.gather(*tasks, return_exceptions=True)
    _siri_ms = (_t.perf_counter() - _t_siri) * 1000
    TrackLogger.info(
        f"⏱ BUS SIRI: {len(stops_to_query)} stops fetched in {_siri_ms:.0f}ms"
    )

    # Track which route IDs already have live data
    routes_with_live: set[str] = set()

    fail_count = 0
    first_error: Exception | None = None
    for i, result in enumerate(stop_results):
        stop = stops_to_query[i]
        if isinstance(result, Exception):
            fail_count += 1
            if first_error is None:
                first_error = result
            continue
        
        # result is a list[BusArrival]
        for arrival in result:
            # Skip arrivals in the past
            if arrival.expected_arrival:
                now_utc = datetime.now(timezone.utc)
                exp_utc = arrival.expected_arrival
                if exp_utc.tzinfo is None:
                    exp_utc = exp_utc.replace(tzinfo=timezone.utc)
                
                # Allow 1 minute grace period for "Just Moved"
                if (exp_utc - now_utc).total_seconds() < -60:
                    continue

            minutes = _bus_minutes_away(arrival.expected_arrival)

            # Normalise route_id — SIRI sometimes gives "B63" (PublishedLineName)
            # and sometimes "MTA NYCT_B63" (LineRef fallback).  Stripping the
            # agency prefix guarantees both directions of the same route land in
            # the same grouped card.
            normalised_route = _display_name(arrival.route_id)

            # Direction grouping — use the same strategy as subway:
            # prefer the destination name as the direction key so that
            # BRANCHING routes get separate swipeable tabs per terminal.
            #
            # Examples (B46 Utica Ave):
            #   dest="KINGS PLAZA"    → direction key "KINGS PLAZA"
            #   dest="AV H"          → direction key "AV H"
            #   dest="WILLIAMSBURG"   → direction key "WILLIAMSBURG"
            #
            # This mirrors how subway uses destination ("Far Rockaway",
            # "Lefferts Blvd") so the A train gets one tab per branch.
            #
            # Fallback chain: DestinationName → DirectionRef → stop compass → "Loop"
            dest = arrival.destination_name
            if dest:
                direction = dest
            elif arrival.direction_ref is not None:
                direction = str(arrival.direction_ref)
            elif stop.direction:
                direction = stop.direction
            else:
                direction = "Loop"

            routes_with_live.add(normalised_route)
            # Also track the raw form for the backfill check
            routes_with_live.add(arrival.route_id)

            results.append(
                NearbyTransitArrival(
                    route_id=normalised_route,
                    stop_name=stop.name,
                    arrival_ts=int(arrival.expected_arrival.timestamp()) if arrival.expected_arrival else None,
                    direction=direction,
                    minutes_away=minutes,
                    status=arrival.status_text,
                    mode="bus",
                    stop_lat=stop.lat,
                    stop_lon=stop.lon,
                    stop_id=stop.id,
                    vehicle_id=arrival.vehicle_id,
                    destination=arrival.destination_name or arrival.status_text,
                )
            )

    if fail_count > 0:
        TrackLogger.warning(
            f"Bus arrivals failed for {fail_count}/{len(stop_results)} stops (MTA 5xx): {first_error}"
        )

    # -----------------------------------------------------------------
    # 1b. Populate stop.route_ids from SIRI observations
    # -----------------------------------------------------------------
    # OBA's stops-for-location often returns EMPTY routeIds.  Without
    # them the backfill / anchor phases below (A-D) are completely
    # inoperative — they iterate `for rid in stop.route_ids` which
    # yields nothing.  Fix: use the SIRI responses we just collected
    # to learn which routes actually serve each stop.
    _siri_routes_per_stop: dict[str, set[str]] = defaultdict(set)
    for r in results:
        if r.stop_id:
            _siri_routes_per_stop[r.stop_id].add(r.route_id)
    _siri_backfilled = 0
    for stop in stops:
        if not stop.route_ids and stop.id in _siri_routes_per_stop:
            # Re-qualify IDs so _display_name() later still works.
            # SIRI route_ids in `results` are already display-normalised,
            # but the backfill loops call _display_name(rid) on them.
            stop.route_ids = list(_siri_routes_per_stop[stop.id])
            _siri_backfilled += 1
    if _siri_backfilled:
        TrackLogger.bus(
            f"Populated route_ids for {_siri_backfilled} stops from SIRI "
            f"(OBA returned empty routeIds)"
        )

    # -----------------------------------------------------------------
    # 1c. Populate stop.route_ids from static schedule DB (bus fallback)
    # -----------------------------------------------------------------
    # Some areas have no live SIRI vehicles at query time and OBA returns
    # empty routeIds for nearby stops. Use static schedule arrivals to infer
    # route membership so those routes still appear in /nearby and grouped cards.
    _schedule_backfilled = 0
    for stop in stops:
        if stop.route_ids:
            continue
        scheduled = schedule_service.get_scheduled_arrivals(stop.id, limit=20)
        inferred_routes: set[str] = set()
        for s in scheduled:
            rid = _display_name(s.route_id)
            if rid and rid.upper() not in {"N/A", "UNKNOWN"}:
                inferred_routes.add(rid)
        if inferred_routes:
            stop.route_ids = sorted(inferred_routes)
            _schedule_backfilled += 1

    if _schedule_backfilled:
        TrackLogger.bus(
            f"Populated route_ids for {_schedule_backfilled} stops from schedule DB "
            f"(no live SIRI + empty OBA routeIds)"
        )

    # Log direction distribution per route for debugging
    _route_dirs: dict[str, set[str]] = defaultdict(set)
    for r in results:
        _route_dirs[r.route_id].add(r.direction)
    single_dir = [rid for rid, dirs in _route_dirs.items() if len(dirs) == 1]
    if single_dir:
        TrackLogger.bus(
            f"Bus routes with only 1 direction ({len(single_dir)}/{len(_route_dirs)}): "
            f"{single_dir[:10]}"
        )

    # -----------------------------------------------------------------
    # 2. Backfill: ensure every nearby bus route has BOTH directions.
    #
    #    Phase A — routes with NO live data at all get a placeholder.
    #    Phase B — routes with only ONE direction of live data get a
    #              placeholder for the missing direction so the grouped
    #              card shows two swipeable direction tabs (like subway).
    # -----------------------------------------------------------------

    # Track which (route, direction) pairs we already have from live data
    live_route_dirs: dict[str, set[str]] = defaultdict(set)
    for r in results:
        live_route_dirs[r.route_id].add(r.direction)

    # Prefer an existing route direction key for placeholder anchors so
    # we don't create synthetic tabs like "Eastbound" next to destination tabs.
    route_primary_direction: dict[str, str] = {}
    for r in sorted(results, key=lambda x: x.minutes_away):
        route_primary_direction.setdefault(r.route_id, r.direction)

    # Phase A: routes with zero live data — create one placeholder per route
    # Also: create a placeholder for the ABSOLUTE CLOSEST stop of ANY route
    # so that the iOS distance calculation is exactly the distance to the nearest stop.
    missing_routes: dict[str, tuple[BusStop, str]] = {}
    closest_stops_by_route: dict[str, BusStop] = {}

    for stop in stops:
        for rid in stop.route_ids:
            short = _display_name(rid)
            
            # Track the closest physical stop for EVERY route (since `stops` is sorted by distance already)
            if short not in closest_stops_by_route:
                closest_stops_by_route[short] = stop

            # Skip if we already have live data for this route
            if rid in routes_with_live or short in routes_with_live:
                continue
            # Keep the first (closest) stop per route for full missing route
            if rid not in missing_routes:
                direction = stop.direction or "N/A"
                missing_routes[rid] = (stop, direction)

    # Inject the absolute nearest stop into the results so iOS distance sorting evaluates the true nearest stop.
    for rid, closest_stop in closest_stops_by_route.items():
        # Check if the closest stop ALREADY has a live arrival for this route
        has_live_at_closest = any(r for r in results if r.route_id == rid and r.stop_id == closest_stop.id)
        if not has_live_at_closest:
            direction = route_primary_direction.get(rid) or closest_stop.direction or "N/A"
            # It's possible the route isn't completely 'missing', just missing live data at the closest stop.
            results.append(
                NearbyTransitArrival(
                    route_id=rid,
                    stop_name=closest_stop.name,
                    arrival_ts=None,
                    direction=direction,
                    minutes_away=_PLACEHOLDER_MINUTES,
                    status="Scheduled",
                    mode="bus",
                    stop_lat=closest_stop.lat,
                    stop_lon=closest_stop.lon,
                    stop_id=closest_stop.id,
                    vehicle_id=None,
                    destination=None,
                )
            )

    for rid, (stop, direction) in missing_routes.items():
        # Check if we didn't just add it above (in the closest stops backfill)
        already_added = any(r for r in results if r.route_id == _display_name(rid) and r.stop_id == stop.id)
        if already_added:
            continue
            
        results.append(
            NearbyTransitArrival(
                route_id=_display_name(rid),
                stop_name=stop.name,
                arrival_ts=None,
                direction=direction,
                minutes_away=_PLACEHOLDER_MINUTES,
                status="Scheduled",
                mode="bus",
                stop_lat=stop.lat,
                stop_lon=stop.lon,
                stop_id=stop.id,
                vehicle_id=None,
                destination=None,
            )
        )

    if missing_routes:
        TrackLogger.bus(
            f"Backfilled {len(missing_routes)} bus routes with no live data "
            f"(total {len(results)} bus arrivals from {len(stops)} stops)"
        )

    # Phase B: routes with fewer live directions than nearby stops
    # suggest.  For each route, find stops that didn't contribute any
    # live arrivals and add a placeholder for the direction they
    # represent.  This handles:
    #   • Simple A→B / B→A routes (2 directions)
    #   • Branching routes (e.g. B46 splits to Kings Plaza / Av H / Williamsburg)
    #   • Loop routes with a single direction
    #
    # Direction key strategy:
    #   - Direction keys are now destination names from SIRI
    #     (e.g. "KINGS PLAZA", "AV H").  Backfill placeholders use
    #     the OBA compass direction from the stop (e.g. "N", "SW")
    #     as a fallback key — since it won't collide with destination
    #     names, it always creates a new tab.
    #   - If all existing keys are SIRI numeric ("0"/"1" — only when
    #     DestinationName was unavailable), assign the next unused
    #     numeric key for consistency.

    # Build a set of stop_ids that already contributed live results per route
    live_stop_ids_per_route: dict[str, set[str]] = defaultdict(set)
    for r in results:
        live_stop_ids_per_route[r.route_id].add(r.stop_id)

    opposite_backfill = 0
    for stop in stops:
        for rid in stop.route_ids:
            short = _display_name(rid)
            # Only consider routes that DO have some live data already
            if short not in live_route_dirs:
                continue
            # Skip if this specific stop already contributed arrivals
            if stop.id in live_stop_ids_per_route.get(short, set()):
                continue

            # Determine a direction key for this stop's placeholder.
            existing_dirs = live_route_dirs[short]

            # If a route already has 2+ semantic destination tabs, don't add
            # compass fallback tabs (would create fake extra directions).
            # But if there's only ONE semantic tab, allow compass backfill from
            # other nearby stops to surface branching directions.
            semantic_dirs = {d for d in existing_dirs if not _is_fallback_direction_key(d)}
            if len(semantic_dirs) >= 2:
                continue

            # If ALL existing keys are SIRI numeric (rare: DestinationName
            # was unavailable), assign next unused numeric key.
            if existing_dirs and existing_dirs <= _NUMERIC_DIR_KEYS:
                for candidate in ("0", "1", "2", "3"):
                    if candidate not in existing_dirs:
                        new_dir = candidate
                        break
                else:
                    continue  # All 4 slots taken — unlikely
            else:
                # Route uses destination-name keys (normal path) —
                # use the stop's OBA compass direction as the backfill key.
                compass = stop.direction or "N/A"
                if compass in existing_dirs:
                    continue  # Already have this direction
                new_dir = compass

            results.append(
                NearbyTransitArrival(
                    route_id=short,
                    stop_name=stop.name,
                    arrival_ts=None,
                    direction=new_dir,
                    minutes_away=_PLACEHOLDER_MINUTES,
                    status="Scheduled",
                    mode="bus",
                    stop_lat=stop.lat,
                    stop_lon=stop.lon,
                    stop_id=stop.id,
                    vehicle_id=None,
                    destination=None,
                )
            )
            live_route_dirs[short].add(new_dir)
            live_stop_ids_per_route[short].add(stop.id)
            opposite_backfill += 1

    if opposite_backfill:
        TrackLogger.bus(
            f"Backfilled {opposite_backfill} missing-direction placeholders "
            f"for routes with incomplete live directions"
        )

    # -----------------------------------------------------------------
    # Phase C: Routes that STILL have only 1 direction after Phases A+B.
    #
    # This typically happens for express buses (BxM3, BM1, …) and
    # SBS routes (M79-SBS) where all nearby stops face the same way.
    # We infer an opposite direction so the grouped card always shows
    # two swipeable tabs — matching user expectations and subway parity.
    #
    # Strategy:
    #   - If existing key is a destination name ("MIDTOWN"), create a
    #     placeholder with the opposite compass direction label.
    #   - If existing key is a compass direction ("N"), use the
    #     opposite compass ("S").
    #   - If existing key is numeric ("0"), create "1" and vice versa.
    # -----------------------------------------------------------------
    _OPPOSITE_COMPASS: dict[str, str] = {
        "N": "S", "S": "N", "E": "W", "W": "E",
        "NE": "SW", "SW": "NE", "NW": "SE", "SE": "NW",
        "INBOUND": "OUTBOUND", "OUTBOUND": "INBOUND",
    }

    # Rebuild direction counts after Phase B additions
    final_route_dirs: dict[str, set[str]] = defaultdict(set)
    for r in results:
        if r.mode == "bus":
            final_route_dirs[r.route_id].add(r.direction)

    phase_c_count = 0

    for route_id, dirs in final_route_dirs.items():
        if len(dirs) != 1:
            continue  # Already has 2+ directions

        existing_dir = next(iter(dirs))

        # Find a representative stop for this route to anchor the placeholder
        rep_stop: BusStop | None = None
        for r in results:
            if r.route_id == route_id and r.stop_lat and r.stop_lon:
                rep_stop = BusStop(
                    id=r.stop_id or "",
                    name=r.stop_name,
                    lat=r.stop_lat,
                    lon=r.stop_lon,
                    direction=None,
                    route_ids=[],
                )
                break
        if rep_stop is None:
            continue

        # Determine the opposite direction key
        upper = existing_dir.upper()
        if upper in _OPPOSITE_COMPASS:
            new_dir = _OPPOSITE_COMPASS[upper]
        elif upper in _NUMERIC_DIR_KEYS:
            new_dir = "1" if existing_dir == "0" else "0"
        else:
            # Destination name — pick compass from the stop or default to "S"/"N"
            # Try to find the compass direction from nearby stops
            stop_compass = None
            for s in stops:
                if route_id in [_display_name(rid) for rid in s.route_ids]:
                    if s.direction:
                        stop_compass = s.direction.upper()
                        break
            if stop_compass and stop_compass in _OPPOSITE_COMPASS:
                new_dir = _OPPOSITE_COMPASS[stop_compass]
            else:
                # Default: if direction is a destination name going one way,
                # use a generic opposite label
                new_dir = _OPPOSITE_DIRECTION

        results.append(
            NearbyTransitArrival(
                route_id=route_id,
                stop_name=rep_stop.name,
                arrival_ts=None,
                direction=new_dir,
                minutes_away=_PLACEHOLDER_MINUTES,
                status="Scheduled",
                mode="bus",
                stop_lat=rep_stop.lat,
                stop_lon=rep_stop.lon,
                stop_id=rep_stop.id,
                vehicle_id=None,
                destination=None,
            )
        )
        phase_c_count += 1

    if phase_c_count:
        TrackLogger.bus(
            f"Phase C: Created {phase_c_count} opposite-direction placeholders "
            f"for single-direction routes"
        )

    # -----------------------------------------------------------------
    # Phase D: Nearest-stop anchor (OBA stops-for-route lookup)
    #
    # OBA's stops-for-location API does NOT return routeIds, so the
    # SIRI-based backfill in Phase 1b only covers routes that happened
    # to have a live bus heading to a nearby stop at query time.
    #
    # For routes whose nearest SIRI-observed stop is far (> 400 m),
    # fetch the full stop list via OBA stops-for-route and check if
    # the route actually serves a closer physical stop.  If so, add
    # a placeholder anchor at that stop so the iOS distance badge
    # reflects the true walking distance.
    #
    # get_bus_route_stops() is cached (60 s fresh / 300 s stale) so
    # repeated calls for the same route are essentially free.
    # -----------------------------------------------------------------

    _ANCHOR_THRESHOLD_M = 400  # Only look up routes farther than this

    # Build {route_id: nearest SIRI-observed distance}
    nearest_entry_dist: dict[str, float] = {}
    for r in results:
        if r.mode != "bus" or r.stop_lat is None or r.stop_lon is None:
            continue
        d = haversine_m(lat, lon, r.stop_lat, r.stop_lon)
        if r.route_id not in nearest_entry_dist or d < nearest_entry_dist[r.route_id]:
            nearest_entry_dist[r.route_id] = d

    # Build a quick lookup of nearby stop coordinates by ID
    _nearby_stop_map: dict[str, BusStop] = {s.id: s for s in stops}

    # Identify routes that might benefit from an anchor
    routes_needing_anchor = [
        rid for rid, d in nearest_entry_dist.items()
        if d > _ANCHOR_THRESHOLD_M
    ]

    phase_d_count = 0
    if routes_needing_anchor:
        # Resolve display names → canonical OBA IDs for the API call
        # get_bus_route_stops handles resolve_bus_id internally
        anchor_tasks = {
            rid: get_bus_route_stops(rid)
            for rid in routes_needing_anchor
        }
        anchor_results = await asyncio.gather(
            *anchor_tasks.values(), return_exceptions=True
        )

        for rid, route_stops in zip(anchor_tasks.keys(), anchor_results):
            if isinstance(route_stops, Exception) or not route_stops:
                continue

            # Find the closest stop on this route to the user
            best_stop: BusStop | None = None
            best_dist = nearest_entry_dist.get(rid, float("inf"))
            for rs in route_stops:
                d = haversine_m(lat, lon, rs.lat, rs.lon)
                if d < best_dist:
                    best_dist = d
                    best_stop = rs

            if best_stop is None:
                continue  # No closer stop found

            # Skip if this stop already has an entry for this route
            if best_stop.id in live_stop_ids_per_route.get(rid, set()):
                continue

            results.append(
                NearbyTransitArrival(
                    route_id=rid,
                    stop_name=best_stop.name,
                    arrival_ts=None,
                    direction=route_primary_direction.get(rid) or best_stop.direction or "N/A",
                    minutes_away=_PLACEHOLDER_MINUTES,
                    status="Scheduled",
                    mode="bus",
                    stop_lat=best_stop.lat,
                    stop_lon=best_stop.lon,
                    stop_id=best_stop.id,
                    vehicle_id=None,
                    destination=None,
                )
            )
            nearest_entry_dist[rid] = best_dist
            live_stop_ids_per_route[rid].add(best_stop.id)
            phase_d_count += 1

    if phase_d_count:
        TrackLogger.bus(
            f"Phase D: Added {phase_d_count} nearest-stop anchors via "
            f"stops-for-route lookup (checked {len(routes_needing_anchor)} routes)"
        )

    # -----------------------------------------------------------------
    # Phase E: Static GTFS fallback (guarantee route visibility in radius)
    # -----------------------------------------------------------------
    # When both live SIRI and OBA stop routeIds are sparse, some valid nearby
    # routes can still be missed. Use local GTFS bus stop-times to ensure any
    # route with a stop inside the radius is represented with a placeholder.
    # Only run broad static fallback during degraded upstream conditions
    # to avoid over-inflating direction/tab expectations in normal mode.
    run_phase_e = fail_count > 0 or any(not s.route_ids for s in stops)
    if run_phase_e:
        static_routes = _nearby_static_bus_routes(lat, lon, effective_radius)
        existing_routes = {r.route_id for r in results if r.mode == "bus"}
        phase_e_count = 0
        for route_id, (stop_name, stop_lat, stop_lon, stop_id) in static_routes.items():
            if route_id in existing_routes:
                continue
            results.append(
                NearbyTransitArrival(
                    route_id=route_id,
                    stop_name=stop_name,
                    arrival_ts=None,
                    direction=route_primary_direction.get(route_id) or "N/A",
                    minutes_away=_PLACEHOLDER_MINUTES,
                    status="Scheduled",
                    mode="bus",
                    stop_lat=stop_lat,
                    stop_lon=stop_lon,
                    stop_id=f"MTA_{stop_id}",
                    vehicle_id=None,
                    destination=None,
                )
            )
            existing_routes.add(route_id)
            phase_e_count += 1

        if phase_e_count:
            TrackLogger.bus(
                f"Phase E: Added {phase_e_count} static-GTFS nearby bus routes "
                f"(radius={effective_radius}m)"
            )

    # -----------------------------------------------------------------
    # Phase F: OBA route-stop scan for locale-matched candidates
    # -----------------------------------------------------------------
    # Final safety net: if nearby stops still have missing route metadata,
    # scan candidate routes (matching local prefixes like Q/B/M/BX) via
    # OBA stops-for-route and inject placeholders for routes with stops
    # inside the radius.
    empty_route_metadata_stops = sum(1 for s in stops if not s.route_ids)
    run_phase_f = empty_route_metadata_stops and (fail_count > 0)
    if run_phase_f:
        local_prefixes = {
            _route_prefix(r.route_id)
            for r in results
            if r.mode == "bus" and _route_prefix(r.route_id)
        }
        if not local_prefixes:
            local_prefixes = {"B", "BX", "M", "Q", "S", "BM", "QM", "SIM"}

        try:
            all_routes = await get_all_bus_routes()
        except Exception:
            all_routes = []

        candidate_route_ids: list[str] = []
        for route in all_routes:
            short = _display_name(route.short_name or route.id)
            if not short:
                continue
            if _route_prefix(short) in local_prefixes:
                candidate_route_ids.append(short)

        # Keep request load bounded; route-stop responses are cached in bus_client.
        _MAX_PHASE_F_CANDIDATES = 160
        candidate_route_ids = sorted(set(candidate_route_ids))[:_MAX_PHASE_F_CANDIDATES]

        phase_f_count = 0
        existing_routes = {r.route_id for r in results if r.mode == "bus"}
        if candidate_route_ids:
            scan_tasks = [get_bus_route_stops(route_id) for route_id in candidate_route_ids]
            scan_results = await asyncio.gather(*scan_tasks, return_exceptions=True)

            for route_id, route_stops in zip(candidate_route_ids, scan_results):
                if route_id in existing_routes:
                    continue
                if isinstance(route_stops, Exception) or not route_stops:
                    continue

                best_stop: BusStop | None = None
                best_dist = float("inf")
                for s in route_stops:
                    d = haversine_m(lat, lon, s.lat, s.lon)
                    if d <= effective_radius and d < best_dist:
                        best_dist = d
                        best_stop = s

                if best_stop is None:
                    continue

                results.append(
                    NearbyTransitArrival(
                        route_id=route_id,
                        stop_name=best_stop.name,
                        arrival_ts=None,
                        direction=route_primary_direction.get(route_id) or best_stop.direction or "N/A",
                        minutes_away=_PLACEHOLDER_MINUTES,
                        status="Scheduled",
                        mode="bus",
                        stop_lat=best_stop.lat,
                        stop_lon=best_stop.lon,
                        stop_id=best_stop.id,
                        vehicle_id=None,
                        destination=None,
                    )
                )
                existing_routes.add(route_id)
                phase_f_count += 1

        if phase_f_count:
            TrackLogger.bus(
                f"Phase F: Added {phase_f_count} OBA-scanned nearby bus routes "
                f"from {len(candidate_route_ids)} locale candidates"
            )

    return results



# ---------------------------------------------------------------------------
# Rail helpers
# ---------------------------------------------------------------------------


async def _fetch_nearby_rail(
    lat: float, lon: float, radius: int, agency: str
) -> list[NearbyTransitArrival]:
    """Fetch arrivals for LIRR or Metro-North, filtered to nearby stations."""
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
        # Skip arrivals with no route_id — these can't be meaningfully grouped
        if not arrival.route_id:
            continue
            
        stop_info = get_stop_info(arrival.station, agency=agency)
        
        # Prefix route_id so client can distinguish LIRR "9" from subway "9"
        prefixed_route_id = f"{prefix}{arrival.route_id}"
        
        results.append(
            NearbyTransitArrival(
                route_id=prefixed_route_id,
                stop_name=stop_info.name if stop_info else arrival.station,
                # Prefer terminal destination for direction grouping so branch
                # terminals can appear as distinct tabs. If destination is
                # unavailable, fall back to canonical Inbound/Outbound.
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

    # -----------------------------------------------------------------
    # Fallback: ensure routes still appear when no live train is nearby.
    # -----------------------------------------------------------------
    stops_with_live = {a.stop_id for a in results}
    missing_stops = nearby_stops - stops_with_live

    if missing_stops:
        fallback_count = 0
        for stop_id in missing_stops:
            stop_info = get_stop_info(stop_id, agency=agency)
            if stop_info is None:
                continue

            scheduled = schedule_service.get_scheduled_arrivals(stop_id, limit=6)
            for s in scheduled:
                if not s.route_id:
                    continue

                # Rail branches are numeric GTFS route IDs in this codepath.
                if not s.route_id.isdigit():
                    continue

                prefixed_route_id = f"{prefix}{s.route_id}"
                results.append(
                    NearbyTransitArrival(
                        route_id=prefixed_route_id,
                        stop_name=stop_info.name,
                        direction=s.destination or s.direction,
                        destination=s.destination,
                        minutes_away=s.minutes_away,
                        arrival_ts=s.arrival_ts,
                        status="Scheduled",
                        mode=agency,
                        stop_lat=stop_info.lat,
                        stop_lon=stop_info.lon,
                        stop_id=stop_id,
                        trip_id=s.trip_id,
                    )
                )
                fallback_count += 1

        if fallback_count:
            TrackLogger.info(
                f"{agency.upper()}: Backfilled {fallback_count} scheduled entries "
                f"for {len(missing_stops)} nearby stops with no live trains"
            )
        
    return results


def _bus_minutes_away(expected: datetime | None) -> int:
    """Calculate minutes until a bus arrival."""
    if expected is None:
        return 99
    now = datetime.now(timezone.utc)
    if expected.tzinfo is None:
        expected = expected.replace(tzinfo=timezone.utc)
    diff = (expected - now).total_seconds()
    return max(0, int(diff // 60))
