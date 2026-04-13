"""Router for delay prediction.

Replaces the old client-side heuristic (DelayCalculator.swift) with a
server-side GradientBoosting model that can be retrained without any
app update.

── How it works ──────────────────────────────────────────────────────────

1. iOS calls  GET /predict/delay  with:
minutes_away, route_id, hour, day_of_week, weather[, mode]

2. We compute delay_factor for the context (route + hour + dow +
weather + mode) using DelayModel.predict_factor().

3. adjusted_minutes = ceil(minutes_away × factor)

── Caching ───────────────────────────────────────────────────────────────

factor is keyed ONLY on (route_id, hour, dow, weather, mode) —
NOT on minutes_away.  This is intentional:

• The factor answers "how much slower is the 7-train on a rainy
Wednesday at 8 PM?" — independent of whether this specific train
is 3 min or 15 min away.

• 1,000 users watching the same route in the same conditions all
share one cached factor.  One compute → thousands served instantly.

• TTL = 1 hour.  Rush-hour transitions & weather buckets are stable
within a single hour window.

Cache layers:
L1  In-process LRU dict  (zero-latency, same Render instance)
L2  Redis               (shared across all Render instances + deploys)."""

from __future__ import annotations

import asyncio
import math
import os
import time
from collections import OrderedDict

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BaseModel, ConfigDict, Field

from app.cache_config import PREDICT_FACTOR_MAX_SIZE, PREDICT_FACTOR_TTL
from app.clients import redis_client as _redis
from app.ml.delay_model import predict_factor
from app.ml.recency_model import get_weighted_error
from app.models import RESP_400, RESP_403, ReloadModelResponse
from app.utils.logger import TrackLogger
from app.utils.metrics import ML_PREDICTION_FACTOR, ML_PREDICTIONS_TOTAL

# ── Day-of-week labels (match recency_model convention: Mon=2…Sun=1) ──────
_DOW_LABELS = {2: "Monday", 3: "Tuesday", 4: "Wednesday", 5: "Thursday",
               6: "Friday", 7: "Saturday", 1: "Sunday"}

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
_L1: OrderedDict[str, tuple[float, float]] = OrderedDict()  # key → (factor, stored_at)

# ── Inflight coalescing for contextual cache misses ───────────────────────
# Prevents thundering herd: if 50 requests hit the same expired key
# simultaneously, only one computes the factor + writes to Redis.
_inflight: dict[str, asyncio.Task] = {}


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
_MAX_RECENCY_CORRECTION_S = 300.0


async def _redis_get(key: str) -> float | None:
    client = _redis.get_client()
    if client is None:
        return None
    try:
        raw = await client.get(f"{_REDIS_PREFIX}:{key}")
        return float(raw) if raw is not None else None
    except (ConnectionError, TimeoutError, OSError) as exc:
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
    except (ConnectionError, TimeoutError, OSError) as exc:
        TrackLogger.warning(f"[PREDICT CACHE] Redis SET error: {exc}", tag="ML")


