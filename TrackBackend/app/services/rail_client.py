#
# rail_client.py
# TrackBackend
#
# Client for fetching real-time arrivals from LIRR and Metro-North GTFS-RT feeds.
#

from __future__ import annotations

from google.transit import gtfs_realtime_pb2  # type: ignore[import-untyped]

from app.config import get_settings
from app.models import TrackArrival
from app.services.mta_client import fetch_protobuf
from app.services.station_lookup import get_stop_name
from app.utils.geo_utils import minutes_until as _minutes_until
from app.utils.logger import TrackLogger

# Known terminal stop_ids for direction inference when direction_id is absent.
# MNR: Grand Central = "1"; LIRR: Penn Station = "237", Atlantic Terminal = "12"
_TERMINAL_IDS: frozenset[str] = frozenset({"1", "237", "12"})


def filter_fresh_arrivals(arrivals: list) -> list:
    """Drop already-departed trains and recalculate minutes_away from now.

    Used identically by the LIRR and MNR routers — extracted here to avoid
    copy-pasting the same four lines in two places.
    """
    import time as _t
    now = int(_t.time())
    fresh = [a for a in arrivals if a.arrival_ts and a.arrival_ts > now]
    for a in fresh:
        a.minutes_away = max(0, (a.arrival_ts - now) // 60)
    return fresh


async def fetch_rail_arrivals(agency: str) -> list[TrackArrival]:
    """Fetch & clean arrivals for a rail agency ('lirr' or 'metro_north')."""
    settings = get_settings()

    if agency == "lirr":
        url = settings.urls.lirr
    elif agency == "metro_north":
        url = settings.urls.metro_north
    else:
        TrackLogger.warning(f"Unknown rail agency: {agency}", tag="RAIL")
        return []

    raw = await fetch_protobuf(url)

    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(raw)

    arrivals: list[TrackArrival] = []

    # Map feed agency name to station_lookup agency key
    lookup_agency = "mnr" if agency == "metro_north" else agency
    
    for entity in feed.entity:
        if not entity.HasField("trip_update"):
            continue
            
        trip_update = entity.trip_update
        route_id = trip_update.trip.route_id
        
        # Determine destination from the last stop in the trip update
        destination = "Unknown"
        if trip_update.stop_time_update:
            last_stop_id = trip_update.stop_time_update[-1].stop_id
            destination = get_stop_name(last_stop_id, agency=lookup_agency)

        # Determine direction — prefer GTFS direction_id, infer from
        # terminal stop_ids when it's absent (e.g. Metro-North feeds).
        direction = "N/A"
        if trip_update.trip.HasField("direction_id"):
            direction = "Outbound" if trip_update.trip.direction_id == 1 else "Inbound"
        elif trip_update.stop_time_update:
            first_stop_id = trip_update.stop_time_update[0].stop_id
            last_stop_id_check = trip_update.stop_time_update[-1].stop_id
            if first_stop_id in _TERMINAL_IDS:
                direction = "Outbound"
            elif last_stop_id_check in _TERMINAL_IDS:
                direction = "Inbound"

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
            
            arrivals.append(
                TrackArrival(
                    route_id=route_id,
                    station=stu.stop_id,
                    station_name=get_stop_name(stu.stop_id, agency=lookup_agency),
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
    TrackLogger.rail(f"{agency}: {len(arrivals)} arrivals from {len(feed.entity)} entities")
    return arrivals
