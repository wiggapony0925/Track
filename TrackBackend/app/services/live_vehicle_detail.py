"""Build backend-owned live vehicle detail objects."""

from __future__ import annotations

import datetime as dt
from typing import Any

from app.models import BusVehicle, LiveVehicleDetail, TransitVehicle


STALE_POSITION_SECONDS = 180.0


def _now_utc() -> dt.datetime:
    return dt.datetime.now(dt.UTC)


def _age_seconds(
    recorded_at: dt.datetime | None,
    *,
    now: dt.datetime,
) -> float | None:
    if recorded_at is None:
        return None
    if recorded_at.tzinfo is None:
        recorded_at = recorded_at.replace(tzinfo=dt.UTC)
    return max(0.0, (now - recorded_at).total_seconds())


def _timestamp_age_seconds(timestamp: int | None, *, now: dt.datetime) -> float | None:
    if not timestamp:
        return None
    return max(0.0, now.timestamp() - float(timestamp))


def _confidence(
    *,
    is_realtime: bool,
    is_stale: bool,
    has_age: bool,
    position_source: str = "gps",
) -> float:
    if is_stale:
        return 0.15
    if not is_realtime:
        return 0.55
    if position_source == "crowdsourced":
        return 0.72 if has_age else 0.65
    if position_source == "stop_anchor":
        return 0.68
    if not has_age:
        return 0.85
    return 1.0


def build_bus_live_vehicle_details(
    vehicles: list[BusVehicle],
    *,
    now: dt.datetime | None = None,
) -> list[LiveVehicleDetail]:
    """Create live details for SIRI bus vehicle positions in O(n)."""
    now = now or _now_utc()
    details: list[LiveVehicleDetail] = []
    for vehicle in vehicles:
        age = _age_seconds(vehicle.position_recorded_at, now=now)
        is_stale = age is not None and age > STALE_POSITION_SECONDS
        downstream_stop_ids = [
            call.stop_id for call in vehicle.onward_calls if call.stop_id
        ]
        first_call = vehicle.onward_calls[0] if vehicle.onward_calls else None
        headsign = vehicle.destination_ref or (first_call.destination_name if first_call else None)
        position_source = "crowdsourced" if vehicle.is_crowdsourced else "gps"
        details.append(
            LiveVehicleDetail(
                vehicle_id=vehicle.vehicle_id,
                route_id=vehicle.route_id,
                mode="bus",
                trip_id=vehicle.trip_id,
                pattern_id=None,
                direction_id=vehicle.direction_ref,
                headsign=headsign,
                lat=vehicle.lat,
                lon=vehicle.lon,
                bearing=vehicle.bearing,
                next_stop_id=vehicle.next_stop,
                next_stop_name=first_call.stop_name if first_call else None,
                downstream_stop_count=len(downstream_stop_ids),
                downstream_stop_ids=downstream_stop_ids,
                position_source=position_source if vehicle.is_realtime else "interpolated",
                position_age_seconds=age,
                is_stale=is_stale,
                is_realtime=vehicle.is_realtime,
                position_confidence=_confidence(
                    is_realtime=vehicle.is_realtime,
                    is_stale=is_stale,
                    has_age=age is not None,
                    position_source=position_source,
                ),
                status=vehicle.status_text,
                vehicle=vehicle.model_dump(mode="json"),
            )
        )
    return details


def build_train_live_vehicle_details(
    vehicles: list[TransitVehicle],
    *,
    now: dt.datetime | None = None,
) -> list[LiveVehicleDetail]:
    """Create live details for GTFS-RT train vehicle positions in O(n)."""
    now = now or _now_utc()
    details: list[LiveVehicleDetail] = []
    for vehicle in vehicles:
        age = _timestamp_age_seconds(vehicle.timestamp, now=now)
        is_stale = age is not None and age > STALE_POSITION_SECONDS
        position_source = "gps" if vehicle.bearing is not None or vehicle.speed_mph else "stop_anchor"
        details.append(
            LiveVehicleDetail(
                vehicle_id=vehicle.vehicle_id,
                route_id=vehicle.route_id,
                mode=vehicle.mode,
                trip_id=vehicle.trip_id,
                pattern_id=None,
                direction_id=None,
                headsign=None,
                lat=vehicle.lat,
                lon=vehicle.lon,
                bearing=vehicle.bearing,
                next_stop_id=vehicle.current_stop_id,
                next_stop_name=vehicle.current_stop_name,
                downstream_stop_count=1 if vehicle.current_stop_id else 0,
                downstream_stop_ids=[vehicle.current_stop_id] if vehicle.current_stop_id else [],
                position_source=position_source,
                position_age_seconds=age,
                is_stale=is_stale,
                is_realtime=True,
                position_confidence=_confidence(
                    is_realtime=True,
                    is_stale=is_stale,
                    has_age=age is not None,
                    position_source=position_source,
                ),
                status=vehicle.status,
                vehicle=vehicle.model_dump(mode="json"),
            )
        )
    return details