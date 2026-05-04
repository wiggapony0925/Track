"""Tests for crowdsourced GO-mode vehicle tracking beacons."""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest

from app.clients import bus_client
from app.clients import redis_client
from app.models import BusVehicle, TransitVehicle
from app.routers import tracking
from app.services.live_vehicle_detail import (
    STALE_POSITION_SECONDS,
    build_bus_live_vehicle_details,
    build_train_live_vehicle_details,
)


class FakeRedis:
    def __init__(self) -> None:
        self.store: dict[str, str] = {}
        self.expiry_seconds: dict[str, int] = {}

    async def set(self, key: str, value: str, ex: int | None = None) -> None:
        self.store[key] = value
        if ex is not None:
            self.expiry_seconds[key] = ex

    async def keys(self, pattern: str) -> list[str]:
        prefix = pattern.removesuffix("*")
        return [key for key in self.store if key.startswith(prefix)]

    async def mget(self, keys: list[Any]) -> list[str | None]:
        return [self.store.get(key.decode() if isinstance(key, bytes) else key) for key in keys]


@pytest.mark.asyncio
async def test_tracking_beacon_round_trip_uses_redis_ttl(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_redis = FakeRedis()
    monkeypatch.setattr(redis_client, "get_client", lambda: fake_redis)

    beacon = tracking.VehicleBeacon(
        route_id="B63",
        vehicle_id="vehicle-1",
        trip_id="trip-1",
        lat=40.677,
        lon=-73.982,
        bearing=182,
        speed=7.2,
        accuracy=8.5,
        timestamp=1_777_777_777,
    )

    result = await tracking.ingest_beacon(beacon)
    stored = await tracking.get_beacons("B63")

    assert result == {"status": "ok"}
    assert fake_redis.expiry_seconds["track:beacons:B63:vehicle-1"] == 60
    assert stored == [beacon]


@pytest.mark.asyncio
async def test_bus_vehicle_lookup_finds_app_short_route_beacon(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_redis = FakeRedis()
    fake_redis.store["track:beacons:B63:trip-ghost"] = json.dumps(
        {
            "route_id": "B63",
            "vehicle_id": None,
            "trip_id": "trip-ghost",
            "lat": 40.677,
            "lon": -73.982,
            "bearing": 181.0,
            "speed": 6.1,
            "accuracy": 12.0,
            "timestamp": 1_777_777_777,
        }
    )
    monkeypatch.setattr(bus_client._redis, "get_client", lambda: fake_redis)

    beacons = await bus_client._fetch_beacons("MTA NYCT_B63")
    vehicles = bus_client._blend_vehicles_with_beacons([], beacons)

    assert len(vehicles) == 1
    ghost = vehicles[0]
    assert ghost.vehicle_id == "trip-ghost"
    assert ghost.route_id == "B63"
    assert ghost.is_crowdsourced is True


@pytest.mark.asyncio
async def test_cached_official_vehicles_still_receive_beacon_overlay(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_redis = FakeRedis()
    fake_redis.store["track:beacons:B63:trip-ghost"] = json.dumps(
        {
            "route_id": "B63",
            "vehicle_id": None,
            "trip_id": "trip-ghost",
            "lat": 40.677,
            "lon": -73.982,
            "timestamp": 1_777_777_777,
        }
    )
    monkeypatch.setattr(bus_client._redis, "get_client", lambda: fake_redis)

    official = [
        BusVehicle(
            vehicle_id="official-1",
            route_id="MTA NYCT_B63",
            lat=40.68,
            lon=-73.98,
        )
    ]

    blended = await bus_client._blend_cached_vehicles_with_beacons(
        official,
        "MTA NYCT_B63",
    )

    assert [vehicle.vehicle_id for vehicle in blended] == ["official-1", "trip-ghost"]
    assert blended[1].is_crowdsourced is True


def test_crowdsourced_bus_live_detail_preserves_trip_and_age() -> None:
    vehicle = BusVehicle(
        vehicle_id="trip-ghost",
        route_id="B63",
        trip_id="trip-ghost",
        lat=40.677,
        lon=-73.982,
        position_recorded_at=datetime.now(UTC),
        is_crowdsourced=True,
    )

    detail = build_bus_live_vehicle_details([vehicle])[0]

    assert detail.trip_id == "trip-ghost"
    assert detail.position_source == "crowdsourced"
    assert detail.position_age_seconds is not None
    assert detail.position_confidence == 0.72
    assert detail.vehicle["is_crowdsourced"] is True


def test_bus_live_detail_confidence_distinguishes_quality_bands() -> None:
    now = datetime.now(UTC)
    vehicles = [
        BusVehicle(
            vehicle_id="official-fresh",
            route_id="B63",
            lat=40.677,
            lon=-73.982,
            position_recorded_at=now - timedelta(seconds=12),
        ),
        BusVehicle(
            vehicle_id="interpolated",
            route_id="B63",
            lat=40.678,
            lon=-73.981,
            is_realtime=False,
            position_recorded_at=now - timedelta(seconds=30),
        ),
        BusVehicle(
            vehicle_id="stale",
            route_id="B63",
            lat=40.679,
            lon=-73.980,
            position_recorded_at=now - timedelta(seconds=STALE_POSITION_SECONDS + 5),
        ),
    ]

    details = {
        detail.vehicle_id: detail
        for detail in build_bus_live_vehicle_details(vehicles, now=now)
    }

    assert details["official-fresh"].position_source == "gps"
    assert details["official-fresh"].position_confidence == 1.0
    assert details["interpolated"].position_source == "interpolated"
    assert details["interpolated"].position_confidence == 0.55
    assert details["stale"].is_stale is True
    assert details["stale"].position_confidence == 0.15


def test_train_stop_anchor_confidence_stays_visible_but_estimated() -> None:
    now = datetime.now(UTC)
    train = TransitVehicle(
        vehicle_id="trip-A",
        route_id="A",
        trip_id="trip-A",
        lat=40.7527,
        lon=-73.9772,
        current_stop_id="A27",
        timestamp=int((now - timedelta(seconds=20)).timestamp()),
    )

    detail = build_train_live_vehicle_details([train], now=now)[0]

    assert detail.position_source == "stop_anchor"
    assert detail.position_confidence == 0.68
    assert detail.position_confidence >= 0.5
