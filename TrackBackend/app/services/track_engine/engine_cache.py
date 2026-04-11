"""Synchronous Redis cache for C++ TrackEngine /plan and /go responses.

The engine router endpoints run synchronously (in a thread pool), so we
use the **sync** ``redis.Redis`` client rather than the async one used
by the MTA/bus feed caches.

Cache keys are constructed from origin/destination coordinates, the
query timestamp (bucketed to 60-second windows), and modes.  This
ensures that identical requests within a minute share the same cached
response from the C++ engine, dropping response time from ~50ms to
<1ms for repeat queries.

The cache is optional — if ``REDIS_URL`` is not set or the connection
fails, all helpers are silent no-ops and the service falls back to
calling the C++ engine directly every time.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time as _time
from typing import Any

from app.cache_config import (
    ENGINE_CACHE_TS_BUCKET_S,
    ENGINE_GO_FRESH_TTL,
    ENGINE_GO_STALE_TTL,
    ENGINE_PLAN_FRESH_TTL,
    ENGINE_PLAN_STALE_TTL,
    ENGINE_REDIS_PREFIX,
)

logger = logging.getLogger("track.engine_cache")

# ---------------------------------------------------------------------------
# Lazy sync Redis client (one per process)
# ---------------------------------------------------------------------------

_sync_client: Any = None
_init_attempted: bool = False


def _ensure_client() -> Any:
    """Create a sync Redis client on first use.  Returns None when unavailable."""
    global _sync_client, _init_attempted
    if _init_attempted:
        return _sync_client
    _init_attempted = True

    redis_url = os.getenv("REDIS_URL", "").strip()
    if not redis_url:
        return None

    try:
        import redis  # sync client

        _sync_client = redis.from_url(
            redis_url,
            encoding="utf-8",
            decode_responses=True,
            socket_timeout=2.0,
            socket_connect_timeout=2.0,
        )
        _sync_client.ping()
        logger.info("[ENGINE_CACHE] Sync Redis connected for engine response caching")
    except Exception as exc:
        logger.warning(
            "[ENGINE_CACHE] Sync Redis unavailable (%s) — engine cache disabled",
            exc,
        )
        _sync_client = None
    return _sync_client


# ---------------------------------------------------------------------------
# Cache key construction
# ---------------------------------------------------------------------------


def _cache_key(endpoint: str, payload: dict) -> str:
    """Build a deterministic cache key from the engine request payload.

    The key includes origin/destination coordinates (rounded to 5 decimals
    ~1m precision), the query timestamp bucketed to ``ENGINE_CACHE_TS_BUCKET_S``
    windows, and the sorted modes list.  This ensures nearby-identical
    requests share the same cache entry.
    """
    origin = payload.get("origin", {})
    destination = payload.get("destination", {})
    query_ts = payload.get("query_ts", 0)
    modes = sorted(payload.get("modes", []))
    now_ts = payload.get("now_ts")

    # Round coordinates to 5 decimal places (~1m precision)
    o_lat = round(origin.get("lat") or 0.0, 5)
    o_lon = round(origin.get("lon") or 0.0, 5)
    d_lat = round(destination.get("lat") or 0.0, 5)
    d_lon = round(destination.get("lon") or 0.0, 5)

    # Bucket query_ts to reduce cache churn
    ts_bucket = (query_ts // ENGINE_CACHE_TS_BUCKET_S) * ENGINE_CACHE_TS_BUCKET_S

    # Include now_ts bucket for /go (live status depends on current time)
    now_bucket = ""
    if now_ts is not None:
        now_bucket = f"|now={now_ts // ENGINE_CACHE_TS_BUCKET_S}"

    raw = (
        f"{o_lat},{o_lon}|{d_lat},{d_lon}|"
        f"ts={ts_bucket}|m={'_'.join(modes)}|"
        f"t={payload.get('max_transfers', 1)}{now_bucket}"
    )
    digest = hashlib.md5(raw.encode(), usedforsecurity=False).hexdigest()[:12]
    return f"{ENGINE_REDIS_PREFIX}:{endpoint}:{digest}"


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def get_cached_plan(payload: dict) -> dict | None:
    """Try to get a cached /plan response.  Returns parsed JSON or None."""
    client = _ensure_client()
    if client is None:
        return None
    key = _cache_key("plan", payload)
    try:
        raw = client.get(key)
        if not raw:
            return None
        envelope = json.loads(raw)
        age = _time.time() - float(envelope.get("fetched_at", 0.0))
        if age <= ENGINE_PLAN_FRESH_TTL:
            logger.debug("[ENGINE_CACHE] plan HIT (fresh, age=%.1fs)", age)
            return envelope["data"]
        if age <= ENGINE_PLAN_STALE_TTL:
            logger.debug("[ENGINE_CACHE] plan HIT (stale, age=%.1fs)", age)
            return envelope["data"]
        return None
    except Exception as exc:
        logger.warning("[ENGINE_CACHE] plan GET error: %s", exc)
        return None


def set_cached_plan(payload: dict, data: dict) -> None:
    """Cache a /plan response."""
    client = _ensure_client()
    if client is None:
        return
    key = _cache_key("plan", payload)
    envelope = {"fetched_at": _time.time(), "data": data}
    try:
        serialized = json.dumps(envelope)
        client.set(key, serialized, ex=max(1, int(ENGINE_PLAN_STALE_TTL)))
    except Exception as exc:
        logger.warning("[ENGINE_CACHE] plan SET error: %s", exc)


def get_cached_go(payload: dict) -> dict | None:
    """Try to get a cached /go response.  Returns parsed JSON or None."""
    client = _ensure_client()
    if client is None:
        return None
    key = _cache_key("go", payload)
    try:
        raw = client.get(key)
        if not raw:
            return None
        envelope = json.loads(raw)
        age = _time.time() - float(envelope.get("fetched_at", 0.0))
        if age <= ENGINE_GO_FRESH_TTL:
            logger.debug("[ENGINE_CACHE] go HIT (fresh, age=%.1fs)", age)
            return envelope["data"]
        if age <= ENGINE_GO_STALE_TTL:
            logger.debug("[ENGINE_CACHE] go HIT (stale, age=%.1fs)", age)
            return envelope["data"]
        return None
    except Exception as exc:
        logger.warning("[ENGINE_CACHE] go GET error: %s", exc)
        return None


def set_cached_go(payload: dict, data: dict) -> None:
    """Cache a /go response."""
    client = _ensure_client()
    if client is None:
        return
    key = _cache_key("go", payload)
    envelope = {"fetched_at": _time.time(), "data": data}
    try:
        serialized = json.dumps(envelope)
        client.set(key, serialized, ex=max(1, int(ENGINE_GO_STALE_TTL)))
    except Exception as exc:
        logger.warning("[ENGINE_CACHE] go SET error: %s", exc)
