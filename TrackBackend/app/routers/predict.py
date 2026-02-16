#
# predict.py
# TrackBackend
#
# Router for delay prediction.
# Replaces client-side heuristic (DelayCalculator.swift) with a
# server-side model that can be upgraded to ML without an app update.
#

from __future__ import annotations

from fastapi import APIRouter, Query
from pydantic import BaseModel

from app.utils.logger import TrackLogger

router = APIRouter(tags=["predict"])


class DelayPrediction(BaseModel):
    """Predicted arrival adjustment."""

    adjusted_minutes: int
    original_minutes: int
    delay_factor: float
    adjustment_reason: str | None = None


# Compass code → human-readable direction label (also used by nearby.py)
_RUSH_MORNING = range(7, 10)  # 7-9 AM
_RUSH_EVENING = range(17, 20)  # 5-7 PM


@router.get("/predict/delay", response_model=DelayPrediction)
async def predict_delay(
    minutes_away: int = Query(..., description="MTA-predicted minutes until arrival"),
    route_id: str = Query(..., description="Transit route ID"),
    hour: int = Query(..., ge=0, le=23, description="Current hour (0-23)"),
    day_of_week: int = Query(..., ge=1, le=7, description="Day of week (1=Sun, 7=Sat)"),
    weather: str = Query("clear", description="Weather: clear, rain, snow"),
) -> DelayPrediction:
    """Return a delay-adjusted arrival time.

    Currently uses the same heuristic that was in DelayCalculator.swift.
    Can be upgraded to a trained model without requiring an app update.
    """
    factor = 1.0
    reasons: list[str] = []

    # Rush hour adjustment (weekdays 7-9 AM, 5-7 PM)
    is_weekday = 2 <= day_of_week <= 6
    if is_weekday and (hour in _RUSH_MORNING or hour in _RUSH_EVENING):
        factor += 0.1
        reasons.append("rush hour")

    # Weather adjustment
    weather_lower = weather.lower()
    if weather_lower == "rain":
        factor += 0.1
        reasons.append("rain")
    elif weather_lower == "snow":
        factor += 0.2
        reasons.append("snow")

    import math
    adjusted = math.ceil(minutes_away * factor)
    reason = f"Adjusted for {', '.join(reasons)}" if reasons else None

    TrackLogger.info(
        f"Delay prediction: {route_id} {minutes_away}min → {adjusted}min "
        f"(factor={factor:.2f}, weather={weather}, hour={hour})"
    )

    return DelayPrediction(
        adjusted_minutes=adjusted,
        original_minutes=minutes_away,
        delay_factor=factor,
        adjustment_reason=reason,
    )
