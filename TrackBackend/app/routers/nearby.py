#
# nearby.py
# TrackBackend
#
# Router for the unified nearby transit endpoint.
# Returns the nearest buses and trains with live countdowns,
# sorted by minutes away. No trips or routing — just arrivals.
#

from __future__ import annotations

import asyncio
from datetime import datetime

from fastapi import APIRouter, Query

from app.models import NearbyTransitArrival
from app.services.bus_client import get_nearby_stops, get_realtime_arrivals
from app.services.data_cleaner import get_arrivals_for_line

router = APIRouter(tags=["nearby"])


@router.get("/nearby", response_model=list[NearbyTransitArrival])
async def nearby_transit(
    lat: float = Query(..., description="User latitude"),
    lon: float = Query(..., description="User longitude"),
    radius: int = Query(500, description="Search radius in meters"),
) -> list[NearbyTransitArrival]:
    """Return the nearest buses and trains with live countdowns.

    Combines subway arrivals from GTFS-RT feeds and bus arrivals from
    SIRI, sorted by ``minutes_away``. No routing or trips — just a
    flat list of what's arriving soon nearby.
    """
    results: list[NearbyTransitArrival] = []

    subway_task = _fetch_nearby_subway()
    bus_task = _fetch_nearby_buses(lat, lon)

    subway_results, bus_results = await asyncio.gather(
        subway_task, bus_task, return_exceptions=True,
    )

    if isinstance(subway_results, list):
        results.extend(subway_results)
    if isinstance(bus_results, list):
        results.extend(bus_results)

    results.sort(key=lambda a: a.minutes_away)
    return results[:20]


async def _fetch_nearby_subway() -> list[NearbyTransitArrival]:
    """Fetch arrivals from all subway feeds and return as NearbyTransitArrival."""
    results: list[NearbyTransitArrival] = []

    # Pick representative lines (one per feed) to avoid duplicate fetches
    feed_lines = ["A", "G", "N", "1", "B", "J", "L"]

    tasks = [get_arrivals_for_line(line) for line in feed_lines]
    feed_results = await asyncio.gather(*tasks, return_exceptions=True)

    for line, arrivals in zip(feed_lines, feed_results):
        if isinstance(arrivals, Exception) or not isinstance(arrivals, list):
            continue
        for arrival in arrivals[:5]:  # Top 5 per feed
            results.append(
                NearbyTransitArrival(
                    route_id=line,
                    stop_name=arrival.station,
                    direction=arrival.direction,
                    minutes_away=arrival.minutes_away,
                    status=arrival.status,
                    mode="subway",
                )
            )

    return results


async def _fetch_nearby_buses(lat: float, lon: float) -> list[NearbyTransitArrival]:
    """Fetch live bus arrivals from nearby stops."""
    results: list[NearbyTransitArrival] = []

    try:
        stops = await get_nearby_stops(lat, lon)
    except Exception:
        return results

    # Fetch arrivals for up to 3 nearest stops
    tasks = [get_realtime_arrivals(stop.id) for stop in stops[:3]]
    stop_results = await asyncio.gather(*tasks, return_exceptions=True)

    for i, arrivals in enumerate(stop_results):
        if isinstance(arrivals, Exception) or not isinstance(arrivals, list):
            continue
        stop_name = stops[i].name if i < len(stops) else "Bus Stop"
        for arrival in arrivals:
            minutes = _bus_minutes_away(arrival.expected_arrival)
            results.append(
                NearbyTransitArrival(
                    route_id=arrival.route_id,
                    stop_name=stop_name,
                    direction=arrival.status_text,
                    minutes_away=minutes,
                    status=arrival.status_text,
                    mode="bus",
                )
            )

    return results


def _bus_minutes_away(expected: datetime | None) -> int:
    """Calculate minutes until a bus arrival."""
    if expected is None:
        return 99
    from datetime import timezone

    now = datetime.now(timezone.utc)
    if expected.tzinfo is None:
        expected = expected.replace(tzinfo=timezone.utc)
    diff = (expected - now).total_seconds()
    return max(0, int(diff // 60))
