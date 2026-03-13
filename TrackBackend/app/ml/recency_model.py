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

import asyncio
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

# Semaphore: cap concurrent Redis query connections so that a large /nearby
# response (169+ stops) can't exhaust the pool (typically 20 connections) by
# firing all get_weighted_error calls simultaneously.
# 8 concurrent queries is plenty — each query takes ~1-2ms.
#
# Lazily created inside the running event loop to avoid the
# "Semaphore is bound to a different event loop" error on reload.
_QUERY_SEMAPHORE: asyncio.Semaphore | None = None
_QUERY_SEMAPHORE_LOOP_ID: int | None = None

# Semaphore: cap concurrent OBSERVE operations (write pipelines).
# On Render's Redis plans maxclients is very low (10–20).  Multiple concurrent
# /nearby requests each fire ensure_future(observe_siri_delays_batch(…)) at
# the same moment.  Limiting to 2 concurrent write pipelines keeps us well
# under the server limit while still writing observations fast enough.
_OBSERVE_SEMAPHORE: asyncio.Semaphore | None = None
_OBSERVE_SEMAPHORE_LOOP_ID: int | None = None


def _get_query_semaphore() -> asyncio.Semaphore:
    global _QUERY_SEMAPHORE, _QUERY_SEMAPHORE_LOOP_ID
    loop_id = id(asyncio.get_running_loop())
    if _QUERY_SEMAPHORE is None or _QUERY_SEMAPHORE_LOOP_ID != loop_id:
        _QUERY_SEMAPHORE = asyncio.Semaphore(8)
        _QUERY_SEMAPHORE_LOOP_ID = loop_id
    return _QUERY_SEMAPHORE


def _get_observe_semaphore() -> asyncio.Semaphore:
    global _OBSERVE_SEMAPHORE, _OBSERVE_SEMAPHORE_LOOP_ID
    loop_id = id(asyncio.get_running_loop())
    if _OBSERVE_SEMAPHORE is None or _OBSERVE_SEMAPHORE_LOOP_ID != loop_id:
        _OBSERVE_SEMAPHORE = asyncio.Semaphore(2)
        _OBSERVE_SEMAPHORE_LOOP_ID = loop_id
    return _OBSERVE_SEMAPHORE


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
        async with _get_observe_semaphore():
            pipe = client.pipeline(transaction=False)
            pipe.zadd(obs_key, {str(round(deviation_s, 2)): now})
            pipe.zremrangebyrank(obs_key, 0, -(MAX_OBS_PER_KEY + 1))
            pipe.expire(obs_key, _OBS_TTL)
            await pipe.execute()
    except Exception as exc:
        TrackLogger.warning(
            f"[RECENCY] observe_siri_delay error {route_id}/{stop_id}: {exc}", tag="ML"
        )


async def observe_siri_delays_batch(
    observations: list[tuple[str, str, float]],
) -> None:
    """Write multiple SIRI deviation observations in a single Redis pipeline.

    This is the preferred API for callers that collect multiple deviations
    at once (e.g. a full SIRI response with 100s of stops).  Using one
    pipeline instead of N concurrent futures prevents connection-pool
    exhaustion on Render Redis plans with low maxclients limits.

    Args:
        observations: list of (route_id, stop_id, deviation_s) tuples.
                      deviation_s = ExpectedArrivalTime − AimedArrivalTime (seconds).
                      Positive = running late, negative = running early.
    """
    if not observations:
        return

    client = _redis.get_client()
    if client is None:
        return

    now = _time.time()
    dt = datetime.fromtimestamp(now, tz=timezone.utc)
    dow = (dt.isoweekday() % 7) + 1   # Mon=2 … Sun=1
    hour = dt.hour

    # Filter garbage before touching Redis
    valid = [
        (r, s, d) for r, s, d in observations
        if abs(d) <= _MAX_ERROR_SECS
    ]
    if not valid:
        return

    try:
        async with _get_observe_semaphore():
            pipe = client.pipeline(transaction=False)
            for route_id, stop_id, deviation_s in valid:
                obs_key = _obs_key(route_id, stop_id, dow, hour)
                pipe.zadd(obs_key, {str(round(deviation_s, 2)): now})
                pipe.zremrangebyrank(obs_key, 0, -(MAX_OBS_PER_KEY + 1))
                pipe.expire(obs_key, _OBS_TTL)
            await pipe.execute()
    except Exception as exc:
        TrackLogger.warning(
            f"[RECENCY] batch observe error ({len(valid)} obs): {exc}", tag="ML"
        )


