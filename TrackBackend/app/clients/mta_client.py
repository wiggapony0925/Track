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

from app.cache_config import (
    MTA_CACHE_MAX_SIZE,
    MTA_FEED_STALE_TTL_SECONDS,
    MTA_FEED_TTL_SECONDS,
    MTA_UPSTREAM_CONCURRENCY,
)
from app.config import get_settings
from app.utils import cache_stats
from app.utils import redis_client as _redis
from app.utils.logger import TrackLogger

# Cache-stats kind label used for all MTA feeds (subway / LIRR / MNR).
# The URL itself is the unique key within this kind.
_FEED_KIND = "mta.feed"
_RETRYABLE_STATUS_CODES = {408, 425, 429, 500, 502, 503, 504}


def _get_timeout() -> httpx.Timeout:
    """Build an httpx Timeout from settings."""
    settings = get_settings()
    return httpx.Timeout(
        settings.app_settings.http_timeout_seconds,
        connect=settings.app_settings.http_connect_timeout_seconds,
    )


def _describe_exception(exc: BaseException) -> str:
    """Return a log-friendly exception string even when str(exc) is empty."""
    detail = str(exc).strip()
    if detail:
        return f"{type(exc).__name__}: {detail}"
    return type(exc).__name__


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

    def __init__(
        self,
        fresh_ttl: float = MTA_FEED_TTL_SECONDS,
        stale_ttl: float = MTA_FEED_STALE_TTL_SECONDS,
        max_size: int = MTA_CACHE_MAX_SIZE,
    ):
        self.fresh_ttl = fresh_ttl
        self.stale_ttl = stale_ttl
        self.max_size = max_size
        self._cache: dict[str, tuple[float, Any]] = {}

    def get_state(self, key: str) -> tuple[Any | None, str | None]:
        entry = self._cache.get(key)
        if entry is None:
            cache_stats.bucket("mta.feed").miss += 1
            cache_stats.tick()
            return None, None
        ts, value = entry
        age = time.time() - ts
        if age < self.fresh_ttl:
            TrackLogger.cache(f"HIT  {key[:80]}")
            cache_stats.bucket("mta.feed").fresh += 1
            cache_stats.tick()
            return value, "fresh"
        if age < self.stale_ttl:
            TrackLogger.cache(f"STALE  {key[:80]}")
            cache_stats.bucket("mta.feed").stale += 1
            cache_stats.tick()
            return value, "stale"
        del self._cache[key]
        TrackLogger.cache(f"EXPIRED  {key[:80]}")
        cache_stats.bucket("mta.feed").miss += 1
        cache_stats.tick()
        return None, None

    def set(self, key: str, value: Any) -> None:
        if len(self._cache) >= self.max_size:
            TrackLogger.cache(f"Evicting — cache at {len(self._cache)}/{self.max_size}")
            self._evict()
        self._cache[key] = (time.time(), value)
        s = cache_stats.bucket("mta.feed")
        s.sets += 1
        if not s._first_set_logged:
            s._first_set_logged = True
            TrackLogger.redis(
                f"[MTA CACHE] ✓ First SET  key={key[:100]}  "
                f"fresh={int(self.fresh_ttl)}s stale={int(self.stale_ttl)}s"
            )
        cache_stats.tick()

    def _evict(self) -> None:
        """Remove expired entries; if still over limit, drop oldest 25%."""
        now = time.time()
        # Remove all expired
        self._cache = {
            k: (ts, v) for k, (ts, v) in self._cache.items()
            if now - ts < self.stale_ttl
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
# Lazily created inside the running event loop to avoid the
# "Semaphore is bound to a different event loop" error on reload.
_upstream_semaphore: asyncio.Semaphore | None = None
_upstream_semaphore_loop_id: int | None = None


def _get_upstream_semaphore() -> asyncio.Semaphore:
    global _upstream_semaphore, _upstream_semaphore_loop_id
    loop_id = id(asyncio.get_running_loop())
    if _upstream_semaphore is None or _upstream_semaphore_loop_id != loop_id:
        _upstream_semaphore = asyncio.Semaphore(MTA_UPSTREAM_CONCURRENCY)
        _upstream_semaphore_loop_id = loop_id
    return _upstream_semaphore


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
        _shared_client = httpx.AsyncClient(
            timeout=_get_timeout(),
            limits=httpx.Limits(
                max_connections=MTA_UPSTREAM_CONCURRENCY,
                max_keepalive_connections=min(16, MTA_UPSTREAM_CONCURRENCY),
            ),
        )
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
    settings = get_settings()
    max_retries = settings.app_settings.http_max_retries
    retry_delay = settings.app_settings.http_retry_delay_seconds

    for attempt in range(max_retries + 1):
        try:
            async with _get_upstream_semaphore():
                response = await client.get(url, headers=_build_mta_headers())
            response.raise_for_status()
            return response.json() if parse_json else response.content
        except httpx.HTTPStatusError as exc:
            status = exc.response.status_code
            retryable = status in _RETRYABLE_STATUS_CODES
            if retryable and attempt < max_retries:
                TrackLogger.retry(
                    f"[MTA_FEED] Retry {attempt + 1}/{max_retries} for {url[:100]} "
                    f"(HTTP {status})"
                )
                await asyncio.sleep(retry_delay)
                continue
            raise
        except (httpx.TimeoutException, httpx.ConnectError) as exc:
            if attempt < max_retries:
                TrackLogger.retry(
                    f"[MTA_FEED] Retry {attempt + 1}/{max_retries} for {url[:100]} "
                    f"({_describe_exception(exc)})"
                )
                await asyncio.sleep(retry_delay)
                continue
            raise


async def _fetch_with_cache(url: str, *, parse_json: bool) -> Any:
    async def _run_fetch() -> Any:
        data = await _fetch_from_upstream(url, parse_json=parse_json)
        _HTTP_CACHE.set(url, data)
        await _redis.feed_set(
            _FEED_KIND, url, data, stale_ttl=_HTTP_CACHE.stale_ttl, is_bytes=not parse_json
        )
        return data

    def _stale_candidate(
        local_value: Any | None,
        local_state: str | None,
        redis_value: Any | None,
        redis_state: str | None,
    ) -> Any | None:
        if local_state == "stale":
            return local_value
        if redis_state == "stale":
            return redis_value
        return None

    def _start_background_refresh() -> None:
        if url in _INFLIGHT_FETCHES:
            return

        async def _refresh() -> None:
            try:
                await _run_fetch()
            except Exception as exc:
                TrackLogger.warning(
                    f"[MTA_FEED] Background refresh failed for {url[:100]} "
                    f"({_describe_exception(exc)})",
                    tag="TRACK",
                )
            finally:
                if _INFLIGHT_FETCHES.get(url) is task:
                    _INFLIGHT_FETCHES.pop(url, None)

        task = asyncio.create_task(_refresh())
        _INFLIGHT_FETCHES[url] = task

    local_value, local_state = _HTTP_CACHE.get_state(url)
    if local_state == "fresh":
        return local_value

    redis_value, redis_state = await _redis.feed_get(
        _FEED_KIND,
        url,
        fresh_ttl=_HTTP_CACHE.fresh_ttl,
        stale_ttl=_HTTP_CACHE.stale_ttl,
        is_bytes=not parse_json,
    )
    if redis_state == "fresh":
        _HTTP_CACHE.set(url, redis_value)
        return redis_value

    stale_value = _stale_candidate(local_value, local_state, redis_value, redis_state)
    if stale_value is not None:
        TrackLogger.cache(f"STALE HIT  {url[:80]} — serving while refresh runs")
        _start_background_refresh()
        return stale_value

    inflight = _INFLIGHT_FETCHES.get(url)
    if inflight is not None:
        return await inflight

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
