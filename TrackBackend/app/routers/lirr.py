#
# lirr.py
# TrackBackend
#
# Router for Long Island Rail Road arrivals.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.models import TrackArrival
from app.services.rail_client import fetch_rail_arrivals

router = APIRouter(tags=["lirr"])

@router.get("/lirr", response_model=list[TrackArrival])
async def lirr_arrivals() -> list[TrackArrival]:
    """Return upcoming LIRR arrivals from the GTFS-Realtime feed."""
    try:
        arrivals = await fetch_rail_arrivals("lirr")
        return arrivals
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"LIRR Feed Error: {str(exc)}") from exc
