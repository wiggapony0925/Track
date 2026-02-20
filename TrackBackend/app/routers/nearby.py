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
from datetime import datetime, timezone

from fastapi import APIRouter, Query

from app.config import get_settings
from app.models import BusStop, DirectionArrivals, GroupedNearbyTransit, NearbyTransitArrival
from app.services.bus_client import get_nearby_stops, get_realtime_arrivals, BUS_AGENCY_PREFIXES
from app.services.data_cleaner import get_arrivals_for_line
from app.services.station_lookup import get_nearby_stop_ids, get_stop_info
from app.utils.logger import TrackLogger
from app.utils.transit_utils import get_subway_color
from app.services.schedule_service import schedule_service
from app.services.rail_client import fetch_rail_arrivals
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

# Fallback direction key for Phase C when no compass direction can be inferred
_OPPOSITE_DIRECTION = "Opposite"


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
    # For legacy numeric direction keys (DirectionRef fallback),
    # try to get the destination from the first arrival.
    if direction in _NUMERIC_DIR_KEYS and arrivals:
        for a in arrivals:
            if a.destination:
                return a.destination
        return _DIRECTION_LABELS.get(direction, f"Direction {direction}")

    upper = direction.upper()

    # Known compass / special codes → canonical label
    if upper in _DIRECTION_LABELS:
        base_label = _DIRECTION_LABELS[upper]
        # For subway compass directions, enrich with unique destination names
        # so the label shows where trains are heading (e.g. "Northbound → Inwood-207 St").
        # Only apply to subway — bus routes with compass keys don't need this.
        if arrivals and upper in ("N", "S"):
            subway_arrivals = [a for a in arrivals if a.mode == "subway"]
            if subway_arrivals:
                dests = sorted({a.destination for a in subway_arrivals if a.destination})
                if dests:
                    return f"{base_label} → {' / '.join(dests)}"
        return base_label

    # Destination-name keys (e.g. "KINGS PLAZA") → title-case for display
    return direction.title()


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
                direction_label=_direction_label(direction, arrivals),
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
            # key so that all branches (e.g. Far Rockaway, Lefferts Blvd) are
            # consolidated into a single direction bucket. The destination name
            # is preserved in the separate `destination` field for display.
            # Bus/rail modes can still use destination as the direction key.
            
            results.append(
                NearbyTransitArrival(
                    route_id=arrival.route_id or line,
                    stop_name=stop_name,
                    direction=arrival.direction,
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
                # as the grouping key, same as live arrivals above.
                sched_dir = s.direction  # already "N"/"S" from stop_id suffix
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

    try:
        stops = await get_nearby_stops(lat, lon, radius_m=effective_radius)
    except Exception as exc:
        TrackLogger.error(f"Bus stops fetch failed: {exc}")
        return results

    if not stops:
        TrackLogger.info("No bus stops found within search radius")
        return results

    # -----------------------------------------------------------------
    # 1. Fetch live SIRI arrivals for every nearby stop
    # -----------------------------------------------------------------
    # Query ALL nearby stops (not truncated by max_nearby_results) so that
    # both directions of a route are captured even when the opposite-direction
    # stop is farther away in the sorted list.
    # Safety cap at 80 stops to avoid hammering the MTA API in extremely
    # dense areas; 80 is generous enough to cover both sides of a street
    # for all routes in the search radius.
    _MAX_SIRI_STOPS = 80
    stops_to_query = stops[:_MAX_SIRI_STOPS]
    tasks = [get_realtime_arrivals(stop.id) for stop in stops_to_query]
    stop_results = await asyncio.gather(*tasks, return_exceptions=True)

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

    # Phase A: routes with zero live data — create one placeholder per route
    missing_routes: dict[str, tuple[BusStop, str]] = {}
    for stop in stops:
        for rid in stop.route_ids:
            short = _display_name(rid)
            # Skip if we already have live data for this route
            if rid in routes_with_live or short in routes_with_live:
                continue
            # Keep the first (closest) stop per route
            if rid not in missing_routes:
                direction = stop.direction or "N/A"
                missing_routes[rid] = (stop, direction)

    for rid, (stop, direction) in missing_routes.items():
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
            
        stop_info = get_stop_info(arrival.station, agency=agency)
        
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
    now = datetime.now(timezone.utc)
    if expected.tzinfo is None:
        expected = expected.replace(tzinfo=timezone.utc)
    diff = (expected - now).total_seconds()
    return max(0, int(diff // 60))
