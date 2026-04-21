"""Router for the unified nearby transit endpoint.
Returns the nearest buses and trains with live countdowns,
sorted by minutes away. No trips or routing — just arrivals.

The ``/nearby/grouped`` endpoint collapses duplicate routes into a
single card with swipeable direction sub-groups — so the iOS app
shows one entry per route instead of eight "A" trains."""

from __future__ import annotations

import asyncio
import contextlib
import csv
import json as _json
import re
from collections import defaultdict
from datetime import UTC, datetime
from functools import lru_cache
from pathlib import Path

from fastapi import APIRouter, Query, Response
from pydantic import TypeAdapter as _TypeAdapter

from app.cache_config import (
    BUS_MAX_SIRI_STOPS,
    NEARBY_GPS_DECIMALS,
    NEARBY_RESPONSE_ERROR_TTL,
    NEARBY_RESPONSE_FRESH_TTL,
    NEARBY_RESPONSE_MAX_SIZE,
    NEARBY_RESPONSE_STALE_TTL,
    SIRI_WAVE_SIZE,
    SIRI_WAVE_DELAY,
)
from app.clients.bus_client import (
    BUS_AGENCY_PREFIXES,
    CANONICAL_BUS_DISPLAY,
    get_nearby_stops,
    get_realtime_arrivals,
)
from app.clients.bus_client import (
    get_routes as get_all_bus_routes,
)
from app.clients.bus_client import (
    get_stops as get_bus_route_stops,
)
from app.clients.rail_client import fetch_rail_arrivals
from app.config import get_settings
from app.ml.delay_model import (
    predict_factor as _predict_factor,
)
from app.ml.delay_model import (
    predict_factor_batch as _predict_factor_batch,
)
from app.ml.recency_model import (
    get_weighted_error as _get_weighted_error,
)
from app.ml.recency_model import (
    get_weighted_errors_batch as _get_weighted_errors_batch,
)
from app.models import (
    RESP_503,
    BusStop,
    DirectionArrivals,
    GroupedNearbyTransit,
    InactiveRoute,
    InlineAlert,
    NearbyTransitArrival,
)
from app.services.gtfs.realtime_parser import get_arrivals_for_line
from app.services.mapping.rail.shapes import (
    get_lirr_route_color,
    get_lirr_route_name,
    get_mnr_route_color,
    get_mnr_route_name,
)
from app.services.mapping.subway.shapes import (
    get_stops_for_route as get_subway_stops_for_route,
)
from app.services.transit.alert_service import (
    get_alert_boost as _get_alert_boost,
)
from app.services.transit.alert_service import (
    maybe_refresh as _maybe_refresh_alerts,
)
from app.services.transit.schedule_service import schedule_service
from app.services.transit.station_lookup import get_nearby_stop_ids, get_stop_info
from app.utils.geo_utils import haversine_m
from app.utils.logger import TrackLogger
from app.utils.brand import (
    bus_color as _brand_bus_color,
    mode_color as _brand_mode_color,
    mode_name as _brand_mode_name,
    text_color_for_route as _brand_text_color,
)
from app.utils.transit_utils import get_subway_color

# Bus colors now sourced from config/brand_colors.json via brand.py
# (no more hardcoded hex values here)

# ---------------------------------------------------------------------------
# Dynamic limited-route detection from GTFS trip headsigns
# ---------------------------------------------------------------------------
# MTA marks limited-stop trips with "LIMITED …" or "RUSH …" prefixes in the
# trip_headsign field of trips.txt.  Scanning at import time means the set
# auto-updates whenever the GTFS refresh service pulls new feeds — no
# hardcoded route lists to maintain.

_GTFS_DATA_ROOT = Path(__file__).resolve().parent.parent / "data"

# Regex to strip the leading-zero route IDs in GTFS (Q09 → Q9)
_GTFS_ROUTE_ZERO_RE = re.compile(r"^([A-Za-z]+)0+(\d+)$")


_STATIC_LIMITED_JSON = _GTFS_DATA_ROOT / "limited_routes.json"


def _load_static_limited_fallback() -> tuple[frozenset[str], frozenset[str]]:
    """Load pre-computed limited route sets from the static JSON file.

    This file is committed to the repo and ships with every deploy, so
    production (Render) always has a baseline even when GTFS trips.txt
    files are not present.
    """
    if not _STATIC_LIMITED_JSON.exists():
        return frozenset(), frozenset()
    try:
        data = _json.loads(_STATIC_LIMITED_JSON.read_text(encoding="utf-8"))
        only = frozenset(r.upper() for r in data.get("limited_only", []))
        mixed = frozenset(r.upper() for r in data.get("limited_mixed", []))
        TrackLogger.info(
            f"🚌 Static limited fallback loaded: {len(only)} limited-only, "
            f"{len(mixed)} mixed"
        )
        return only, mixed
    except Exception as exc:
        TrackLogger.info(f"🚌 Static limited fallback failed: {exc}")
        return frozenset(), frozenset()


def _build_limited_route_sets() -> tuple[frozenset[str], frozenset[str]]:
    """Scan all local GTFS trips.txt for LIMITED / RUSH headsigns.

    Returns two frozensets of **normalised, upper-case** route short-names:

    1. **limited_only** — routes where **all** trips are LIMITED/RUSH
       (e.g. Q9, Q10).  Classified as ``"Limited"``.
    2. **limited_mixed** — routes where **some** (but not all) trips are
       LIMITED/RUSH (e.g. M5, BX15).  Classified as ``"Local / Limited"``
       so the user knows both service patterns exist.

    The scan covers:
    - ``app/data/bus/{Borough}/trips.txt``  (MTA NYCT bus feeds)
    - ``app/data/MTA Bus Company/trips.txt`` (MTABC feed — Queens redesign)

    Falls back to ``app/data/limited_routes.json`` (static snapshot) when
    no GTFS trip data is available (e.g. on production Render deploys).
    """
    # route → [total_trips, limited_trips]
    route_counts: dict[str, list[int]] = {}
    search_dirs: list[Path] = []

    # Borough-level NYCT feeds
    bus_dir = _GTFS_DATA_ROOT / "bus"
    if bus_dir.is_dir():
        search_dirs.extend(d for d in bus_dir.iterdir() if d.is_dir())
    # MTABC (MTA Bus Company) feed
    mtabc_dir = _GTFS_DATA_ROOT / "MTA Bus Company"
    if mtabc_dir.is_dir():
        search_dirs.append(mtabc_dir)

    for directory in search_dirs:
        trips_file = directory / "trips.txt"
        if not trips_file.exists():
            continue
        try:
            with trips_file.open(encoding="utf-8-sig") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    route_id = row.get("route_id", "").strip().upper()
                    # Normalise: Q09 → Q9
                    m = _GTFS_ROUTE_ZERO_RE.match(route_id)
                    norm = (m.group(1) + m.group(2)).upper() if m else route_id
                    if norm not in route_counts:
                        route_counts[norm] = [0, 0]
                    route_counts[norm][0] += 1
                    headsign = (row.get("trip_headsign") or "").strip().upper()
                    if headsign.startswith(("LIMITED ", "RUSH ")):
                        route_counts[norm][1] += 1
        except Exception:
            continue

    limited_only: set[str] = set()
    limited_mixed: set[str] = set()
    for route, (total, ltd) in route_counts.items():
        if ltd == 0:
            continue
        if ltd == total:
            limited_only.add(route)
        else:
            limited_mixed.add(route)

    # If GTFS scan found nothing (e.g. production), fall back to static JSON
    if not limited_only and not limited_mixed:
        static_only, static_mixed = _load_static_limited_fallback()
        if static_only or static_mixed:
            return static_only, static_mixed

    TrackLogger.info(
        f"🚌 Dynamic limited routes: {len(limited_only)} limited-only, "
        f"{len(limited_mixed)} mixed  "
        f"(only: {', '.join(sorted(limited_only)[:8])}{'…' if len(limited_only) > 8 else ''})  "
        f"(mixed: {', '.join(sorted(limited_mixed)[:8])}{'…' if len(limited_mixed) > 8 else ''})"
    )
    return frozenset(limited_only), frozenset(limited_mixed)


_GTFS_LIMITED_ONLY: frozenset[str]
_GTFS_LIMITED_MIXED: frozenset[str]
_GTFS_LIMITED_ONLY, _GTFS_LIMITED_MIXED = _build_limited_route_sets()


def refresh_limited_route_set() -> None:
    """Re-scan GTFS data and update the limited route sets.

    Called by the GTFS refresh service after downloading new feeds so
    the classifier picks up changes without a server restart.
    Also persists the updated sets to the static JSON fallback so that
    production deploys (which lack GTFS trips.txt) stay current.
    """
    global _GTFS_LIMITED_ONLY, _GTFS_LIMITED_MIXED  # noqa: PLW0603
    _GTFS_LIMITED_ONLY, _GTFS_LIMITED_MIXED = _build_limited_route_sets()
    # Persist to static JSON for production fallback
    if _GTFS_LIMITED_ONLY or _GTFS_LIMITED_MIXED:
        try:
            data = {
                "limited_only": sorted(_GTFS_LIMITED_ONLY),
                "limited_mixed": sorted(_GTFS_LIMITED_MIXED),
                "_comment": (
                    "Auto-generated from GTFS trips.txt headsigns. "
                    "Routes with LIMITED/RUSH in all trips = limited_only; "
                    "some trips = limited_mixed."
                ),
            }
            _STATIC_LIMITED_JSON.write_text(
                _json.dumps(data, indent=2), encoding="utf-8"
            )
            TrackLogger.info(
                f"🚌 Static limited_routes.json updated: "
                f"{len(_GTFS_LIMITED_ONLY)} only, {len(_GTFS_LIMITED_MIXED)} mixed"
            )
        except Exception as exc:
            TrackLogger.info(f"🚌 Failed to persist limited_routes.json: {exc}")


def _classify_bus_service_type(
    display_name: str,
    open_data_service_type: str | None = None,
) -> str:
    """Derive MTA bus service classification from the display name.

    Rules (in order of specificity):
    1. Contains '-SBS' or '+SBS' → Select Bus Service
    1b. Ends with '+' (MTA open-data SBS naming: M15+, B44+, Q44+) → SBS
    2. Starts with 'BXM' or 'BM' or 'QM' or 'SIM' or 'X' → Express
    3. Route has ALL trips LIMITED/RUSH in GTFS → Limited
    4. Route has SOME trips LIMITED/RUSH in GTFS → Local / Limited
    5. Open-data ``route_type`` fallback (catches S81, etc.) → mapped type
    6. Everything else → Local

    Args:
        display_name: Route display string (e.g. "B63", "M15-SBS", "Q44+").
        open_data_service_type: Optional ``route_type`` from the MTA open-data
            shapes dataset (e.g. "local", "limited", "sbs", "express").
            Used as a last-resort fallback when GTFS headsigns don't cover
            the route.
    """
    upper = display_name.upper().strip()
    # SBS routes — OBA uses "-SBS" / "+SBS", open data uses trailing "+"
    if "-SBS" in upper or "+SBS" in upper:
        return "Select Bus Service"
    if upper.endswith("+"):
        return "Select Bus Service"
    # Express bus prefixes (NYC express buses)
    if upper.startswith(("BXM", "BM", "QM", "SIM", "X")):
        return "Express"
    # Dynamic: 100% limited/rush trips
    if upper in _GTFS_LIMITED_ONLY:
        return "Limited"
    # Dynamic: mixed local + limited/rush
    if upper in _GTFS_LIMITED_MIXED:
        return "Local / Limited"
    # Fallback: MTA open-data route_type field (catches routes whose GTFS
    # headsigns don't include LIMITED/RUSH but are classified by MTA).
    if open_data_service_type:
        _oda = open_data_service_type.strip().lower()
        _ODA_MAP: dict[str, str] = {
            "limited": "Limited",
            "sbs": "Select Bus Service",
            "express": "Express",
            "school": "School",
        }
        if _oda in _ODA_MAP:
            return _ODA_MAP[_oda]
    return "Local"


def _bus_color_for_service_type(service_type: str) -> str:
    """Return the MTA-standard hex color for a bus service type."""
    return _brand_bus_color(service_type)


def _build_bus_route_color_lookup(routes) -> dict[str, str]:
    """Build a flexible lookup of bus route identifiers to exact OBA colors."""
    lookup: dict[str, str] = {}
    for route in routes:
        color = (getattr(route, "color", "") or "").strip()
        if not color:
            continue
        color_hex = color if color.startswith("#") else f"#{color}"
        route_id = (getattr(route, "id", "") or "").strip()
        short_name = (getattr(route, "short_name", "") or "").strip()

        keys = {
            route_id.upper(),
            short_name.upper(),
            _normalize_route_display(short_name).upper(),
        }
        if route_id:
            keys.add(_display_name(route_id).upper())
            if "_" in route_id:
                stripped = route_id.rsplit("_", 1)[-1]
                keys.add(stripped.upper())
                keys.add(_normalize_route_display(stripped).upper())

        for key in keys:
            if key:
                lookup[key] = color_hex
    return lookup


def _lookup_bus_route_color(
    route_id: str,
    display_name: str,
    color_lookup: dict[str, str] | None,
) -> str | None:
    """Return the exact OBA route color when available."""
    if not color_lookup:
        return None

    candidates = [
        route_id,
        display_name,
        _normalize_route_display(display_name),
        _display_name(route_id),
    ]
    if "_" in route_id:
        stripped = route_id.rsplit("_", 1)[-1]
        candidates.extend([stripped, _normalize_route_display(stripped)])

    for candidate in candidates:
        if not candidate:
            continue
        color = color_lookup.get(candidate.upper())
        if color:
            return color
    return None

# Load tunable constants from settings.json → app_settings
_PLACEHOLDER_MINUTES: int = get_settings().app_settings.placeholder_minutes
_MAX_SCHEDULE_PER_DORMANT: int = get_settings().app_settings.max_schedule_per_dormant

_BUS_STATIC_GTFS_ROOT = Path(__file__).resolve().parent.parent / "data" / "bus"

# ---------------------------------------------------------------------------
# Express / Limited service classifier
# ---------------------------------------------------------------------------
# Subway routes that run express service (skip stops a local wouldn't serve).
# Sourced from MTA GTFS routes.txt route_long_name.
# NOTE: These routes run express on *some* segments / *some* times of day,
# but the route itself is classified as express.  The E runs express in
# Queens, A/B/D/2/3/4/5/N/Q run express in Manhattan, etc.
_SUBWAY_EXPRESS_ROUTES: frozenset[str] = frozenset({
    "A", "B", "D", "E", "F",       # 8th/6th Av express & Queens Blvd
    "N", "Q", "Z",                  # Broadway express, Nassau express
    "2", "3", "4", "5",            # 7th Av / Lex express
    "6X", "7X", "FX",              # Dedicated express variants
})

# Bus route-name patterns that indicate express / limited / SBS service.
_BUS_EXPRESS_PREFIX_RE = re.compile(
    r"^(SIM|BxM|BM|QM|X)\d",
    re.IGNORECASE,
)


