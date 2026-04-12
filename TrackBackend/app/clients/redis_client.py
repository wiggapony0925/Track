"""TrackBackend/app/clients

Shared Redis connection used by ALL transit service clients.
Bus, subway, LIRR, and MNR all funnel through the same pool so that
the cache survives deploys and is shared across Render instances.

Public API:
init_redis()            — call once at startup (main.py)
close_redis()           — call once at shutdown (main.py)
get_client()            — returns live redis client or None
cache_get(prefix, kind, identifier, ...)  — structured GET (bus-style)
cache_set(prefix, kind, identifier, ...)  — structured SET (bus-style)
feed_get(kind, url, ...)                  — MTA feed GET (subway/LIRR/MNR)
feed_set(kind, url, data, ...)            — MTA feed SET."""

from __future__ import annotations

import asyncio
import base64
import contextlib
import json
import os
import time as _time
from typing import TYPE_CHECKING, Any
from urllib.parse import urlparse

from app.utils import cache_stats
from app.utils.logger import TrackLogger

if TYPE_CHECKING:
    from collections.abc import Callable

# redis-py is an optional dependency — fall back gracefully when absent.
try:
    import redis.asyncio as redis_asyncio  # type: ignore[import-untyped]
except ImportError:
    redis_asyncio = None  # type: ignore[assignment]

# Redis key namespace for MTA feeds (subway / LIRR / MNR).
_MTA_PREFIX = "track:mta"

_redis_client: Any = None
_redis_init_attempted: bool = False
_redis_loop_id: int | None = None  # track which event loop owns the client


def _current_loop_id() -> int | None:
    """Return the active asyncio loop id, or None outside a running loop."""
    try:
        return id(asyncio.get_running_loop())
    except RuntimeError:
        return None


async def _close_client(client: Any) -> None:
    """Best-effort close for redis-py clients across versions."""
    close = getattr(client, "aclose", None) or getattr(client, "close", None)
    if close is None:
        return
    result = close()
    if asyncio.iscoroutine(result):
        await result


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------


def get_client() -> Any:
    """Return the live Redis client for the current loop, or None.

    redis-py async clients are loop-affine. Returning a client created on a
    different event loop causes production errors like:
    ``<asyncio.locks.Lock ...> is bound to a different event loop``.
    Sync callers can't reconnect on their own, so they fail open here.
    """
    if _redis_client is None:
        return None

    current_loop_id = _current_loop_id()
    if (
        current_loop_id is None
        or _redis_loop_id is None
        or current_loop_id == _redis_loop_id
    ):
        return _redis_client
    return None


async def _get_client_for_current_loop() -> Any:
    """Return a loop-safe Redis client, reconnecting on loop changes."""
    client = get_client()
    if client is not None:
        return client

    current_loop_id = _current_loop_id()
    if (
        _redis_client is not None
        and current_loop_id is not None
        and _redis_loop_id is not None
        and current_loop_id != _redis_loop_id
    ):
        TrackLogger.info(
            "[REDIS] Event loop changed — recycling shared client for the new loop",
            tag="REDIS",
        )
        await init_redis()
        return get_client()
    return None


async def init_redis() -> None:
    """Connect to Redis once at app startup.

    Best-effort — if REDIS_URL is absent or the connection fails, all
    helpers quietly fall back to in-process caches (no crash).
    """
    global _redis_client, _redis_init_attempted, _redis_loop_id
    # If a gunicorn worker is recycled, the event loop changes but
    # module-level state persists.  Detect loop change and re-init.
    current_loop_id = _current_loop_id()
    if _redis_init_attempted and current_loop_id == _redis_loop_id:
        return
    old_client = _redis_client
    old_loop_id = _redis_loop_id
    # New loop (or first boot) — reset and reconnect
    _redis_init_attempted = True
    _redis_loop_id = current_loop_id
    _redis_client = None

    if (
        old_client is not None
        and old_loop_id is not None
        and current_loop_id is not None
        and old_loop_id != current_loop_id
    ):
        with contextlib.suppress(Exception):
            await _close_client(old_client)

    redis_url = os.getenv("REDIS_URL", "").strip()

    if redis_asyncio is None:
        TrackLogger.info(
            "[REDIS] redis-py not installed — shared cache disabled. "
            "Run: pip install redis>=5.0.0",
            tag="REDIS",
        )
        return

    if not redis_url:
        TrackLogger.redis(
            "[REDIS] REDIS_URL not set — running with in-process caches only. "
            "Set REDIS_URL on Render to enable Redis for bus · subway · LIRR · MNR."
        )
        return

    try:
        _parsed = urlparse(redis_url)
        _safe_url = (
            f"{_parsed.scheme}://{'***@' if _parsed.password else ''}"
            f"{_parsed.hostname}:{_parsed.port or 6379}"
        )
    except Exception:
        _safe_url = "(url parse error)"

    TrackLogger.redis(f"[REDIS] Connecting to {_safe_url} ...")

    try:
        # max_connections caps the pool so we never exceed the Render Redis
        # plan's server-side maxclients limit.  Render Starter allows ~250
        # connections.  With Standard plan (2 workers), each worker gets its
        # own pool — 75 × 2 = 150 total, well under the 250 server limit.
        _max_conn = int(os.getenv("REDIS_MAX_CONNECTIONS", "75"))
        client = redis_asyncio.from_url(
            redis_url,
            encoding="utf-8",
            decode_responses=True,
            max_connections=_max_conn,
        )
        t0 = _time.monotonic()
        await client.ping()
        ping_ms = (_time.monotonic() - t0) * 1000
        _redis_client = client
        TrackLogger.redis(
            f"[REDIS] Connected — ping {ping_ms:.1f}ms | {_safe_url} | "
            f"pool max_connections={_max_conn} | "
            f"shared cache ACTIVE  bus · subway · LIRR · MNR"
        )
    except Exception as exc:
        _redis_client = None
        TrackLogger.info(
            f"[REDIS] Connection FAILED to {_safe_url} — "
            f"{type(exc).__name__}: {exc} | falling back to in-process caches",
            tag="REDIS",
        )


