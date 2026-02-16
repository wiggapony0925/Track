#
# mnr.py
# TrackBackend
#
# Router for Metro-North Railroad arrivals.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.models import TrackArrival
from app.services.rail_client import fetch_rail_arrivals

router = APIRouter(tags=["mnr"])

@router.get("/mnr", response_model=list[TrackArrival])
async def mnr_arrivals() -> list[TrackArrival]:
    """Return upcoming Metro-North arrivals from the GTFS-Realtime feed."""
    try:
        arrivals = await fetch_rail_arrivals("metro_north")
        return arrivals
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Metro-North Feed Error: {str(exc)}") from exc