# ── Response schema ───────────────────────────────────────────────────────
class DelayPrediction(BaseModel):
    """Predicted arrival adjustment returned to the iOS app."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "adjusted_minutes": 9,
                    "original_minutes": 8,
                    "delay_factor": 1.15,
                    "adjustment_reason": "Rush-hour slowdown pattern on this line",
                    "model_source": "model_live",
                    "recency_error_seconds": 32.5,
                    "is_rush_hour": True,
                    "weather_condition": "clear",
                }
            ]
        }
    )

    adjusted_minutes: int = Field(
        ..., description="Delay-adjusted minutes until arrival."
    )
    original_minutes: int = Field(..., description="Original MTA-predicted minutes.")
    delay_factor: float = Field(
        ..., description="Multiplicative delay factor applied (e.g. 1.15 = 15% slower)."
    )
    adjustment_reason: str | None = Field(
        None, description="Human-readable reason for the adjustment."
    )
    model_source: str = Field(
        "heuristic",
        description="Prediction source: 'model', 'model_live', 'heuristic', 'heuristic_live', 'l1_hit', 'l2_hit', 'coalesced', or 'disabled'.",
    )
    recency_error_seconds: float = Field(
        0.0,
        description="Signed correction from recency model in seconds (positive = late).",
    )
    is_rush_hour: bool = Field(False, description="True during rush hour periods.")
    weather_condition: str = Field(
        "clear",
        description="Weather condition used for prediction (e.g. 'clear', 'rain', 'snow').",
    )


# ── Delay-history models ─────────────────────────────────────────────────
class DelayPattern(BaseModel):
    """One delay-pattern bucket (one combination of day + hour)."""

    day_of_week: str = Field(..., description="Day name, e.g. 'Monday'.")
    hour: int = Field(..., ge=0, le=23, description="Hour of day (0-23).")
    avg_delay_seconds: float = Field(
        ..., description="Mean delay in seconds (positive = late, negative = early)."
    )
    observation_count: int = Field(
        ..., description="Number of observations used."
    )
    pattern_text: str = Field(
        ...,
        description="Human-readable summary, e.g. 'Usually 2 min late'.",
    )


class DelayHistoryResponse(BaseModel):
    """Aggregated delay-history patterns for a route + stop."""

    route_id: str
    stop_id: str
    patterns: list[DelayPattern]
    data_window_hours: int = Field(
        25,
        description="How far back observations go (limited by Redis TTL).",
    )


def _pattern_text(avg_s: float) -> str:
    """Convert average delay seconds to a human summary."""
    abs_s = abs(avg_s)
    if abs_s < 30:
        return "On time"
    mins = abs_s / 60
    if mins < 1:
        label = f"{int(abs_s)}s"
    else:
        label = f"{mins:.0f} min"
    return f"Usually {label} {'late' if avg_s > 0 else 'early'}"


# ── Endpoint ──────────────────────────────────────────────────────────────
@router.get(
    "/predict/delay",
    response_model=DelayPrediction,
    summary="Predict arrival delay",
    description=(
        "Returns a delay-adjusted arrival time by blending three signals: "
        "(1) a LightGBM model trained on historical route reliability patterns, "
        "(2) a recency model that corrects per-stop prediction errors, and "
        "(3) live SIRI schedule deviation data when available. "
        "The response includes the adjusted minutes, the multiplicative delay factor, "
        "and the model source used."
    ),
    responses={**RESP_400},
)
async def predict_delay(
    minutes_away: int = Query(
        ...,
        ge=0,
        description="MTA-predicted minutes until arrival (from GTFS-RT or SIRI feed).",
        examples=[8],
    ),
    route_id: str = Query(
        ...,
        description="Transit route ID (e.g. subway line or bus route).",
        examples=["7", "A", "B63"],
    ),
    hour: int = Query(
        ...,
        ge=0,
        le=23,
        description="Current hour of the day (0–23, 24-hour format).",
        examples=[17],
    ),
    day_of_week: int = Query(
        ...,
        ge=1,
        le=7,
        description="Day of week (1=Sunday, 2=Monday, … 7=Saturday).",
        examples=[3],
    ),
    weather: str | None = Query(
        None,
        description="Weather condition code. If omitted, auto-detected from the Open-Meteo cache.",
        examples=["clear", "rain", "snow"],
    ),
    mode: str = Query(
        "subway",
        description="Transit mode for selecting the correct prediction model.",
        examples=["subway", "bus", "lirr", "mnr"],
    ),
    stop_id: str | None = Query(
        None,
        description="GTFS stop_id — enables per-stop recency error correction for higher accuracy.",
        examples=["726S", "127N"],
    ),
    schedule_deviation_s: int | None = Query(
        None,
        description=(
            "Live SIRI schedule deviation in seconds "
            "(ExpectedArrival − AimedArrival). Positive values mean running late. "
            "When provided, feeds into the LightGBM model as a momentum signal."
        ),
        examples=[45, -15],
    ),
) -> DelayPrediction:
    """Return a delay-adjusted arrival time.

    Blends three signals:

    1. **LightGBM factor** — route reliability, rush hour, day-of-week,
       weather, and transit mode patterns.
    2. **Recency model** — exponentially-weighted correction from recent
       actual-vs-predicted errors at this specific stop.
    3. **Live SIRI deviation** — `schedule_deviation_s` as a momentum
       signal (buses already running late tend to slip further).

    **Formula:** `adjusted_minutes = ceil((mta_seconds + recency_error) × factor / 60)`

    Response includes `adjusted_minutes`, `original_minutes`, `delay_factor`,
    `model_source`, `recency_error_seconds`, and a human-readable
    `adjustment_reason`.

    Safe to call on every arrival row — < 1 ms when cached.
    """
    # Auto-detect weather from Open-Meteo if the client didn't supply it
    if weather is None:
        from app.clients.weather_client import get_current_weather

        weather = await get_current_weather()
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
    factor_cache_key = (
        f"{route_id.upper()}:{hour}:{day_of_week}:{weather_lower}:{mode_lower}"
    )
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
                # Coalesce concurrent misses for the same key — only one
                # task computes the factor and writes to Redis/L1.
                inflight = _inflight.get(factor_cache_key)
                if inflight is not None:
                    factor, source = await inflight
                    source = "coalesced"
                else:

                    async def _compute_and_store(k: str) -> tuple[float, str]:
                        try:
                            f, s = predict_factor(
                                route_id=route_id,
                                hour=hour,
                                dow=day_of_week,
                                weather=weather_lower,
                                mode=mode_lower,
                            )
                            _l1_set(k, f)
                            await _redis_set(k, f)
                            return f, s
                        finally:
                            _inflight.pop(k, None)

                    task = asyncio.create_task(_compute_and_store(factor_cache_key))
                    _inflight[factor_cache_key] = task
                    factor, source = await task

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
            recency_error_s = max(
                -_MAX_RECENCY_CORRECTION_S, min(_MAX_RECENCY_CORRECTION_S, error)
            )

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
        reason_parts.append(
            f"running +{round(recency_error_s / 60, 1)} min late (recent trips)"
        )
    elif recency_error_s < -15:
        reason_parts.append(
            f"running {round(recency_error_s / 60, 1)} min early (recent trips)"
        )
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

    # ── Prometheus metrics ──
    ML_PREDICTIONS_TOTAL.labels(source=source, mode=mode_lower).inc()
    ML_PREDICTION_FACTOR.labels(mode=mode_lower).observe(factor)

    return DelayPrediction(
        adjusted_minutes=adjusted,
        original_minutes=minutes_away,
        delay_factor=factor,
        adjustment_reason=reason,
        model_source=source,
        recency_error_seconds=round(recency_error_s, 2),
        is_rush_hour=_is_rush(hour, day_of_week),
        weather_condition=weather_lower,
    )


def _is_rush(hour: int, dow: int) -> bool:
    is_weekday = 2 <= dow <= 6
    return is_weekday and (hour in range(7, 10) or hour in range(17, 20))


# ── Historical delay patterns endpoint ────────────────────────────────────
_HISTORY_OBS_PREFIX = "track:recency:obs"


@router.get(
    "/predict/history",
    response_model=DelayHistoryResponse,
    summary="Historical delay patterns",
    description=(
        "Returns aggregated delay patterns for a route + stop across all "
        "available day/hour buckets. Data spans up to ~25 hours (limited by "
        "Redis observation TTL). Each bucket shows the average delay and "
        "a human-readable pattern like 'Usually 2 min late'."
    ),
    responses={**RESP_400},
)
async def delay_history(
    route_id: str = Query(
        ..., description="Route identifier, e.g. '7', 'A', 'SIR'."
    ),
    stop_id: str = Query(
        ..., description="GTFS stop ID, e.g. '726S'."
    ),
    dow: int | None = Query(
        None,
        ge=1,
        le=7,
        description="Day-of-week filter (Mon=2…Sat=7, Sun=1). Omit for all days.",
    ),
    hour: int | None = Query(
        None,
        ge=0,
        le=23,
        description="Hour-of-day filter (0-23). Omit for all hours.",
    ),
) -> DelayHistoryResponse:
    """Scan Redis observation buckets and aggregate into delay patterns."""
    client = _redis.get_client()
    if client is None:
        return DelayHistoryResponse(
            route_id=route_id, stop_id=stop_id, patterns=[]
        )

    # Normalise route the same way recency_model does
    route = route_id.upper()
    if "_" in route:
        route = route.split("_")[-1]

    # Build the set of (dow, hour) pairs to scan
    dows = [dow] if dow is not None else [1, 2, 3, 4, 5, 6, 7]
    hours = [hour] if hour is not None else list(range(24))

    pairs = [(d, h) for d in dows for h in hours]
    keys = [f"{_HISTORY_OBS_PREFIX}:{route}:{stop_id}:{d}:{h}" for d, h in pairs]

    # Pipeline-fetch all ZSETs in one round-trip
    patterns: list[DelayPattern] = []
    try:
        pipe = client.pipeline(transaction=False)
        for k in keys:
            pipe.zrangebyscore(k, "-inf", "+inf", withscores=False)
        results = await pipe.execute()

        for (d, h), values in zip(pairs, results):
            if not values:
                continue
            errors = [float(v) for v in values]
            avg = sum(errors) / len(errors)
            patterns.append(
                DelayPattern(
                    day_of_week=_DOW_LABELS.get(d, str(d)),
                    hour=h,
                    avg_delay_seconds=round(avg, 1),
                    observation_count=len(errors),
                    pattern_text=_pattern_text(avg),
                )
            )
    except (ConnectionError, TimeoutError, OSError) as exc:
        TrackLogger.warning(
            f"[PREDICT HISTORY] Redis error: {exc}", tag="ML"
        )

    # Sort by day-of-week then hour for deterministic output
    dow_order = {2: 0, 3: 1, 4: 2, 5: 3, 6: 4, 7: 5, 1: 6}
    patterns.sort(key=lambda p: (dow_order.get(
        next((k for k, v in _DOW_LABELS.items() if v == p.day_of_week), 0), 99
    ), p.hour))

    return DelayHistoryResponse(
        route_id=route_id,
        stop_id=stop_id,
        patterns=patterns,
    )


@router.post(
    "/predict/reload-model",
    response_model=ReloadModelResponse,
    summary="Reload ML model",
    description="Hot-reloads the LightGBM delay model from disk without restarting the server. Localhost only.",
    responses={**RESP_403},
)
async def reload_model_endpoint(request: Request) -> ReloadModelResponse:
    """Hot-reload the delay prediction model from disk.

    Call this after training a new model so updated weights take effect
    immediately. Clears the L1 factor cache so predictions use the new model.

    **Restricted to localhost** — returns `403` when called from a remote IP.
    """
    client = request.client
    if client and client.host not in ("127.0.0.1", "::1", "localhost"):
        raise HTTPException(status_code=403, detail="localhost only")

    from app.ml.delay_model import reload_model

    _L1.clear()  # flush L1 so stale factors are recomputed
    success = reload_model()
    return ReloadModelResponse(
        success=success,
        message=(
            "Model reloaded — L1 cache cleared."
            if success
            else "No model file found. Using heuristic."
        ),
    )
