#
# mta_client.py
# TrackBackend
#
# Async HTTP client that fetches raw data from MTA endpoints.
# Returns bytes (Protobuf) or parsed JSON depending on the feed.
#
# Uses a shared httpx.AsyncClient for connection pooling and a
# bounded TTL cache with automatic eviction.
#

from __future__ import annotations

import asyncio
import time
from typing import Any

import httpx

from app.cache_config import MTA_CACHE_MAX_SIZE, MTA_FEED_TTL_SECONDS, MTA_UPSTREAM_CONCURRENCY
from app.config import get_settings
from app.utils import cache_stats
from app.utils import redis_client as _redis
from app.utils.logger import TrackLogger

# Cache-stats kind label used for all MTA feeds (subway / LIRR / MNR).
# The URL itself is the unique key within this kind.
_FEED_KIND = "mta.feed"


def _get_timeout() -> httpx.Timeout:
    """Build an httpx Timeout from settings."""
    settings = get_settings()
    return httpx.Timeout(
        settings.app_settings.http_timeout_seconds,
        connect=settings.app_settings.http_connect_timeout_seconds,
    )


# ---------------------------------------------------------------------------
# TTL Cache with bounded size
# ---------------------------------------------------------------------------

class AsyncTTLCache:
    """Simple bounded TTL cache.

    - get(): O(1)
    - set(): O(1) amortized, O(n) worst-case during eviction sweep.
    - Eviction: When cache exceeds *max_size*, removes all expired entries.
      If still over limit, drops the oldest 25%.
    """

    def __init__(self, ttl: float = MTA_FEED_TTL_SECONDS, max_size: int = MTA_CACHE_MAX_SIZE):
        self.ttl = ttl
        self.max_size = max_size
        self._cache: dict[str, tuple[float, Any]] = {}

    def get(self, key: str) -> Any | None:
        entry = self._cache.get(key)
        if entry is None:
            cache_stats.bucket("mta.feed").miss += 1
            cache_stats.tick()
            return None
        ts, value = entry
        if time.time() - ts < self.ttl:
            TrackLogger.cache(f"HIT  {key[:80]}")
            cache_stats.bucket("mta.feed").fresh += 1
            cache_stats.tick()
            return value
        del self._cache[key]
        TrackLogger.cache(f"EXPIRED  {key[:80]}")
        cache_stats.bucket("mta.feed").stale += 1
        cache_stats.tick()
        return None

    def set(self, key: str, value: Any) -> None:
        if len(self._cache) >= self.max_size:
            TrackLogger.cache(f"Evicting — cache at {len(self._cache)}/{self.max_size}")
            self._evict()
        self._cache[key] = (time.time(), value)
        s = cache_stats.bucket("mta.feed")
        s.sets += 1
        if not s._first_set_logged:
            s._first_set_logged = True
            TrackLogger.redis(f"[MTA CACHE] ✓ First SET  key={key[:100]}  ttl={int(self.ttl)}s")
        cache_stats.tick()

    def _evict(self) -> None:
        """Remove expired entries; if still over limit, drop oldest 25%."""
        now = time.time()
        # Remove all expired
        self._cache = {
            k: (ts, v) for k, (ts, v) in self._cache.items()
            if now - ts < self.ttl
        }
        # If still at capacity, drop oldest quarter
        if len(self._cache) >= self.max_size:
            sorted_keys = sorted(self._cache, key=lambda k: self._cache[k][0])
            drop_count = max(1, len(sorted_keys) // 4)
            for k in sorted_keys[:drop_count]:
                del self._cache[k]


# Shared cache instance
_HTTP_CACHE = AsyncTTLCache()

# Prevent duplicate upstream calls for the same URL under burst traffic.
_INFLIGHT_FETCHES: dict[str, asyncio.Task[Any]] = {}

# Keep outbound MTA concurrency bounded.
_upstream_semaphore = asyncio.Semaphore(MTA_UPSTREAM_CONCURRENCY)


# ---------------------------------------------------------------------------
# Shared HTTP client (connection pooling)
# ---------------------------------------------------------------------------

_shared_client: httpx.AsyncClient | None = None
_shared_client_loop_id: int | None = None


def _get_client() -> httpx.AsyncClient:
    """Return a module-level shared AsyncClient for connection pooling.

    Lazy-initialised so it's created inside the event loop.  Recreated
    if the event loop changes (e.g. between test runs).
    """
    import asyncio

    global _shared_client, _shared_client_loop_id
    try:
        current_loop_id = id(asyncio.get_running_loop())
    except RuntimeError:
        current_loop_id = None

    if (
        _shared_client is None
        or _shared_client.is_closed
        or _shared_client_loop_id != current_loop_id
    ):
        _shared_client = httpx.AsyncClient(timeout=_get_timeout())
        _shared_client_loop_id = current_loop_id
        TrackLogger.debug("Created new shared httpx.AsyncClient", tag="HTTP")
    return _shared_client


def _build_mta_headers() -> dict[str, str]:
    settings = get_settings()
    headers: dict[str, str] = {}
    if settings.api_keys.mta_api_key:
        headers["x-api-key"] = settings.api_keys.mta_api_key
    return headers


async def _fetch_from_upstream(url: str, *, parse_json: bool) -> Any:
    client = _get_client()
    async with _upstream_semaphore:
        response = await client.get(url, headers=_build_mta_headers())
    response.raise_for_status()
    return response.json() if parse_json else response.content


async def _fetch_with_cache(url: str, *, parse_json: bool) -> Any:
    # 1. Redis first — survives deploys and is shared across all Render instances.
    #    If a sibling instance or a recent process already fetched this feed,
    #    we get the result instantly without hitting MTA upstream.
    redis_hit = await _redis.feed_get(
        _FEED_KIND, url, ttl=_HTTP_CACHE.ttl, is_bytes=not parse_json
    )
    if redis_hit is not None:
        return redis_hit

    # 2. In-process TTL cache — zero-latency for same-instance repeat calls.
    cached = _HTTP_CACHE.get(url)
    if cached is not None:
        return cached

    # 3. Deduplicate burst requests for the same URL within this instance.
    inflight = _INFLIGHT_FETCHES.get(url)
    if inflight is not None:
        return await inflight

    async def _run_fetch() -> Any:
        data = await _fetch_from_upstream(url, parse_json=parse_json)
        # Populate both caches so every path benefits.
        _HTTP_CACHE.set(url, data)
        await _redis.feed_set(
            _FEED_KIND, url, data, ttl=_HTTP_CACHE.ttl, is_bytes=not parse_json
        )
        return data

    task = asyncio.create_task(_run_fetch())
    _INFLIGHT_FETCHES[url] = task
    try:
        return await task
    finally:
        if _INFLIGHT_FETCHES.get(url) is task:
            _INFLIGHT_FETCHES.pop(url, None)


# ---------------------------------------------------------------------------
# Public fetch helpers
# ---------------------------------------------------------------------------


def clear_mta_cache() -> int:
    """Clear the HTTP/protobuf TTL cache. Returns number of entries cleared."""
    count = len(_HTTP_CACHE._cache)
    _HTTP_CACHE._cache.clear()
    _INFLIGHT_FETCHES.clear()
    return count


async def fetch_protobuf(url: str) -> bytes:
    """Fetch a GTFS-Realtime Protobuf feed and return raw bytes."""
    TrackLogger.feed(f"Fetching protobuf: {url[:100]}")
    data = await _fetch_with_cache(url, parse_json=False)
    TrackLogger.feed(f"Protobuf OK ({len(data)} bytes): {url[:100]}")
    return data


async def fetch_json(url: str) -> Any:
    """Fetch a JSON feed and return the parsed object."""
    TrackLogger.feed(f"Fetching JSON: {url[:100]}")
    data = await _fetch_with_cache(url, parse_json=True)
    TrackLogger.feed(f"JSON OK: {url[:100]}")
    return data