def _is_express_service(route_id: str, mode: str) -> bool:
    """Classify whether a route_id represents express/limited service.

    Subway: route is in the express set (A, B, D, 2-5, etc.) or is
    an explicit express variant (6X, 7X, FX).

    Bus: route name contains "-SBS" (Select Bus Service), matches an
    express bus prefix (SIM, BxM, BM, QM), or ends with "+" (SBS
    alternate notation).

    LIRR/MNR: always False (no express/local distinction at route level).
    """
    if mode == "subway":
        # Strip any agency prefix (shouldn't exist for subway but be safe)
        name = route_id.upper().strip()
        return name in _SUBWAY_EXPRESS_ROUTES
    if mode == "bus":
        name = route_id.upper().strip()
        # SBS routes: "B44-SBS", "M34-SBS", "M15+"
        if "-SBS" in name or name.endswith("+"):
            return True
        # Express bus prefixes: SIM*, BxM*, BM1-9, QM*
        if _BUS_EXPRESS_PREFIX_RE.match(name):
            return True
        return False
    return False


async def _schedule_arrivals_for_stop(
    stop_id: str,
    route_id: str,
    stop_name: str,
    stop_lat: float | None,
    stop_lon: float | None,
    fallback_direction: str = "N/A",
    limit: int = _MAX_SCHEDULE_PER_DORMANT,
) -> list[NearbyTransitArrival]:
    """Try to get real GTFS scheduled departures for a dormant route at a stop.

    Returns a list of ``NearbyTransitArrival`` with real ``arrival_ts`` and
    ``minutes_away`` values (status="Scheduled").  If the schedule DB has no
    data for this stop+route, returns a single bare placeholder so the route
    still appears in the dashboard.
    """
    # GTFS DB stores bare numeric stop IDs; OBA prefixes them with "MTA_"
    bare_stop = _canonical_bus_stop_id(stop_id)
    sched = await schedule_service.get_scheduled_arrivals_async(
        bare_stop, route_id=route_id, limit=limit
    )
    if sched:
        out: list[NearbyTransitArrival] = []
        for s in sched:
            # Prefer the GTFS trip_headsign (destination) as the direction key
            # so scheduled arrivals merge with live SIRI arrivals that use
            # DestinationName — avoids creating duplicate compass-key tabs
            # ("Northbound") alongside real destination tabs ("KINGS PLAZA").
            if (
                s.destination
                and s.destination.strip()
                and s.destination.strip().lower() != "unknown"
            ):
                direction = s.destination.strip()
            elif s.direction and s.direction != "N/A":
                direction = s.direction
            else:
                direction = fallback_direction
            out.append(
                NearbyTransitArrival(
                    route_id=route_id,
                    stop_name=stop_name,
                    arrival_ts=s.arrival_ts,
                    direction=direction,
                    minutes_away=s.minutes_away,
                    status="Scheduled",
                    mode="bus",
                    stop_lat=stop_lat,
                    stop_lon=stop_lon,
                    stop_id=stop_id,
                    vehicle_id=None,
                    destination=s.destination,
                    trip_id=s.trip_id,
                    is_express=_is_express_service(route_id, "bus"),
                )
            )
        return out

    # No schedule data — fall back to a single bare placeholder
    return [
        NearbyTransitArrival(
            route_id=route_id,
            stop_name=stop_name,
            arrival_ts=None,
            direction=fallback_direction,
            minutes_away=_PLACEHOLDER_MINUTES,
            status="Scheduled",
            mode="bus",
            stop_lat=stop_lat,
            stop_lon=stop_lon,
            stop_id=stop_id,
            vehicle_id=None,
            destination=None,
            is_express=_is_express_service(route_id, "bus"),
        )
    ]


def _canonical_bus_stop_id(stop_id: str) -> str:
    sid = (stop_id or "").strip()
    if sid.startswith("MTA_"):
        sid = sid[4:]
    return sid


@lru_cache(maxsize=1)
def _load_static_bus_route_stop_index() -> (
    dict[str, tuple[float, float, str, set[str]]]
):
    """Load bus stop → (lat, lon, name, {route_short}) from SQLite schedule DB.

    Previous implementation read 6.5M CSV rows from stop_times.txt across 5
    boroughs, peaking at ~2 GB of transient memory.  This version queries
    the already-built transit_schedule.db with a single JOIN — constant
    memory, ~2s instead of 30s, and 100 % compatible output.
    """
    import sqlite3

    db_path = Path("app/data/transit_schedule.db")
    index: dict[str, tuple[float, float, str, set[str]]] = {}

    if not db_path.exists():
        # Fall back to empty — Phase E will be a no-op
        TrackLogger.bus("Static bus fallback: schedule DB not found")
        return index

    try:
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()
        # route_type=3 → bus in GTFS spec
        cursor.execute("""
            SELECT DISTINCT
                s.stop_id, s.stop_lat, s.stop_lon, s.stop_name,
                r.route_short_name
            FROM stop_times st
            JOIN trips t  ON t.trip_id  = st.trip_id
            JOIN routes r ON r.route_id = t.route_id AND r.route_type = 3
            JOIN stops s  ON s.stop_id  = st.stop_id
            WHERE s.stop_lat IS NOT NULL AND s.stop_lon IS NOT NULL
        """)

        for stop_id, lat, lon, name, route_short in cursor.fetchall():
            canonical = _canonical_bus_stop_id(stop_id)
            if not canonical or not route_short:
                continue
            if canonical in index:
                index[canonical][3].add(route_short)
            else:
                index[canonical] = (lat, lon, name or canonical, {route_short})

        conn.close()
    except Exception as exc:
        TrackLogger.info(f"Static bus fallback DB query failed: {exc}", exc_info=True)
        return {}

    TrackLogger.bus(
        f"Static bus fallback index loaded: {len(index)} stops (from SQLite)"
    )
    return index


def _nearby_static_bus_routes(
    lat: float, lon: float, radius_m: int
) -> dict[str, tuple[str, float, float, str]]:
    """Return route_short -> (stop_name, stop_lat, stop_lon, stop_id) for nearest nearby static stop."""
    index = _load_static_bus_route_stop_index()
    if not index:
        return {}

    from app.providers import get_provider as _get_provider

    _prov = _get_provider()

    lat_span = radius_m / _prov.meters_per_deg_lat
    lon_span = radius_m / _prov.meters_per_deg_lon

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
# Caches the final assembled list[GroupedNearbyTransit] **plus the pre-
# serialised JSON bytes** so that repeat requests skip ALL upstream calls,
# processing, AND Pydantic→JSON serialisation.  On a 0.5-CPU Render
# instance, serialising 500 KB of Pydantic objects costs 3-6 seconds
# when GIL-contending with background feed parsing.  Returning raw bytes
# via ``Response(content=...)`` bypasses all of that.
#
# Uses stale-while-revalidate: serve stale bytes instantly and kick a
# background refresh so the next request gets fresh data.

_grouped_ta = _TypeAdapter(list[GroupedNearbyTransit])

_nearby_resp_cache: dict[
    tuple[float, float, int, str | None, bool],  # (rounded_lat, rounded_lon, radius, mode, quick)
    tuple[float, list[GroupedNearbyTransit], bytes],  # (timestamp, result, json_bytes)
] = {}
_nearby_resp_inflight: dict[tuple, asyncio.Task] = {}


def _describe_exception(exc: BaseException) -> str:
    """Return a log-friendly exception string even when str(exc) is empty."""
    detail = str(exc).strip()
    if detail:
        return f"{type(exc).__name__}: {detail}"
    return type(exc).__name__


# Maximum time (seconds) for a single /nearby/grouped computation.
# Prevents runaway upstream calls (hung MTA feeds, slow OBA) from
# blocking a Gunicorn worker indefinitely.  45 s is generous enough
# for a cold-cache fan-out (7 subway + bus + 2 rail) but short enough
# that the worker is freed before the iOS 60 s resource timeout.
_NEARBY_COMPUTE_TIMEOUT: int = (
    get_settings().app_settings.nearby_compute_timeout_seconds
)


async def _compute_and_cache_grouped(
    key: tuple[float, float, int, str | None, bool],
    lat: float,
    lon: float,
    radius: int,
    mode: str | None,
    *,
    quick: bool = False,
) -> list[GroupedNearbyTransit]:
    import time as _time

    # ── Pre-load ML model in background thread ──────────────────────
    # Without this, the first _ml_corrected() call inside
    # _fetch_nearby_subway triggers a synchronous joblib.load() that
    # blocks the event loop for 30+ seconds on Render cold starts,
    # causing _collect_all to exceed its timeout.  Loading here (before
    # the timeout wrapper) keeps the budget for actual feed fetching.
    from app.ml.delay_model import ensure_model_loaded as _eml

    with contextlib.suppress(TimeoutError, Exception):
        await asyncio.wait_for(_eml(), timeout=35.0)

    # ── Collect arrivals ────────────────────────────────────────────
    # _collect_all internally uses asyncio.wait() with a 30 s timeout
    # and explicitly cancels + awaits all pending tasks — no zombies.
    # The outer 45 s guard catches pathological cases (e.g. the
    # cancellation itself is blocked by GIL contention).
    _ca_task = asyncio.create_task(_collect_all(lat, lon, radius, mode_filter=mode, quick=quick))
    try:
        flat = await asyncio.wait_for(
            asyncio.shield(_ca_task),
            timeout=_NEARBY_COMPUTE_TIMEOUT,
        )
    except TimeoutError:
        _ca_task.cancel()
        # Wait briefly for the cancel to propagate, but don't hang
        with contextlib.suppress(asyncio.TimeoutError, asyncio.CancelledError):
            await asyncio.wait_for(_ca_task, timeout=3.0)
        TrackLogger.info(
            f"_collect_all timed out after {_NEARBY_COMPUTE_TIMEOUT}s "
            f"for ({lat:.4f}, {lon:.4f}) radius={radius} mode={mode}",
            tag="NEARBY",
        )
        # Salvage any partial results if _collect_all managed to return
        flat = (
            _ca_task.result()
            if _ca_task.done()
            and not _ca_task.cancelled()
            and _ca_task.exception() is None
            else []
        )

    # ── Inline alerts (timeout-guarded) ─────────────────────────────
    try:
        alert_index = await asyncio.wait_for(_get_inline_alerts(), timeout=3.0)
    except TimeoutError:
        TrackLogger.info(
            "Inline alert fetch timed out after 3s — proceeding without alerts",
            tag="NEARBY",
        )
        alert_index = _inline_alert_cache  # fall back to stale cache
    try:
        bus_route_color_lookup = _build_bus_route_color_lookup(
            await get_all_bus_routes()
        )
    except Exception as exc:
        TrackLogger.info(f"Bus route color lookup failed: {exc}", tag="NEARBY")
        bus_route_color_lookup = {}
    grouped = _group_arrivals(
        flat,
        alert_index=alert_index,
        bus_color_lookup=bus_route_color_lookup,
    )

    # ── Mark placeholder arrivals ──────────────────────────────────
    # Placeholders keep minutes_away=99 so the iOS `isPlaceholder`
    # guard works (`minutesAway >= 99 && arrivalTs == nil`).  We only
    # tag status="No Data" so the client can show an appropriate UI.
    # DO NOT set minutes_away=None — iOS decodes it as non-optional Int.
    for g in grouped:
        for d in g.directions:
            for a in d.arrivals:
                if a.minutes_away >= _PLACEHOLDER_MINUTES and a.arrival_ts is None:
                    a.status = "No Data"

    # Pre-serialise so cache hits return raw bytes (zero Pydantic overhead)
    json_bytes = _grouped_ta.dump_json(grouped)

    if len(_nearby_resp_cache) >= NEARBY_RESPONSE_MAX_SIZE:
        oldest_key = min(_nearby_resp_cache, key=lambda k: _nearby_resp_cache[k][0])
        del _nearby_resp_cache[oldest_key]

    # Never cache empty results.  During warmup feeds aren't ready yet;
    # after warmup a transient timeout / 502 would poison the cache for
    # FRESH_TTL seconds, causing every subsequent request to return 0
    # groups until the entry expires.  Only cache non-empty responses.
    if grouped:
        _nearby_resp_cache[key] = (_time.time(), grouped, json_bytes)
    return grouped


def clear_nearby_cache() -> int:
    """Clear the response-level cache. Returns number of entries cleared."""
    count = len(_nearby_resp_cache)
    _nearby_resp_cache.clear()
    _nearby_resp_inflight.clear()
    return count


# During drag search (quick=True), use 3 decimal places (~111 m grid)
# instead of 4 (~11 m) so that small pan movements hit the same cache
# cell.  This dramatically improves cache-hit rate while panning.
_QUICK_GPS_DECIMALS: int = 3


def _nearby_cache_key(
    lat: float, lon: float, radius: int, mode: str | None, *, quick: bool = False,
) -> tuple[float, float, int, str | None, bool]:
    """Round GPS to grid cells for cache bucketing.

    Normal mode: 4 decimals (~11 m).  Quick mode: 3 decimals (~111 m).
    """
    decimals = _QUICK_GPS_DECIMALS if quick else NEARBY_GPS_DECIMALS
    factor = 10**decimals
    return (round(lat * factor) / factor, round(lon * factor) / factor, radius, mode, quick)


def _find_cached_grouped_fallback(
    key: tuple[float, float, int, str | None, bool],
    now: float,
    *,
    max_age: float,
    include_neighbor_cells: bool,
) -> (
    tuple[tuple[float, float, int, str | None, bool], list[GroupedNearbyTransit], float]
    | None
):
    """Find the freshest compatible cached response for this location key.

    Exact-key matches are always considered. When ``include_neighbor_cells`` is
    true, adjacent rounded GPS cells for the same radius/mode are also eligible.
    This keeps small GPS jitter from blowing away nearby/grouped cache hits.
    """
    req_lat, req_lon, req_radius, req_mode, req_quick = key
    decimals = _QUICK_GPS_DECIMALS if req_quick else NEARBY_GPS_DECIMALS
    factor = 10**decimals
    cell_span = 1 / factor

    best: (
        tuple[
            tuple[float, float],
            tuple[float, float, int, str | None, bool],
            list[GroupedNearbyTransit],
            bytes,
        ]
        | None
    ) = None
    for candidate_key, (ts, data, jb) in _nearby_resp_cache.items():
        cand_lat, cand_lon, cand_radius, cand_mode, cand_quick = candidate_key
        if cand_radius != req_radius or cand_mode != req_mode or cand_quick != req_quick:
            continue

        lat_ok = abs(cand_lat - req_lat) < 1e-12
        lon_ok = abs(cand_lon - req_lon) < 1e-12
        if not (lat_ok and lon_ok):
            if not include_neighbor_cells:
                continue
            if (
                abs(cand_lat - req_lat) > cell_span
                or abs(cand_lon - req_lon) > cell_span
            ):
                continue

        age = now - ts
        if age > max_age:
            continue

        score = (abs(cand_lat - req_lat) + abs(cand_lon - req_lon), age)
        if best is None or score < best[0]:
            best = (score, candidate_key, data, jb)

    if best is None:
        return None
    score, candidate_key, data, json_bytes = best
    age = score[1]
    return candidate_key, data, age, json_bytes


router = APIRouter(tags=["nearby"])


