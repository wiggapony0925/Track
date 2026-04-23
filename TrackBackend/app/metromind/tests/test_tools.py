"""Unit tests for MetroMind tools and dispatcher.

These tests mock out the Track services so they can run without
live data or network access.
"""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest

from app.metromind.schemas import UserContext
from app.metromind.tools import dispatch, tool_schemas


def test_tool_schemas_shape() -> None:
    """Each registered tool should conform to the OpenAI function schema."""
    schemas = tool_schemas()
    names = {entry["function"]["name"] for entry in schemas}
    assert names == {"plan_route", "get_service_alerts", "search_stations"}
    for entry in schemas:
        assert entry["type"] == "function"
        fn = entry["function"]
        assert "name" in fn
        assert "description" in fn and len(fn["description"]) > 20
        assert fn["parameters"]["type"] == "object"


@pytest.mark.asyncio
async def test_dispatch_unknown_tool_returns_error_result() -> None:
    result = await dispatch("nonexistent_tool", "{}")
    assert not result.ok
    assert "Unknown tool" in result.content


@pytest.mark.asyncio
async def test_dispatch_malformed_arguments_returns_error() -> None:
    result = await dispatch("plan_route", "{this is not json")
    assert not result.ok
    assert "Malformed arguments" in result.content


# ── plan_route ─────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_plan_route_returns_serialised_itineraries() -> None:
    fake_itin = SimpleNamespace(
        itinerary_id="itin-1",
        summary="A to B",
        total_duration_s=720,
        in_vehicle_s=600,
        walking_s=120,
        waiting_s=0,
        transfer_count=0,
        walk_meters=300,
        score=0.9,
        accessible=True,
        leave_at_ts=0,
        arrive_at_ts=720,
        fare=SimpleNamespace(total_cents=290),
        legs=[
            SimpleNamespace(
                mode="subway",
                route_id="L",
                route_name="L",
                headsign="8 Av",
                board_stop_name="Bedford Av",
                alight_stop_name="Union Sq",
                departure_ts=0,
                arrival_ts=720,
                duration_s=720,
                stop_count=6,
                walk_meters=100,
                live_status=None,
                alerts=[],
            )
        ],
    )

    fake_engine = SimpleNamespace(
        plan=AsyncMock(return_value=([fake_itin], None)),
        repository=SimpleNamespace(search_stops=AsyncMock(return_value=[])),
    )

    with patch("app.metromind.tools.plan.get_engine_service", return_value=fake_engine):
        result = await dispatch(
            "plan_route",
            json.dumps(
                {
                    "origin_label": "Bedford Av",
                    "origin_lat": 40.7171,
                    "origin_lon": -73.9568,
                    "destination_label": "Union Sq",
                    "destination_lat": 40.7359,
                    "destination_lon": -73.9911,
                }
            ),
        )

    assert result.ok
    payload = json.loads(result.content)
    assert payload["origin"] == "Bedford Av"
    assert payload["destination"] == "Union Sq"
    assert len(payload["itineraries"]) == 1
    itin = payload["itineraries"][0]
    assert itin["legs"][0]["route_id"] == "L"
    assert itin["total_duration_min"] == 12.0


@pytest.mark.asyncio
async def test_plan_route_requires_both_endpoints() -> None:
    result = await dispatch(
        "plan_route",
        json.dumps({"origin_label": "A"}),  # Missing destination.
    )
    assert not result.ok


@pytest.mark.asyncio
async def test_plan_route_rejects_missing_coordinates() -> None:
    # No lat/lon, no stop_id, and label search returns nothing — error from run().
    fake_engine = SimpleNamespace(
        plan=AsyncMock(),
        repository=SimpleNamespace(search_stops=AsyncMock(return_value=[])),
    )
    with patch(
        "app.metromind.tools.plan.get_engine_service",
        return_value=fake_engine,
    ):
        result = await dispatch(
            "plan_route",
            json.dumps(
                {"origin_label": "Nowhere", "destination_label": "Somewhere"}
            ),
        )
    assert not result.ok
    assert "coordinates" in result.content.lower() or "missing" in result.content.lower()


# ── get_service_alerts ──────────────────────────────────────────────────

def _fake_alert(**overrides):
    base = dict(
        title="[L] Suspended",
        description="No L train service between Bedford Av and 8 Av.",
        severity="severe",
        mode="subway",
        route_id="L",
        affected_routes=["L"],
        alert_type="Suspended",
        effect="NO_SERVICE",
        cause="MAINTENANCE",
        human_readable_active_period="Until Sun 5 AM",
        active_period_end=None,
        sort_order=100,
    )
    base.update(overrides)
    return SimpleNamespace(**base)


@pytest.mark.asyncio
async def test_alerts_filters_by_route_id() -> None:
    alerts = [
        _fake_alert(route_id="L", affected_routes=["L"], title="[L] Suspended"),
        _fake_alert(route_id="7", affected_routes=["7"], title="[7] Delays"),
    ]
    with patch(
        "app.metromind.tools.alerts.get_alerts",
        AsyncMock(return_value=alerts),
    ):
        result = await dispatch(
            "get_service_alerts",
            json.dumps({"route_id": "L"}),
        )

    assert result.ok
    payload = json.loads(result.content)
    assert len(payload["alerts"]) == 1
    assert payload["alerts"][0]["route_id"] == "L"


@pytest.mark.asyncio
async def test_alerts_rejects_invalid_mode() -> None:
    result = await dispatch(
        "get_service_alerts",
        json.dumps({"mode": "monorail"}),
    )
    assert not result.ok
    assert "Invalid mode" in result.content


# ── search_stations ─────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_search_stations_serialises_results() -> None:
    fake_stops = [
        SimpleNamespace(
            stop_id="635",
            stop_name="14 St-Union Sq",
            lat=40.7359,
            lon=-73.9911,
        )
    ]
    fake_engine = SimpleNamespace(
        repository=SimpleNamespace(
            search_stops=AsyncMock(return_value=fake_stops),
        ),
    )

    with patch(
        "app.metromind.tools.stations.get_engine_service",
        return_value=fake_engine,
    ):
        result = await dispatch(
            "search_stations",
            json.dumps({"query": "Union Sq"}),
        )

    assert result.ok
    payload = json.loads(result.content)
    assert payload["query"] == "Union Sq"
    assert payload["stops"][0]["stop_id"] == "635"


@pytest.mark.asyncio
async def test_search_stations_rejects_empty_query() -> None:
    result = await dispatch(
        "search_stations",
        json.dumps({"query": "   "}),
    )
    assert not result.ok


# ── UserContext plumbing ────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_plan_route_uses_device_location_for_current() -> None:
    captured: dict = {}

    async def fake_plan(req):
        captured["origin"] = req.origin
        return [], None

    fake_engine = SimpleNamespace(
        plan=fake_plan,
        repository=SimpleNamespace(search_stops=AsyncMock(return_value=[])),
    )

    with patch(
        "app.metromind.tools.plan.get_engine_service",
        return_value=fake_engine,
    ):
        await dispatch(
            "plan_route",
            json.dumps(
                {
                    "origin_label": "Current location",
                    "destination_label": "Union Sq",
                    "destination_lat": 40.7359,
                    "destination_lon": -73.9911,
                }
            ),
            context=UserContext(lat=40.7171, lon=-73.9568),
        )

    assert captured["origin"].lat == pytest.approx(40.7171)
    assert captured["origin"].lon == pytest.approx(-73.9568)
