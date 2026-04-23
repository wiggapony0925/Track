"""TrackBackend/app/services/gtfs

Converts raw MTA Protobuf (GTFS-Realtime) and JSON data into clean,
standardized Pydantic models that the iOS app can consume directly."""

from __future__ import annotations

import asyncio
import contextlib
import time as _time
from typing import Any

from google.transit import gtfs_realtime_pb2  # type: ignore[import-untyped]

from app.clients.mta_client import fetch_json, fetch_protobuf
from app.config import get_feed_url, get_settings
from app.ml.recency_model import observe_siri_delays_batch, observe_trip_updates_batch
from app.models import ElevatorStatus, TrackArrival, TransitAlert
from app.services.mapping.shared.coords import haversine_km as _haversine_km
from app.services.transit.station_lookup import get_stop_info, get_stop_name
from app.utils.geo_utils import minutes_until as _minutes_until
from app.utils.logger import TrackLogger

# Strong references to fire-and-forget tasks so the GC won't collect them.
_background_tasks: set[asyncio.Task[Any]] = set()

# ---------------------------------------------------------------------------
# Fast-travel detection — mirrors ext/bestpractices/fast_travel.go
# ---------------------------------------------------------------------------

# Maximum plausible speeds (km/h) per GTFS route_type.  Arrivals implying
# higher speeds are phantom predictions and should be discarded.
_MAX_SPEEDS_KMH: dict[int, float] = {
    0: 200.0,   # tram
    1: 200.0,   # metro / subway
    2: 500.0,   # rail
    3: 200.0,   # bus
    4: 100.0,   # ferry
    5: 100.0,   # cable car
    6: 100.0,   # gondola
    7: 100.0,   # funicular
    11: 100.0,  # trolleybus
    12: 100.0,  # monorail
}
_DEFAULT_MAX_SPEED_KMH = 200.0   # subway / metro default
_FAST_TRAVEL_MIN_SECS = 30       # ignore segments < 30 s (noise guard)

# Rate-limit fast-travel log spam: keyed by trip_id so all dropped stops
# within one trip are batched into a single log entry.  After the first
# warning for a trip, subsequent occurrences are suppressed for
# _FAST_TRAVEL_WARN_COOLDOWN_SECS so a persistently glitchy MTA feed
# doesn't flood the log on every 10-second poll cycle.
#
# Entries older than the cooldown are pruned every
# _FAST_TRAVEL_CLEANUP_INTERVAL_SECS to prevent unbounded growth.
_fast_travel_warn_ts: dict[str, float] = {}  # trip_id → last warn timestamp
_FAST_TRAVEL_WARN_COOLDOWN_SECS = 300.0       # 5 min per trip
_fast_travel_cleanup_at: float = 0.0
_FAST_TRAVEL_CLEANUP_INTERVAL_SECS = 600.0    # prune stale entries every 10 min


def _log_fast_travel_drop(
    trip_id: str,
    pairs: list[str],
) -> None:
    """Log a rate-limited fast-travel prune at debug level.

    These drops are expected feed-hygiene behavior, not an operator-facing
    warning. Keep them available for local debugging without polluting
    production warning logs.

    Args:
        trip_id: Trip identifier associated with the dropped predictions.
        pairs: Ordered list of offending stop-pair summaries.
    """
    summary = pairs[0]
    if len(pairs) > 1:
        summary += f" (+{len(pairs) - 1} more)"
    TrackLogger.debug(
        f"[RT] Fast-travel on trip {trip_id}: {summary} — dropping",
        tag="RT",
    )


