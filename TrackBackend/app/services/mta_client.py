#
# mta_client.py
# TrackBackend
#
# Async HTTP client that fetches raw data from MTA endpoints.
# Returns bytes (Protobuf) or parsed JSON depending on the feed.
#

from __future__ import annotations

from typing import Any

import httpx

from app.config import get_settings


def _get_timeout() -> httpx.Timeout:
    """Build an httpx Timeout from settings."""
    settings = get_settings()
    return httpx.Timeout(
        settings.app_settings.http_timeout_seconds,
        connect=settings.app_settings.http_connect_timeout_seconds,
    )


import time

class AsyncTTLCache:
    def __init__(self, ttl: float = 15.0):
        self.ttl = ttl
        self._cache: dict[str, tuple[float, Any]] = {}

    def get(self, key: str) -> Any | None:
        if key in self._cache:
            original_ts, value = self._cache[key]
            if time.time() - original_ts < self.ttl:
                return value
            else:
                del self._cache[key]
        return None

    def set(self, key: str, value: Any):
        self._cache[key] = (time.time(), value)

# Shared cache instance
_HTTP_CACHE = AsyncTTLCache(ttl=15.0)


async def fetch_protobuf(url: str) -> bytes:
    """Fetch a GTFS-Realtime Protobuf feed and return raw bytes."""
    # Check cache
    cached = _HTTP_CACHE.get(url)
    if cached is not None:
        return cached

    settings = get_settings()
    headers = {}
    if settings.api_keys.mta_api_key:
        headers["x-api-key"] = settings.api_keys.mta_api_key
    
    async with httpx.AsyncClient(timeout=_get_timeout()) as client:
        response = await client.get(url, headers=headers)
        response.raise_for_status()
        data = response.content
        _HTTP_CACHE.set(url, data)
        return data


async def fetch_json(url: str) -> Any:
    """Fetch a JSON feed and return the parsed object."""
    # Check cache
    cached = _HTTP_CACHE.get(url)
    if cached is not None:
        return cached

    settings = get_settings()
    headers = {}
    if settings.api_keys.mta_api_key:
        headers["x-api-key"] = settings.api_keys.mta_api_key
    
    async with httpx.AsyncClient(timeout=_get_timeout()) as client:
        response = await client.get(url, headers=headers)
        response.raise_for_status()
        data = response.json()
        _HTTP_CACHE.set(url, data)
        return data
