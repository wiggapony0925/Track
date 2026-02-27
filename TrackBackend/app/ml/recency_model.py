#
# recency_model.py
# app/ml/recency_model.py
#
# Transit-style recency correction.
# Watches every GTFS-RT poll, records actual vs. MTA-predicted times per stop,
# and returns an exponentially-weighted mean error to correct minutes_away.
#
# ── How it works ──────────────────────────────────────────────────────────
#
# OBSERVE (after each data_cleaner.py GTFS-RT parse):
#   • Snapshot the current stop_time_updates for each trip in Redis.
#   • Next poll: stops that disappeared = vehicle passed them.
#     error = now − predicted_arrival_ts  (positive = late, negative = early)
#   • Store error in a sorted set keyed by (route, stop, dow, hour).
#
# QUERY (from predict.py):
#   • Fetch last 50 observations for (route, stop, dow, hour).
#   • Apply exponential decay: w = exp(−0.5 × age_hours) → half-life ≈ 1.4 h.
#     A train that passed 10 minutes ago weighs ~7× more than one from 3 hours ago.
#   • Also sample ±1 hour bucket for more signal, at half weight.
#   • Return weighted mean error in seconds (None if < 3 observations).
#
# ── Redis key structure ────────────────────────────────────────────────────
#   track:recency:snap:{trip_id}      HASH  {stop_id→arrival_ts}  TTL=2h
#   track:recency:obs:{route}:{stop}:{dow}:{hour}
#                                     ZSET  score=unix_ts  value=error_s  TTL=25h
#
# ── Graceful degradation ──────────────────────────────────────────────────
#   Every Redis call is fire-and-forget.  Redis unavailable = silent no-op.
#

from __future__ import annotations

import math
import time as _time
from datetime import datetime, timezone

from app.utils import redis_client as _redis
from app.utils.logger import TrackLogger

_SNAP_PREFIX      = "track:recency:snap"
_OBS_PREFIX       = "track:recency:obs"
_SNAP_TTL         = 7_200    # 2 hours
_OBS_TTL          = 90_000   # 25 hours
MAX_OBS_PER_KEY   = 50
MAX_AGE_HOURS     = 6.0
_LAMBDA           = 0.5      # decay constant (half-life ≈ 1.4 h)
_MAX_ERROR_SECS   = 600      # ±10 min — discard garbage (cancelled trips)


def _snap_key(trip_id: str) -> str:
    return f"{_SNAP_PREFIX}:{trip_id}"


def _obs_key(route_id: str, stop_id: str, dow: int, hour: int) -> str:
    route = route_id.upper()
    if "_" in route:
        route = route.split("_")[-1]
    return f"{_OBS_PREFIX}:{route}:{stop_id}:{dow}:{hour}"


async def observe_trip_updates(
    trip_id: str,
    route_id: str,
    stop_arrivals: dict[str, int],  # stop_id → arrival_ts (epoch s)
) -> None:
    """Record a GTFS-RT snapshot and emit error observations for passed stops."""
    client = _redis.get_client()
    if client is None:
        return

    snap_key = _snap_key(trip_id)
    now = _time.time()

    try:
        raw = await client.hgetall(snap_key)
        if raw:
            prev = {k: int(v) for k, v in raw.items()}
            passed = set(prev.keys()) - set(stop_arrivals.keys())

            for stop_id in passed:
                error_s = now - prev[stop_id]
                if abs(error_s) > _MAX_ERROR_SECS:
                    continue

                dt = datetime.fromtimestamp(now, tz=timezone.utc)
                dow = (dt.isoweekday() % 7) + 1  # Mon=2 … Sun=1 (match predict router)
                hour = dt.hour

                obs_key = _obs_key(route_id, stop_id, dow, hour)
                pipe = client.pipeline(transaction=False)
                pipe.zadd(obs_key, {str(round(error_s, 2)): now})
                pipe.zremrangebyrank(obs_key, 0, -(MAX_OBS_PER_KEY + 1))
                pipe.expire(obs_key, _OBS_TTL)
                await pipe.execute()

        if stop_arrivals:
            pipe = client.pipeline(transaction=False)
            pipe.hset(snap_key, mapping={k: str(v) for k, v in stop_arrivals.items()})
            pipe.expire(snap_key, _SNAP_TTL)
            await pipe.execute()
        else:
            await client.delete(snap_key)

    except Exception as exc:
        TrackLogger.warning(f"[RECENCY] observe error trip={trip_id}: {exc}", tag="ML")


