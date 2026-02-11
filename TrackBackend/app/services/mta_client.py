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

_TIMEOUT = httpx.Timeout(15.0, connect=10.0)


async def fetch_protobuf(url: str) -> bytes:
    """Fetch a GTFS-Realtime Protobuf feed and return raw bytes."""
    settings = get_settings()
    headers = {"x-api-key": settings.api_keys.mta_api_key}
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(url, headers=headers)
        response.raise_for_status()
        return response.content


async def fetch_json(url: str) -> Any:
    """Fetch a JSON feed and return the parsed object."""
    settings = get_settings()
    headers = {"x-api-key": settings.api_keys.mta_api_key}
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(url, headers=headers)
        response.raise_for_status()
        return response.json()