def _is_fast_travel(
    lat1: float,
    lon1: float,
    t1: int,
    lat2: float,
    lon2: float,
    t2: int,
    max_speed_kmh: float = _DEFAULT_MAX_SPEED_KMH,
) -> bool:
    """Return True if travel between two stops implies an impossible speed.

    Mirrors ``StopTimeFastTravelCheck.Validate`` from transitland-lib's
    ``ext/bestpractices/fast_travel.go``.  Only triggers when the
    inter-stop time exceeds :data:`_FAST_TRAVEL_MIN_SECS` to exclude
    precision noise on very short segments.

    Args:
        lat1, lon1:    Coordinates of the first (earlier) stop.
        t1:            Predicted Unix arrival timestamp at the first stop.
        lat2, lon2:    Coordinates of the second (later) stop.
        t2:            Predicted Unix arrival timestamp at the second stop.
        max_speed_kmh: Speed ceiling in km/h.

    Returns:
        True if the implied travel speed exceeds *max_speed_kmh*.
    """
    dt = t2 - t1
    if dt <= _FAST_TRAVEL_MIN_SECS:
        return False
    dist_km = _haversine_km(lat1, lon1, lat2, lon2)
    if dist_km == 0.0:
        return False
    speed_kmh = dist_km / (dt / 3600.0)
    return speed_kmh > max_speed_kmh

# ---------------------------------------------------------------------------
# Parsed-arrivals cache — avoid re-parsing protobuf entities on cache hits.
#
# The HTTP-level feed cache (_HTTP_CACHE in mta_client) stores raw bytes
# with a 12-second fresh TTL.  Without this second cache, every call to
# get_arrivals_for_line() runs _parse_feed_sync in the thread pool even
# when the underlying bytes haven't changed — wasting CPU and causing GIL
# contention when 9 feeds parse simultaneously during the background
# refresh loop.
#
# With this cache, the second+ call within the TTL returns the pre-parsed
# list in <1 µs — zero thread pool, zero CPU, zero GIL pressure.
# ---------------------------------------------------------------------------
_PARSED_CACHE: dict[str, tuple[float, list, list, int, dict]] = (
    {}
)  # url → (ts, arrivals, siri_obs, entity_count, trip_index)
_PARSED_CACHE_TTL = 120.0  # 2 min — outlive request interval so subway hits warm cache


