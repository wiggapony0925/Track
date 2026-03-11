#
# status.py
# TrackBackend
#
# Router for service alerts and elevator/escalator accessibility status.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException, Query

from app.models import ElevatorStatus, TransitAlert
from app.services.gtfs.data_cleaner import get_alerts, get_broken_elevators
from app.utils.logger import TrackLogger

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
        TrackLogger.error(f"[ALERTS] Failed to fetch alerts (mode={mode}): {exc}", tag="ALERTS", exc_info=True)
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/accessibility", response_model=list[ElevatorStatus])
async def accessibility() -> list[ElevatorStatus]:
    """Return currently broken elevators and escalators."""
    try:
        return await get_broken_elevators()
    except Exception as exc:
        TrackLogger.error(f"[ALERTS] Failed to fetch elevator status: {exc}", tag="ALERTS", exc_info=True)
        raise HTTPException(status_code=502, detail=str(exc)) from exc
