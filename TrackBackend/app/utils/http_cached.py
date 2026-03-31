#
# http_cached.py
# app/utils/http_cached.py
#
# Lightweight TTL-cached HTTP helper for simple GET endpoints.
#
# Inspired by Transit App's pyamplitude ``cached_request()`` pattern:
# a single function that wraps httpx calls with transparent in-memory
# TTL caching.  This avoids hitting the same upstream URL multiple times
# within a short window — useful for weather APIs, Supabase metadata,
# and other low-churn endpoints.
#
# For high-throughput MTA GTFS-RT feeds, use mta_client.py's full
# caching stack (L1 in-memory + L2 Redis + stale-while-revalidate).
# This module is for everything else.
#

from __future__ import annotations

import asyncio
import hashlib
import time
from dataclasses import dataclass, field
from typing import Any

import httpx

from app.utils.logger import TrackLogger


# ── TTL Cache ────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class _CacheEntry:
    value: Any
    expires_at: float


class TTLCache:
    """Simple thread-safe TTL cache for async HTTP responses.

    Uses a dict + expiry timestamp — no external dependencies.
    Inspired by pyamplitude's ``@cached(TTLCache(1, 60))`` pattern but
    adapted for async and multiple keys.
    """

    def __init__(self, ttl_seconds: float = 30.0, max_size: int = 256):
        self._ttl = ttl_seconds
        self._max_size = max_size
        self._store: dict[str, _CacheEntry] = {}
        self._lock = asyncio.Lock()

    async def get(self, key: str) -> tuple[bool, Any]:
        """Return (hit, value). If expired or missing, returns (False, None)."""
        entry = self._store.get(key)
        if entry is not None and time.monotonic() < entry.expires_at:
            return True, entry.value
        return False, None

    async def set(self, key: str, value: Any) -> None:
        async with self._lock:
            if len(self._store) >= self._max_size:
                self._evict_expired()
            self._store[key] = _CacheEntry(
                value=value,
                expires_at=time.monotonic() + self._ttl,
            )

    def clear(self) -> int:
        """Clear all entries. Returns count of entries removed."""
        count = len(self._store)
        self._store.clear()
        return count

    def _evict_expired(self) -> None:
        now = time.monotonic()
        expired = [k for k, v in self._store.items() if now >= v.expires_at]
        for k in expired:
            del self._store[k]

    @property
    def stats(self) -> dict[str, int]:
        now = time.monotonic()
        alive = sum(1 for v in self._store.values() if now < v.expires_at)
        return {"total": len(self._store), "alive": alive}


# ── Module-level cache + client ──────────────────────────────────────────

_cache = TTLCache(ttl_seconds=30.0, max_size=256)
_client: httpx.AsyncClient | None = None


def _get_client() -> httpx.AsyncClient:
    global _client
    if _client is None or _client.is_closed:
        _client = httpx.AsyncClient(
            timeout=10.0,
            limits=httpx.Limits(max_connections=20, max_keepalive_connections=10),
        )
    return _client


def _cache_key(url: str, params: dict[str, str] | None) -> str:
    """Deterministic cache key from URL + sorted params."""
    raw = url
    if params:
        raw += "?" + "&".join(f"{k}={v}" for k, v in sorted(params.items()))
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


# ── Public API ───────────────────────────────────────────────────────────

async def cached_get_json(
    url: str,
    *,
    params: dict[str, str] | None = None,
    headers: dict[str, str] | None = None,
    ttl: float | None = None,
) -> Any:
    """Fetch JSON from *url* with transparent TTL caching.

    Args:
        url: The URL to GET.
        params: Optional query parameters.
        headers: Optional headers (e.g., API keys).
        ttl: Override the default 30s TTL for this request.

    Returns:
        Parsed JSON (dict/list).

    Raises:
        httpx.HTTPStatusError: On 4xx/5xx responses.
    """
    key = _cache_key(url, params)

    hit, value = await _cache.get(key)
    if hit:
        return value

    client = _get_client()
    resp = await client.get(url, params=params, headers=headers)
    resp.raise_for_status()
    data = resp.json()

    # Use custom TTL if provided
    if ttl is not None:
        old_ttl = _cache._ttl
        _cache._ttl = ttl
        await _cache.set(key, data)
        _cache._ttl = old_ttl
    else:
        await _cache.set(key, data)

    return data


async def cached_get_bytes(
    url: str,
    *,
    params: dict[str, str] | None = None,
    headers: dict[str, str] | None = None,
    ttl: float | None = None,
) -> bytes:
    """Same as cached_get_json but returns raw bytes (e.g., protobuf)."""
    key = _cache_key(url, params) + ":bytes"

    hit, value = await _cache.get(key)
    if hit:
        return value

    client = _get_client()
    resp = await client.get(url, params=params, headers=headers)
    resp.raise_for_status()
    data = resp.content

    if ttl is not None:
        old_ttl = _cache._ttl
        _cache._ttl = ttl
        await _cache.set(key, data)
        _cache._ttl = old_ttl
    else:
        await _cache.set(key, data)

    return data


def get_cache_stats() -> dict[str, Any]:
    """Return cache stats for /debug endpoint."""
    return _cache.stats


def clear_cache() -> int:
    """Clear all cached responses. Returns count cleared."""
    return _cache.clear()