def _parse_feed_sync(
    raw: bytes,
    line_id: str,
) -> tuple[list[TrackArrival], list[tuple[str, str, float]], int]:
    """Parse a GTFS-RT protobuf feed and extract arrivals — **runs in a thread**.

    This is the CPU-heavy function that was previously blocking the event
    loop.  Everything here is synchronous: protobuf deserialization,
    entity iteration, string comparisons, Pydantic model creation.
    Running it via ``run_in_executor`` keeps the async event loop free.

    Returns (arrivals, siri_observations, entity_count).
    """
    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(raw)

    # Header timestamp staleness guard — warn if the feed header is more than
    # 5 minutes behind wall clock.  This catches partial MTA RT outages where
    # the server returns a cached (stale) protobuf with no HTTP error.
    header_ts = feed.header.timestamp
    if header_ts > 0 and (_time.time() - header_ts) > 300:
        TrackLogger.warning(
            f"[RT] {line_id} feed is stale: header.timestamp is "
            f"{int(_time.time() - header_ts)}s old",
            tag="RT",
        )

    arrivals: list[TrackArrival] = []
    siri_obs: list[tuple[str, str, float]] = []

    for entity in feed.entity:
        if not entity.HasField("trip_update"):
            continue
        trip = entity.trip_update
        route = trip.trip.route_id

        trip_cancelled = False
        if trip.trip.HasField("schedule_relationship"):
            trip_cancelled = trip.trip.schedule_relationship == 3

        destination = None
        if trip.stop_time_update:
            last_stop_id = trip.stop_time_update[-1].stop_id
            destination = get_stop_name(last_stop_id)
            if (
                destination == "Unknown"
                and len(last_stop_id) > 1
                and last_stop_id[-1] in "NS"
            ):
                destination = get_stop_name(last_stop_id[:-1])
            if destination == "Unknown":
                destination = None

        for stu in trip.stop_time_update:
            arrival_time = stu.arrival.time if stu.HasField("arrival") else 0
            if arrival_time == 0:
                continue

            stop_cancelled = trip_cancelled
            stop_skipped = False
            stop_no_data = False
            if not stop_cancelled and stu.HasField("schedule_relationship"):
                # GTFS-RT StopTimeUpdate.ScheduleRelationship enum:
                # 0=SCHEDULED, 1=SKIPPED, 2=NO_DATA, 3=UNSCHEDULED
                sr = stu.schedule_relationship
                stop_cancelled = sr == 1
                stop_skipped = sr == 1
                stop_no_data = sr == 2

            minutes = _minutes_until(arrival_time)
            direction = "N" if stu.stop_id.endswith("N") else "S"

            departure_time: int | None = None
            if stu.HasField("departure") and stu.departure.time:
                departure_time = int(stu.departure.time)

            arrival_delay: int | None = None
            if stu.HasField("arrival") and stu.arrival.delay != 0:
                arrival_delay = int(stu.arrival.delay)
                siri_obs.append((route, stu.stop_id, float(stu.arrival.delay)))

            departure_delay: int | None = None
            if stu.HasField("departure") and stu.departure.delay != 0:
                departure_delay = int(stu.departure.delay)

            resolved_name = get_stop_name(stu.stop_id)
            if (
                resolved_name == stu.stop_id
                and len(stu.stop_id) > 1
                and stu.stop_id[-1] in "NS"
            ):
                resolved_name = get_stop_name(stu.stop_id[:-1])

            stop_info = get_stop_info(stu.stop_id)
            if stop_info is None and len(stu.stop_id) > 1 and stu.stop_id[-1] in "NS":
                stop_info = get_stop_info(stu.stop_id[:-1])

            arrivals.append(
                TrackArrival(
                    route_id=route,
                    station=stu.stop_id,
                    station_name=resolved_name,
                    direction=direction,
                    destination=destination,
                    minutes_away=minutes,
                    arrival_ts=arrival_time,
                    status="Cancelled" if stop_cancelled else "On Time",
                    trip_id=trip.trip.trip_id,
                    is_cancelled=stop_cancelled,
                    stop_lat=stop_info.lat if stop_info else None,
                    stop_lon=stop_info.lon if stop_info else None,
                    departure_ts=departure_time,
                    delay_seconds=arrival_delay,
                    departure_delay_seconds=departure_delay,
                    is_skipped=stop_skipped,
                    is_no_data=stop_no_data,
                )
            )

    return arrivals, siri_obs, len(feed.entity)


