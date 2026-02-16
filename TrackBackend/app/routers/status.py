#
# status.py
# TrackBackend
#
# Router for service alerts and elevator/escalator accessibility status.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException, Query

from app.models import ElevatorStatus, TransitAlert
from app.services.data_cleaner import get_alerts, get_broken_elevators

router = APIRouter(tags=["status"])


@router.get("/alerts", response_model=list[TransitAlert])
async def alerts(
    mode: str | None = Query(
        default=None,
        description="Filter by transit mode: subway, bus, lirr, mnr. Omit for all.",
    ),
) -> list[TransitAlert]:
    """Return critical MTA service alerts, optionally filtered by mode."""
    try:
        return await get_alerts(mode=mode)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/accessibility", response_model=list[ElevatorStatus])
async def accessibility() -> list[ElevatorStatus]:
    """Return currently broken elevators and escalators."""
    try:
        return await get_broken_elevators()
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