@router.get(
    "/nearby",
    response_model=list[NearbyTransitArrival],
    deprecated=True,
    summary="List nearby arrivals (flat)",
    description=(
        "Returns a flat list of upcoming transit arrivals near the given coordinates. "
        "**Deprecated** — use `/nearby/grouped` instead, which groups arrivals by route, "
        "includes ML delay corrections, and benefits from response-level caching."
    ),
    responses={**RESP_503},
)
async def nearby_transit(
    response: Response,
    lat: float = Query(
        ...,
        ge=-90,
        le=90,
        description="Latitude of the user's location.",
        examples=[40.7580],
    ),
    lon: float = Query(
        ...,
        ge=-180,
        le=180,
        description="Longitude of the user's location.",
        examples=[-73.9855],
    ),
    radius: int | None = Query(
        None,
        ge=100,
        le=10000,
        description="Maximum search radius from the request location (in meters). Defaults to the server-configured value (~800\u202fm).",
        examples=[800],
    ),
) -> list[NearbyTransitArrival]:
    """Return the nearest buses and trains with live countdowns.

    **Deprecated** — prefer `/nearby/grouped` which returns one card per
    route with direction sub-groups, benefits from response-level caching,
    and includes ML delay corrections.
    """
    settings = get_settings()
    effective_radius = (
        radius if radius is not None else settings.app_settings.search_radius_meters
    )
    TrackLogger.location(lat, lon, "nearby")
    response.headers["Deprecation"] = "true"
    response.headers["Link"] = '</nearby/grouped>; rel="successor-version"'
    results = await _collect_all(lat, lon, effective_radius)
    results.sort(key=lambda a: a.minutes_away)
    return results


@router.get(
    "/nearby/grouped",
    response_model=list[GroupedNearbyTransit],
    summary="List nearby arrivals grouped by route",
    description=(
        "The primary endpoint for the Track home screen. Returns nearby transit arrivals "
        "grouped by route with direction sub-groups, ML delay corrections, inline service alerts, "
        "and MTA canonical ordering. Supports filtering by transit mode.\n\n"
        "Bus routes include a `bus_service_type` field (Local, Limited, Local / Limited, "
        "Select Bus Service, Express, School) and a `color_hex` matching the official MTA Bus Routes map palette."
    ),
    responses={**RESP_503},
)
async def nearby_transit_grouped(
    lat: float = Query(
        ...,
        ge=-90,
        le=90,
        description="Latitude of the user's location.",
        examples=[40.7580],
    ),
    lon: float = Query(
        ...,
        ge=-180,
        le=180,
        description="Longitude of the user's location.",
        examples=[-73.9855],
    ),
    radius: int | None = Query(
        None,
        ge=100,
        le=10000,
        description="Maximum search radius from the request location (in meters). Defaults to the server-configured value (~800\u202fm).",
        examples=[800],
    ),
    mode: str | None = Query(
        None,
        description="Filter results to a single transit mode. Omit for all modes.",
        examples=["subway", "bus", "lirr", "mnr"],
    ),
    quick: bool = Query(
        False,
        description=(
            "When true, skip expensive bus backfill phases (D/E/F) and use a "
            "coarser GPS grid (~111 m) for faster cache hits.  Designed for "
            "drag-to-search where speed matters more than completeness.  "
            "Full results are returned on the next non-quick refresh."
        ),
    ),
) -> list[GroupedNearbyTransit]:
    """Return nearby arrivals grouped by route with direction sub-groups.

    Instead of returning separate rows for every upcoming train, this endpoint
    returns **one card per route**. Each card contains a `directions` list
    (e.g. Northbound / Southbound) that the client can render as swipeable tabs.

    Results are sorted by the soonest arrival so the most imminent route appears first.

    **Features:**
    - Groups arrivals by route with direction sub-groups
    - Applies ML delay corrections (LightGBM + recency model)
    - Embeds inline service alerts per route
    - Bus routes include ``bus_service_type`` (Local / Limited / Local·Limited / Select Bus Service / Express / School)
      and ``color_hex`` matching the official MTA Bus Routes map palette
    - Response-level caching (5 s fresh / 30 s stale-while-revalidate)

    **Modes:** `subway`, `bus`, `lirr`, `mnr` — omit for all modes.

    Returns `503` with `Retry-After` header during server cold start (~20 s).
    """
    import time as _time

    # ── Warmup gate ─────────────────────────────────────────────
    # During cold start, feeds aren't cached yet so _collect_all
    # returns empty results.  Instead of caching & serving 0 groups
    # (which the iOS client treats as "no transit nearby"), return
    # 503 + Retry-After so the client retries after feeds are ready.
    from app.main import is_warmed_up as _is_warmed_up  # lazy to avoid circular import

    if not _is_warmed_up():
        from fastapi.responses import JSONResponse

        TrackLogger.info(
            "[WARMUP] /nearby/grouped → 503 (feeds not ready)", tag="WARMUP"
        )
        return JSONResponse(
            status_code=503,
            content={"detail": "Feeds warming up"},
            headers={"Retry-After": "5"},
        )

    settings = get_settings()
    effective_radius = (
        radius if radius is not None else settings.app_settings.search_radius_meters
    )
    TrackLogger.location(lat, lon, "nearby/grouped")

    key = _nearby_cache_key(lat, lon, effective_radius, mode, quick=quick)
    now = _time.time()

    # 1. Check cache
    cached = _nearby_resp_cache.get(key)
    if cached is not None:
        ts, _data, json_bytes = cached
        age = now - ts
        if age < NEARBY_RESPONSE_FRESH_TTL:
            TrackLogger.cache(f"RESP HIT (fresh {age:.1f}s) /nearby/grouped")
            r = Response(content=json_bytes, media_type="application/json")
            r.headers["X-Track-Cache"] = f"HIT-FRESH age={age:.1f}s"
            return r
        if age < NEARBY_RESPONSE_STALE_TTL:
            TrackLogger.cache(
                f"RESP HIT (stale {age:.1f}s) /nearby/grouped — bg refresh"
            )
            # Kick background refresh if not already in-flight
            if key not in _nearby_resp_inflight:

                async def _bg_refresh(
                    k: tuple, r: int, m: str | None, *, q: bool = False,
                ) -> list[GroupedNearbyTransit] | None:
                    try:
                        return await _compute_and_cache_grouped(k, k[0], k[1], r, m, quick=q)
                    except Exception as exc:
                        TrackLogger.info(
                            f"BG refresh /nearby/grouped failed: {_describe_exception(exc)}",
                        )
                        return None
                    finally:
                        _nearby_resp_inflight.pop(k, None)

                task = asyncio.create_task(_bg_refresh(key, effective_radius, mode, q=quick))
                _nearby_resp_inflight[key] = task
            resp = Response(content=json_bytes, media_type="application/json")
            resp.headers["X-Track-Cache"] = f"HIT-STALE age={age:.1f}s"
            return resp
        # Fall through — entry exists but is too old
        TrackLogger.cache(
            f"RESP EXPIRED age={age:.1f}s > stale_ttl={NEARBY_RESPONSE_STALE_TTL}s"
        )

    nearby_fallback = _find_cached_grouped_fallback(
        key, now, max_age=NEARBY_RESPONSE_STALE_TTL, include_neighbor_cells=True
    )
    if nearby_fallback is not None:
        fallback_key, _fallback_data, fallback_age, fallback_json = nearby_fallback
        fallback_kind = "exact" if fallback_key == key else "neighbor-cell"
        TrackLogger.cache(
            f"RESP HIT ({fallback_kind} stale {fallback_age:.1f}s) /nearby/grouped"
        )
        if key not in _nearby_resp_inflight:

            async def _bg_refresh_exact(
                k: tuple, req_lat: float, req_lon: float, r: int, m: str | None,
                *, q: bool = False,
            ) -> list[GroupedNearbyTransit] | None:
                try:
                    return await _compute_and_cache_grouped(k, req_lat, req_lon, r, m, quick=q)
                except Exception as exc:
                    TrackLogger.info(
                        f"BG refresh /nearby/grouped failed: {_describe_exception(exc)}",
                    )
                    return None
                finally:
                    _nearby_resp_inflight.pop(k, None)

            task = asyncio.create_task(
                _bg_refresh_exact(key, lat, lon, effective_radius, mode, q=quick)
            )
            _nearby_resp_inflight[key] = task
        return Response(content=fallback_json, media_type="application/json")

    # 2. Cache miss — coalesce concurrent requests for same key
    inflight = _nearby_resp_inflight.get(key)
    if inflight is not None:
        TrackLogger.cache("RESP MISS coalesced /nearby/grouped")
        result = await inflight
        if result is not None:
            # The coalesced task stored json_bytes in the cache — return those
            cached_after = _nearby_resp_cache.get(key)
            if cached_after is not None:
                _, _, jb = cached_after
                resp = Response(content=jb, media_type="application/json")
                resp.headers["X-Track-Cache"] = "COALESCED"
                return resp
            return result
        # Background refresh returned None (failed) — fall through to fresh compute

    async def _miss_compute() -> list[GroupedNearbyTransit] | Response:
        try:
            result = await _compute_and_cache_grouped(
                key, lat, lon, effective_radius, mode, quick=quick,
            )
            # Return pre-serialized bytes from cache — skip response_model
            cached_after = _nearby_resp_cache.get(key)
            if cached_after is not None:
                _, _, jb = cached_after
                resp = Response(content=jb, media_type="application/json")
                resp.headers["X-Track-Cache"] = "MISS-COMPUTED"
                return resp
            # Cache wasn't populated (e.g. result was mocked — return data directly)
            if result is not None:
                import json as _json

                resp = Response(
                    content=_json.dumps(
                        [g.model_dump() for g in result], default=str
                    ).encode(),
                    media_type="application/json",
                )
                resp.headers["X-Track-Cache"] = "MISS-COMPUTED-DIRECT"
                return resp
            raise RuntimeError("_compute_and_cache_grouped returned None")
        except Exception as exc:
            fallback = _find_cached_grouped_fallback(
                key,
                now,
                max_age=NEARBY_RESPONSE_ERROR_TTL,
                include_neighbor_cells=True,
            )
            if fallback is not None:
                fallback_key, _fallback_data, fallback_age, _fb_json = fallback
                TrackLogger.info(
                    f"RESP STALE-IF-ERROR /nearby/grouped age={fallback_age:.1f}s "
                    f"exact={fallback_key == key} because {_describe_exception(exc)}",
                    tag="CACHE",
                )
                return Response(content=_fb_json, media_type="application/json")
            raise
        finally:
            _nearby_resp_inflight.pop(key, None)

    task = asyncio.create_task(_miss_compute())
    _nearby_resp_inflight[key] = task
    return await task


# ---------------------------------------------------------------------------
# /nearby/inactive — routes serving the area with no active service
# ---------------------------------------------------------------------------

# In-memory cache: key → (timestamp, json_bytes)
_inactive_cache: dict[tuple, tuple[float, bytes]] = {}
_INACTIVE_FRESH_TTL = 300.0  # 5 min — inactive routes change slowly
_INACTIVE_STALE_TTL = 900.0  # 15 min


@lru_cache(maxsize=1)
def _load_all_gtfs_routes() -> dict[str, tuple[str, str | None, int]]:
    """Load all routes from GTFS: route_short_name → (route_id, route_color, route_type)."""
    import sqlite3

    db_path = Path("app/data/transit_schedule.db")
    if not db_path.exists():
        return {}
    try:
        conn = sqlite3.connect(db_path)
        cur = conn.cursor()
        cur.execute(
            "SELECT route_id, route_short_name, route_color, route_type FROM routes"
        )
        result: dict[str, tuple[str, str | None, int]] = {}
        for route_id, short_name, color, rtype in cur.fetchall():
            if short_name:
                result[short_name] = (route_id, color, rtype or 0)
        conn.close()
        return result
    except Exception:
        return {}


def _mode_for_route_type(route_type: int) -> str:
    """Map GTFS route_type to Track mode string."""
    if route_type == 1:
        return "subway"
    if route_type == 2:
        return "lirr"  # commuter rail (covers both LIRR / MNR in NYC)
    if route_type == 3:
        return "bus"
    return "bus"


@router.get(
    "/nearby/inactive",
    response_model=list[InactiveRoute],
    summary="List inactive transit routes in an area",
    description=(
        "Returns transit routes that serve stops near the given coordinates but "
        "have no active service right now. Designed for the 'Inactive Lines' "
        "section at the bottom of the home screen."
    ),
)
async def nearby_inactive_routes(
    lat: float = Query(
        ..., ge=-90, le=90,
        description="Latitude of the user's location.",
        examples=[40.7580],
    ),
    lon: float = Query(
        ..., ge=-180, le=180,
        description="Longitude of the user's location.",
        examples=[-73.9855],
    ),
    radius: int | None = Query(
        None, ge=100, le=10000,
        description="Search radius in meters.",
        examples=[800],
    ),
    active_routes: str | None = Query(
        None,
        description=(
            "Comma-separated display names of currently active routes "
            "(from /nearby/grouped). These will be excluded from the inactive list."
        ),
        examples=["A,C,F,B63,M34-SBS"],
    ),
) -> list[InactiveRoute]:
    """Return routes serving the area that have no active service.

    The client calls this after ``/nearby/grouped`` and passes the
    ``active_routes`` it received so the backend can subtract them.
    """
    import json as _json
    import time as _time

    settings = get_settings()
    effective_radius = (
        radius if radius is not None else settings.app_settings.search_radius_meters
    )

    # Coarse grid key (same 3-decimal quick grid)
    grid_lat = round(lat, 3)
    grid_lon = round(lon, 3)
    cache_key = (grid_lat, grid_lon, effective_radius)

    now = _time.time()
    cached = _inactive_cache.get(cache_key)
    if cached is not None:
        ts, jb = cached
        if now - ts < _INACTIVE_FRESH_TTL:
            # Filter by current active_routes before returning
            return _filter_inactive_json(jb, active_routes)

    # Discover all routes serving nearby stops via GTFS static data.
    # Use a wider radius (2x) for inactive discovery — express buses (QM, BxM,
    # SIM) often have their nearest stop 1–2 km away but still serve the area.
    # The active endpoint already handles the tight radius; the inactive list
    # benefits from being more inclusive so users see routes like QM1/QM17
    # which have stops ~1.3 km away.
    discovery_radius = min(effective_radius * 2, 5000)
    all_routes_in_area = await _discover_routes_in_area(lat, lon, discovery_radius)
    bus_route_color_lookup = _build_bus_route_color_lookup(await get_all_bus_routes())

    # Build InactiveRoute objects (before filtering by active — cache the full set)
    inactive_list: list[InactiveRoute] = []
    for display_name_raw, (route_id, color, route_type) in sorted(all_routes_in_area.items()):
        display_name = _normalize_route_display(display_name_raw)
        mode = _mode_for_route_type(route_type)
        service_type = _classify_bus_service_type(display_name) if mode == "bus" else None
        color_hex = None
        if mode == "bus":
            color_hex = _bus_color_for_service_type(service_type or "Local")
        elif color:
            color_hex = f"#{color}" if not color.startswith("#") else color

        # Guarantee color_hex is never null — fall back to mode default
        if not color_hex:
            color_hex = _brand_mode_color(mode)

        inactive_list.append(
            InactiveRoute(
                route_id=route_id,
                display_name=display_name,
                mode=mode,
                color_hex=color_hex,
                text_color_hex=_brand_text_color(mode, route_id),
                mode_name=_brand_mode_name(mode),
                bus_service_type=service_type,
                sorting_key=_sorting_key(mode, display_name),
            )
        )

    inactive_list.sort(key=lambda r: r.sorting_key)

    # Cache the full list
    jb = _json.dumps([r.model_dump() for r in inactive_list]).encode()
    _inactive_cache[cache_key] = (now, jb)

    # Evict old entries
    stale_keys = [k for k, (t, _) in _inactive_cache.items() if now - t > _INACTIVE_STALE_TTL]
    for k in stale_keys:
        _inactive_cache.pop(k, None)

    # Filter out currently active routes and return
    if active_routes:
        active_set = {n.strip().upper() for n in active_routes.split(",") if n.strip()}
        return [r for r in inactive_list if r.display_name.upper() not in active_set]
    return inactive_list


