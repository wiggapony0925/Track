#
# status.py
# TrackBackend
#
# Router for service alerts and elevator/escalator accessibility status.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.models import ElevatorStatus, TransitAlert
from app.services.data_cleaner import get_alerts, get_broken_elevators

router = APIRouter(tags=["status"])


@router.get("/alerts", response_model=list[TransitAlert])
async def alerts() -> list[TransitAlert]:
    """Return critical subway service alerts."""
    try:
        return await get_alerts()
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/accessibility", response_model=list[ElevatorStatus])
async def accessibility() -> list[ElevatorStatus]:
    """Return currently broken elevators and escalators."""
    try:
        return await get_broken_elevators()
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
