"""Router for crowdsourced vehicle beacons.
Ingests real-time location data from users in GO mode to enhance fleet tracking."""

from __future__ import annotations

import time
from typing import Annotated

from fastapi import APIRouter, Body, Depends, HTTPException
from pydantic import BaseModel, Field

from app.clients import redis_client
from app.utils.logger import TrackLogger

router = APIRouter(prefix="/tracking", tags=["tracking"])

class VehicleBeacon(BaseModel):
    """Real-time location report from a user's device."""
    route_id: str = Field(..., description="Canonical route ID (e.g. 'MTA NYCT_B63')")
    vehicle_id: str | None = Field(None, description="Official vehicle ID if known")
    trip_id: str | None = Field(None, description="GTFS trip ID if known")
    lat: float = Field(..., ge=-90, le=90)
    lon: float = Field(..., ge=-180, le=180)
    bearing: float | None = Field(None, ge=0, le=360)
    speed: float | None = Field(None, ge=0)
    accuracy: float | None = Field(None, description="Horizontal accuracy in meters")
    timestamp: float = Field(default_factory=time.time)

@router.post("/beacon")
async def ingest_beacon(
    beacon: Annotated[VehicleBeacon, Body()],
) -> dict[str, str]:
    """Ingest a location beacon from a user in GO mode.
    
    Data is stored in Redis with a 60-second TTL. This crowdsourced data
    is blended with official SIRI data to provide 'Ghost' tracking for
    vehicles that are missing from the official feed.
    """
    client = redis_client.get_client()
    if client is None:
        # Fail silently to the user, but log it
        TrackLogger.debug("Redis unavailable, beacon discarded", tag="TRACKING")
        return {"status": "accepted_no_cache"}

    # Use a specific prefix for beacons
    # Key: track:beacons:{route_id}:{vehicle_id_or_trip_id_or_anon}
    # For anonymity, we don't store user IDs. We group by vehicle/trip.
    # If official vehicle_id is missing, we use trip_id. 
    # If both missing, we use a hashed combination of route + position 
    # (though trip_id should usually be present in GO mode).
    
    entity_id = beacon.vehicle_id or beacon.trip_id or "anon"
    key = f"track:beacons:{beacon.route_id}:{entity_id}"
    
    # Store the latest beacon for this entity.
    # We use a list to store multiple reports if needed, but for now 
    # let's just keep the latest for simplicity and speed.
    payload = beacon.model_dump_json()
    
    try:
        # TTL of 60 seconds ensures stale data disappears quickly.
        await client.set(key, payload, ex=60)
        return {"status": "ok"}
    except Exception as exc:
        TrackLogger.warning(f"Failed to store beacon in Redis: {exc}", tag="TRACKING")
        return {"status": "error"}

@router.get("/beacons/{route_id}")
async def get_beacons(route_id: str) -> list[VehicleBeacon]:
    """Retrieve all active beacons for a specific route."""
    client = redis_client.get_client()
    if client is None:
        return []

    try:
        # Scan for all beacon keys for this route
        pattern = f"track:beacons:{route_id}:*"
        keys = await client.keys(pattern)
        if not keys:
            return []
            
        raw_beacons = await client.mget(keys)
        beacons = []
        for raw in raw_beacons:
            if raw:
                beacons.append(VehicleBeacon.model_validate_json(raw))
        return beacons
    except Exception as exc:
        TrackLogger.warning(f"Failed to retrieve beacons from Redis: {exc}", tag="TRACKING")
        return []
