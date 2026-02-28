#
# predict.py
# TrackBackend
#
# Router for delay prediction.
#
# Replaces the old client-side heuristic (DelayCalculator.swift) with a
# server-side GradientBoosting model that can be retrained without any
# app update.
#
# ── How it works ──────────────────────────────────────────────────────────
#
#  1. iOS calls  GET /predict/delay  with:
#       minutes_away, route_id, hour, day_of_week, weather[, mode]
#
#  2. We compute delay_factor for the context (route + hour + dow +
#     weather + mode) using DelayModel.predict_factor().
#
#  3. adjusted_minutes = ceil(minutes_away × factor)
#
# ── Caching ───────────────────────────────────────────────────────────────
#
#  factor is keyed ONLY on (route_id, hour, dow, weather, mode) —
#  NOT on minutes_away.  This is intentional:
#
#  • The factor answers "how much slower is the 7-train on a rainy
#    Wednesday at 8 PM?" — independent of whether this specific train
#    is 3 min or 15 min away.
#
#  • 1,000 users watching the same route in the same conditions all
#    share one cached factor.  One compute → thousands served instantly.
#
#  • TTL = 1 hour.  Rush-hour transitions & weather buckets are stable
#    within a single hour window.
#
#  Cache layers:
#    L1  In-process LRU dict  (zero-latency, same Render instance)
#    L2  Redis               (shared across all Render instances + deploys)
#

from __future__ import annotations

import math
import os
import time
from collections import OrderedDict

from fastapi import APIRouter, Query, Request
from pydantic import BaseModel

from app.cache_config import PREDICT_FACTOR_MAX_SIZE, PREDICT_FACTOR_TTL
from app.ml.delay_model import predict_factor
from app.ml.recency_model import get_weighted_error
from app.utils import redis_client as _redis
from app.utils.logger import TrackLogger

router = APIRouter(tags=["predict"])

# ── Feature flag ──────────────────────────────────────────────────────────
# Set  ARRIVING_PREDICTION_MODEL=false  in your Render env vars to instantly
# bypass the ML model and recency correction without a deploy.
# Any value other than "false" / "0" / "off" leaves the feature ENABLED.
def _ml_enabled() -> bool:
    """Read the feature flag fresh each call so Render env changes take effect
    without a restart (Render re-injects env vars on the fly for some tiers)."""
    val = os.environ.get("ARRIVING_PREDICTION_MODEL", "true").strip().lower()
    return val not in ("false", "0", "off", "no", "disabled")

# ── In-process L1 LRU cache ───────────────────────────────────────────────
_L1: "OrderedDict[str, tuple[float, float]]" = OrderedDict()  # key → (factor, stored_at)


def _l1_get(key: str) -> float | None:
    entry = _L1.get(key)
    if entry is None:
        return None
    factor, stored_at = entry
    if time.time() - stored_at > PREDICT_FACTOR_TTL:
        _L1.pop(key, None)
        return None
    _L1.move_to_end(key)
    return factor


def _l1_set(key: str, factor: float) -> None:
    if len(_L1) >= PREDICT_FACTOR_MAX_SIZE:
        _L1.popitem(last=False)  # evict oldest
    _L1[key] = (factor, time.time())


# ── Redis helpers ─────────────────────────────────────────────────────────
_REDIS_PREFIX = "track:predict:factor"


async def _redis_get(key: str) -> float | None:
    client = _redis.get_client()
    if client is None:
        return None
    try:
        raw = await client.get(f"{_REDIS_PREFIX}:{key}")
        return float(raw) if raw is not None else None
    except Exception as exc:
        TrackLogger.warning(f"[PREDICT CACHE] Redis GET error: {exc}", tag="ML")
        return None


async def _redis_set(key: str, factor: float) -> None:
    client = _redis.get_client()
    if client is None:
        return
    try:
        await client.set(
            f"{_REDIS_PREFIX}:{key}",
            str(factor),
            ex=max(1, int(PREDICT_FACTOR_TTL)),
        )
    except Exception as exc:
        TrackLogger.warning(f"[PREDICT CACHE] Redis SET error: {exc}", tag="ML")