async def get_arrivals_for_line(
    line_id: str,
    *,
    force_refresh: bool = False,
) -> list[TrackArrival]:
    """Fetch & decode GTFS-RT Protobuf for *line_id*, returning clean arrivals.

    Each feed covers a family of lines (e.g. ACE, BDFM).  We return
    ALL routes found in the feed — not just the representative letter —
    so the caller gets every train from that feed.

    Performance: If the feed was parsed within the last 30 seconds
    (by the background refresh loop or a prior request), returns the
    cached result immediately — zero thread pool, zero CPU.

    Parameters
    ----------
    force_refresh : bool
        When ``True`` (used by the background refresh loop), skip the
        parsed cache and always re-fetch + re-parse.  This keeps data
        fresh while still allowing user requests to hit the cache.
    """
    url = get_feed_url(line_id)
    if url is None:
        TrackLogger.info(f"No feed URL for line_id={line_id}", tag="SUBWAY")
        return []

    # ── Fast path: return cached parsed arrivals if still fresh ──
    if not force_refresh:
        cached = _PARSED_CACHE.get(url)
        if cached is not None:
            ts, cached_arrivals, _cached_siri_obs, _cached_entity_count, _trip_idx = cached
            if _time.time() - ts < _PARSED_CACHE_TTL:
                TrackLogger.cache(f"PARSED HIT {line_id}")
                return list(cached_arrivals)  # shallow copy — caller may sort/filter

    raw = await fetch_protobuf(url)

    # Offload ALL CPU-bound work (protobuf parsing + entity iteration +
    # object creation) to the thread-pool so the event loop stays
    # responsive for health checks and other concurrent requests.
    loop = asyncio.get_running_loop()
    arrivals, siri_obs, entity_count = await loop.run_in_executor(
        None, _parse_feed_sync, raw, line_id
    )

    arrivals.sort(key=lambda a: a.minutes_away)

    # Build trip_id → arrivals index for O(1) live-activity lookups
    trip_index: dict[str, list[TrackArrival]] = {}
    for _a in arrivals:
        if _a.trip_id:
            trip_index.setdefault(_a.trip_id, []).append(_a)

    # ── Fast-travel filter ───────────────────────────────────────────────
    # Prune stop entries that imply physically impossible speeds rather than
    # dropping the whole trip.  When stop B teleports from stop A, B is
    # removed and the scan continues from A — multi-hop glitches are all
    # caught while the rest of the trip's valid arrivals stay visible.
    #
    # All drops within one trip are batched into a single log entry, keyed
    # by trip_id with a 5-minute cooldown, so a persistently glitchy feed
    # does not flood the log on every 10-second poll cycle.
    # Periodic dict cleanup prevents unbounded growth over long uptimes.
    _now = _time.time()
    global _fast_travel_cleanup_at
    if _now - _fast_travel_cleanup_at > _FAST_TRAVEL_CLEANUP_INTERVAL_SECS:
        _cutoff = _now - _FAST_TRAVEL_WARN_COOLDOWN_SECS
        stale_keys = [k for k, t in _fast_travel_warn_ts.items() if t < _cutoff]
        for _k in stale_keys:
            del _fast_travel_warn_ts[_k]
        _fast_travel_cleanup_at = _now

    bad_stop_ids: set[int] = set()        # id() of TrackArrival objects to prune
    trip_drops: dict[str, list[str]] = {}  # trip_id → dropped pair strings
    for trip_id, trip_arrivals in trip_index.items():
        prev: TrackArrival | None = None
        for arr in trip_arrivals:
            if (
                prev is not None
                and arr.stop_lat is not None
                and arr.stop_lon is not None
                and prev.stop_lat is not None
                and prev.stop_lon is not None
                and arr.arrival_ts
                and prev.arrival_ts
                and _is_fast_travel(
                    prev.stop_lat,
                    prev.stop_lon,
                    prev.arrival_ts,
                    arr.stop_lat,
                    arr.stop_lon,
                    arr.arrival_ts,
                )
            ):
                trip_drops.setdefault(trip_id, []).append(
                    f"{prev.station}→{arr.station}"
                )
                # Prune the offending arrival; keep prev as the anchor so
                # subsequent stops are validated against the last known good.
                bad_stop_ids.add(id(arr))
            else:
                prev = arr

    # Emit at most one log per trip per cooldown window.
    for trip_id, pairs in trip_drops.items():
        if (
            _now - _fast_travel_warn_ts.get(trip_id, 0.0)
            >= _FAST_TRAVEL_WARN_COOLDOWN_SECS
        ):
            _log_fast_travel_drop(trip_id, pairs)
            _fast_travel_warn_ts[trip_id] = _now

    if bad_stop_ids:
        arrivals = [a for a in arrivals if id(a) not in bad_stop_ids]
        # Rebuild trip index to match the pruned arrivals list.
        trip_index = {}
        for _a in arrivals:
            if _a.trip_id:
                trip_index.setdefault(_a.trip_id, []).append(_a)

    # Cache the parsed result so subsequent calls skip all CPU work
    _PARSED_CACHE[url] = (_time.time(), arrivals, siri_obs, entity_count, trip_index)

    TrackLogger.subway(
        f"Feed {line_id}: {len(arrivals)} arrivals from {entity_count} entities"
    )

    # ── Fire-and-forget recency observations ────────────────────────────
    # Collect all SIRI delay observations and trip snapshots, then write
    # everything in two pipelines (one per call) instead of one future
    # per stop/trip — prevents connection-pool exhaustion.
    trip_stops: dict[str, tuple[str, dict[str, int]]] = (
        {}
    )  # trip_id → (route_id, {stop_id: ts})
    for arrival in arrivals:
        if arrival.trip_id and arrival.arrival_ts:
            if arrival.trip_id not in trip_stops:
                trip_stops[arrival.trip_id] = (arrival.route_id, {})
            trip_stops[arrival.trip_id][1][arrival.station] = arrival.arrival_ts

    if siri_obs:
        task = asyncio.ensure_future(observe_siri_delays_batch(siri_obs))
        _background_tasks.add(task)
        task.add_done_callback(_background_tasks.discard)

    if trip_stops:
        trips = [(tid, rid, smap) for tid, (rid, smap) in trip_stops.items()]
        task = asyncio.ensure_future(observe_trip_updates_batch(trips))
        _background_tasks.add(task)
        task.add_done_callback(_background_tasks.discard)

    return arrivals


