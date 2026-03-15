from __future__ import annotations

import asyncio
import time
from types import SimpleNamespace

import httpx
import pytest

import app.clients.mta_client as mta_client
from app.routers.nearby import _describe_exception as describe_nearby_exception


class _FakeAsyncClient:
    def __init__(self, responses: list[Exception | httpx.Response]) -> None:
        self._responses = responses
        self.calls = 0

    async def get(self, url: str, headers: dict[str, str] | None = None) -> httpx.Response:
        response = self._responses[self.calls]
        self.calls += 1
        if isinstance(response, Exception):
            raise response
        return response


def _fake_settings(*, retries: int = 2, delay: float = 0.0) -> SimpleNamespace:
    return SimpleNamespace(
        app_settings=SimpleNamespace(
            http_max_retries=retries,
            http_retry_delay_seconds=delay,
            http_timeout_seconds=15.0,
            http_connect_timeout_seconds=10.0,
        ),
        api_keys=SimpleNamespace(mta_api_key=""),
    )


@pytest.mark.asyncio
async def test_fetch_from_upstream_retries_connect_timeout_then_succeeds(monkeypatch):
    request = httpx.Request("GET", "https://example.com/feed")
    client = _FakeAsyncClient([
        httpx.ConnectTimeout("upstream timed out", request=request),
        httpx.Response(200, request=request, content=b"ok"),
    ])

    monkeypatch.setattr(mta_client, "get_settings", lambda: _fake_settings(retries=2))
    monkeypatch.setattr(mta_client, "_get_client", lambda: client)
    monkeypatch.setattr(mta_client, "_get_upstream_semaphore", lambda: asyncio.Semaphore(1))

    data = await mta_client._fetch_from_upstream("https://example.com/feed", parse_json=False)

    assert data == b"ok"
    assert client.calls == 2


@pytest.mark.asyncio
async def test_fetch_from_upstream_does_not_retry_non_retryable_status(monkeypatch):
    request = httpx.Request("GET", "https://example.com/feed")
    client = _FakeAsyncClient([
        httpx.Response(403, request=request, content=b"forbidden"),
    ])

    monkeypatch.setattr(mta_client, "get_settings", lambda: _fake_settings(retries=2))
    monkeypatch.setattr(mta_client, "_get_client", lambda: client)
    monkeypatch.setattr(mta_client, "_get_upstream_semaphore", lambda: asyncio.Semaphore(1))

    with pytest.raises(httpx.HTTPStatusError):
        await mta_client._fetch_from_upstream("https://example.com/feed", parse_json=False)

    assert client.calls == 1


def test_describe_exception_keeps_type_when_message_is_blank():
    request = httpx.Request("GET", "https://example.com/feed")
    exc = httpx.ConnectTimeout("", request=request)

    assert describe_nearby_exception(exc) == "ConnectTimeout"


@pytest.mark.asyncio
async def test_fetch_with_cache_serves_stale_local_data_while_refreshing(monkeypatch):
    url = "https://example.com/feed"
    stale_value = b"stale"
    fresh_value = b"fresh"

    mta_client.clear_mta_cache()
    mta_client._HTTP_CACHE._cache[url] = (
        time.time() - (mta_client._HTTP_CACHE.fresh_ttl + 1),
        stale_value,
    )

    async def fake_feed_get(*args, **kwargs):
        return None, None

    async def fake_feed_set(*args, **kwargs):
        return None

    async def fake_fetch(url: str, *, parse_json: bool):
        return fresh_value

    monkeypatch.setattr(mta_client._redis, "feed_get", fake_feed_get)
    monkeypatch.setattr(mta_client._redis, "feed_set", fake_feed_set)
    monkeypatch.setattr(mta_client, "_fetch_from_upstream", fake_fetch)

    data = await mta_client._fetch_with_cache(url, parse_json=False)

    assert data == stale_value

    await asyncio.sleep(0)
    await asyncio.sleep(0)

    assert mta_client._HTTP_CACHE._cache[url][1] == fresh_value
    assert url not in mta_client._INFLIGHT_FETCHES


@pytest.mark.asyncio
async def test_fetch_with_cache_serves_stale_redis_data_while_refreshing(monkeypatch):
    url = "https://example.com/feed"
    stale_value = b"stale-from-redis"
    fresh_value = b"fresh"

    mta_client.clear_mta_cache()

    async def fake_feed_get(*args, **kwargs):
        return stale_value, "stale"

    async def fake_feed_set(*args, **kwargs):
        return None

    async def fake_fetch(url: str, *, parse_json: bool):
        return fresh_value

    monkeypatch.setattr(mta_client._redis, "feed_get", fake_feed_get)
    monkeypatch.setattr(mta_client._redis, "feed_set", fake_feed_set)
    monkeypatch.setattr(mta_client, "_fetch_from_upstream", fake_fetch)

    data = await mta_client._fetch_with_cache(url, parse_json=False)

    assert data == stale_value

    await asyncio.sleep(0)
    await asyncio.sleep(0)

    assert mta_client._HTTP_CACHE._cache[url][1] == fresh_value
    assert url not in mta_client._INFLIGHT_FETCHES
