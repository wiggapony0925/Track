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
from app.clients.mta_client import fetch_protobuf
from app.services.transit.station_lookup import get_stop_name
from app.utils.geo_utils import minutes_until as _minutes_until
from app.utils.logger import TrackLogger
import time as _time

# ── Parsed-arrivals cache ────────────────────────────────────────
# Keyed by feed URL.  Background refresh populates it; user requests
# return the cached list in < 1 µs — zero thread pool, zero CPU.
_RAIL_PARSED_CACHE: dict[str, tuple[float, list, int]] = {}
_RAIL_PARSED_CACHE_TTL = 60.0  # must outlive bg refresh cycle + interval (~30s)

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


def _parse_rail_feed_sync(
    raw: bytes, agency: str, lookup_agency: str,
) -> tuple[list["TrackArrival"], int]:
    """Parse a rail GTFS-RT feed — **runs in a thread**.

    Returns (arrivals, entity_count).
    """
    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(raw)

    arrivals: list[TrackArrival] = []

    for entity in feed.entity:
        if not entity.HasField("trip_update"):
            continue

        trip_update = entity.trip_update
        route_id = trip_update.trip.route_id

        # Resolve the terminal station name from the last stop in the trip.
        # Use None instead of "Unknown" so downstream code doesn't treat
        # an unresolved name as a truthy destination string.
        destination: str | None = None
        if trip_update.stop_time_update:
            last_stop_id = trip_update.stop_time_update[-1].stop_id
            resolved = get_stop_name(last_stop_id, agency=lookup_agency)
            # get_stop_name returns the raw stop_id when the name isn't found.
            # Treat raw IDs and "Unknown" as unresolved.
            if resolved and resolved != last_stop_id and resolved.lower() != "unknown":
                destination = resolved

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
            arrival_time = 0
            if stu.HasField("arrival"):
                arrival_time = stu.arrival.time
            elif stu.HasField("departure"):
                arrival_time = stu.departure.time

            if arrival_time == 0:
                continue

            minutes = _minutes_until(arrival_time)

            delay_secs = 0
            if stu.HasField("arrival") and stu.arrival.HasField("delay"):
                delay_secs = stu.arrival.delay
            elif stu.HasField("departure") and stu.departure.HasField("delay"):
                delay_secs = stu.departure.delay

            if delay_secs >= 360:
                status = f"Late ({delay_secs // 60}m)"
            elif delay_secs >= 60:
                status = f"Delayed ({delay_secs // 60}m)"
            else:
                status = "On Time"

            arrivals.append(
                TrackArrival(
                    route_id=route_id,
                    station=stu.stop_id,
                    station_name=get_stop_name(stu.stop_id, agency=lookup_agency),
                    direction=direction,
                    destination=destination,
                    minutes_away=minutes,
                    arrival_ts=arrival_time,
                    status=status,
                    trip_id=trip_update.trip.trip_id
                )
            )

    return arrivals, len(feed.entity)


async def fetch_rail_arrivals(
    agency: str, *, force_refresh: bool = False,
) -> list[TrackArrival]:
    """Fetch & clean arrivals for a rail agency ('lirr' or 'metro_north')."""
    settings = get_settings()

    if agency == "lirr":
        url = settings.urls.lirr
    elif agency == "metro_north":
        url = settings.urls.metro_north
    else:
        TrackLogger.warning(f"Unknown rail agency: {agency}", tag="RAIL")
        return []

    # ── Fast path: return cached parsed arrivals if still fresh ──
    if not force_refresh:
        cached = _RAIL_PARSED_CACHE.get(url)
        if cached is not None:
            ts, cached_arrivals, _cnt = cached
            if _time.time() - ts < _RAIL_PARSED_CACHE_TTL:
                TrackLogger.cache(f"PARSED HIT rail/{agency}")
                return list(cached_arrivals)

    raw = await fetch_protobuf(url)

    # Offload ALL CPU-bound work (protobuf parsing + entity iteration)
    # to the thread-pool so the event loop stays responsive.
    import asyncio as _asyncio
    lookup_agency = "mnr" if agency == "metro_north" else agency
    loop = _asyncio.get_running_loop()
    arrivals, entity_count = await loop.run_in_executor(
        None, _parse_rail_feed_sync, raw, agency, lookup_agency
    )

    arrivals.sort(key=lambda a: a.arrival_ts)

    # Cache the parsed result so subsequent calls skip all CPU work
    _RAIL_PARSED_CACHE[url] = (_time.time(), arrivals, entity_count)

    TrackLogger.rail(f"{agency}: {len(arrivals)} arrivals from {entity_count} entities")
    return arrivals