async def observe_siri_delay(
    route_id: str,
    stop_id: str,
    deviation_s: float,
) -> None:
    """Store a direct SIRI schedule-deviation observation.

    Called on *every* SIRI poll (every ~30 s) for StopMonitoring /
    VehicleMonitoring.  Unlike ``observe_trip_updates`` — which must wait for
    stops to disappear from successive GTFS-RT snapshots — this function fires
    the moment SIRI reports AimedArrivalTime vs ExpectedArrivalTime, giving
    us real observations at 10–30× the rate of the snapshot approach.

    deviation_s = ExpectedArrivalTime − AimedArrivalTime
                  Positive → bus/train running late.
                  Negative → running ahead of schedule.
    """
    if abs(deviation_s) > _MAX_ERROR_SECS:
        return  # discard obvious garbage (cancelled / extreme re-routes)

    client = _redis.get_client()
    if client is None:
        return

    try:
        now = _time.time()
        dt = datetime.fromtimestamp(now, tz=timezone.utc)
        dow = (dt.isoweekday() % 7) + 1   # Mon=2 … Sun=1
        hour = dt.hour

        obs_key = _obs_key(route_id, stop_id, dow, hour)
        pipe = client.pipeline(transaction=False)
        pipe.zadd(obs_key, {str(round(deviation_s, 2)): now})
        pipe.zremrangebyrank(obs_key, 0, -(MAX_OBS_PER_KEY + 1))
        pipe.expire(obs_key, _OBS_TTL)
        await pipe.execute()
    except Exception as exc:
        TrackLogger.warning(
            f"[RECENCY] observe_siri_delay error {route_id}/{stop_id}: {exc}", tag="ML"
        )


async def get_weighted_error(
    route_id: str, stop_id: str, dow: int, hour: int
) -> float | None:
    """Return recency-weighted mean error in seconds for this stop context.

    Positive = trains running late. Negative = running early.
    Returns None when fewer than 3 observations exist.
    """
    client = _redis.get_client()
    if client is None:
        return None

    try:
        now = _time.time()
        cutoff = now - (MAX_AGE_HOURS * 3600)

        # Exact slot (2× weight) + adjacent hours ±1 (1× weight)
        exact_key = _obs_key(route_id, stop_id, dow, hour)
        raw_exact: list[tuple[str, float]] = await client.zrangebyscore(
            exact_key, cutoff, "+inf", withscores=True
        )

        raw_adj: list[tuple[str, float]] = []
        for h in [(hour - 1) % 24, (hour + 1) % 24]:
            entries = await client.zrangebyscore(
                _obs_key(route_id, stop_id, dow, h), cutoff, "+inf", withscores=True
            )
            raw_adj.extend(entries)

        if len(raw_exact) + len(raw_adj) < 3:
            return None

        def _wsum(entries: list[tuple[str, float]], scale: float) -> tuple[float, float]:
            sw, swx = 0.0, 0.0
            for val_str, ts in entries:
                try:
                    err = float(val_str)
                except ValueError:
                    continue
                w = math.exp(-_LAMBDA * (now - ts) / 3600.0) * scale
                swx += w * err
                sw  += w
            return swx, sw

        wx_e, w_e = _wsum(raw_exact, 2.0)
        wx_a, w_a = _wsum(raw_adj,   1.0)
        total_w = w_e + w_a
        if total_w <= 0:
            return None

        error = (wx_e + wx_a) / total_w
        TrackLogger.debug(
            f"[RECENCY] {route_id} {stop_id} dow={dow} h={hour} → {error:+.1f}s "
            f"({len(raw_exact)} exact + {len(raw_adj)} adj)",
            tag="ML",
        )
        return error

    except Exception as exc:
        TrackLogger.warning(f"[RECENCY] query error {route_id}/{stop_id}: {exc}", tag="ML")
        return None
