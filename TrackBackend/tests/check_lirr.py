from __future__ import annotations

import asyncio
import os
import sys

import httpx
from google.transit import gtfs_realtime_pb2

# Add app to path
sys.path.append(os.getcwd())
from app.config import get_settings


async def test_lirr():
    settings = get_settings()
    url = settings.urls.lirr
    print(f"Fetching LIRR from {url}...")

    async with httpx.AsyncClient() as client:
        resp = await client.get(url)
        feed = gtfs_realtime_pb2.FeedMessage()
        feed.ParseFromString(resp.content)

        count = 0
        for entity in feed.entity:
            if entity.HasField("trip_update"):
                trip = entity.trip_update
                print(f"\nTrip: {trip.trip.trip_id} | Route: {trip.trip.route_id}")
                for stu in trip.stop_time_update[:3]:
                    print(f"  Stop: {stu.stop_id} | Arrival: {stu.arrival.time}")
                count += 1
                if count >= 3:
                    break


if __name__ == "__main__":
    asyncio.run(test_lirr())
