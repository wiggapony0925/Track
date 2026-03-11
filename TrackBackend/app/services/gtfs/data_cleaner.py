#
# data_cleaner.py
# TrackBackend
#
# Converts raw MTA Protobuf (GTFS-Realtime) and JSON data into clean,
# standardized Pydantic models that the iOS app can consume directly.
#

from __future__ import annotations

import asyncio
from typing import Any

from google.transit import gtfs_realtime_pb2  # type: ignore[import-untyped]

from app.config import get_feed_url, get_settings
from app.models import ElevatorStatus, TrackArrival, TransitAlert
from app.clients.mta_client import fetch_json, fetch_protobuf
from app.ml.recency_model import observe_trip_updates_batch, observe_siri_delays_batch
from app.services.transit.station_lookup import get_stop_name
from app.utils.geo_utils import minutes_until as _minutes_until
from app.utils.logger import TrackLogger


async def get_arrivals_for_line(line_id: str) -> list[TrackArrival]:
    """Fetch & decode GTFS-RT Protobuf for *line_id*, returning clean arrivals.

    Each feed covers a family of lines (e.g. ACE, BDFM).  We return
    ALL routes found in the feed — not just the representative letter —
    so the caller gets every train from that feed.
    """
    url = get_feed_url(line_id)
    if url is None:
        TrackLogger.warning(f"No feed URL for line_id={line_id}", tag="SUBWAY")
        return []

    raw = await fetch_protobuf(url)

    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(raw)

    arrivals: list[TrackArrival] = []
    siri_obs: list[tuple[str, str, float]] = []  # (route_id, stop_id, deviation_s)

    for entity in feed.entity:
        if not entity.HasField("trip_update"):
            continue
        trip = entity.trip_update
        route = trip.trip.route_id  # e.g. "A", "C", "E" from the ACE feed

        # Detect cancelled trips via GTFS-RT schedule_relationship.
        # Value 3 = CANCELED in gtfs_realtime_pb2.TripDescriptor.ScheduleRelationship.
        trip_cancelled = False
        if trip.trip.HasField("schedule_relationship"):
            trip_cancelled = trip.trip.schedule_relationship == 3
        
        # Determine destination from the last stop in the update
        destination = None
        if trip.stop_time_update:
            last_stop_id = trip.stop_time_update[-1].stop_id
            destination = get_stop_name(last_stop_id)
            # If default lookup failed (returned "Unknown"), try parent ID
            if destination == "Unknown" and len(last_stop_id) > 1 and last_stop_id[-1] in "NS":
                destination = get_stop_name(last_stop_id[:-1])
            
            if destination == "Unknown":
                destination = None

        for stu in trip.stop_time_update:
            arrival_time = stu.arrival.time if stu.HasField("arrival") else 0
            if arrival_time == 0:
                continue

            # Per-stop cancellation: schedule_relationship on stop_time_update
            # Value 1 = SKIPPED in GTFS-RT StopTimeUpdate.ScheduleRelationship.
            stop_cancelled = trip_cancelled
            if not stop_cancelled and stu.HasField("schedule_relationship"):
                stop_cancelled = stu.schedule_relationship == 1

            minutes = _minutes_until(arrival_time)
            direction = "N" if stu.stop_id.endswith("N") else "S"

            # GTFS-RT delay field: signed integer in seconds (+ve = late).
            # MTA populates this when it has real-time tracking on the trip.
            gtfs_delay_s: int | None = None
            if stu.HasField("arrival") and stu.arrival.delay != 0:
                gtfs_delay_s = stu.arrival.delay
                # Collect for batch observe — avoids per-stop Redis futures.
                siri_obs.append((route, stu.stop_id, float(stu.arrival.delay)))

            # Resolve station name: try full ID first, then strip N/S suffix
            resolved_name = get_stop_name(stu.stop_id)
            if resolved_name == stu.stop_id and len(stu.stop_id) > 1 and stu.stop_id[-1] in "NS":
                resolved_name = get_stop_name(stu.stop_id[:-1])

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
                )
            )

    arrivals.sort(key=lambda a: a.minutes_away)
    TrackLogger.subway(f"Feed {line_id}: {len(arrivals)} arrivals from {len(feed.entity)} entities")

    # ── Fire-and-forget recency observations ────────────────────────────
    # Collect all SIRI delay observations and trip snapshots, then write
    # everything in two pipelines (one per call) instead of one future
    # per stop/trip — prevents connection-pool exhaustion.
    trip_stops: dict[str, tuple[str, dict[str, int]]] = {}  # trip_id → (route_id, {stop_id: ts})
    for arrival in arrivals:
        if arrival.trip_id and arrival.arrival_ts:
            if arrival.trip_id not in trip_stops:
                trip_stops[arrival.trip_id] = (arrival.route_id, {})
            trip_stops[arrival.trip_id][1][arrival.station] = arrival.arrival_ts

    if siri_obs:
        asyncio.ensure_future(observe_siri_delays_batch(siri_obs))

    if trip_stops:
        trips = [(tid, rid, smap) for tid, (rid, smap) in trip_stops.items()]
        asyncio.ensure_future(observe_trip_updates_batch(trips))

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
        TrackLogger.error(f"Failed to fetch {mode} alerts: {exc}", tag="ALERTS", exc_info=True)
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
                try:
                    max_sort_order = max(max_sort_order, int(so_raw.rsplit(":", 1)[-1]))
                except (ValueError, IndexError):
                    pass

        # ── Text fields ─────────────────────────────────────────────────
        header_text = alert_data.get("header_text", {})
        translations = header_text.get("translation", [])
        title = translations[0].get("text", "Service Alert") if translations else "Service Alert"

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

    # Fetch all feeds concurrently
    tasks = [_parse_alert_feed(url, m) for m, url in feed_map.items()]
    results = await asyncio.gather(*tasks)
    all_alerts: list[TransitAlert] = []
    for result in results:
        all_alerts.extend(result)

    TrackLogger.alerts(f"Fetched {len(all_alerts)} alerts across {len(feed_map)} feeds")
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