async def _parse_alert_feed(url: str, mode: str) -> list[TransitAlert]:
    """Parse a single MTA JSON alerts feed and return active alerts.

    Implements MTA GTFS-RT Mercury extension fields:
    - ``active_period.end`` — filter expired alerts (start <= now <= end).
    - ``display_before_active`` — show before active window starts.
    - ``sort_order`` — numeric severity rank (higher = more severe).
    - ``alert_type`` — human-friendly status label (e.g. "Delays").
    """
    import time as _t

    try:
        data: Any = await fetch_json(url)
    except Exception as exc:
        TrackLogger.info(f"Failed to fetch {mode} alerts: {exc}", tag="ALERTS")
        return []

    now = int(_t.time())
    alerts: list[TransitAlert] = []
    entities = data.get("entity", []) if isinstance(data, dict) else []
    for entity in entities:
        alert_data = entity.get("alert", {})

        # Include alerts with meaningful severity.
        # MTA feeds use: UNKNOWN_SEVERITY, INFO, WARNING, SEVERE
        # We exclude only INFO (informational, non-disruptive).
        severity_level = alert_data.get("severity_level", "")
        if severity_level == "INFO":
            continue

        # ── Mercury extension fields ────────────────────────────────────
        mercury = alert_data.get("transit_realtime.mercury_alert", {})
        alert_type: str | None = mercury.get("alert_type")  # e.g. "Delays"
        display_before_active: int | None = mercury.get("display_before_active")
        # human_readable_active_period (translation array, take first text)
        hrap_translations = (
            mercury.get("human_readable_active_period", {}).get("translation", [])
            if isinstance(mercury, dict)
            else []
        )
        human_readable_active_period: str | None = (
            hrap_translations[0].get("text") if hrap_translations else None
        )

        # GTFS-RT Cause / Effect (string enum names in the JSON feed)
        cause: str | None = alert_data.get("cause") or None
        effect: str | None = alert_data.get("effect") or None
        if cause in ("UNKNOWN_CAUSE", ""):
            cause = None
        if effect in ("UNKNOWN_EFFECT", ""):
            effect = None

        # ── Active-period filtering (Gap #1) ────────────────────────────
        # An alert is visible when ANY active_period bracket contains 'now'
        # (adjusted for display_before_active).  If the entity has no valid
        # brackets at all, we still include it (fail-open).
        active_periods = alert_data.get("active_period", [])
        updated_at: int | None = None
        active_period_end: int | None = None
        visible = False  # at least one bracket must contain "now"

        if active_periods:
            starts = [int(ap["start"]) for ap in active_periods if ap.get("start")]
            if starts:
                updated_at = max(starts)

            for ap in active_periods:
                ap_start = int(ap["start"]) if ap.get("start") else 0
                ap_end = int(ap["end"]) if ap.get("end") else None

                # display_before_active: surface the alert N seconds early.
                effective_start = ap_start
                if display_before_active is not None and display_before_active > 0:
                    effective_start = ap_start - display_before_active

                if ap_end is not None:
                    if effective_start <= now <= ap_end:
                        visible = True
                        active_period_end = max(active_period_end or 0, ap_end)
                else:
                    # Open-ended period — visible after effective_start
                    if now >= effective_start:
                        visible = True
        else:
            # No active_period at all — fail-open, show it.
            visible = True

        if not visible:
            continue

        # ── Informed entities ───────────────────────────────────────────
        informed = alert_data.get("informed_entity", [])
        route_id = informed[0].get("route_id") if informed else None

        # Collect ALL affected route_ids for this alert
        affected_routes: list[str] = []
        for ie in informed:
            rid = ie.get("route_id")
            if rid and rid not in affected_routes:
                affected_routes.append(rid)

        # ── sort_order (Gap #2) — extract numeric severity rank ─────────
        # Format: "MTASBWY:N:26" → 26.  Take the MAX across all entities.
        max_sort_order = 0
        for ie in informed:
            mes = ie.get("transit_realtime.mercury_entity_selector", {})
            so_raw = mes.get("sort_order", "")
            if ":" in so_raw:
                with contextlib.suppress(ValueError, IndexError):
                    max_sort_order = max(max_sort_order, int(so_raw.rsplit(":", 1)[-1]))

        # ── Text fields ─────────────────────────────────────────────────
        header_text = alert_data.get("header_text", {})
        translations = header_text.get("translation", [])
        title = (
            translations[0].get("text", "Service Alert")
            if translations
            else "Service Alert"
        )

        desc_text = alert_data.get("description_text", {})
        desc_translations = desc_text.get("translation", [])
        description = desc_translations[0].get("text", "") if desc_translations else ""

        # Normalize severity for the frontend
        normalized_severity = severity_level.lower() if severity_level else "warning"
        if normalized_severity in ("unknown_severity", ""):
            normalized_severity = "warning"

        alerts.append(
            TransitAlert(
                route_id=route_id,
                title=title,
                description=description,
                severity=normalized_severity,
                mode=mode,
                updated_at=updated_at,
                affected_routes=affected_routes,
                alert_type=alert_type,
                sort_order=max_sort_order,
                display_before_active=display_before_active,
                active_period_end=active_period_end,
                cause=cause,
                effect=effect,
                human_readable_active_period=human_readable_active_period,
            )
        )

    return alerts