async def observe_trip_updates_batch(
    trips: list[tuple[str, str, dict[str, int]]],
) -> None:
    """Record GTFS-RT snapshots for many trips in two pipelines (read then write).

    Reduces N×2 connection borrows (one hgetall + one pipeline per trip) down
    to exactly 2 connection borrows for ALL trips combined.

    Args:
        trips: list of (trip_id, route_id, stop_arrivals) where
               stop_arrivals maps stop_id → arrival_ts (epoch seconds).
    """
    if not trips:
        return

    client = _redis.get_client()
    if client is None:
        return

    try:
        now = _time.time()
        dt = datetime.fromtimestamp(now, tz=timezone.utc)
        dow = (dt.isoweekday() % 7) + 1
        hour = dt.hour

        # ── Phase 1: read all previous snapshots in one pipeline ──────────
        read_pipe = client.pipeline(transaction=False)
        for trip_id, _route_id, _stop_arrivals in trips:
            read_pipe.hgetall(_snap_key(trip_id))
        prev_snapshots: list = await read_pipe.execute()

        # ── Phase 2: compute all observations + write everything at once ──
        write_pipe = client.pipeline(transaction=False)
        for (trip_id, route_id, stop_arrivals), prev_raw in zip(trips, prev_snapshots):
            snap_key = _snap_key(trip_id)

            if prev_raw:
                prev = {k: int(v) for k, v in prev_raw.items()}
                passed = set(prev.keys()) - set(stop_arrivals.keys())
                for stop_id in passed:
                    error_s = now - prev[stop_id]
                    if abs(error_s) > _MAX_ERROR_SECS:
                        continue
                    obs_key = _obs_key(route_id, stop_id, dow, hour)
                    write_pipe.zadd(obs_key, {str(round(error_s, 2)): now})
                    write_pipe.zremrangebyrank(obs_key, 0, -(MAX_OBS_PER_KEY + 1))
                    write_pipe.expire(obs_key, _OBS_TTL)

            if stop_arrivals:
                write_pipe.hset(snap_key, mapping={k: str(v) for k, v in stop_arrivals.items()})
                write_pipe.expire(snap_key, _SNAP_TTL)
            else:
                write_pipe.delete(snap_key)

        async with _get_observe_semaphore():
            await write_pipe.execute()

    except Exception as exc:
        TrackLogger.warning(f"[RECENCY] batch trip observe error ({len(trips)} trips): {exc}", tag="ML")


async def get_weighted_errors_batch(
    queries: list[tuple[str, str, int, int]],  # (route_id, stop_id, dow, hour)
) -> dict[tuple[str, str], float | None]:
    """Single-pipeline fetch for many (route_id, stop_id) pairs.

    Deduplicates identical tuples, fires ONE Redis PIPELINE containing
    all ZRANGEBYSCORE lookups (3 per unique pair: exact + ±1 hour), then
    computes the EWMA-weighted error for each.

    Returns {(route_id, stop_id): seconds_error | None}.

    Used by nearby.py to pre-fetch all recency corrections before the ML
    correction loop — reducing N×3 Redis round-trips down to 1 pipeline call
    with a single connection borrow.
    """
    client = _redis.get_client()
    if client is None or not queries:
        return {}

    now = _time.time()
    cutoff = now - (MAX_AGE_HOURS * 3600)

    # Deduplicate: same (route_id, stop_id, dow, hour) appears once per
    # arrival — e.g. "A A57S" may appear 8+ times in one nearby response.
    # Use dict to preserve first-seen order while deduplicating.
    unique: list[tuple[str, str, int, int]] = list(dict.fromkeys(queries))

    try:
        pipe = client.pipeline(transaction=False)
        for route_id, stop_id, dow, hour in unique:
            pipe.zrangebyscore(_obs_key(route_id, stop_id, dow, hour),        cutoff, "+inf", withscores=True)
            pipe.zrangebyscore(_obs_key(route_id, stop_id, dow, (hour-1)%24), cutoff, "+inf", withscores=True)
            pipe.zrangebyscore(_obs_key(route_id, stop_id, dow, (hour+1)%24), cutoff, "+inf", withscores=True)
        raw_all: list = await pipe.execute()
    except Exception as exc:
        TrackLogger.warning(
            f"[RECENCY] batch query error ({len(unique)} unique stops): {exc}", tag="ML"
        )
        return {}

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

    out: dict[tuple[str, str], float | None] = {}
    for i, (route_id, stop_id, dow, hour) in enumerate(unique):
        raw_exact: list[tuple[str, float]] = raw_all[i * 3]
        raw_adj: list[tuple[str, float]]   = list(raw_all[i * 3 + 1]) + list(raw_all[i * 3 + 2])

        if len(raw_exact) + len(raw_adj) < 3:
            out[(route_id, stop_id)] = None
            continue

        wx_e, w_e = _wsum(raw_exact, 2.0)
        wx_a, w_a = _wsum(raw_adj,   1.0)
        total_w = w_e + w_a
        if total_w <= 0:
            out[(route_id, stop_id)] = None
            continue

        out[(route_id, stop_id)] = (wx_e + wx_a) / total_w

    return out


async def get_weighted_error(
    route_id: str, stop_id: str, dow: int, hour: int
) -> float | None:
    """Return recency-weighted mean error in seconds for this stop context.

    Positive = trains running late. Negative = running early.
    Returns None when fewer than 3 observations exist.

    A semaphore limits concurrent Redis queries to 8 to prevent pool
    exhaustion when predict.py is called concurrently for many stops.
    """
    client = _redis.get_client()
    if client is None:
        return None

    async with _get_query_semaphore():
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
