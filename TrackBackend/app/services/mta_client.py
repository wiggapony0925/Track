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


async def fetch_protobuf(url: str) -> bytes:
    """Fetch a GTFS-Realtime Protobuf feed and return raw bytes."""
    settings = get_settings()
    headers = {}
    if settings.api_keys.mta_api_key:
        headers["x-api-key"] = settings.api_keys.mta_api_key
    async with httpx.AsyncClient(timeout=_get_timeout()) as client:
        response = await client.get(url, headers=headers)
        response.raise_for_status()
        return response.content


async def fetch_json(url: str) -> Any:
    """Fetch a JSON feed and return the parsed object."""
    settings = get_settings()
    headers = {}
    if settings.api_keys.mta_api_key:
        headers["x-api-key"] = settings.api_keys.mta_api_key
    async with httpx.AsyncClient(timeout=_get_timeout()) as client:
        response = await client.get(url, headers=headers)
        response.raise_for_status()
        return response.json()