async def get_alerts(mode: str | None = None) -> list[TransitAlert]:
    """Fetch MTA service alerts. Optionally filter by mode (subway/bus/lirr/mnr).

    When *mode* is ``None`` all feeds are fetched concurrently.
    """
    settings = get_settings()

    feed_map: dict[str, str] = {
        "subway": settings.urls.alerts_json,
        "bus": settings.urls.bus_alerts_json,
        "lirr": settings.urls.lirr_alerts_json,
        "mnr": settings.urls.mnr_alerts_json,
    }

    # Filter out modes without a configured URL
    feed_map = {k: v for k, v in feed_map.items() if v}

    if mode and mode in feed_map:
        return await _parse_alert_feed(feed_map[mode], mode)

    # Fetch all feeds concurrently — tolerate individual feed failures
    tasks = [_parse_alert_feed(url, m) for m, url in feed_map.items()]
    results = await asyncio.gather(*tasks, return_exceptions=True)
    all_alerts: list[TransitAlert] = []
    ok_count = 0
    for m_key, result in zip(feed_map.keys(), results, strict=False):
        if isinstance(result, BaseException):
            TrackLogger.info(
                f"[ALERTS] {m_key} alert feed failed: {result}",
                tag="ALERTS",
            )
            continue
        all_alerts.extend(result)
        ok_count += 1

    TrackLogger.alerts(
        f"Fetched {len(all_alerts)} alerts across {ok_count}/{len(feed_map)} feeds"
    )
    return all_alerts


