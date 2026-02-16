#
# rail_client.py
# TrackBackend
#
# Client for fetching real-time arrivals from LIRR and Metro-North GTFS-RT feeds.
#

from __future__ import annotations

import time
from typing import Any
from google.transit import gtfs_realtime_pb2  # type: ignore[import-untyped]

from app.config import get_settings
from app.models import TrackArrival
from app.services.mta_client import fetch_protobuf
from app.services.station_lookup import get_stop_name

def _minutes_until(epoch: int) -> int:
    """Return the number of whole minutes from *now* until *epoch*."""
    diff = epoch - int(time.time())
    return max(0, diff // 60)

async def fetch_rail_arrivals(agency: str) -> list[TrackArrival]:
    """Fetch & clean arrivals for a rail agency ('lirr' or 'metro_north')."""
    settings = get_settings()
    
    if agency == "lirr":
        url = settings.urls.lirr
    elif agency == "metro_north":
        url = settings.urls.metro_north
    else:
        return []

    try:
        raw = await fetch_protobuf(url)
    except Exception as e:
        # Re-raise to be caught by the router
        raise e

    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(raw)

    arrivals: list[TrackArrival] = []
    
    for entity in feed.entity:
        if not entity.HasField("trip_update"):
            continue
            
        trip_update = entity.trip_update
        route_id = trip_update.trip.route_id
        
        # Determine destination from the last stop in the trip update
        destination = "Unknown"
        if trip_update.stop_time_update:
            last_stop_id = trip_update.stop_time_update[-1].stop_id
            destination = get_stop_name(last_stop_id)

        for stu in trip_update.stop_time_update:
            # We want future arrivals
            arrival_time = 0
            if stu.HasField("arrival"):
                arrival_time = stu.arrival.time
            elif stu.HasField("departure"):
                arrival_time = stu.departure.time
                
            if arrival_time == 0:
                continue
                
            minutes = _minutes_until(arrival_time)
            
            # For Rail, usually direction is encoded in trip or stop_id.
            # GTFS-RT direction_id is often used.
            direction = "N/A"
            if trip_update.trip.HasField("direction_id"):
                direction = "Outbound" if trip_update.trip.direction_id == 1 else "Inbound"
            
            arrivals.append(
                TrackArrival(
                    route_id=route_id,
                    station=stu.stop_id,
                    station_name=get_stop_name(stu.stop_id),
                    direction=direction,
                    destination=destination,
                    minutes_away=minutes,
                    arrival_ts=arrival_time,
                    status="On Time",  # TODO: Check delay field
                    trip_id=trip_update.trip.trip_id
                )
            )

    # Sort by arrival time
    arrivals.sort(key=lambda a: a.arrival_ts)
    return arrivals
