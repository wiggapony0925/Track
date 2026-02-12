#
# data_cleaner.py
# TrackBackend
#
# Converts raw MTA Protobuf (GTFS-Realtime) and JSON data into clean,
# standardized Pydantic models that the iOS app can consume directly.
#

from __future__ import annotations

import time
from typing import Any

from google.transit import gtfs_realtime_pb2  # type: ignore[import-untyped]

from app.config import get_feed_url
from app.models import ElevatorStatus, TrackArrival, TransitAlert
from app.services.mta_client import fetch_json, fetch_protobuf
from app.services.station_lookup import get_stop_name


def _minutes_until(epoch: int) -> int:
    """Return the number of whole minutes from *now* until *epoch*."""
    diff = epoch - int(time.time())
    return max(0, diff // 60)


async def get_arrivals_for_line(line_id: str) -> list[TrackArrival]:
    """Fetch & decode GTFS-RT Protobuf for *line_id*, returning clean arrivals.

    Each feed covers a family of lines (e.g. ACE, BDFM).  We return
    ALL routes found in the feed — not just the representative letter —
    so the caller gets every train from that feed.
    """
    url = get_feed_url(line_id)
    if url is None:
        return []

    raw = await fetch_protobuf(url)

    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(raw)

    arrivals: list[TrackArrival] = []

    for entity in feed.entity:
        if not entity.HasField("trip_update"):
            continue
        trip = entity.trip_update
        route = trip.trip.route_id  # e.g. "A", "C", "E" from the ACE feed
        
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
            minutes = _minutes_until(arrival_time)
            direction = "N" if stu.stop_id.endswith("N") else "S"
            arrivals.append(
                TrackArrival(
                    route_id=route,
                    station=stu.stop_id,
                    direction=direction,
                    destination=destination,
                    minutes_away=minutes,
                    status="On Time",
                )
            )

    arrivals.sort(key=lambda a: a.minutes_away)
    return arrivals


async def get_alerts() -> list[TransitAlert]:
    """Fetch the JSON service alerts feed and return critical alerts only."""
    from app.config import get_settings

    settings = get_settings()
    url = settings.urls.alerts_json
    data: Any = await fetch_json(url)

    alerts: list[TransitAlert] = []
    entities = data.get("entity", []) if isinstance(data, dict) else []
    for entity in entities:
        alert_data = entity.get("alert", {})

        # Only include alerts with a severity of WARNING or SEVERE
        severity_level = alert_data.get("severity_level", "")
        if severity_level not in ("WARNING", "SEVERE"):
            continue

        informed = alert_data.get("informed_entity", [])
        route_id = informed[0].get("route_id") if informed else None

        header_text = alert_data.get("header_text", {})
        translations = header_text.get("translation", [])
        title = translations[0].get("text", "Service Alert") if translations else "Service Alert"

        desc_text = alert_data.get("description_text", {})
        desc_translations = desc_text.get("translation", [])
        description = desc_translations[0].get("text", "") if desc_translations else ""

        alerts.append(
            TransitAlert(
                route_id=route_id,
                title=title,
                description=description,
                severity=severity_level.lower(),
            )
        )

    return alerts


async def get_broken_elevators() -> list[ElevatorStatus]:
    """Fetch the elevator/escalator JSON feed and return out-of-service units."""
    from app.config import get_settings

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

    return results
