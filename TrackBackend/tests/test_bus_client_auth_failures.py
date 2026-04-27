from __future__ import annotations

from types import SimpleNamespace

import httpx
import pytest

from app.clients import bus_client


def _http_status_error(status_code: int = 403) -> httpx.HTTPStatusError:
    request = httpx.Request("GET", "https://bustime.mta.info/api/siri/test.json")
    response = httpx.Response(status_code, request=request, content=b"forbidden")
    return httpx.HTTPStatusError("forbidden", request=request, response=response)


def test_siri_auth_background_failure_does_not_warn(monkeypatch):
    warnings: list[tuple[str, str]] = []
    debug_messages: list[tuple[str, str]] = []

    monkeypatch.setattr(
        bus_client.TrackLogger,
        "warning",
        lambda msg, *, tag="TRACK", exc_info=False: warnings.append((tag, msg)),
    )
    monkeypatch.setattr(
        bus_client.TrackLogger,
        "debug",
        lambda msg, *, tag="TRACK": debug_messages.append((tag, msg)),
    )

    bus_client._log_siri_background_refresh_failure(
        "BUS_ARRIVALS",
        "MTA_501160",
        _http_status_error(403),
    )

    assert warnings == []
    assert debug_messages == [
        (
            "BUS",
            "[BUS_ARRIVALS] Background refresh skipped for MTA_501160: "
            "SIRI auth unavailable",
        )
    ]


def test_non_auth_background_failure_still_warns(monkeypatch):
    warnings: list[tuple[str, str]] = []
    debug_messages: list[tuple[str, str]] = []

    monkeypatch.setattr(
        bus_client.TrackLogger,
        "warning",
        lambda msg, *, tag="TRACK", exc_info=False: warnings.append((tag, msg)),
    )
    monkeypatch.setattr(
        bus_client.TrackLogger,
        "debug",
        lambda msg, *, tag="TRACK": debug_messages.append((tag, msg)),
    )

    bus_client._log_siri_background_refresh_failure(
        "BUS_ARRIVALS",
        "MTA_501160",
        TimeoutError("upstream timed out"),
    )

    assert debug_messages == []
    assert warnings == [
        (
            "BUS",
            "[BUS_ARRIVALS] Background refresh failed for MTA_501160: "
            "upstream timed out",
        )
    ]


@pytest.mark.asyncio
async def test_vehicle_positions_does_not_retry_siri_auth_errors(monkeypatch):
    calls = 0

    async def fake_get_vehicles_impl(canonical_id: str):
        nonlocal calls
        calls += 1
        raise _http_status_error(403)

    monkeypatch.setattr(
        bus_client,
        "get_settings",
        lambda: SimpleNamespace(
            app_settings=SimpleNamespace(
                http_max_retries=3,
                http_retry_delay_seconds=0.0,
            )
        ),
    )
    monkeypatch.setattr(bus_client, "_get_vehicles_impl", fake_get_vehicles_impl)

    with pytest.raises(httpx.HTTPStatusError):
        await bus_client._fetch_vehicle_positions_uncached("MTA NYCT_M11")

    assert calls == 1