# ── Response schema ───────────────────────────────────────────────────────
class DelayPrediction(BaseModel):
    """Predicted arrival adjustment returned to the iOS app."""

    adjusted_minutes: int
    original_minutes: int
    delay_factor: float
    adjustment_reason: str | None = None
    model_source: str = "heuristic"   # "model"|"model_live"|"heuristic"|"heuristic_live"|"l1_hit"|"l2_hit"|"disabled"
    recency_error_seconds: float = 0.0  # signed correction from recency model (+ = late)


# ── Endpoint ──────────────────────────────────────────────────────────────
@router.get("/predict/delay", response_model=DelayPrediction)
async def predict_delay(
    minutes_away: int = Query(..., description="MTA-predicted minutes until arrival"),
    route_id: str = Query(..., description="Transit route ID (e.g. '7', 'L', 'B63')"),
    hour: int = Query(..., ge=0, le=23, description="Current hour (0-23)"),
    day_of_week: int = Query(..., ge=1, le=7, description="Day of week (1=Sun, 7=Sat)"),
    weather: str = Query("clear", description="Weather condition: clear | rain | snow"),
    mode: str = Query("subway", description="Transit mode: subway | bus | lirr | mnr"),
    stop_id: str | None = Query(None, description="GTFS stop_id (enables recency correction)"),
    schedule_deviation_s: int | None = Query(
        None,
        description=(
            "Live SIRI schedule deviation in seconds "
            "(ExpectedArrivalTime minus AimedArrivalTime). "
            "Positive = running late. When provided, bypasses the contextual "
            "cache and feeds the deviation into the GBR model as a momentum "
            "signal so systematically-late vehicles get a higher factor."
        ),
    ),
) -> DelayPrediction:
    """Return a delay-adjusted arrival time blending three signals:

    1. **Recency model** (Transit-style): if ``stop_id`` is provided, looks up
       recent actual-vs-predicted error observations at this exact stop and
       applies an exponentially-weighted correction.  Recent trips weigh far
       more than old ones (half-life ≈1.4 hours).  Observations now arrive
       at every SIRI poll (~30 s) via ``observe_siri_delay``.

    2. **LightGBM factor** (pattern model): accounts for route reliability,
       rush-hour, day-of-week, weather, and transit mode.  Result is cached
       per (route, hour, dow, weather, mode) when no live deviation is
       available.  When ``schedule_deviation_s`` is provided the factor is
       computed fresh with the deviation as an 8th feature (momentum signal—
       buses already running late tend to slip further).

    3. **Live SIRI deviation** (momentum): ``schedule_deviation_s`` feeds the
       LightGBM model so it can learn that currently-late vehicles arrive even
       later than the contextual factor alone predicts.

    Final ETA:
        adjusted_minutes = ceil((mta_seconds + recency_error_s) × factor / 60)

    Safe to call on every arrival row — < 1 ms when fully cached.
    """
    weather_lower = weather.lower()
    mode_lower = mode.lower()

    # ── 0. Feature flag guard ─────────────────────────────────────────────
    # When ARRIVING_PREDICTION_MODEL=false the endpoint still exists and
    # returns a valid response — the iOS client keeps working unchanged.
    # We just pass `minutes_away` through untouched so every displayed ETA
    # is straight from the MTA with no ML adjustment at all.
    if not _ml_enabled():
        TrackLogger.ml(
            f"[PREDICT] ML disabled via env flag — passthrough "
            f"route={route_id} {minutes_away}min",
        )
        return DelayPrediction(
            adjusted_minutes=minutes_away,
            original_minutes=minutes_away,
            delay_factor=1.0,
            adjustment_reason=None,
            model_source="disabled",
            recency_error_seconds=0.0,
        )

    # ── 1. LightGBM factor ─────────────────────────────────────────────────
    # Two paths:
    #   • Live  (schedule_deviation_s provided): vehicle-specific prediction.
    #     The deviation is fed as the 8th LightGBM feature (momentum signal).
    #     NOT cached — each vehicle has its own current running delay.
    #   • Contextual (no deviation): shared cache keyed on route+hour+dow+
    #     weather+mode.  One compute → every user on this route served.
    factor_cache_key = f"{route_id.upper()}:{hour}:{day_of_week}:{weather_lower}:{mode_lower}"
    live_deviation = float(schedule_deviation_s) if schedule_deviation_s else 0.0
    use_live = live_deviation != 0.0

    factor: float
    source: str

    if use_live:
        # Live per-vehicle path — bypass cache; feeds momentum into LightGBM
        factor, source = predict_factor(
            route_id=route_id,
            hour=hour,
            dow=day_of_week,
            weather=weather_lower,
            mode=mode_lower,
            current_delay_s=live_deviation,
        )
        source = f"{source}_live"
    else:
        # Cached contextual path
        factor = _l1_get(factor_cache_key)
        source = "l1_hit"

        if factor is None:
            factor = await _redis_get(factor_cache_key)
            if factor is not None:
                _l1_set(factor_cache_key, factor)
                source = "l2_hit"
            else:
                factor, source = predict_factor(
                    route_id=route_id,
                    hour=hour,
                    dow=day_of_week,
                    weather=weather_lower,
                    mode=mode_lower,
                )
                _l1_set(factor_cache_key, factor)
                await _redis_set(factor_cache_key, factor)

    # ── 2. Recency correction (per-stop, real-time) ──────────────────────
    # How much this specific stop has been running late/early recently.
    # None when stop_id is absent or there are fewer than 3 observations.
    recency_error_s: float = 0.0
    if stop_id:
        error = await get_weighted_error(
            route_id=route_id,
            stop_id=stop_id,
            dow=day_of_week,
            hour=hour,
        )
        if error is not None:
            # Cap recency correction at ±5 minutes — guards against stale
            # or outlier data corrupting the displayed ETA.
            recency_error_s = max(-300.0, min(300.0, error))

    # ── 3. Blend: apply recency first, then multiply by LightGBM factor ──
    # Recency corrects the base seconds (additive: "this stop runs +90s late")
    # LightGBM factor scales the corrected value (multiplicative: "rush hour × 1.1")
    # We never let the corrected seconds go below 0.
    base_seconds = max(0.0, minutes_away * 60.0 + recency_error_s)
    adjusted_seconds = base_seconds * factor
    adjusted = math.ceil(adjusted_seconds / 60)

    # ── 4. Reason string ─────────────────────────────────────────────────
    reason_parts: list[str] = []
    if recency_error_s > 15:
        reason_parts.append(f"running +{round(recency_error_s / 60, 1)} min late (recent trips)")
    elif recency_error_s < -15:
        reason_parts.append(f"running {round(recency_error_s / 60, 1)} min early (recent trips)")
    if factor > 1.02:
        pct = round((factor - 1.0) * 100)
        rush_label = "rush hour" if _is_rush(hour, day_of_week) else "off-peak"
        reason_parts.append(f"+{pct}% ({rush_label}, {weather_lower})")
    reason = "; ".join(reason_parts) if reason_parts else None

    TrackLogger.prediction(
        route_id=route_id,
        minutes_away=minutes_away,
        adjusted=adjusted,
        factor=factor,
        source=source,
        recency_s=recency_error_s,
        stop_id=stop_id,
        mode=mode_lower,
    )

    return DelayPrediction(
        adjusted_minutes=adjusted,
        original_minutes=minutes_away,
        delay_factor=factor,
        adjustment_reason=reason,
        model_source=source,
        recency_error_seconds=round(recency_error_s, 2),
    )


def _is_rush(hour: int, dow: int) -> bool:
    is_weekday = 2 <= dow <= 6
    return is_weekday and (hour in range(7, 10) or hour in range(17, 20))


@router.post("/predict/reload-model")
async def reload_model_endpoint(request: Request) -> dict:
    """Hot-reload the GBR model from disk without restarting the server.

    Call this after running scripts/train_model.py so new weights take
    effect immediately.  Restricted to localhost only (same as /admin/cache/clear).
    """
    client = request.client
    if client and client.host not in ("127.0.0.1", "::1", "localhost"):
        from fastapi import HTTPException
        raise HTTPException(status_code=403, detail="localhost only")

    from app.ml.delay_model import reload_model
    _L1.clear()  # flush L1 so stale factors are recomputed
    success = reload_model()
    return {
        "success": success,
        "message": "Model reloaded — L1 cache cleared." if success
                   else "No model file found. Using heuristic.",
    }