def _filter_inactive_json(jb: bytes, active_routes: str | None) -> list[InactiveRoute]:
    """Deserialize cached inactive list and filter out active routes."""
    import json as _json

    raw = _json.loads(jb)
    all_routes = [InactiveRoute(**r) for r in raw]
    if not active_routes:
        return all_routes
    active_set = {n.strip().upper() for n in active_routes.split(",") if n.strip()}
    return [r for r in all_routes if r.display_name.upper() not in active_set]


async def _discover_routes_in_area(
    lat: float, lon: float, radius_m: int,
) -> dict[str, tuple[str, str | None, int]]:
    """Return display_name → (route_id, route_color, route_type) for all GTFS routes
    serving stops within radius_m of (lat, lon)."""
    from app.services.transit.db_pool import schedule_pool

    db_path = Path("app/data/transit_schedule.db")
    if not db_path.exists():
        return {}

    from app.providers import get_provider as _get_provider

    _prov = _get_provider()
    lat_span = radius_m / _prov.meters_per_deg_lat
    lon_span = radius_m / _prov.meters_per_deg_lon

    try:
        async with schedule_pool.acquire() as conn:
            cursor = await conn.execute(
                """
                SELECT DISTINCT
                    r.route_id, r.route_short_name, r.route_color, r.route_type
                FROM stops s
                JOIN stop_times st ON st.stop_id = s.stop_id
                JOIN trips t ON t.trip_id = st.trip_id
                JOIN routes r ON r.route_id = t.route_id
                WHERE s.stop_lat BETWEEN ? AND ?
                  AND s.stop_lon BETWEEN ? AND ?
                """,
                (lat - lat_span, lat + lat_span, lon - lon_span, lon + lon_span),
            )
            result: dict[str, tuple[str, str | None, int]] = {}
            for route_id, short_name, color, rtype in await cursor.fetchall():
                if short_name:
                    result[short_name] = (route_id, color, rtype or 0)
            return result
    except Exception as exc:
        TrackLogger.info(f"Inactive route discovery failed: {exc}", exc_info=True)
        return {}


# ---------------------------------------------------------------------------
# Shared data collection
# ---------------------------------------------------------------------------


