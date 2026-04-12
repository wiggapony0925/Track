from __future__ import annotations

import json
import time

import pytest

from app.clients import redis_client


class _FakeRedisClient:
    def __init__(self, *, raw_get: str | None = None) -> None:
        self.raw_get = raw_get
        self.get_calls: list[str] = []
        self.set_calls: list[tuple[str, str, int | None]] = []
        self.close_calls = 0

    async def get(self, key: str) -> str | None:
        self.get_calls.append(key)
        return self.raw_get

    async def set(self, key: str, value: str, ex: int | None = None) -> None:
        self.set_calls.append((key, value, ex))

    async def close(self) -> None:
        self.close_calls += 1


def _set_client_state(
    monkeypatch: pytest.MonkeyPatch,
    *,
    client: object | None,
    loop_id: int | None,
    init_attempted: bool = True,
) -> None:
    monkeypatch.setattr(redis_client, "_redis_client", client)
    monkeypatch.setattr(redis_client, "_redis_loop_id", loop_id)
    monkeypatch.setattr(redis_client, "_redis_init_attempted", init_attempted)


def test_get_client_returns_none_when_loop_changes(monkeypatch: pytest.MonkeyPatch) -> None:
    client = object()
    _set_client_state(monkeypatch, client=client, loop_id=111)
    monkeypatch.setattr(redis_client, "_current_loop_id", lambda: 222)

    assert redis_client.get_client() is None


@pytest.mark.asyncio
async def test_feed_get_reinitializes_client_after_loop_change(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    old_client = _FakeRedisClient()
    fresh_payload = json.dumps(
        {
            "fetched_at": time.time(),
            "data": {"ok": True},
        }
    )
    new_client = _FakeRedisClient(raw_get=fresh_payload)
    _set_client_state(monkeypatch, client=old_client, loop_id=111)
    monkeypatch.setattr(redis_client, "_current_loop_id", lambda: 222)

    reconnects = 0

    async def fake_init() -> None:
        nonlocal reconnects
        reconnects += 1
        redis_client._redis_client = new_client
        redis_client._redis_loop_id = 222
        redis_client._redis_init_attempted = True

    monkeypatch.setattr(redis_client, "init_redis", fake_init)

    value, state = await redis_client.feed_get(
        "mta.feed",
        "https://example.com/feed",
        fresh_ttl=30,
        stale_ttl=120,
        is_bytes=False,
    )

    assert reconnects == 1
    assert state == "fresh"
    assert value == {"ok": True}
    assert old_client.get_calls == []
    assert new_client.get_calls == [
        redis_client._feed_key("mta.feed", "https://example.com/feed")
    ]


@pytest.mark.asyncio
async def test_feed_set_reinitializes_client_after_loop_change(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    old_client = _FakeRedisClient()
    new_client = _FakeRedisClient()
    _set_client_state(monkeypatch, client=old_client, loop_id=111)
    monkeypatch.setattr(redis_client, "_current_loop_id", lambda: 222)

    reconnects = 0

    async def fake_init() -> None:
        nonlocal reconnects
        reconnects += 1
        redis_client._redis_client = new_client
        redis_client._redis_loop_id = 222
        redis_client._redis_init_attempted = True

    monkeypatch.setattr(redis_client, "init_redis", fake_init)

    await redis_client.feed_set(
        "mta.feed",
        "https://example.com/feed",
        {"kind": "json"},
        stale_ttl=120,
        is_bytes=False,
    )

    assert reconnects == 1
    assert old_client.set_calls == []
    assert len(new_client.set_calls) == 1
    key, serialized, ttl = new_client.set_calls[0]
    assert key == redis_client._feed_key("mta.feed", "https://example.com/feed")
    assert ttl == 120
    payload = json.loads(serialized)
    assert payload["data"] == {"kind": "json"}