async def get_broken_elevators() -> list[ElevatorStatus]:
    """Fetch the elevator/escalator JSON feed and return out-of-service units."""
    settings = get_settings()
    url = settings.urls.elevators_json
    data: Any = await fetch_json(url)

    results: list[ElevatorStatus] = []
    outages = data if isinstance(data, list) else data.get("results", [])
    for item in outages:
        if not isinstance(item, dict):
            continue
        is_active = item.get("isactive", "Y")
        # Only report units that are currently out of service
        if str(is_active).upper() == "Y":
            continue
        results.append(
            ElevatorStatus(
                station=item.get("station", "Unknown"),
                equipment_type=item.get("equipmenttype", "Elevator"),
                description=item.get("serving", ""),
                outage_since=item.get("outagedate"),
            )
        )

    TrackLogger.data(f"Elevator/escalator outages: {len(results)} out of service")
    return results


# ---------------------------------------------------------------------------
# Vehicle Position parsing — extract live train positions from GTFS-RT feeds
# ---------------------------------------------------------------------------
from app.models import TransitVehicle as _TransitVehicle

_VEHICLE_CACHE: dict[str, tuple[float, list[_TransitVehicle]]] = {}
_VEHICLE_CACHE_TTL = 15.0


_VEHICLE_STATUS_MAP = {
    0: "INCOMING_AT",
    1: "STOPPED_AT",
    2: "IN_TRANSIT_TO",
}


# ---------------------------------------------------------------------------
# Per-trip stop-time lookup
#
# When the iOS user taps a chip representing one specific train trip,
# the app needs to know that exact trip's predicted arrival time at
# every downstream stop so the Stops list can re-render its ETAs from
# the rider's perspective.
#
# The data is already available — `_PARSED_CACHE` stores a per-feed
# `trip_index` mapping `trip_id → list[TrackArrival]` (one arrival per
# stop_time_update on that trip).  This helper just fans out across
# every cached feed, returning the first match (subway trip_ids are
# globally unique within a feed family).
# ---------------------------------------------------------------------------
def find_arrivals_for_trip(trip_id: str) -> list[TrackArrival]:
    """Return all cached `TrackArrival` rows for *trip_id* in feed order.

    Returns an empty list when the trip is unknown (either not currently
    in any active GTFS-RT feed, or all feeds with the trip have expired
    from `_PARSED_CACHE`).
    """
    if not trip_id:
        return []
    for cached in _PARSED_CACHE.values():
        # Tuple shape: (ts, arrivals, siri_obs, entity_count, trip_index)
        if len(cached) < 5:
            continue
        trip_index = cached[4]
        hits = trip_index.get(trip_id)
        if hits:
            return list(hits)
    return []


