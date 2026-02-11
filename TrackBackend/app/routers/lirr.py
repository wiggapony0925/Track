#
# lirr.py
# TrackBackend
#
# Router for Long Island Rail Road arrivals.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.config import get_settings
from app.models import TrackArrival
from app.services.data_cleaner import _minutes_until
from app.services.mta_client import fetch_protobuf

router = APIRouter(tags=["lirr"])


@router.get("/lirr", response_model=list[TrackArrival])
async def lirr_arrivals() -> list[TrackArrival]:
    """Return upcoming LIRR arrivals from the GTFS-Realtime feed."""
    from google.transit import gtfs_realtime_pb2  # type: ignore[import-untyped]

    settings = get_settings()
    url = settings.urls.lirr

    try:
        raw = await fetch_protobuf(url)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(raw)

    arrivals: list[TrackArrival] = []
    for entity in feed.entity:
        if not entity.HasField("trip_update"):
            continue
        trip = entity.trip_update
        for stu in trip.stop_time_update:
            arrival_time = stu.arrival.time if stu.HasField("arrival") else 0
            if arrival_time == 0:
                continue
            minutes = _minutes_until(arrival_time)
            arrivals.append(
                TrackArrival(
                    station=stu.stop_id,
                    direction=trip.trip.route_id,
                    minutes_away=minutes,
                    status="On Time",
                )
            )

    arrivals.sort(key=lambda a: a.minutes_away)
    return arrivals