async def _collect_all(
    lat: float,
    lon: float,
    radius: int | None = None,
    *,
    mode_filter: str | None = None,
    quick: bool = False,
) -> list[NearbyTransitArrival]:
    """Gather subway + bus arrivals in parallel.

    When *mode_filter* is provided (e.g. ``"subway"``, ``"bus"``, ``"lirr"``,
    ``"mnr"``), only that mode is fetched — skipping unnecessary network
    calls for the other feeds.

    When *quick* is ``True`` (drag-search), bus Phase D/E/F backfill is
    skipped for faster response at the cost of completeness.

    Uses ``asyncio.wait()`` with an explicit timeout so that:
    1. Completed modes return partial results even when others are slow.
    2. Pending tasks are **cancelled and awaited** — no zombie tasks
       that continue blocking the event loop after the timeout fires.

    Previous implementation used ``asyncio.ensure_future(asyncio.wait_for(…))``
    which created detached tasks that survived cancellation of the parent
    ``_collect_all`` coroutine, causing 97 s response times when only 45 s
    was budgeted.
    """
    settings = get_settings()
    effective_radius = (
        radius if radius is not None else settings.app_settings.search_radius_meters
    )
    results: list[NearbyTransitArrival] = []

    _WAIT_TIMEOUT = 42  # seconds — wall-clock budget for all modes

    import time as _t

    _t0 = _t.perf_counter()

    import time as _mono

    _collect_deadline = _mono.monotonic() + _WAIT_TIMEOUT

    # Build task dict — plain create_task, NO nested wait_for
    # Pre-warm alert index + weather cache runs AS A TASK alongside the
    # mode fetchers — not sequentially before them — so we don't lose
    # 0.7–10 s of the 38 s budget on the first HTTP fetch.
    async def _pre_warm() -> list:
        await _maybe_refresh_alerts()
        from app.clients.weather_client import get_current_weather

        await get_current_weather()
        return []  # return empty list so it blends with other results

    tasks: dict[str, asyncio.Task] = {}
    tasks["_warm"] = asyncio.create_task(_pre_warm())
    if mode_filter is None or mode_filter == "subway":
        tasks["subway"] = asyncio.create_task(
            _fetch_nearby_subway(
                lat, lon, effective_radius, _deadline=_collect_deadline
            )
        )
    if mode_filter is None or mode_filter == "bus":
        tasks["bus"] = asyncio.create_task(
            _fetch_nearby_buses(lat, lon, effective_radius, quick=quick)
        )
    if mode_filter is None or mode_filter == "lirr":
        tasks["lirr"] = asyncio.create_task(
            _fetch_nearby_rail(lat, lon, effective_radius, "lirr")
        )
    if mode_filter is None or mode_filter == "mnr":
        tasks["mnr"] = asyncio.create_task(
            _fetch_nearby_rail(lat, lon, effective_radius, "mnr")
        )

    if not tasks:
        return results

    # Map Task → label for result harvesting
    task_to_label = {t: lbl for lbl, t in tasks.items()}

    # ── Wait with timeout, then forcibly cancel stragglers ──────────
    pending: set[asyncio.Task] = set()
    try:
        _done, pending = await asyncio.wait(
            tasks.values(),
            timeout=_WAIT_TIMEOUT,
            return_when=asyncio.ALL_COMPLETED,
        )
    except asyncio.CancelledError:
        # Parent (_compute_and_cache_grouped) cancelled us — propagate
        for t in tasks.values():
            t.cancel()
        await asyncio.gather(*tasks.values(), return_exceptions=True)
        raise
    finally:
        # Cancel every task that didn't finish in time
        for t in pending:
            t.cancel()
        # Wait briefly for cancellations to propagate.  Don't block
        # indefinitely — run_in_executor threads (protobuf parsing)
        # can't be interrupted; they'll finish in the background.
        if pending:
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(
                    asyncio.gather(*pending, return_exceptions=True),
                    timeout=2.0,
                )

    _elapsed = _t.perf_counter() - _t0

    # ── Harvest results ─────────────────────────────────────────────
    _mode_times: dict[str, str] = {}
    for task in tasks.values():
        label = task_to_label[task]
        if label.startswith("_"):
            continue  # skip internal helper tasks (_warm)
        if task in pending:
            _mode_times[label] = "TIMEOUT"
            TrackLogger.info(
                f"{label.upper()} feed cancelled after {_WAIT_TIMEOUT}s — partial results returned",
                tag="NEARBY",
            )
        elif task.cancelled():
            _mode_times[label] = "CANCELLED"
        elif task.exception() is not None:
            exc = task.exception()
            TrackLogger.info(
                f"{label.upper()} feed failed: {_describe_exception(exc)}",
                tag="NEARBY",
            )
            _mode_times[label] = "FAILED"
        else:
            result = task.result()
            if isinstance(result, list):
                results.extend(result)
                _mode_times[label] = f"{len(result)} items"
            else:
                _mode_times[label] = "empty"

    TrackLogger.info(
        f"[COLLECT] {_elapsed:.3f}s r={effective_radius}m "
        f"mode={mode_filter or 'all'} {_mode_times}",
        tag="NEARBY",
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
        TrackLogger.info(
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


# MTA GTFS static data and SIRI real-time feeds sometimes disagree on zero-padding:
# GTFS has "Q07" while SIRI sends "Q7". Normalise so both collapse to "Q7".
_LEADING_ZERO_RE = re.compile(r"^([A-Za-z]+)0+(\d+)$")


def _normalize_route_display(name: str) -> str:
    """Strip leading zeros and normalise SBS suffix on bus route display names.

    Examples:
      Q07      → Q7
      B09      → B9
      M34-SBS  → M34+   (MTA canonical SBS notation)
      M34+SBS  → M34+
      M34+     → M34+   (already canonical, unchanged)
      Bx12     → Bx12   (no leading zeros, not SBS)

    Subway/LIRR/MNR identifiers are unaffected.
    """
    # Normalise SBS variants to trailing "+" before stripping leading zeros
    normalized = re.sub(r"-SBS$", "+", name, flags=re.IGNORECASE)
    normalized = re.sub(r"\+SBS$", "+", normalized, flags=re.IGNORECASE)
    m = _LEADING_ZERO_RE.match(normalized)
    return (m.group(1) + m.group(2)) if m else normalized


def _display_name(route_id: str) -> str:
    """Build a user-facing display name for a route_id.

    Strips agency prefixes for subway/bus using the data-driven
    ``BUS_AGENCY_PREFIXES`` set (built from early_2026_buses_tag.json
    at import time).  This automatically supports any new agency
    prefix the MTA introduces without code changes.

    Additionally normalises bus route numbers to remove MTA-feed
    leading-zero inconsistencies (Q07 → Q7, Q09 → Q9).

    Currently known bus prefixes: ``MTA NYCT_``, ``MTABC_``, ``MTA BUS_``.
    LIRR/MNR numeric IDs are resolved to human-readable branch names.
    """
    # Bus / subway: strip any known agency prefix then normalise zero-padding
    for prefix in BUS_AGENCY_PREFIXES:
        if route_id.startswith(prefix):
            raw = _normalize_route_display(route_id[len(prefix) :])
            # Normalise to canonical mixed-case (e.g. "BXM2" → "BxM2")
            return CANONICAL_BUS_DISPLAY.get(raw.upper(), raw)

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

# Canonical opposite-direction mapping.  Reused by _opposite_direction_key()
# and Phase C bus backfill — single source of truth.
# Values use title-case to match _DIRECTION_LABELS conventions.
_OPPOSITE_COMPASS: dict[str, str] = {
    "N": "S",
    "S": "N",
    "E": "W",
    "W": "E",
    "NE": "SW",
    "SW": "NE",
    "NW": "SE",
    "SE": "NW",
    "INBOUND": "Outbound",
    "OUTBOUND": "Inbound",
}


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


def _direction_label(
    direction: str, arrivals: list[NearbyTransitArrival] | None = None
) -> str:
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
            if (
                a.destination
                and a.destination.strip()
                and a.destination.strip().lower() != "unknown"
            ):
                return a.destination.strip()
        return None

    terminal = _primary_destination(arrivals)
    route_id = arrivals[0].route_id if arrivals else None

    # For legacy numeric direction keys (DirectionRef fallback),
    # try to get the destination from the first arrival.
    if direction in _NUMERIC_DIR_KEYS and arrivals:
        if terminal:
            return terminal
        # Try GTFS headsign for numeric direction keys
        if route_id:
            did = int(direction) if direction in ("0", "1") else None
            if did is not None:
                headsigns = schedule_service.get_headsigns_for_route(
                    _display_name(route_id), direction_id=did
                )
                if did in headsigns:
                    return headsigns[did]
        return _DIRECTION_LABELS.get(direction, f"Direction {direction}")

    upper = direction.upper()

    # Known compass / special codes → canonical label
    if upper in _DIRECTION_LABELS:
        base_label = _DIRECTION_LABELS[upper]
        # Append the terminal destination when available so the user
        # sees where the bus/train is going (e.g. "Northbound → Inwood-207 St")
        # instead of bare "Northbound".
        if terminal:
            return f"{base_label} → {terminal}"

        # For Inbound/Outbound without a terminal, try GTFS headsign
        # so the label shows "Inbound → Penn Station" instead of bare "Inbound".
        if upper in ("INBOUND", "OUTBOUND") and route_id:
            did = 0 if upper == "INBOUND" else 1
            # Strip LIRR_/MNR_ prefix for GTFS lookup — GTFS uses bare numeric IDs
            lookup = route_id
            if lookup.startswith("LIRR_"):
                lookup = lookup[5:]
            elif lookup.startswith("MNR_"):
                lookup = lookup[4:]
            else:
                lookup = _display_name(route_id)
            headsigns = schedule_service.get_headsigns_for_route(
                lookup, direction_id=did
            )
            if did in headsigns:
                return f"{base_label} → {headsigns[did]}"

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

    # Compass and commuter-rail canonical pairs (reuse module constant)
    if upper in _OPPOSITE_COMPASS:
        return _OPPOSITE_COMPASS[upper]
    # Numeric SIRI direction refs
    _NUMERIC_OPPOSITE = {"0": "1", "1": "0", "2": "3", "3": "2"}
    if upper in _NUMERIC_OPPOSITE:
        return _NUMERIC_OPPOSITE[upper]

    # For destination-name direction keys, return None — the caller should
    # use _resolve_opposite_headsign() to look up the GTFS headsign for
    # the other direction instead of falling back to generic "Outbound".
    return None


# ── GTFS headsign cache for opposite-direction placeholders ──────────
# Avoids hitting the SQLite DB on every call to _resolve_opposite_headsign().
_headsign_cache: dict[str, dict[int, str]] = {}  # route_id → {direction_id: headsign}


def _resolve_opposite_headsign(
    route_id: str,
    primary_direction: str,
    primary_arrivals: list[NearbyTransitArrival],
) -> str | None:
    """Look up the GTFS trip_headsign for the direction opposite to `primary_direction`.

    Uses the GTFS trips table to find real terminal names instead of generic
    "Outbound"/"Inbound" labels.  Returns the headsign string if found,
    or None if the headsign can't be determined.

    Strategy:
    1. Get all headsigns for this route from GTFS (cached).
    2. The primary direction's arrivals tell us which direction_id it is.
    3. The opposite direction_id's headsign is the answer.
    """
    # Normalise route_id for GTFS lookup — strip agency prefixes
    lookup_id = route_id
    for prefix in BUS_AGENCY_PREFIXES:
        if lookup_id.startswith(prefix):
            lookup_id = lookup_id[len(prefix) :]
            break

    # LIRR/MNR: strip "LIRR_" / "MNR_" prefix — GTFS stores bare numeric IDs
    if lookup_id.startswith("LIRR_"):
        lookup_id = lookup_id[5:]
    elif lookup_id.startswith("MNR_"):
        lookup_id = lookup_id[4:]

    # Fetch headsigns from cache or DB
    if lookup_id not in _headsign_cache:
        headsigns = schedule_service.get_headsigns_for_route(lookup_id)
        # Also try with common agency prefixes if direct lookup is empty
        if not headsigns:
            for pfx in ["MTABC_", "MTA NYCT_"]:
                headsigns = schedule_service.get_headsigns_for_route(
                    f"{pfx}{lookup_id}"
                )
                if headsigns:
                    break
        _headsign_cache[lookup_id] = headsigns

    headsigns = _headsign_cache.get(lookup_id, {})
    if not headsigns:
        return None

    # Determine which direction_id the primary direction corresponds to.
    # Compare the primary direction key (or its arrivals' destinations)
    # against the cached headsigns to infer direction_id.
    primary_upper = primary_direction.upper().strip()

    # Check if primary direction matches a known headsign
    matched_dir_id: int | None = None
    for did, hs in headsigns.items():
        hs_upper = hs.upper().strip()
        # Exact match or substring match (e.g. "JAMAICA" matches "Jamaica")
        if (
            primary_upper == hs_upper
            or primary_upper in hs_upper
            or hs_upper in primary_upper
        ):
            matched_dir_id = did
            break

    # Try matching against arrival destinations if direction key didn't match
    if matched_dir_id is None and primary_arrivals:
        for arr in primary_arrivals:
            if not arr.destination or arr.destination.strip().lower() in (
                "",
                "unknown",
            ):
                continue
            dest_upper = arr.destination.upper().strip()
            for did, hs in headsigns.items():
                hs_upper = hs.upper().strip()
                if (
                    dest_upper == hs_upper
                    or dest_upper in hs_upper
                    or hs_upper in dest_upper
                ):
                    matched_dir_id = did
                    break
            if matched_dir_id is not None:
                break

    # If we identified the primary direction_id, return the opposite
    if matched_dir_id is not None:
        opposite_did = 1 - matched_dir_id  # 0→1, 1→0
        if opposite_did in headsigns:
            return headsigns[opposite_did]

    # Fallback: if we have exactly 2 direction_ids, pick the one that
    # doesn't match the primary
    if len(headsigns) == 2 and set(headsigns.keys()) == {0, 1}:
        # Pick whichever headsign is NOT similar to the primary direction
        for _did, hs in headsigns.items():
            hs_upper = hs.upper().strip()
            if (
                primary_upper != hs_upper
                and primary_upper not in hs_upper
                and hs_upper not in primary_upper
            ):
                return hs

    # Last resort: return whichever headsign we have if there's only one
    # and it's different from the primary
    for _did, hs in headsigns.items():
        hs_upper = hs.upper().strip()
        if primary_upper != hs_upper:
            return hs

    return None


# ── MTA canonical sort order ──────────────────────────────────────────
# Subway letters are grouped by service family and displayed in the
# standard MTA order.  Routes not in this map sort alphabetically after
# all entries that are.
_MTA_SUBWAY_SORT: dict[str, str] = {
    "1": "010",
    "2": "011",
    "3": "012",
    "4": "020",
    "5": "021",
    "6": "022",
    "6X": "023",
    "7": "030",
    "7X": "031",
    "A": "040",
    "C": "041",
    "E": "042",
    "B": "050",
    "D": "051",
    "F": "052",
    "FX": "053",
    "M": "054",
    "G": "060",
    "J": "070",
    "Z": "071",
    "L": "080",
    "N": "090",
    "Q": "091",
    "R": "092",
    "W": "093",
    "S": "100",
    "SI": "110",
}


def _sorting_key(mode: str, display: str) -> str:
    """Return a sort key that reproduces the canonical MTA display order."""
    if mode == "subway":
        return _MTA_SUBWAY_SORT.get(display.upper(), f"999_{display}")
    if mode == "lirr":
        return f"A_LIRR_{display}"
    if mode == "mnr":
        return f"B_MNR_{display}"
    # Bus: sort numerically if possible, then alphabetically
    digits = "".join(c for c in display if c.isdigit())
    prefix = "".join(c for c in display if c.isalpha())
    num_part = digits.zfill(4) if digits else "9999"
    return f"C_BUS_{prefix}_{num_part}"


# ── Inline alert index (refreshed with each grouped call) ────────────
# Keys are uppercased route display names so "A" matches alert for "A".
_inline_alert_cache: dict[str, list[InlineAlert]] = {}
_inline_alert_ts: float = 0.0


async def _get_inline_alerts() -> dict[str, list[InlineAlert]]:
    """Return a dict mapping uppercased route display names to InlineAlerts."""
    global _inline_alert_cache, _inline_alert_ts
    import time as _t

    now = _t.time()
    if now - _inline_alert_ts < 120.0 and _inline_alert_cache:
        return _inline_alert_cache

    try:
        from app.services.gtfs.realtime_parser import get_alerts

        raw_alerts = await asyncio.wait_for(get_alerts(), timeout=3.0)
        index: dict[str, list[InlineAlert]] = defaultdict(list)
        for alert in raw_alerts:
            sev = (alert.severity or "").lower()
            if sev not in ("severe", "warning"):
                continue
            inline = InlineAlert(
                title=alert.title,
                severity=sev,
                affected_routes=alert.affected_routes,
                alert_type=alert.alert_type,
                sort_order=alert.sort_order,
            )
            for rid in alert.affected_routes:
                key = rid.upper().strip()
                if "_" in key:
                    key = key.split("_")[-1]
                index[key].append(inline)
            if alert.route_id:
                key = alert.route_id.upper().strip()
                if "_" in key:
                    key = key.split("_")[-1]
                if key not in index or inline not in index[key]:
                    index[key].append(inline)
        _inline_alert_cache = dict(index)
        _inline_alert_ts = now
    except TimeoutError:
        TrackLogger.info(
            "Inline alert fetch timed out after 3s — using stale cache", tag="NEARBY"
        )
    except Exception as exc:
        TrackLogger.info(f"Inline alert fetch failed: {exc}")
    return _inline_alert_cache


def _group_arrivals(
    flat: list[NearbyTransitArrival],
    alert_index: dict[str, list[InlineAlert]] | None = None,
    bus_color_lookup: dict[str, str] | None = None,
) -> list[GroupedNearbyTransit]:
    """Collapse a flat arrival list into one entry per route.

    Each route gets direction buckets (e.g. "N" / "S" for subway,
    or compass directions like "SW" / "NE" for buses).  Arrivals
    inside each direction are sorted by ``minutes_away``.

    Grouping is keyed on ``(mode, normalised_display_name)`` rather than the
    raw ``route_id`` so that GTFS-static IDs (e.g. ``MTABC_Q07``) and
    real-time IDs (e.g. ``MTA NYCT_Q7``) that refer to the same physical
    route are merged into a single card instead of appearing twice.

    Express subway variants (6X, 7X, FX) are merged into their local
    counterpart's group (6, 7, F) so a single card shows combined
    arrivals with an ``express_routes`` list indicating active express
    service.
    """
    # Express subway variants → local base route for merge grouping.
    _express_to_local: dict[str, str] = {"6X": "6", "7X": "7", "FX": "F"}

    by_route: dict[str, dict[str, list[NearbyTransitArrival]]] = defaultdict(
        lambda: defaultdict(list),
    )
    # merge_key → (mode, display_name, canonical_route_id)
    route_meta: dict[str, tuple[str, str, str]] = {}
    # merge_key → set of express variant display names seen
    express_seen: dict[str, set[str]] = defaultdict(set)

    for a in flat:
        display = _display_name(a.route_id)  # already normalised
        upper = display.upper()

        # Merge express subway variants into the local base route's group.
        base = _express_to_local.get(upper)
        if base and a.mode == "subway":
            merge_display = base
            express_seen_key = f"{a.mode}:{base.upper()}"
            express_seen[express_seen_key].add(upper)
        else:
            merge_display = display

        merge_key = f"{a.mode}:{merge_display.upper()}"
        by_route[merge_key][a.direction].append(a)
        if merge_key not in route_meta:
            # Keep the first-seen raw route_id as the canonical identifier
            # so the client's favourite-matching logic (which uses route_id)
            # continues to work with whichever ID was stored first.
            # For express merges, use the local base as canonical.
            canonical_id = base if base and a.mode == "subway" else a.route_id
            route_meta[merge_key] = (a.mode, merge_display, canonical_id)

    groups: list[GroupedNearbyTransit] = []
    single_direction_before = 0
    single_direction_after = 0

    def _has_live_arrivals(direction_group: DirectionArrivals) -> bool:
        return any(
            a.minutes_away < _PLACEHOLDER_MINUTES for a in direction_group.arrivals
        )

    def _direction_sort_key(
        direction_group: DirectionArrivals,
    ) -> tuple[int, int, int, str]:
        direction = direction_group.direction
        has_live = _has_live_arrivals(direction_group)
        is_fallback = _is_fallback_direction_key(direction)
        return (
            0 if not is_fallback else 1,
            0 if has_live else 1,
            0,
            direction.upper(),
        )

    for merge_key, dir_map in by_route.items():
        mode, display, route_id = route_meta[merge_key]
        bus_svc: str | None = None  # set only for bus routes
        # Assign color: subway lines use the official palette,
        # LIRR/MNR use per-branch colors from routes.txt,
        # and bus routes use the canonical service-type palette so local
        # buses stay blue, SBS stays cyan, limited stays purple, etc.
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
            bus_svc = _classify_bus_service_type(display)
            color = _bus_color_for_service_type(bus_svc)

        directions: list[DirectionArrivals] = []
        for direction, arrivals in dir_map.items():
            arrivals.sort(key=lambda a: a.minutes_away)

            # ── Deduplicate by vehicle / trip ─────────────────────────────
            # SIRI emits one prediction per upcoming stop for every vehicle, so
            # the same bus appears 5-7 times in the flat list.  We keep exactly
            # ONE prediction per unique vehicle: the one at the stop that is
            # CLOSEST TO THE USER (smallest distance_m).  This is the prediction
            # the iOS countdown chips should show.
            #
            # Previous bug: we kept the *globally soonest* prediction (stop
            # nearest the bus).  iOS then filtered chips to arrivals at the
            # user's nearest stop — but after dedup only the bus-nearest stop
            # survived, so the user's stop had no match → chips disappeared.
            #
            # Fix: group predictions by vehicle, pick the one with min distance_m
            # (fallback: min minutes_away when distance is unknown).
            # Scheduled/GTFS-static entries (key is None) are kept as-is.
            from collections import defaultdict as _dd

            _veh_groups: dict[str, list] = _dd(list)
            _no_key: list[NearbyTransitArrival] = []
            for arr in arrivals:
                _k = arr.vehicle_id or arr.trip_id
                if _k is None:
                    _no_key.append(arr)
                else:
                    _veh_groups[_k].append(arr)

            deduped: list[NearbyTransitArrival] = list(_no_key)
            for _preds in _veh_groups.values():
                # Pick the prediction at the stop closest to the user.
                # distance_m is None for entries that lack coordinates; rank
                # those last so coordinate-rich entries always win.
                best = min(
                    _preds,
                    key=lambda a: (
                        a.distance_m if a.distance_m is not None else float("inf"),
                        a.minutes_away,
                    ),
                )
                deduped.append(best)

            deduped.sort(key=lambda a: a.minutes_away)  # re-sort by ETA
            arrivals = deduped  # noqa: PLW2901
            # ─────────────────────────────────────────────────────────────

            directions.append(
                DirectionArrivals(
                    direction=direction,
                    direction_label=_direction_label(direction, arrivals),
                    arrivals=arrivals,
                )
            )

        # ── Cross-direction vehicle dedup ─────────────────────────────────
        # A vehicle can appear in multiple direction buckets when SIRI
        # predictions for that vehicle span stops that map to different
        # headsign keys (e.g. the same bus appears in both "RUSH JFK AIRPORT"
        # AND "RUSH KEW GARDENS").  Keep each vehicle only in the direction
        # where its user-nearest stop has the SMALLEST distance_m.
        # Per-direction dedup above already selected the closest stop per
        # vehicle within each direction, so we just arbitrate across buckets.
        _veh_best_dir: dict[str, tuple[float, int]] = {}  # vkey → (dist, dir_idx)
        for _dx, _d in enumerate(directions):
            for _arr in _d.arrivals:
                _vk = _arr.vehicle_id or _arr.trip_id
                if _vk is None:
                    continue
                _dist = _arr.distance_m if _arr.distance_m is not None else float("inf")
                if _vk not in _veh_best_dir or _dist < _veh_best_dir[_vk][0]:
                    _veh_best_dir[_vk] = (_dist, _dx)
        for _dx, _d in enumerate(directions):
            _d.arrivals = [
                _arr
                for _arr in _d.arrivals
                if (_arr.vehicle_id or _arr.trip_id) is None
                or _veh_best_dir.get(_arr.vehicle_id or _arr.trip_id, (None, _dx))[1]
                == _dx
            ]
        # ─────────────────────────────────────────────────────────────────

        # ── Drop compass-only placeholder tabs ────────────────────────────
        # Phase B backfill creates direction tabs keyed by OBA compass
        # bearing ("NE", "NW", "SW", etc.) that contain ONLY placeholder
        # arrivals (99 min, no arrival_ts).  When the route already has
        # at least one real destination-name direction tab with live data,
        # these compass tabs are noise — the user sees confusing labels
        # like "Northwest" with no useful timing info.
        #
        # Remove compass-only placeholder tabs when:
        #   1. Direction key is a known compass/fallback key
        #   2. ALL arrivals in the tab are placeholders (minutes >= 99, no ts)
        #   3. At least one OTHER tab has real arrivals
        has_any_semantic_live = any(
            not _is_fallback_direction_key(d.direction)
            and any(
                a.minutes_away < _PLACEHOLDER_MINUTES or a.arrival_ts is not None
                for a in d.arrivals
            )
            for d in directions
        )
        if has_any_semantic_live and len(directions) > 1:
            _before_prune = len(directions)
            directions = [
                d
                for d in directions
                if not (
                    _is_fallback_direction_key(d.direction)
                    and all(
                        a.minutes_away >= _PLACEHOLDER_MINUTES and a.arrival_ts is None
                        for a in d.arrivals
                    )
                )
            ]
            _pruned = _before_prune - len(directions)
            if _pruned:
                TrackLogger.debug(
                    f"Pruned {_pruned} compass-only placeholder tab(s) from {display}"
                )
        # ─────────────────────────────────────────────────────────────────

        if len(directions) == 1:
            single_direction_before += 1

            primary = directions[0]
            allow_opposite_placeholder = True

            # Step 1: Try canonical compass/numeric opposite
            opposite = _opposite_direction_key(mode, primary.direction)

            # Step 2: If no canonical opposite (destination-name direction),
            # look up the GTFS headsign for the other direction so the
            # placeholder tab shows a real terminal name (e.g. "Jamaica")
            # instead of generic "Outbound".
            if opposite is None:
                headsign = _resolve_opposite_headsign(
                    route_id, primary.direction, primary.arrivals
                )
                if headsign:
                    opposite = headsign
                    TrackLogger.debug(
                        f"GTFS headsign for opposite of '{primary.direction}' "
                        f"on {display}: '{headsign}'"
                    )
                else:
                    # Last resort — fall back to generic label
                    opposite = _OPPOSITE_DIRECTION

            if (
                allow_opposite_placeholder
                and opposite
                and opposite != primary.direction
                and opposite.upper() != primary.direction.upper()
                and opposite not in dir_map
            ):
                exemplar = primary.arrivals[0] if primary.arrivals else None
                placeholder = NearbyTransitArrival(
                    route_id=route_id,
                    stop_name=exemplar.stop_name if exemplar else display,
                    direction=opposite,
                    destination=(
                        opposite if not _is_fallback_direction_key(opposite) else None
                    ),
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
                    is_express=_is_express_service(route_id, mode),
                )
                directions.append(
                    DirectionArrivals(
                        direction=opposite,
                        direction_label=_direction_label(opposite, [placeholder]),
                        arrivals=[placeholder],
                    )
                )

        if len(directions) == 1:
            single_direction_after += 1

        # Prioritise terminal/live directions before fallback placeholders
        # (prevents transient "Outbound" tabs from becoming the default tab).
        directions.sort(key=_direction_sort_key)

        # Attach inline alerts if available
        route_alerts: list[InlineAlert] = []
        if alert_index:
            key = display.upper().strip()
            route_alerts = list(alert_index.get(key, []))
            # Also pull in alerts for express variants merged into this group.
            for ev in express_seen.get(merge_key, set()):
                for a in alert_index.get(ev.upper().strip(), []):
                    if a not in route_alerts:
                        route_alerts.append(a)

        # Collect express variant IDs active in this merged group.
        active_express = sorted(express_seen.get(merge_key, set()))

        groups.append(
            GroupedNearbyTransit(
                route_id=route_id,
                display_name=display,
                mode=mode,
                color_hex=color,
                text_color_hex=_brand_text_color(mode, route_id),
                mode_name=_brand_mode_name(mode),
                directions=directions,
                sorting_key=_sorting_key(mode, display),
                alerts=route_alerts,
                express_routes=active_express,
                bus_service_type=bus_svc if mode == "bus" else None,
            )
        )

    # Keep placeholder-only groups visible.  Phase E adds routes from the
    # static GTFS index that have confirmed nearby stops but no live SIRI
    # data.  Dropping them hides legitimate routes the user could walk to.
    # Log for debugging but do NOT prune.
    def _has_any_real(g: GroupedNearbyTransit) -> bool:
        return any(
            a.minutes_away < _PLACEHOLDER_MINUTES or a.arrival_ts is not None
            for d in g.directions
            for a in d.arrivals
        )

    placeholder_only = [g for g in groups if not _has_any_real(g)]
    if placeholder_only:
        names = [g.display_name for g in placeholder_only]
        TrackLogger.debug(
            f"{len(placeholder_only)} placeholder-only route(s) kept "
            f"(GTFS-backed, no live data): {names}"
        )

    # Sort groups by canonical MTA order, then by soonest arrival
    groups.sort(key=lambda g: (g.sorting_key, _soonest_minutes(g)))

    if single_direction_after > 0:
        # Real problem: routes that slipped through all backfill phases with only 1 direction.
        slipped = [g.route_id for g in groups if len(g.directions) == 1]
        TrackLogger.info(
            f"[BACKFILL GAP] {single_direction_after} route(s) still have only 1 direction "
            f"after Phase B/C and grouping fix: {slipped}"
        )
    elif single_direction_before:
        TrackLogger.debug(
            f"All 1-direction routes fixed by backfill: "
            f"{single_direction_before} routes → 0 remaining after Phase B/C"
        )

    return groups


def _soonest_minutes(group: GroupedNearbyTransit) -> int:
    """Return the smallest ``minutes_away`` across all directions."""
    mins = [a.minutes_away for d in group.directions for a in d.arrivals]
    return min(mins) if mins else 999


# ---------------------------------------------------------------------------
# Subway helpers
# ---------------------------------------------------------------------------


async def _fetch_nearby_subway(
    lat: float,
    lon: float,
    radius: int,
    *,
    _deadline: float | None = None,
) -> list[NearbyTransitArrival]:
    """Fetch arrivals from all subway feeds, filtered to nearby stations.

    Uses the GTFS stops.txt station database to determine which stop_ids
    are within the user's search radius, so we only return trains that
    are actually arriving at stations the user could walk to.
    """
    get_settings()
    results: list[NearbyTransitArrival] = []

    # Pre-compute which stop_ids are within range of the user
    # agency="subway" ensures LIRR/MNR stops are excluded at the source
    nearby_stops = get_nearby_stop_ids(lat, lon, float(radius), agency="subway")
    if not nearby_stops:
        TrackLogger.info(
            f"No subway stations within {radius}m of ({lat:.5f}, {lon:.5f})"
        )
        return results

    TrackLogger.info(f"Found {len(nearby_stops)} subway stop_ids within {radius}m")

    # Pick representative lines (one per feed) to avoid duplicate fetches
    feed_lines = ["A", "G", "N", "1", "B", "J", "L"]

    tasks = [get_arrivals_for_line(line) for line in feed_lines]
    feed_results = await asyncio.gather(*tasks, return_exceptions=True)

    # Pre-fetch all recency errors in ONE pipeline before the correction loop.
    # Without this, N arrivals × 3 Redis calls each = hundreds of connections.
    # Deduplication inside the batch call means repeated (route, stop) pairs
    # (e.g. "A A57S" appearing 8× for 8 upcoming A trains) cost only 3 ops total.
    _now_dt = datetime.now(UTC)
    _batch_dow = (_now_dt.isoweekday() % 7) + 1
    _batch_hour = _now_dt.hour
    _subway_recency_qs: list[tuple[str, str, int, int]] = []
    for _ln, _arrs in zip(feed_lines, feed_results, strict=False):
        if isinstance(_arrs, Exception) or not isinstance(_arrs, list):
            continue
        for _a in _arrs:
            if _a.minutes_away <= 0 or _a.station not in nearby_stops:
                continue
            _subway_recency_qs.append(
                (_a.route_id or _ln, _a.station, _batch_dow, _batch_hour)
            )
    _subway_recency_cache = await _get_weighted_errors_batch(_subway_recency_qs)

    # Pre-warm alert index + weather cache so the per-arrival
    # _ml_corrected calls never block on a first-call HTTP fetch.
    await _maybe_refresh_alerts()
    from app.clients.weather_client import get_current_weather as _gcw_sub

    _cached_weather = await _gcw_sub()

    success_count = 0
    total_raw = 0
    total_kept = 0

    # Phase 1: Collect kept arrivals (fast — no ML, no await per item)
    _kept_arrivals: list[tuple] = []  # (arrival, line, stop_info)
    for line, arrivals in zip(feed_lines, feed_results, strict=False):
        if isinstance(arrivals, Exception):
            TrackLogger.info(
                f"Subway feed '{line}' failed: {_describe_exception(arrivals)}"
            )
            continue
        if not isinstance(arrivals, list):
            continue
        success_count += 1
        total_raw += len(arrivals)
        for arrival in arrivals:
            if arrival.minutes_away <= 0:
                continue
            if arrival.station not in nearby_stops:
                continue
            stop_info = get_stop_info(arrival.station)
            _kept_arrivals.append((arrival, line, stop_info))
            total_kept += 1
            if total_kept % 200 == 0:
                await asyncio.sleep(0)

    # Phase 2: Batch ML prediction — ONE model.predict() call for all kept arrivals
    _batch_data = [
        (a.minutes_away, a.route_id or ln, "subway", a.station, 0.0)
        for a, ln, _ in _kept_arrivals
    ]
    _corrected_all = _ml_corrected_batch(
        _batch_data,
        recency_cache=_subway_recency_cache,
        weather=_cached_weather,
    )
    await asyncio.sleep(0)  # yield after batch compute

    # Phase 3: Build result objects
    for idx, (arrival, line, stop_info) in enumerate(_kept_arrivals):
        stop_name = stop_info.name if stop_info else arrival.station
        stop_lat = stop_info.lat if stop_info else None
        stop_lon = stop_info.lon if stop_info else None
        direction_key = arrival.destination or arrival.direction
        results.append(
            NearbyTransitArrival(
                route_id=arrival.route_id or line,
                stop_name=stop_name,
                direction=direction_key,
                destination=arrival.destination,
                minutes_away=_corrected_all[idx],
                arrival_ts=arrival.arrival_ts,
                status=arrival.status,
                mode="subway",
                stop_lat=stop_lat,
                stop_lon=stop_lon,
                stop_id=arrival.station,
                trip_id=arrival.trip_id,
                is_real_time=arrival.status != "Scheduled",
                is_cancelled=arrival.is_cancelled,
                is_express=_is_express_service(
                    arrival.route_id or line, "subway",
                ),
            )
        )

    if success_count == 0 and feed_lines:
        TrackLogger.info(
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
    #
    # Budget gate: the scheduled backfill launches 200+ asyncio.to_thread
    # SQLite queries that saturate the 5-thread pool and create heavy GIL
    # contention, stalling the entire event loop.  Skip it when budget is
    # tight — live arrivals are the priority.
    import time as _mono_sub

    _budget_ok = _deadline is None or (_deadline - _mono_sub.monotonic()) > 12
    if not _budget_ok:
        _budget_left_s = (
            (_deadline - _mono_sub.monotonic()) if _deadline else float("inf")
        )
        TrackLogger.info(
            f"Subway skipping scheduled backfill — only {_budget_left_s:.1f}s left "
            f"(returning {total_kept} live arrivals)"
        )
        return results

    stops_with_live = {a.stop_id for a in results}
    missing_stops = nearby_stops - stops_with_live

    if missing_stops:
        # Pre-filter to subway-only stops, then fetch ALL schedules in parallel
        subway_missing = []
        for stop_id in missing_stops:
            stop_info = get_stop_info(stop_id)
            if stop_info and stop_info.agency in ("lirr", "mnr"):
                continue  # Skip — handled by _fetch_nearby_rail
            subway_missing.append(stop_id)

        if subway_missing:
            # Parallel fetch: all schedule queries at once instead of serial
            all_scheduled = await asyncio.gather(
                *(
                    schedule_service.get_scheduled_arrivals_async(sid, limit=4)
                    for sid in subway_missing
                )
            )

            backfill_count = 0
            for _stop_id, scheduled in zip(subway_missing, all_scheduled, strict=False):
                for s in scheduled:
                    if s.trip_id and ("GO103" in s.trip_id or "METS" in s.trip_id):
                        continue
                    if s.route_id.isdigit() and int(s.route_id) > 7:
                        continue

                    sinfo = get_stop_info(s.station)
                    sched_dir = s.destination or s.direction
                    corrected_mins = await _ml_corrected(
                        s.minutes_away,
                        s.route_id,
                        "subway",
                        stop_id=s.station,
                        _weather=_cached_weather,
                    )
                    results.append(
                        NearbyTransitArrival(
                            route_id=s.route_id,
                            stop_name=sinfo.name if sinfo else s.station,
                            direction=sched_dir,
                            destination=s.destination,
                            minutes_away=corrected_mins,
                            arrival_ts=s.arrival_ts,
                            status="Scheduled",
                            mode="subway",
                            stop_lat=sinfo.lat if sinfo else None,
                            stop_lon=sinfo.lon if sinfo else None,
                            stop_id=s.station,
                            trip_id=s.trip_id,
                            is_express=_is_express_service(
                                s.route_id, "subway",
                            ),
                        )
                    )
                    backfill_count += 1
                    if backfill_count % 50 == 0:
                        await asyncio.sleep(0)

            if backfill_count:
                TrackLogger.info(
                    f"Backfilled {backfill_count} subway schedule entries for {len(subway_missing)} stops"
                )

    # -----------------------------------------------------------------
    # Budget gate: skip anchor phase if running low on time
    _anchor_ok = _deadline is None or (_deadline - _mono_sub.monotonic()) > 5
    if not _anchor_ok:
        TrackLogger.info("Subway skipping anchor phase — budget tight")
        return results

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
            if (
                r.route_id not in nearest_entry_dist
                or d < nearest_entry_dist[r.route_id]
            ):
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
                results.append(
                    NearbyTransitArrival(
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
                        is_express=_is_express_service(
                            route_id, "subway",
                        ),
                    )
                )
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
    lat: float,
    lon: float,
    radius: int | None = None,
    *,
    quick: bool = False,
) -> list[NearbyTransitArrival]:
    """Fetch bus arrivals from nearby stops.

    First collects live SIRI arrivals for every nearby stop.  Then,
    for any route that serves a nearby stop but has **no** live data,
    creates a placeholder entry so the route still appears in the
    dashboard (categorised by distance tier).  This ensures the user
    sees *all* bus service in their area, not just buses that happen to
    be approaching right now.

    When *quick* is ``True`` (drag-search mode), only Phases A-C run.
    Phases D/E/F (expensive OBA stops-for-route + static GTFS) are
    skipped so the endpoint responds in <1 s for drag-search users.
    """
    import time as _monotonic_mod

    # Internal deadline: leave 5 s headroom before the per-mode timeout.
    # Phases A-F are "nice-to-have" enrichment; core SIRI results are
    # the priority.  Returning partial results is much better than
    # timing out and returning nothing.
    # Quick mode: tighter 10 s budget — only Phases A-C need to run.
    _BUS_INTERNAL_DEADLINE = _monotonic_mod.monotonic() + (10 if quick else 25)

    def _budget_left() -> float:
        return _BUS_INTERNAL_DEADLINE - _monotonic_mod.monotonic()

    settings = get_settings()
    effective_radius = (
        radius if radius is not None else settings.app_settings.search_radius_meters
    )
    results: list[NearbyTransitArrival] = []

    async def _add_static_only_placeholders(reason: str) -> list[NearbyTransitArrival]:
        static_routes = await asyncio.to_thread(
            _nearby_static_bus_routes, lat, lon, effective_radius
        )
        # Parallel fetch: all static-route schedule queries at once
        items = list(static_routes.items())
        if not items:
            return []
        all_sched = await asyncio.gather(
            *(
                _schedule_arrivals_for_stop(
                    stop_id=stop_id,
                    route_id=route_id,
                    stop_name=stop_name,
                    stop_lat=stop_lat,
                    stop_lon=stop_lon,
                    fallback_direction="N/A",
                )
                for route_id, (stop_name, stop_lat, stop_lon, stop_id) in items
            )
        )
        out: list[NearbyTransitArrival] = []
        for sched in all_sched:
            out.extend(sched)

        TrackLogger.bus(
            f"Bus static fallback: added {len(out)} arrivals for {len(static_routes)} routes ({reason})"
        )
        return out

    import time as _t

    _t_oba = _t.perf_counter()
    try:
        stops = await get_nearby_stops(lat, lon, radius_m=effective_radius)
    except Exception as exc:
        TrackLogger.info(f"Bus stops fetch failed: {exc}")
        return await _add_static_only_placeholders("nearby-stop lookup failed")
    _oba_ms = (_t.perf_counter() - _t_oba) * 1000

    if not stops:
        TrackLogger.info("No bus stops found within search radius")
        return await _add_static_only_placeholders("no nearby OBA stops")

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
    _t_siri = _t.perf_counter()
    # Wave-based batching: split SIRI requests into waves of
    # SIRI_WAVE_SIZE with SIRI_WAVE_DELAY between each wave to
    # avoid triggering MTA's 403 rate limiter.  During drag-search
    # the app fires rapid location-change requests, each spawning
    # up to 80 concurrent SIRI calls — waves smooth this burst.
    stop_results: list = []
    for _wave_start in range(0, len(stops_to_query), SIRI_WAVE_SIZE):
        _wave = stops_to_query[_wave_start : _wave_start + SIRI_WAVE_SIZE]
        _wave_tasks = [get_realtime_arrivals(s.id) for s in _wave]
        _wave_results = await asyncio.gather(*_wave_tasks, return_exceptions=True)
        stop_results.extend(_wave_results)
        # Sleep between waves (but not after the last one)
        if _wave_start + SIRI_WAVE_SIZE < len(stops_to_query):
            await asyncio.sleep(SIRI_WAVE_DELAY)
    _siri_ms = (_t.perf_counter() - _t_siri) * 1000
    TrackLogger.info(
        f"⏱ BUS SIRI: {len(stops_to_query)} stops fetched in {_siri_ms:.0f}ms"
        f" ({(len(stops_to_query) - 1) // SIRI_WAVE_SIZE + 1} waves)"
    )

    # Pre-fetch all bus recency errors in one pipeline before the correction loop.
    _bus_now_dt = datetime.now(UTC)
    _bus_batch_dow = (_bus_now_dt.isoweekday() % 7) + 1
    _bus_batch_hour = _bus_now_dt.hour
    _bus_recency_qs: list[tuple[str, str, int, int]] = []
    for _bi, _bres in enumerate(stop_results):
        if isinstance(_bres, Exception) or not isinstance(_bres, list):
            continue
        _bstop = stops_to_query[_bi]
        for _barr in _bres:
            _bus_recency_qs.append(
                (
                    _display_name(_barr.route_id),
                    _bstop.id,
                    _bus_batch_dow,
                    _bus_batch_hour,
                )
            )
    _bus_recency_cache = await _get_weighted_errors_batch(_bus_recency_qs)
    await asyncio.sleep(0)  # yield so per-mode timeout can fire

    # Pre-warm weather for the ML loop (avoid per-item await)
    from app.clients.weather_client import get_current_weather as _gcw_bus

    _bus_cached_weather = await _gcw_bus()

    # Track which route IDs already have live data
    routes_with_live: set[str] = set()

    # Phase 1: Collect kept bus arrivals (fast — no ML)
    fail_count = 0
    first_error: Exception | None = None
    _bus_kept: list[tuple] = (
        []
    )  # (arrival, stop, minutes, normalised_route, direction, deviation_s)
    for i, result in enumerate(stop_results):
        stop = stops_to_query[i]
        if isinstance(result, Exception):
            fail_count += 1
            if first_error is None:
                first_error = result
            continue
        if not result:  # None or empty list from SIRI
            continue

        for arrival in result:
            if arrival.expected_arrival:
                now_utc = datetime.now(UTC)
                exp_utc = arrival.expected_arrival
                if exp_utc.tzinfo is None:
                    exp_utc = exp_utc.replace(tzinfo=UTC)
                if (exp_utc - now_utc).total_seconds() < -120:
                    continue

            minutes = _bus_minutes_away(arrival.expected_arrival)
            normalised_route = _display_name(arrival.route_id)

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
            routes_with_live.add(arrival.route_id)
            _bus_kept.append(
                (
                    arrival,
                    stop,
                    minutes,
                    normalised_route,
                    direction,
                    float(arrival.schedule_deviation_s or 0),
                )
            )

    # Phase 2: Batch ML prediction — one model.predict() for all bus arrivals
    _bus_batch_data = [
        (mins, route, "bus", stop.id, dev_s)
        for _, stop, mins, route, _, dev_s in _bus_kept
    ]
    _bus_corrected_all = _ml_corrected_batch(
        _bus_batch_data,
        recency_cache=_bus_recency_cache,
        weather=_bus_cached_weather,
    )
    await asyncio.sleep(0)  # yield after batch compute

    # Phase 3: Build result objects
    for idx, (arrival, stop, _minutes, normalised_route, direction, _) in enumerate(
        _bus_kept
    ):
        bus_status = arrival.status_text if arrival.is_realtime else "Scheduled"
        results.append(
            NearbyTransitArrival(
                route_id=normalised_route,
                stop_name=stop.name,
                arrival_ts=(
                    int(arrival.expected_arrival.timestamp())
                    if arrival.expected_arrival
                    else None
                ),
                direction=direction,
                minutes_away=_bus_corrected_all[idx],
                status=bus_status,
                mode="bus",
                stop_lat=stop.lat,
                stop_lon=stop.lon,
                stop_id=stop.id,
                vehicle_id=arrival.vehicle_id,
                destination=arrival.destination_name or arrival.status_text,
                is_real_time=arrival.is_realtime,
                is_express=_is_express_service(normalised_route, "bus"),
            )
        )

    if fail_count > 0:
        TrackLogger.info(
            f"Bus arrivals failed for {fail_count}/{len(stop_results)} stops (MTA 5xx): {first_error}"
        )

    # -----------------------------------------------------------------
    # 1a-extra: Top-off each direction with upcoming scheduled departures
    # so the route detail always shows a full departure board, not just
    # the 1-2 buses currently in the SIRI feed.
    #
    # e.g.  SIRI returns:  [18m LIVE, 50m LIVE]
    #       After top-off: [18m LIVE, 50m LIVE, 68m Scheduled, 85m Scheduled, …]
    #
    # Scheduled entries added here are AFTER the last live arrival so they
    # never duplicate real-time data.  They are clearly marked "Scheduled"
    # so the iOS app renders them grey and never shows a map marker.
    # -----------------------------------------------------------------
    _MIN_TOPOFF = 20  # target total arrivals per (route, stop, direction)
    _MAX_SCHED = 24  # max scheduled entries added per direction (≈12 h board)

    _t_siri_done = _monotonic_mod.monotonic()
    TrackLogger.info(
        f"⏱ BUS SIRI+ML done | live={len(results)} fail={fail_count} "
        f"budget_left={_budget_left():.1f}s",
        tag="NEARBY",
    )

    # ── Deadline gate: skip enrichment phases if budget exhausted ────
    if _budget_left() <= 0:
        TrackLogger.info(
            "Bus internal deadline expired after SIRI — returning partial results",
            tag="NEARBY",
        )
        return results

    # Group current bus results by (route_id, stop_id, direction)
    _live_by_key: dict[tuple, list] = defaultdict(list)
    for _r in results:
        if _r.mode == "bus" and _r.stop_id:
            _live_by_key[(_r.route_id, _r.stop_id, _r.direction)].append(_r)

    _topoff_added = 0
    _topoff_seen: set[tuple] = set()  # (route, stop, trip_id|minutes) dedup

    # Collect qualifying keys and their metadata, then fetch ALL at once
    _topoff_tasks: list[tuple[tuple, int, int]] = []  # ((rid,sid,dir), last_mins, need)
    for (_rid, _sid, _dir), _entries in _live_by_key.items():
        if len(_entries) >= _MIN_TOPOFF:
            continue
        _last_mins = max(e.minutes_away for e in _entries)
        _need = min(_MIN_TOPOFF - len(_entries), _MAX_SCHED)
        _topoff_tasks.append(((_rid, _sid, _dir), _last_mins, _need))

    if _topoff_tasks:
        # Parallel fetch: all top-off schedule queries at once
        _all_sched_raw = await asyncio.gather(
            *(
                schedule_service.get_scheduled_arrivals_async(
                    sid, route_id=rid, limit=need + 8
                )
                for (rid, sid, _), _, need in _topoff_tasks
            )
        )

        for ((_rid, _sid, _dir), _last_mins, _need), _sched_raw in zip(
            _topoff_tasks, _all_sched_raw, strict=False
        ):
            _added = 0
            for _s in _sched_raw:
                if _added >= _need:
                    break
                _s_rid = _display_name(_s.route_id)
                if _s_rid != _rid:
                    continue
                if _s.minutes_away <= _last_mins:
                    continue
                _dk = (_s_rid, _sid, _s.trip_id or str(_s.minutes_away))
                if _dk in _topoff_seen:
                    continue
                _topoff_seen.add(_dk)
                _sinfo = get_stop_info(_sid)
                results.append(
                    NearbyTransitArrival(
                        route_id=_s_rid,
                        stop_name=_sinfo.name if _sinfo else _sid,
                        direction=_dir,
                        destination=_s.destination,
                        minutes_away=_s.minutes_away,
                        arrival_ts=_s.arrival_ts,
                        status="Scheduled",
                        mode="bus",
                        stop_lat=_sinfo.lat if _sinfo else None,
                        stop_lon=_sinfo.lon if _sinfo else None,
                        stop_id=_sid,
                        vehicle_id=None,
                        trip_id=_s.trip_id,
                        is_express=_is_express_service(_s_rid, "bus"),
                    )
                )
                _added += 1
                _topoff_added += 1

    if _topoff_added:
        TrackLogger.info(
            f"Topped off {_topoff_added} scheduled bus departures alongside live arrivals"
        )

    # -----------------------------------------------------------------
    # 1b. Merge SIRI-observed routes into stop.route_ids
    # -----------------------------------------------------------------
    # OBA's stops-for-location often returns INCOMPLETE routeIds — a stop
    # might list Q10 and Q80 but omit QM16 and Q30 that also serve it.
    # Without the full set, Phases A–D below never create anchors for the
    # missing routes, so they can't be distance-sorted on the client.
    #
    # Fix: MERGE SIRI observations into existing route_ids (not just
    # backfill empty ones).  This ensures every route seen at a stop is
    # available to closest_stops_by_route and subsequent phases.
    _siri_routes_per_stop: dict[str, set[str]] = defaultdict(set)
    for r in results:
        if r.stop_id:
            _siri_routes_per_stop[r.stop_id].add(r.route_id)
    _siri_backfilled = 0
    _siri_merged = 0
    for stop in stops:
        siri_routes = _siri_routes_per_stop.get(stop.id)
        if not siri_routes:
            continue
        if not stop.route_ids:
            # Completely empty — replace wholesale
            stop.route_ids = list(siri_routes)
            _siri_backfilled += 1
        else:
            # Partially populated — merge in any routes OBA omitted.
            # Normalise both sides so "MTA NYCT_Q10" and "Q10" don't
            # create duplicates.
            existing_normalised = {_display_name(rid).upper() for rid in stop.route_ids}
            new_routes = [
                rid
                for rid in siri_routes
                if _display_name(rid).upper() not in existing_normalised
            ]
            if new_routes:
                stop.route_ids = stop.route_ids + new_routes
                _siri_merged += 1
    if _siri_backfilled or _siri_merged:
        TrackLogger.bus(
            f"SIRI route_ids: {_siri_backfilled} stops populated (were empty), "
            f"{_siri_merged} stops enriched (had partial OBA data)"
        )

    # -----------------------------------------------------------------
    # 1c. Enrich stop.route_ids from static schedule DB
    # -----------------------------------------------------------------
    if _budget_left() <= 2:
        TrackLogger.info(
            f"Bus deadline approaching — skipping phases 1c+ (budget={_budget_left():.1f}s)",
            tag="NEARBY",
        )
        return results
    await asyncio.sleep(0)  # yield for timeout checks

    # Like 1b, but uses the GTFS schedule DB for stops where SIRI
    # returned no observations.  Also merges into partially-populated
    # stops so dormant routes (no bus approaching) still get anchors.
    _schedule_backfilled = 0
    _schedule_merged = 0
    _stops_needing_routes = [stop for stop in stops if not stop.route_ids]
    # Also enrich stops that already have SOME routes — schedule DB may
    # know about routes that neither OBA nor SIRI mentioned.
    _stops_needing_enrichment = [
        stop
        for stop in stops
        if stop.route_ids and stop.id not in _siri_routes_per_stop
    ]
    if _stops_needing_routes or _stops_needing_enrichment:
        # Parallel fetch: all schedule-based route_id lookups at once
        _all_stops_1c = _stops_needing_routes + _stops_needing_enrichment
        _all_scheduled = await asyncio.gather(
            *(
                schedule_service.get_scheduled_arrivals_async(stop.id, limit=20)
                for stop in _all_stops_1c
            )
        )
        for stop, scheduled in zip(_all_stops_1c, _all_scheduled, strict=False):
            inferred_routes: set[str] = set()
            for s in scheduled:
                rid = _display_name(s.route_id)
                if rid and rid.upper() not in {"N/A", "UNKNOWN"}:
                    inferred_routes.add(rid)
            if not inferred_routes:
                continue
            if not stop.route_ids:
                stop.route_ids = sorted(inferred_routes)
                _schedule_backfilled += 1
            else:
                existing_normalised = {
                    _display_name(rid).upper() for rid in stop.route_ids
                }
                new_routes = [
                    rid
                    for rid in sorted(inferred_routes)
                    if rid.upper() not in existing_normalised
                ]
                if new_routes:
                    stop.route_ids = stop.route_ids + new_routes
                    _schedule_merged += 1

    if _schedule_backfilled or _schedule_merged:
        TrackLogger.bus(
            f"Schedule DB route_ids: {_schedule_backfilled} stops populated (were empty), "
            f"{_schedule_merged} stops enriched (had partial data)"
        )

    # Log direction distribution per route for debugging
    _route_dirs: dict[str, set[str]] = defaultdict(set)
    for r in results:
        _route_dirs[r.route_id].add(r.direction)
    single_dir = [rid for rid, dirs in _route_dirs.items() if len(dirs) == 1]
    if single_dir:
        # PRE-BACKFILL count — Phase B/C will add placeholder opposite directions
        # for all of these, so this number does NOT reflect the final grouped output.
        # Only log at DEBUG to avoid false alarms.
        TrackLogger.debug(
            f"[pre-backfill] Bus routes with 1 live direction: "
            f"{len(single_dir)}/{len(_route_dirs)} — Phase B/C will add placeholders"
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

    # ── Deadline gate before Phase A (heavy schedule queries) ────────
    if _budget_left() <= 2:
        TrackLogger.info(
            f"Bus deadline approaching — skipping phases A+ (budget={_budget_left():.1f}s)",
            tag="NEARBY",
        )
        return results
    await asyncio.sleep(0)  # yield for timeout checks

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
    # For routes with no live data, try to pull real GTFS schedule times
    # so the iOS app shows actual upcoming departure times instead of "No Service".
    _sched_injected = 0

    # Pre-build a set for O(1) "has live at closest" checks instead of O(n) linear scans
    _existing_route_stop = {(r.route_id, r.stop_id) for r in results}

    # Phase A-1: Gather all closest-stop schedule queries in parallel
    _closest_tasks: list[tuple[str, BusStop, str]] = []  # (rid, stop, direction)
    for rid, closest_stop in closest_stops_by_route.items():
        if (rid, closest_stop.id) not in _existing_route_stop:
            direction = (
                route_primary_direction.get(rid) or closest_stop.direction or "N/A"
            )
            _closest_tasks.append((rid, closest_stop, direction))

    if _closest_tasks:
        _closest_results = await asyncio.gather(
            *(
                _schedule_arrivals_for_stop(
                    stop_id=stop.id,
                    route_id=rid,
                    stop_name=stop.name,
                    stop_lat=stop.lat,
                    stop_lon=stop.lon,
                    fallback_direction=direction,
                )
                for rid, stop, direction in _closest_tasks
            )
        )
        for sched_entries in _closest_results:
            results.extend(sched_entries)
            if sched_entries and sched_entries[0].arrival_ts is not None:
                _sched_injected += len(sched_entries)

    # Rebuild the lookup set after Phase A-1 additions
    _existing_route_stop = {(r.route_id, r.stop_id) for r in results}

    # Phase A-2: Gather all missing-route schedule queries in parallel
    _missing_tasks: list[tuple[str, BusStop, str]] = []  # (short_rid, stop, direction)
    for rid, (stop, direction) in missing_routes.items():
        short = _display_name(rid)
        if (short, stop.id) not in _existing_route_stop:
            _missing_tasks.append((short, stop, direction))

    if _missing_tasks:
        _missing_results = await asyncio.gather(
            *(
                _schedule_arrivals_for_stop(
                    stop_id=stop.id,
                    route_id=short,
                    stop_name=stop.name,
                    stop_lat=stop.lat,
                    stop_lon=stop.lon,
                    fallback_direction=direction,
                )
                for short, stop, direction in _missing_tasks
            )
        )
        for sched_entries in _missing_results:
            results.extend(sched_entries)
            if sched_entries and sched_entries[0].arrival_ts is not None:
                _sched_injected += len(sched_entries)

    if missing_routes:
        TrackLogger.bus(
            f"Backfilled {len(missing_routes)} bus routes with no live data "
            f"({_sched_injected} with real schedule times, "
            f"total {len(results)} bus arrivals from {len(stops)} stops)"
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
            semantic_dirs = {
                d for d in existing_dirs if not _is_fallback_direction_key(d)
            }
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
                    is_express=_is_express_service(short, "bus"),
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

    # ── Deadline gate before Phase C ────────────────────────────────
    if _budget_left() <= 2:
        TrackLogger.info(
            f"Bus deadline — skipping phases C+ (budget={_budget_left():.1f}s)",
            tag="NEARBY",
        )
        return results
    await asyncio.sleep(0)

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
        if upper in _NUMERIC_DIR_KEYS:
            new_dir = "1" if existing_dir == "0" else "0"
        else:
            # Prefer a real GTFS opposite headsign whenever possible,
            # even if the existing direction key is a fallback compass /
            # Inbound label. This avoids generic placeholder tabs like
            # "Outbound" for routes whose opposite terminal is known.
            existing_arrivals = [r for r in results if r.route_id == route_id]
            headsign = _resolve_opposite_headsign(
                route_id, existing_dir, existing_arrivals
            )
            if headsign:
                new_dir = headsign
            elif upper in _OPPOSITE_COMPASS:
                new_dir = _OPPOSITE_COMPASS[upper]
            else:
                # Try to find the compass direction from nearby stops
                stop_compass = None
                for s in stops:
                    if (
                        route_id in [_display_name(rid) for rid in s.route_ids]
                        and s.direction
                    ):
                        stop_compass = s.direction.upper()
                        break
                if stop_compass and stop_compass in _OPPOSITE_COMPASS:
                    new_dir = _OPPOSITE_COMPASS[stop_compass]
                else:
                    new_dir = _OPPOSITE_DIRECTION

        # Set destination on the placeholder when new_dir is a terminal name
        ph_destination = new_dir if not _is_fallback_direction_key(new_dir) else None

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
                destination=ph_destination,
                is_express=_is_express_service(route_id, "bus"),
            )
        )
        phase_c_count += 1

    if phase_c_count:
        TrackLogger.bus(
            f"Phase C: Created {phase_c_count} opposite-direction placeholders "
            f"for single-direction routes"
        )

    # ── Quick mode: skip expensive Phases D/E/F ─────────────────────
    # During drag-search the user is panning the map — speed matters
    # more than completeness.  Phases A-C already give live SIRI data
    # plus missing-route / direction placeholders.  Phases D/E/F add
    # deep OBA stops-for-route lookups and static GTFS which can take
    # 5-12 s.  Return early so drag-search responses are <1 s.
    if quick:
        TrackLogger.bus(
            f"Quick mode — returning {len(results)} bus results "
            f"(skipped Phase D/E/F) budget={_budget_left():.1f}s"
        )
        return results

    # ── Deadline gate before Phase D (network calls to OBA) ─────────
    if _budget_left() <= 3:
        TrackLogger.info(
            f"Bus deadline — skipping phases D+ (budget={_budget_left():.1f}s)",
            tag="NEARBY",
        )
        return results
    await asyncio.sleep(0)

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
        rid for rid, d in nearest_entry_dist.items() if d > _ANCHOR_THRESHOLD_M
    ]

    phase_d_count = 0
    if routes_needing_anchor:
        # Resolve display names → canonical OBA IDs for the API call
        # get_bus_route_stops handles resolve_bus_id internally
        anchor_tasks = {rid: get_bus_route_stops(rid) for rid in routes_needing_anchor}
        anchor_results = await asyncio.gather(
            *anchor_tasks.values(), return_exceptions=True
        )

        for rid, route_stops in zip(anchor_tasks.keys(), anchor_results, strict=False):
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
                    direction=route_primary_direction.get(rid)
                    or best_stop.direction
                    or "N/A",
                    minutes_away=_PLACEHOLDER_MINUTES,
                    status="Scheduled",
                    mode="bus",
                    stop_lat=best_stop.lat,
                    stop_lon=best_stop.lon,
                    stop_id=best_stop.id,
                    vehicle_id=None,
                    destination=None,
                    is_express=_is_express_service(rid, "bus"),
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

    # ── Deadline gate before Phase E (synchronous SQLite) ───────────
    if _budget_left() <= 2:
        TrackLogger.info(
            f"Bus deadline — skipping phases E+ (budget={_budget_left():.1f}s)",
            tag="NEARBY",
        )
        return results
    await asyncio.sleep(0)

    # -----------------------------------------------------------------
    # Phase E: Static GTFS fallback (guarantee route visibility in radius)
    # -----------------------------------------------------------------
    # When live SIRI and OBA stop metadata miss a route, local GTFS stop-times
    # are the most reliable completeness backstop. Run this unconditionally so
    # routes with real nearby stops (for example M11 near Penn Station) are not
    # omitted simply because the upstream nearby-stop sample was incomplete.
    run_phase_e = True
    if run_phase_e:
        static_routes = await asyncio.to_thread(
            _nearby_static_bus_routes, lat, lon, effective_radius
        )
        existing_routes = {r.route_id for r in results if r.mode == "bus"}
        phase_e_count = 0

        # Build schedule queries in parallel for all missing routes.
        missing_items = [
            (route_id, stop_name, stop_lat, stop_lon, stop_id)
            for route_id, (stop_name, stop_lat, stop_lon, stop_id) in static_routes.items()
            if route_id not in existing_routes
        ]

        if missing_items:
            sched_tasks = [
                _schedule_arrivals_for_stop(
                    stop_id=stop_id,
                    route_id=route_id,
                    stop_name=stop_name,
                    stop_lat=stop_lat,
                    stop_lon=stop_lon,
                    fallback_direction=route_primary_direction.get(route_id) or "N/A",
                )
                for route_id, stop_name, stop_lat, stop_lon, stop_id in missing_items
            ]
            sched_results = await asyncio.gather(*sched_tasks, return_exceptions=True)

            for (route_id, stop_name, stop_lat, stop_lon, stop_id), sched in zip(
                missing_items, sched_results
            ):
                if isinstance(sched, Exception) or not sched:
                    # Fallback: bare placeholder so the route still appears
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
                            is_express=_is_express_service(route_id, "bus"),
                        )
                    )
                else:
                    results.extend(sched)
                existing_routes.add(route_id)
                phase_e_count += 1

        if phase_e_count:
            TrackLogger.bus(
                f"Phase E: Added {phase_e_count} static-GTFS nearby bus routes "
                f"(radius={effective_radius}m)"
            )

    # ── Deadline gate before Phase F (up to 160 OBA HTTP requests) ──
    if _budget_left() <= 3:
        TrackLogger.info(
            f"Bus deadline — skipping Phase F (budget={_budget_left():.1f}s)",
            tag="NEARBY",
        )
        return results
    await asyncio.sleep(0)

    # -----------------------------------------------------------------
    # Phase F: OBA route-stop scan for locale-matched candidates
    # -----------------------------------------------------------------
    # Final safety net: if nearby stops still have missing route metadata,
    # scan candidate routes (matching local prefixes like Q/B/M/BX) via
    # OBA stops-for-route and inject placeholders for routes with stops
    # inside the radius.
    empty_route_metadata_stops = sum(1 for s in stops if not s.route_ids)
    run_phase_f = empty_route_metadata_stops or (fail_count > 0)
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
            scan_tasks = [
                get_bus_route_stops(route_id) for route_id in candidate_route_ids
            ]
            scan_results = await asyncio.gather(*scan_tasks, return_exceptions=True)

            for route_id, route_stops in zip(
                candidate_route_ids, scan_results, strict=False
            ):
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
                        direction=route_primary_direction.get(route_id)
                        or best_stop.direction
                        or "N/A",
                        minutes_away=_PLACEHOLDER_MINUTES,
                        status="Scheduled",
                        mode="bus",
                        stop_lat=best_stop.lat,
                        stop_lon=best_stop.lon,
                        stop_id=best_stop.id,
                        vehicle_id=None,
                        destination=None,
                        is_express=_is_express_service(route_id, "bus"),
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
        TrackLogger.info(f"{agency.upper()} feed failed: {_describe_exception(exc)}")
        return results

    _rail_kept = 0
    for arrival in arrivals:
        if arrival.station not in nearby_stops:
            continue
        # Skip arrivals with no route_id — these can't be meaningfully grouped
        if not arrival.route_id:
            continue

        # Yield every 50 kept arrivals so the event loop can service
        # timeout callbacks and health checks.  Rail feeds (LIRR 1444,
        # MNR 3447 arrivals) would otherwise block the loop for seconds.
        _rail_kept += 1
        if _rail_kept % 50 == 0:
            await asyncio.sleep(0)

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
                is_real_time=arrival.status != "Scheduled",
                is_cancelled=arrival.is_cancelled,
            )
        )

    # -----------------------------------------------------------------
    # Fallback: ensure routes still appear when no live train is nearby.
    # -----------------------------------------------------------------
    stops_with_live = {a.stop_id for a in results}
    missing_stops = nearby_stops - stops_with_live

    if missing_stops:
        # Pre-filter to stops with valid stop_info
        _rail_valid = [
            (sid, get_stop_info(sid, agency=agency)) for sid in missing_stops
        ]
        _rail_valid = [(sid, si) for sid, si in _rail_valid if si is not None]

        if _rail_valid:
            # Parallel fetch: all rail schedule queries at once
            _rail_scheduled = await asyncio.gather(
                *(
                    schedule_service.get_scheduled_arrivals_async(sid, limit=6)
                    for sid, _ in _rail_valid
                )
            )

            fallback_count = 0
            for (stop_id, stop_info), scheduled in zip(
                _rail_valid, _rail_scheduled, strict=False
            ):
                for s in scheduled:
                    if not s.route_id:
                        continue
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
    now = datetime.now(UTC)
    if expected.tzinfo is None:
        expected = expected.replace(tzinfo=UTC)
    diff = (expected - now).total_seconds()
    return max(0, int(diff // 60))


async def _ml_corrected(
    minutes_away: int,
    route_id: str,
    mode: str,
    stop_id: str = "",
    deviation_s: float = 0.0,
    recency_cache: dict | None = None,
    *,
    _weather: str | None = None,
) -> int:
    """Return ML-corrected minutes_away.

    Async pipeline:
      1. Alert boost  — SEVERE → ×1.25, WARNING → ×1.10  (in-process dict, ~0 µs)
      2. GBR factor   — route × hour × dow × mode  (~5 µs, sync)
      3. Recency delta — per-stop exponentially-weighted mean error from
                         SIRI observations stored in Redis  (~1 ms, async)
      4. Blend:
           base_seconds  = raw_seconds + recency_delta       (additive)
           final_factor  = min(2.0, gbr_factor × (1+boost))  (multiplicative)
           corrected     = base_seconds × final_factor
           result        = round(corrected / 60)

    Factor range is [0.90, 2.0] before alert boost (floor allows early-arrival
    predictions for reliable off-peak routes; ceiling guards sanity).
    Placeholders (minutes=99) and already-departed (minutes=0) are unchanged.

    When ``_weather`` is supplied (pre-fetched by the caller) and
    ``recency_cache`` is also supplied, this function avoids **all** async
    I/O — the only awaits are the alert index refresh (skipped if TTL fresh)
    and the weather fetch (skipped if ``_weather`` is pre-filled).  This
    dramatically reduces per-item overhead in hot loops (458+ bus arrivals,
    500+ subway arrivals).
    """
    if minutes_away <= 0 or minutes_away >= 99:
        return minutes_away
    now_utc = datetime.now(UTC)
    hour = now_utc.hour
    dow = (now_utc.isoweekday() % 7) + 1  # Mon=2 … Sun=1

    # 1. Alert index — non-blocking refresh if stale, O(1) read
    await _maybe_refresh_alerts()
    alert_boost = _get_alert_boost(route_id)

    # 2. GBR contextual factor — now uses live weather from Open-Meteo
    #    (falls back to "clear" if the weather client hasn't fetched yet)
    if _weather is None:
        from app.clients.weather_client import get_current_weather

        _weather = await get_current_weather()
    factor, _ = _predict_factor(
        route_id=route_id,
        hour=hour,
        dow=dow,
        weather=_weather,
        mode=mode,
        current_delay_s=deviation_s,
    )

    # 3. Per-stop recency: additive seconds from observed SIRI deviations
    # If a pre-fetched cache is supplied (from a batch call before the loop)
    # use it directly — zero Redis calls. Fall back to direct query otherwise.
    recency_s = 0.0
    if stop_id:
        if recency_cache is not None:
            err = recency_cache.get((route_id, stop_id))
        else:
            err = await _get_weighted_error(route_id, stop_id, dow, hour)
        if err is not None:
            recency_s = max(-300.0, min(300.0, err))  # cap ±5 min

    # 4. Blend
    base_seconds = max(0.0, minutes_away * 60.0 + recency_s)
    final_factor = min(2.0, factor * (1.0 + alert_boost))
    corrected = base_seconds * final_factor / 60.0
    result = round(corrected)

    # 5. Horizon-scaled correction cap — addresses the +2.4 min over-inflation
    #    bias observed on 25–50 min arrivals (GBR factor ×1.15 on raw 1800–3000s
    #    produces 4–8 min over-shot).  Caps how far we can shift minutes_away:
    #      ≤ 10 min horizon → ±2 min  (tight — live arrivals must be precise)
    #      ≤ 25 min horizon → ±3 min
    #      > 25 min horizon → ±4 min  (allow larger shift but clip the extreme)
    max_delta = 2 if minutes_away <= 10 else (3 if minutes_away <= 25 else 4)
    result = max(minutes_away - max_delta, min(minutes_away + max_delta, result))
    return max(0, result)


def _ml_corrected_batch(
    arrivals_data: list[tuple[int, str, str, str, float]],
    recency_cache: dict | None = None,
    weather: str = "clear",
) -> list[int]:
    """Synchronous batch ML correction — one model.predict() for N arrivals.

    Each tuple is (minutes_away, route_id, mode, stop_id, deviation_s).
    Returns corrected minutes for each arrival in order.

    This replaces the per-item async _ml_corrected loop, avoiding:
    - N individual model.predict() calls (replaced by 1 batch call)
    - N×2 await statements (alert refresh + weather fetch)
    - N event-loop context switches
    """
    now_utc = datetime.now(UTC)
    hour = now_utc.hour
    dow = (now_utc.isoweekday() % 7) + 1

    # Build batch prediction inputs — only for items that need prediction
    pred_indices: list[int] = []
    pred_inputs: list[tuple[str, int, int, str, str, float]] = []
    for i, (mins, route_id, mode, _stop_id, dev_s) in enumerate(arrivals_data):
        if mins <= 0 or mins >= 99:
            continue
        pred_indices.append(i)
        pred_inputs.append((route_id, hour, dow, weather, mode, dev_s))

    # One batch predict call
    batch_results = _predict_factor_batch(pred_inputs) if pred_inputs else []

    # Build results
    results: list[int] = []
    pred_idx = 0
    for _i, (mins, route_id, _mode, stop_id, _dev_s) in enumerate(arrivals_data):
        if mins <= 0 or mins >= 99:
            results.append(mins)
            continue

        factor, _ = batch_results[pred_idx]
        pred_idx += 1

        alert_boost = _get_alert_boost(route_id)

        recency_s = 0.0
        if stop_id and recency_cache is not None:
            err = recency_cache.get((route_id, stop_id))
            if err is not None:
                recency_s = max(-300.0, min(300.0, err))

        base_seconds = max(0.0, mins * 60.0 + recency_s)
        final_factor = min(2.0, factor * (1.0 + alert_boost))
        corrected = base_seconds * final_factor / 60.0
        result = round(corrected)

        max_delta = 2 if mins <= 10 else (3 if mins <= 25 else 4)
        result = max(mins - max_delta, min(mins + max_delta, result))
        results.append(max(0, result))

    return results