async def close_redis() -> None:
    """Close the Redis connection at app shutdown."""
    global _redis_client, _redis_init_attempted, _redis_loop_id
    if _redis_client is None:
        return
    try:
        await _close_client(_redis_client)
    except Exception:  # Broad catch intentional: best-effort shutdown cleanup.
        TrackLogger.debug("Redis close failed", exc_info=True)
    finally:
        _redis_client = None
        _redis_init_attempted = False
        _redis_loop_id = None


# ---------------------------------------------------------------------------
# Structured helpers — used by bus_client (fresh/stale TTL semantics)
# ---------------------------------------------------------------------------


def _make_key(prefix: str, kind: str, identifier: str) -> str:
    return f"{prefix}:{kind}:{identifier}"


async def cache_get(
    key_prefix: str,
    kind: str,
    identifier: str,
    *,
    fresh_ttl: float,
    stale_ttl: float,
    parser: Callable[[Any], Any],
) -> tuple[Any | None, str | None]:
    """GET from Redis with fresh/stale TTL semantics.

    Returns (value, 'fresh') if within fresh_ttl,
            (value, 'stale') if within stale_ttl,
            (None,  None)    on miss or error.
    """
    client = await _get_client_for_current_loop()
    if client is None:
        return None, None
    key = _make_key(key_prefix, kind, identifier)
    s = cache_stats.bucket(kind)
    try:
        raw = await client.get(key)
        if not raw:
            s.miss += 1
            cache_stats.tick()
            return None, None
        payload = json.loads(raw)
        fetched_at = float(payload.get("fetched_at", 0.0))
        value = parser(payload.get("data"))
        age = _time.time() - fetched_at
        if age <= fresh_ttl:
            s.fresh += 1
            cache_stats.tick()
            return value, "fresh"
        if age <= stale_ttl:
            s.stale += 1
            cache_stats.tick()
            return value, "stale"
        s.miss += 1
        cache_stats.tick()
        return None, None
    except Exception as exc:
        s.errors += 1
        cache_stats.tick()
        TrackLogger.info(
            f"[REDIS] GET error  kind={kind}  id={identifier[:80]}: {exc}", tag="REDIS"
        )
        return None, None


async def cache_set(
    key_prefix: str,
    kind: str,
    identifier: str,
    *,
    stale_ttl: float,
    data: Any,
) -> None:
    """SET to Redis with a JSON envelope (bus-style structured cache)."""
    client = await _get_client_for_current_loop()
    if client is None:
        return
    key = _make_key(key_prefix, kind, identifier)
    payload = {"fetched_at": _time.time(), "data": data}
    s = cache_stats.bucket(kind)
    try:
        serialized = json.dumps(payload)
        await client.set(key, serialized, ex=max(1, int(stale_ttl)))
        s.sets += 1
        if not s._first_set_logged:
            s._first_set_logged = True
            size_kb = len(serialized) / 1024
            TrackLogger.redis(
                f"[REDIS] ✓ First SET  key={key}  ttl={int(stale_ttl)}s  size={size_kb:.1f}KB"
            )
        cache_stats.tick()
    except Exception as exc:
        s.errors += 1
        TrackLogger.info(
            f"[REDIS] SET error  kind={kind}  id={identifier[:80]}: {exc}", tag="REDIS"
        )


# ---------------------------------------------------------------------------
# Feed helpers — used by mta_client (subway / LIRR / MNR protobuf + JSON)
#
# Protobuf feeds are raw bytes; since the Redis client uses decode_responses=True
# we base64-encode them inside a JSON envelope (same transport as structured
# helpers above). JSON feeds are stored directly inside the envelope.
# ---------------------------------------------------------------------------


def _feed_key(kind: str, url: str) -> str:
    """Build a Redis key for an MTA feed URL."""
    return f"{_MTA_PREFIX}:{kind}:{url}"