def _parse_vehicle_positions_sync(
    raw: bytes,
    line_id: str,
    mode: str = "subway",
    color_fn=None,
) -> list[_TransitVehicle]:
    """Extract VehiclePosition entities from a GTFS-RT feed — CPU-bound, runs in thread."""
    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(raw)

    vehicles: list[_TransitVehicle] = []

    for entity in feed.entity:
        if not entity.HasField("vehicle"):
            continue
        vp = entity.vehicle

        # NYCT subway feeds publish VehiclePosition entities with real
        # signal-system data (current_stop_id, current_status, timestamp)
        # but NO GPS position.  When position is missing we fall back to
        # the GTFS stop coordinates of vp.stop_id — that still gives the
        # client the actual platform the train is at, anchored to the
        # right map location, instead of dropping the entity entirely.
        has_position = vp.HasField("position")

        route_id = vp.trip.route_id if vp.trip.HasField("route_id") else ""
        trip_id = vp.trip.trip_id if vp.trip.HasField("trip_id") else None
        vehicle_id = vp.vehicle.id if vp.HasField("vehicle") and vp.vehicle.id else (trip_id or entity.id)

        stop_id = vp.stop_id if vp.stop_id else None
        stop_info = get_stop_info(stop_id) if stop_id else None
        if stop_info is None and stop_id and len(stop_id) > 1 and stop_id[-1] in "NS":
            stop_info = get_stop_info(stop_id[:-1])

        if has_position:
            lat = vp.position.latitude
            lon = vp.position.longitude
            bearing = vp.position.bearing if vp.position.bearing else None
            speed = None
            if vp.position.speed > 0:
                speed = round(vp.position.speed * 2.23694, 1)  # m/s → mph
        elif stop_info is not None:
            lat = stop_info.lat
            lon = stop_info.lon
            bearing = None
            speed = None
        else:
            # No GPS and no resolvable stop — skip; client interpolation
            # will draw something sensible from the trip's arrivals.
            continue

        stop_name_resolved = stop_info.name if stop_info else None
        if stop_name_resolved is None and stop_id:
            stop_name_resolved = get_stop_name(stop_id)
            if stop_name_resolved in (None, "Unknown", stop_id) and len(stop_id) > 1 and stop_id[-1] in "NS":
                resolved = get_stop_name(stop_id[:-1])
                if resolved != "Unknown":
                    stop_name_resolved = resolved

        status_enum = vp.current_status if vp.HasField("current_status") else 2
        status_str = _VEHICLE_STATUS_MAP.get(status_enum, "IN_TRANSIT_TO")

        timestamp = vp.timestamp if vp.timestamp else None

        # GTFS-RT VehiclePosition.OccupancyStatus is an optional enum.
        # Treat default-zero as "unset" only when the field wasn't actually
        # present — protobuf lacks HasField for scalar enums in proto3, so
        # we approximate by checking for any non-default value.  NYCT
        # currently publishes this on a subset of lines (e.g. 7) and the
        # enum value 0 ("empty") is rare enough at peak that a None
        # default better matches reality than "empty".
        occupancy_raw = getattr(vp, "occupancy_status", 0)
        occupancy_value: int | None = (
            int(occupancy_raw) if occupancy_raw and occupancy_raw > 0 else None
        )

        congestion_raw = getattr(vp, "congestion_level", 0)
        congestion_value: int | None = (
            int(congestion_raw) if congestion_raw and congestion_raw > 0 else None
        )

        color = None
        if color_fn and route_id:
            color = color_fn(route_id)

        vehicles.append(_TransitVehicle(
            vehicle_id=vehicle_id,
            route_id=route_id,
            trip_id=trip_id,
            lat=lat,
            lon=lon,
            bearing=bearing,
            speed_mph=speed,
            current_stop_id=stop_id,
            current_stop_name=stop_name_resolved,
            status=status_str,
            mode=mode,
            timestamp=timestamp,
            color_hex=color,
            occupancy_status=occupancy_value,
            congestion_level=congestion_value,
            current_status_code=int(status_enum) if vp.HasField("current_status") else None,
        ))

    return vehicles


async def get_vehicle_positions_for_line(
    line_id: str,
    *,
    mode: str = "subway",
    color_fn=None,
) -> list[_TransitVehicle]:
    """Fetch live vehicle positions for a subway line from GTFS-RT.

    Returns cached positions if polled within the last 15 seconds.
    """
    url = get_feed_url(line_id)
    if url is None:
        return []

    cache_key = f"{url}:{mode}"
    cached = _VEHICLE_CACHE.get(cache_key)
    if cached is not None:
        ts, vehicles = cached
        if _time.time() - ts < _VEHICLE_CACHE_TTL:
            return list(vehicles)

    raw = await fetch_protobuf(url)
    loop = asyncio.get_running_loop()
    vehicles = await loop.run_in_executor(
        None, _parse_vehicle_positions_sync, raw, line_id, mode, color_fn
    )

    _VEHICLE_CACHE[cache_key] = (_time.time(), vehicles)

    TrackLogger.data(f"Vehicle positions {mode}/{line_id}: {len(vehicles)} vehicles")
    return vehicles

