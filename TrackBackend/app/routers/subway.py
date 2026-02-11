#
# subway.py
# TrackBackend
#
# Router for subway line arrivals.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.config import LINE_TO_URL_KEY
from app.models import TrackArrival
from app.services.data_cleaner import get_arrivals_for_line

router = APIRouter(tags=["subway"])


@router.get("/subway/{line_id}", response_model=list[TrackArrival])
async def subway_arrivals(line_id: str) -> list[TrackArrival]:
    """Return upcoming arrivals for a subway line (e.g. ``/subway/L``)."""
    upper = line_id.upper()
    if upper not in LINE_TO_URL_KEY:
        raise HTTPException(
            status_code=404,
            detail=f"Unknown subway line: {line_id}",
        )
    try:
        return await get_arrivals_for_line(upper)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