async def feed_get(
    kind: str,
    url: str,
    *,
    fresh_ttl: float,
    stale_ttl: float,
    is_bytes: bool,
) -> tuple[bytes | Any | None, str | None]:
    """GET an MTA feed from Redis.

    Returns (value, "fresh") when age <= fresh_ttl,
            (value, "stale") when age <= stale_ttl,
            (None, None) on miss/error/expiry.
    """
    client = await _get_client_for_current_loop()
    if client is None:
        return None, None
    key = _feed_key(kind, url)
    s = cache_stats.bucket(kind)
    try:
        raw = await client.get(key)
        if not raw:
            s.miss += 1
            cache_stats.tick()
            return None, None
        payload = json.loads(raw)
        age = _time.time() - float(payload.get("fetched_at", 0.0))
        if age <= fresh_ttl:
            s.fresh += 1
            cache_stats.tick()
            data = payload["data"]
            return (base64.b64decode(data) if is_bytes else data), "fresh"
        if age <= stale_ttl:
            s.stale += 1
            cache_stats.tick()
            data = payload["data"]
            return (base64.b64decode(data) if is_bytes else data), "stale"
        s.miss += 1
        cache_stats.tick()
        return None, None
    except Exception as exc:
        s.errors += 1
        cache_stats.tick()
        TrackLogger.info(f"[REDIS] feed GET error  kind={kind}: {exc}", tag="REDIS")
        return None, None


async def feed_set(
    kind: str,
    url: str,
    data: bytes | Any,
    *,
    stale_ttl: float,
    is_bytes: bool,
) -> None:
    """SET an MTA feed to Redis.

    Stores with Redis TTL = stale_ttl seconds so stale-if-error callers can
    still recover recent data after the fresh window expires.
    """
    client = await _get_client_for_current_loop()
    if client is None:
        return
    key = _feed_key(kind, url)
    encoded = base64.b64encode(data).decode("ascii") if is_bytes else data
    payload = {"fetched_at": _time.time(), "data": encoded}
    s = cache_stats.bucket(kind)
    try:
        serialized = json.dumps(payload)
        await client.set(key, serialized, ex=max(1, int(stale_ttl)))
        s.sets += 1
        if not s._first_set_logged:
            s._first_set_logged = True
            size_kb = len(serialized) / 1024
            TrackLogger.redis(
                f"[REDIS] ✓ First SET  kind={kind}  ttl={int(stale_ttl)}s  size={size_kb:.1f}KB"
            )
        cache_stats.tick()
    except Exception as exc:
        s.errors += 1
        TrackLogger.info(f"[REDIS] feed SET error  kind={kind}: {exc}", tag="REDIS")


# ---------------------------------------------------------------------------
# Engine helpers — used by TrackEngineService for /plan and /go response cache
# ---------------------------------------------------------------------------

_ENGINE_PREFIX = "track:engine"


def _engine_key(endpoint: str, cache_key: str) -> str:
    """Build a Redis key for a cached engine response."""
    return f"{_ENGINE_PREFIX}:{endpoint}:{cache_key}"


async def engine_get(
    endpoint: str,
    cache_key: str,
    *,
    fresh_ttl: float,
    stale_ttl: float,
) -> tuple[dict | None, str | None]:
    """GET a cached C++ engine response from Redis.

    Returns ``(parsed_json, "fresh"|"stale")`` on hit, ``(None, None)`` on miss.
    """
    client = await _get_client_for_current_loop()
    if client is None:
        return None, None
    key = _engine_key(endpoint, cache_key)
    s = cache_stats.bucket(f"engine_{endpoint}")
    try:
        raw = await client.get(key)
        if not raw:
            s.miss += 1
            cache_stats.tick()
            return None, None
        payload = json.loads(raw)
        fetched_at = float(payload.get("fetched_at", 0.0))
        age = _time.time() - fetched_at
        if age <= fresh_ttl:
            s.fresh += 1
            cache_stats.tick()
            return payload["data"], "fresh"
        if age <= stale_ttl:
            s.stale += 1
            cache_stats.tick()
            return payload["data"], "stale"
        s.miss += 1
        cache_stats.tick()
        return None, None
    except Exception as exc:
        s.errors += 1
        cache_stats.tick()
        TrackLogger.info(
            f"[REDIS] engine GET error  endpoint={endpoint}: {exc}", tag="REDIS"
        )
        return None, None


async def engine_set(
    endpoint: str,
    cache_key: str,
    data: dict,
    *,
    stale_ttl: float,
) -> None:
    """SET a C++ engine response to Redis."""
    client = await _get_client_for_current_loop()
    if client is None:
        return
    key = _engine_key(endpoint, cache_key)
    payload = {"fetched_at": _time.time(), "data": data}
    s = cache_stats.bucket(f"engine_{endpoint}")
    try:
        serialized = json.dumps(payload)
        await client.set(key, serialized, ex=max(1, int(stale_ttl)))
        s.sets += 1
        if not s._first_set_logged:
            s._first_set_logged = True
            size_kb = len(serialized) / 1024
            TrackLogger.redis(
                f"[REDIS] ✓ First SET  engine:{endpoint}  "
                f"ttl={int(stale_ttl)}s  size={size_kb:.1f}KB"
            )
        cache_stats.tick()
    except Exception as exc:
        s.errors += 1
        TrackLogger.info(
            f"[REDIS] engine SET error  endpoint={endpoint}: {exc}", tag="REDIS"
        )
