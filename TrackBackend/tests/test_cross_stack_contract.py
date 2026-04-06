"""Cross-stack contract tests that verify the backend JSON output is
decodable by the iOS Swift Codable structs.  Each test builds a
Pydantic model, serialises it to JSON, and asserts that:

1. Every field the iOS CodingKey expects is present
2. Field types match (str→String, int→Int, float→Double, null→Optional)
3. Default values are sent explicitly (not omitted)
4. snake_case naming is consistent with iOS CodingKeys

These tests catch drift between models.py and the Swift models in
Track/Models/ before it reaches users as decode failures."""

from __future__ import annotations

import json
import time
from datetime import UTC, datetime

from app.models import (
    AllCommuterRailLinesResponse,
    AllSubwayLinesResponse,
    AllSubwayStationsResponse,
    BusArrival,
    BusRoute,
    BusScheduleDeparture,
    BusScheduleDirection,
    BusScheduleResponse,
    BusStop,
    BusVehicle,
    CommuterRailLineOverlay,
    CommuterRailStop,
    DirectionArrivals,
    DirectionShape,
    ElevatorStatus,
    GroupedNearbyTransit,
    InlineAlert,
    NearbyTransitArrival,
    ProcessedStation,
    ProcessedStationsResponse,
    RouteShape,
    StopPosition,
    SubwayLineOverlay,
    SubwayStation,
    TrackArrival,
    TransitAlert,
    TrunkGroupPolylines,
)

# ===================================================================
# HELPERS
# ===================================================================


def _json(model) -> dict:
    """Serialize a Pydantic model to a Python dict using JSON-compatible mode."""
    return json.loads(model.model_dump_json())


def _assert_keys(data: dict, required_keys: list[str], context: str = ""):
    """Assert all required keys are present in the dict."""
    for key in required_keys:
        assert (
            key in data
        ), f"Missing key '{key}' in {context or 'response'}: {list(data.keys())}"


def _assert_type(data: dict, key: str, expected_type: type, nullable: bool = False):
    """Assert a field exists and has the expected type (or None if nullable)."""
    assert key in data, f"Missing key '{key}'"
    if nullable and data[key] is None:
        return
    assert isinstance(data[key], expected_type), (
        f"Field '{key}' expected {expected_type.__name__}, "
        f"got {type(data[key]).__name__}: {data[key]!r}"
    )


# ===================================================================
# 1. TrackArrival ↔ TransitArrivalResponse (iOS)
#    Endpoints: GET /subway/{line_id}, GET /lirr, GET /mnr
# ===================================================================


class TestTrackArrivalContract:
    """Backend TrackArrival → iOS TransitArrivalResponse."""

    # iOS CodingKeys from SubwayModels.swift
    IOS_KEYS = [
        "route_id",
        "station",
        "station_name",
        "direction",
        "destination",
        "minutes_away",
        "status",
        "trip_id",
        "arrival_ts",
        "is_cancelled",
        "stop_lat",
        "stop_lon",
    ]

    def _make(self, **overrides) -> dict:
        defaults = {
            "route_id": "A",
            "station": "A27N",
            "station_name": "59 St-Columbus Circle",
            "direction": "N",
            "destination": "Inwood-207 St",
            "minutes_away": 5,
            "arrival_ts": int(time.time()) + 300,
            "status": "On Time",
            "trip_id": "091400_A..N03R",
            "is_cancelled": False,
        }
        defaults.update(overrides)
        return _json(TrackArrival(**defaults))

    def test_all_ios_keys_present(self):
        data = self._make()
        _assert_keys(data, self.IOS_KEYS, "TrackArrival")

    def test_field_types(self):
        data = self._make()
        _assert_type(data, "route_id", str)
        _assert_type(data, "station", str)
        _assert_type(data, "station_name", str)
        _assert_type(data, "direction", str)
        _assert_type(data, "destination", str, nullable=True)
        _assert_type(data, "minutes_away", int)
        _assert_type(data, "status", str)
        _assert_type(data, "arrival_ts", int)
        _assert_type(data, "trip_id", str, nullable=True)
        _assert_type(data, "is_cancelled", bool)
        _assert_type(data, "stop_lat", (int, float), nullable=True)
        _assert_type(data, "stop_lon", (int, float), nullable=True)

    def test_defaults_are_explicit(self):
        """iOS expects defaults from init(from:) — backend must send them."""
        data = _json(TrackArrival(station="X01", direction="S", minutes_away=0))
        assert data["route_id"] == ""
        assert data["station_name"] == ""
        assert data["arrival_ts"] == 0
        assert data["status"] == "On Time"
        assert data["is_cancelled"] is False

    def test_null_optionals(self):
        data = self._make(destination=None, trip_id=None)
        assert data["destination"] is None
        assert data["trip_id"] is None

    def test_stop_lat_stop_lon_present(self):
        """iOS TransitArrivalResponse has stopLat/stopLon as Optional.
        Backend now sends them (nullable)."""
        data = self._make(stop_lat=40.77, stop_lon=-73.98)
        assert data["stop_lat"] == 40.77
        assert data["stop_lon"] == -73.98

    def test_stop_lat_stop_lon_nullable(self):
        data = self._make()
        assert data["stop_lat"] is None
        assert data["stop_lon"] is None


# ===================================================================
# 2. NearbyTransitArrival ↔ NearbyTransitResponse (iOS)
#    Endpoint: GET /nearby/grouped (nested in DirectionArrivals)
# ===================================================================


class TestNearbyTransitArrivalContract:
    """Backend NearbyTransitArrival → iOS NearbyTransitResponse."""

    IOS_KEYS = [
        "route_id",
        "stop_name",
        "direction",
        "destination",
        "minutes_away",
        "arrival_ts",
        "status",
        "mode",
        "stop_lat",
        "stop_lon",
        "stop_id",
        "vehicle_id",
        "trip_id",
        "distance_m",
        "is_real_time",
        "is_cancelled",
        "is_express",
    ]

    def _make(self, **overrides) -> dict:
        defaults = {
            "route_id": "A",
            "stop_name": "Fulton St",
            "direction": "N",
            "destination": "Inwood-207 St",
            "minutes_away": 3,
            "arrival_ts": int(time.time()) + 180,
            "status": "On Time",
            "mode": "subway",
            "stop_lat": 40.71,
            "stop_lon": -74.0,
            "stop_id": "A28N",
            "vehicle_id": None,
            "trip_id": "trip_1",
            "distance_m": 150.0,
            "is_real_time": True,
            "is_cancelled": False,
            "is_express": False,
        }
        defaults.update(overrides)
        return _json(NearbyTransitArrival(**defaults))

    def test_all_ios_keys_present(self):
        data = self._make()
        _assert_keys(data, self.IOS_KEYS, "NearbyTransitArrival")

    def test_field_types(self):
        data = self._make()
        _assert_type(data, "route_id", str)
        _assert_type(data, "stop_name", str)
        _assert_type(data, "direction", str)
        _assert_type(data, "destination", str, nullable=True)
        _assert_type(data, "minutes_away", int)
        _assert_type(data, "arrival_ts", int, nullable=True)
        _assert_type(data, "status", str)
        _assert_type(data, "mode", str)
        _assert_type(data, "stop_lat", (int, float), nullable=True)
        _assert_type(data, "stop_lon", (int, float), nullable=True)
        _assert_type(data, "stop_id", str, nullable=True)
        _assert_type(data, "vehicle_id", str, nullable=True)
        _assert_type(data, "trip_id", str, nullable=True)
        _assert_type(data, "distance_m", (int, float), nullable=True)
        _assert_type(data, "is_real_time", bool)
        _assert_type(data, "is_cancelled", bool)
        _assert_type(data, "is_express", bool)

    def test_subway_arrival(self):
        data = self._make(mode="subway", vehicle_id=None, stop_lat=40.7, stop_lon=-74.0)
        assert data["mode"] == "subway"

    def test_bus_arrival(self):
        data = self._make(
            route_id="MTA NYCT_B63",
            mode="bus",
            vehicle_id="MTABC_1234",
            stop_id="MTA_500249",
        )
        assert data["mode"] == "bus"
        assert data["vehicle_id"] == "MTABC_1234"

    def test_lirr_arrival(self):
        data = self._make(route_id="LIRR_10", mode="lirr")
        assert data["mode"] == "lirr"

    def test_mnr_arrival(self):
        data = self._make(route_id="MNR_1", mode="mnr")
        assert data["mode"] == "mnr"

    def test_null_optionals(self):
        data = self._make(
            destination=None,
            arrival_ts=None,
            stop_lat=None,
            stop_lon=None,
            stop_id=None,
            vehicle_id=None,
            trip_id=None,
            distance_m=None,
        )
        for key in [
            "destination",
            "arrival_ts",
            "stop_lat",
            "stop_lon",
            "stop_id",
            "vehicle_id",
            "trip_id",
            "distance_m",
        ]:
            assert data[key] is None, f"Expected {key} to be None"

    def test_defaults_explicit(self):
        data = _json(
            NearbyTransitArrival(
                route_id="A",
                stop_name="S",
                direction="N",
                minutes_away=5,
                mode="subway",
            )
        )
        assert data["status"] == "On Time"
        assert data["is_real_time"] is False
        assert data["is_cancelled"] is False


# ===================================================================
# 3. GroupedNearbyTransit ↔ GroupedNearbyTransitResponse (iOS)
#    Endpoint: GET /nearby/grouped
# ===================================================================


class TestGroupedNearbyTransitContract:
    """Backend GroupedNearbyTransit → iOS GroupedNearbyTransitResponse."""

    IOS_KEYS = [
        "route_id",
        "display_name",
        "mode",
        "color_hex",
        "directions",
        "sorting_key",
        "alerts",
    ]

    DIRECTION_KEYS = ["direction", "direction_label", "arrivals"]
    ALERT_KEYS = ["title", "severity", "affected_routes", "alert_type", "sort_order"]

    def _make_full(self) -> dict:
        arrival = NearbyTransitArrival(
            route_id="A",
            stop_name="Fulton St",
            direction="N",
            destination="Inwood-207 St",
            minutes_away=3,
            arrival_ts=int(time.time()) + 180,
            status="On Time",
            mode="subway",
            stop_lat=40.71,
            stop_lon=-74.0,
            stop_id="A28N",
        )
        group = GroupedNearbyTransit(
            route_id="A",
            display_name="A",
            mode="subway",
            color_hex="#0039A6",
            directions=[
                DirectionArrivals(
                    direction="N",
                    direction_label="Northbound",
                    arrivals=[arrival],
                ),
                DirectionArrivals(
                    direction="S",
                    direction_label="Southbound",
                    arrivals=[],
                ),
            ],
            sorting_key="subway_01",
            alerts=[
                InlineAlert(
                    title="A/C/E delays",
                    severity="severe",
                    affected_routes=["A", "C", "E"],
                    alert_type="Delays",
                    sort_order=26,
                ),
            ],
        )
        return _json(group)

    def test_all_ios_keys_present(self):
        data = self._make_full()
        _assert_keys(data, self.IOS_KEYS, "GroupedNearbyTransit")

    def test_direction_keys(self):
        data = self._make_full()
        for direction in data["directions"]:
            _assert_keys(direction, self.DIRECTION_KEYS, "DirectionArrivals")

    def test_alert_keys(self):
        data = self._make_full()
        for alert in data["alerts"]:
            _assert_keys(alert, self.ALERT_KEYS, "InlineAlert")

    def test_field_types(self):
        data = self._make_full()
        _assert_type(data, "route_id", str)
        _assert_type(data, "display_name", str)
        _assert_type(data, "mode", str)
        _assert_type(data, "color_hex", str, nullable=True)
        _assert_type(data, "directions", list)
        _assert_type(data, "sorting_key", str)
        _assert_type(data, "alerts", list)

    def test_defaults_explicit(self):
        data = _json(
            GroupedNearbyTransit(
                route_id="X",
                display_name="X",
                mode="bus",
                directions=[],
            )
        )
        assert data["sorting_key"] == ""
        assert data["alerts"] == []
        assert data["color_hex"] is None

    def test_empty_directions_serializes(self):
        data = _json(
            GroupedNearbyTransit(
                route_id="X",
                display_name="X",
                mode="bus",
                directions=[],
            )
        )
        assert data["directions"] == []

    def test_nested_arrival_has_all_keys(self):
        data = self._make_full()
        arrival = data["directions"][0]["arrivals"][0]
        _assert_keys(
            arrival, TestNearbyTransitArrivalContract.IOS_KEYS, "nested arrival"
        )


# ===================================================================
# 4. TransitAlert ↔ TransitAlert (iOS)
#    Endpoint: GET /alerts
# ===================================================================


class TestTransitAlertContract:
    """Backend TransitAlert → iOS TransitAlert."""

    IOS_KEYS = [
        "route_id",
        "title",
        "description",
        "severity",
        "mode",
        "updated_at",
        "affected_routes",
        "alert_type",
        "sort_order",
        "display_before_active",
        "active_period_end",
    ]

    def _make(self, **overrides) -> dict:
        defaults = {
            "route_id": "A",
            "title": "A/C/E Delays",
            "description": "Delays on the A, C, E lines due to signal problems.",
            "severity": "severe",
            "mode": "subway",
            "updated_at": int(time.time()),
            "affected_routes": ["A", "C", "E"],
            "alert_type": "Delays",
            "sort_order": 26,
            "display_before_active": 3600,
            "active_period_end": int(time.time()) + 7200,
        }
        defaults.update(overrides)
        return _json(TransitAlert(**defaults))

    def test_all_ios_keys_present(self):
        data = self._make()
        _assert_keys(data, self.IOS_KEYS, "TransitAlert")

    def test_field_types(self):
        data = self._make()
        _assert_type(data, "route_id", str, nullable=True)
        _assert_type(data, "title", str)
        _assert_type(data, "description", str)
        _assert_type(data, "severity", str)
        _assert_type(data, "mode", str)
        _assert_type(data, "updated_at", int, nullable=True)
        _assert_type(data, "affected_routes", list)
        _assert_type(data, "alert_type", str, nullable=True)
        _assert_type(data, "sort_order", int)
        _assert_type(data, "display_before_active", int, nullable=True)
        _assert_type(data, "active_period_end", int, nullable=True)

    def test_defaults_explicit(self):
        data = _json(
            TransitAlert(
                title="Test",
                description="test",
                severity="warning",
            )
        )
        assert data["mode"] == "subway"
        assert data["affected_routes"] == []
        assert data["sort_order"] == 0
        assert data["route_id"] is None
        assert data["alert_type"] is None

    def test_null_optionals(self):
        data = self._make(
            route_id=None,
            updated_at=None,
            alert_type=None,
            display_before_active=None,
            active_period_end=None,
        )
        assert data["route_id"] is None
        assert data["updated_at"] is None
        assert data["alert_type"] is None
        assert data["display_before_active"] is None
        assert data["active_period_end"] is None


# ===================================================================
# 5. ElevatorStatus ↔ ElevatorStatus (iOS)
#    Endpoint: GET /accessibility
# ===================================================================


class TestElevatorStatusContract:
    """Backend ElevatorStatus → iOS ElevatorStatus."""

    IOS_KEYS = ["station", "equipment_type", "description", "outage_since"]

    def test_all_ios_keys_present(self):
        data = _json(
            ElevatorStatus(
                station="Fulton St",
                equipment_type="Elevator",
                description="Out of service since 3/15",
                outage_since="2026-03-15",
            )
        )
        _assert_keys(data, self.IOS_KEYS, "ElevatorStatus")

    def test_field_types(self):
        data = _json(
            ElevatorStatus(
                station="S",
                equipment_type="E",
                description="D",
                outage_since="2026-01-01",
            )
        )
        _assert_type(data, "station", str)
        _assert_type(data, "equipment_type", str)
        _assert_type(data, "description", str)
        _assert_type(data, "outage_since", str, nullable=True)

    def test_null_outage_since(self):
        data = _json(ElevatorStatus(station="S", equipment_type="E", description="D"))
        assert data["outage_since"] is None


# ===================================================================
# 6. BusStop ↔ BusStop (iOS)
#    Endpoints: GET /bus/nearby, nested in RouteShape
# ===================================================================


class TestBusStopContract:
    """Backend BusStop → iOS BusStop."""

    IOS_KEYS = ["id", "name", "lat", "lon", "direction", "route_ids"]

    def test_all_ios_keys_present(self):
        data = _json(
            BusStop(
                id="MTA_500249",
                name="Hillside Av / 169 St",
                lat=40.7091,
                lon=-73.7906,
                direction="SW",
                route_ids=["MTA NYCT_Q43", "MTA NYCT_Q36"],
            )
        )
        _assert_keys(data, self.IOS_KEYS, "BusStop")

    def test_field_types(self):
        data = _json(BusStop(id="X", name="N", lat=40.0, lon=-74.0))
        _assert_type(data, "id", str)
        _assert_type(data, "name", str)
        _assert_type(data, "lat", (int, float))
        _assert_type(data, "lon", (int, float))
        _assert_type(data, "direction", str, nullable=True)
        _assert_type(data, "route_ids", list)

    def test_defaults_explicit(self):
        """iOS decodes route_ids as Optional — backend sends [] by default."""
        data = _json(BusStop(id="X", name="N", lat=0, lon=0))
        assert data["route_ids"] == []
        assert data["direction"] is None


# ===================================================================
# 7. BusArrival ↔ BusArrival (iOS)
#    Endpoint: GET /bus/live/{stop_id}
# ===================================================================


class TestBusArrivalContract:
    """Backend BusArrival → iOS BusArrival."""

    # iOS CodingKeys from BusModels.swift
    IOS_KEYS = [
        "route_id",
        "vehicle_id",
        "stop_id",
        "stop_name",
        "status_text",
        "status",
        "expected_arrival",
        "distance_meters",
        "bearing",
        "direction_ref",
        "destination_name",
        "is_realtime",
    ]

    # Backend sends these but iOS doesn't decode them
    BACKEND_ONLY_KEYS = ["aimed_arrival", "schedule_deviation_s"]

    def _make(self, **overrides) -> dict:
        defaults = {
            "route_id": "MTA NYCT_B63",
            "vehicle_id": "MTABC_5678",
            "stop_id": "MTA_300456",
            "stop_name": "Atlantic Av / 4 Av",
            "status_text": "2 stops away",
            "status": "Live",
            "expected_arrival": datetime(2026, 3, 23, 14, 30, 0, tzinfo=UTC),
            "distance_meters": 450.0,
            "bearing": 180.0,
            "direction_ref": 0,
            "destination_name": "BAY RIDGE via 5 AV",
            "is_realtime": True,
        }
        defaults.update(overrides)
        return _json(BusArrival(**defaults))

    def test_all_ios_keys_present(self):
        data = self._make()
        _assert_keys(data, self.IOS_KEYS, "BusArrival")

    def test_backend_only_keys_present(self):
        """Backend sends extra fields that iOS ignores — verify they exist."""
        data = self._make()
        for key in self.BACKEND_ONLY_KEYS:
            assert key in data, f"Backend-only key '{key}' missing"

    def test_field_types(self):
        data = self._make()
        _assert_type(data, "route_id", str)
        _assert_type(data, "vehicle_id", str)
        _assert_type(data, "stop_id", str)
        _assert_type(data, "stop_name", str, nullable=True)
        _assert_type(data, "status_text", str)
        _assert_type(data, "status", str)
        _assert_type(
            data, "expected_arrival", str, nullable=True
        )  # ISO datetime string
        _assert_type(data, "distance_meters", (int, float), nullable=True)
        _assert_type(data, "bearing", (int, float), nullable=True)
        _assert_type(data, "direction_ref", int, nullable=True)
        _assert_type(data, "destination_name", str, nullable=True)

    def test_defaults_explicit(self):
        data = _json(
            BusArrival(
                route_id="X",
                vehicle_id="V",
                stop_id="S",
                status_text="nearby",
            )
        )
        assert data["status"] == "Live"
        assert data["is_realtime"] is True

    def test_is_realtime_decoded_by_ios(self):
        """iOS BusArrival now decodes is_realtime."""
        data = self._make(is_realtime=False)
        assert "is_realtime" in data
        assert data["is_realtime"] is False


# ===================================================================
# 8. BusVehicle ↔ BusVehicleResponse (iOS)
#    Endpoint: GET /bus/vehicles/{route_id}
# ===================================================================


class TestBusVehicleContract:
    """Backend BusVehicle → iOS BusVehicleResponse."""

    IOS_KEYS = [
        "vehicle_id",
        "route_id",
        "lat",
        "lon",
        "bearing",
        "next_stop",
        "status_text",
        "direction_ref",
        "expected_arrival",
        "onward_calls",
        "is_realtime",
        "position_recorded_at",
    ]

    BACKEND_ONLY_KEYS: list[str] = []

    def _make(self, **overrides) -> dict:
        defaults = {
            "vehicle_id": "MTABC_5678",
            "route_id": "MTA NYCT_B63",
            "lat": 40.6844,
            "lon": -73.9775,
            "bearing": 90.0,
            "next_stop": "Atlantic Av / 4 Av",
            "status_text": "1 stop away",
            "direction_ref": 0,
            "expected_arrival": datetime(2026, 3, 23, 14, 30, 0, tzinfo=UTC),
            "is_realtime": True,
            "position_recorded_at": datetime(2026, 3, 23, 14, 28, 0, tzinfo=UTC),
        }
        defaults.update(overrides)
        return _json(BusVehicle(**defaults))

    def test_all_ios_keys_present(self):
        data = self._make()
        _assert_keys(data, self.IOS_KEYS, "BusVehicle")

    def test_backend_only_keys_present(self):
        data = self._make()
        for key in self.BACKEND_ONLY_KEYS:
            assert key in data, f"Backend-only key '{key}' missing"

    def test_field_types(self):
        data = self._make()
        _assert_type(data, "vehicle_id", str)
        _assert_type(data, "route_id", str)
        _assert_type(data, "lat", (int, float))
        _assert_type(data, "lon", (int, float))
        _assert_type(data, "bearing", (int, float), nullable=True)
        _assert_type(data, "next_stop", str, nullable=True)
        _assert_type(data, "status_text", str, nullable=True)
        _assert_type(data, "direction_ref", int, nullable=True)
        _assert_type(data, "expected_arrival", str, nullable=True)
        _assert_type(data, "onward_calls", list)
        _assert_type(data, "is_realtime", bool)

    def test_onward_calls_nested_structure(self):
        """Onward calls are BusArrival objects — verify nested keys."""
        vehicle = BusVehicle(
            vehicle_id="V1",
            route_id="R1",
            lat=40.0,
            lon=-74.0,
            onward_calls=[
                BusArrival(
                    route_id="R1",
                    vehicle_id="V1",
                    stop_id="S1",
                    status_text="next",
                    direction_ref=0,
                ),
            ],
        )
        data = _json(vehicle)
        assert len(data["onward_calls"]) == 1
        call = data["onward_calls"][0]
        _assert_keys(call, TestBusArrivalContract.IOS_KEYS, "onward_call")

    def test_defaults_explicit(self):
        data = _json(
            BusVehicle(
                vehicle_id="V",
                route_id="R",
                lat=0,
                lon=0,
            )
        )
        assert data["is_realtime"] is True
        assert data["onward_calls"] == []

    def test_position_recorded_at_decoded_by_ios(self):
        """iOS BusVehicleResponse now decodes position_recorded_at."""
        data = self._make()
        assert "position_recorded_at" in data


# ===================================================================
# 9. BusRoute ↔ BusRoute (iOS)
#    Endpoint: GET /bus/routes
# ===================================================================


class TestBusRouteContract:
    """Backend BusRoute → iOS BusRoute."""

    IOS_KEYS = ["id", "short_name", "long_name", "color", "description"]

    def test_all_ios_keys_present(self):
        data = _json(
            BusRoute(
                id="MTA NYCT_B63",
                short_name="B63",
                long_name="Atlantic Av / Grand Army Plaza",
                color="0039A6",
                description="Brooklyn",
            )
        )
        _assert_keys(data, self.IOS_KEYS, "BusRoute")

    def test_field_types(self):
        data = _json(
            BusRoute(
                id="X",
                short_name="SN",
                long_name="LN",
                color="C",
                description="D",
            )
        )
        for key in self.IOS_KEYS:
            _assert_type(data, key, str)


# ===================================================================
# 10. RouteShape ↔ RouteShapeResponse (iOS)
#     Endpoints: GET /bus/route-shape/{id}, /subway/shape/{id},
#                /lirr/shape/{id}, /mnr/shape/{id}
# ===================================================================


class TestRouteShapeContract:
    """Backend RouteShape → iOS RouteShapeResponse."""

    IOS_KEYS = ["route_id", "polylines", "stops", "directions", "service_type"]
    DIRECTION_KEYS = ["direction_id", "headsign", "polylines", "stops", "service_type"]

    def _make(self) -> dict:
        stop = BusStop(id="S1", name="Stop 1", lat=40.71, lon=-74.0)
        return _json(
            RouteShape(
                route_id="L",
                polylines=["_p~iF~ps|U_ulLnnqC"],
                stops=[stop],
                directions=[
                    DirectionShape(
                        direction_id=0,
                        headsign="8 Av",
                        polylines=["_p~iF~ps|U_ulLnnqC"],
                        stops=[stop],
                        service_type="local",
                    ),
                    DirectionShape(
                        direction_id=1,
                        headsign="Canarsie-Rockaway Pkwy",
                        polylines=["_p~iF~ps|U_ulLnnqC"],
                        stops=[stop],
                        service_type="local",
                    ),
                ],
                service_type="local",
            )
        )

    def test_all_ios_keys_present(self):
        data = self._make()
        _assert_keys(data, self.IOS_KEYS, "RouteShape")

    def test_direction_keys(self):
        data = self._make()
        for d in data["directions"]:
            _assert_keys(d, self.DIRECTION_KEYS, "DirectionShape")

    def test_field_types(self):
        data = self._make()
        _assert_type(data, "route_id", str)
        _assert_type(data, "polylines", list)
        _assert_type(data, "stops", list)
        _assert_type(data, "directions", list)
        _assert_type(data, "service_type", str, nullable=True)

    def test_stop_nested_in_direction(self):
        data = self._make()
        stop = data["directions"][0]["stops"][0]
        _assert_keys(stop, TestBusStopContract.IOS_KEYS, "nested stop")

    def test_defaults_explicit(self):
        data = _json(
            RouteShape(
                route_id="X",
                polylines=[],
                stops=[],
            )
        )
        assert data["directions"] == []
        assert data["service_type"] is None


# ===================================================================
# 11. SubwayLineOverlay ↔ SubwayLineOverlay (iOS)
#     Nested in AllSubwayLinesResponse
# ===================================================================


class TestSubwayLineOverlayContract:
    """Backend SubwayLineOverlay → iOS SubwayLineOverlay."""

    IOS_KEYS = ["route_id", "color_hex", "polylines"]

    def test_all_ios_keys_present(self):
        data = _json(
            SubwayLineOverlay(
                route_id="A",
                color_hex="#0039A6",
                polylines=["_p~iF~ps|U_ulLnnqC"],
            )
        )
        _assert_keys(data, self.IOS_KEYS, "SubwayLineOverlay")


# ===================================================================
# 12. TrunkGroupPolylines ↔ TrunkGroupPolylines (iOS)
#     Nested in AllSubwayLinesResponse
# ===================================================================


class TestTrunkGroupPolylinesContract:
    """Backend TrunkGroupPolylines → iOS TrunkGroupPolylines."""

    IOS_KEYS = [
        "trunk_index",
        "color_hex",
        "route_ids",
        "polylines",
        "lane_offset",
        "polyline_lane_offsets",
    ]

    def _make(self) -> dict:
        return _json(
            TrunkGroupPolylines(
                trunk_index=0,
                color_hex="#0039A6",
                route_ids=["A", "C", "E"],
                polylines=["_p~iF~ps|U_ulLnnqC", "abc123"],
                lane_offset=-12.0,
                polyline_lane_offsets=[-12.0, 0.0],
            )
        )

    def test_all_ios_keys_present(self):
        data = self._make()
        _assert_keys(data, self.IOS_KEYS, "TrunkGroupPolylines")

    def test_field_types(self):
        data = self._make()
        _assert_type(data, "trunk_index", int)
        _assert_type(data, "color_hex", str)
        _assert_type(data, "route_ids", list)
        _assert_type(data, "polylines", list)
        _assert_type(data, "lane_offset", (int, float))
        _assert_type(data, "polyline_lane_offsets", list)

    def test_defaults_explicit(self):
        data = _json(
            TrunkGroupPolylines(
                trunk_index=0,
                color_hex="#C",
                route_ids=[],
                polylines=[],
            )
        )
        assert data["lane_offset"] == 0.0
        assert data["polyline_lane_offsets"] == []


# ===================================================================
# 13. AllSubwayLinesResponse ↔ AllSubwayLinesResponse (iOS)
#     Endpoint: GET /subway/shapes/all
# ===================================================================


class TestAllSubwayLinesResponseContract:
    """Backend AllSubwayLinesResponse → iOS AllSubwayLinesResponse."""

    IOS_KEYS = ["lines", "trunk_polylines"]

    def test_all_ios_keys_present(self):
        data = _json(
            AllSubwayLinesResponse(
                lines=[
                    SubwayLineOverlay(
                        route_id="A", color_hex="#0039A6", polylines=["abc"]
                    )
                ],
                trunk_polylines=[
                    TrunkGroupPolylines(
                        trunk_index=0,
                        color_hex="#0039A6",
                        route_ids=["A", "C", "E"],
                        polylines=["abc"],
                    ),
                ],
            )
        )
        _assert_keys(data, self.IOS_KEYS, "AllSubwayLinesResponse")

    def test_defaults_explicit(self):
        """iOS decodes trunk_polylines as Optional — backend sends [] by default."""
        data = _json(AllSubwayLinesResponse(lines=[]))
        assert data["trunk_polylines"] == []


# ===================================================================
# 14. SubwayStation ↔ SubwayStation (iOS)
#     Nested in AllSubwayStationsResponse
# ===================================================================


class TestSubwayStationContract:
    """Backend SubwayStation → iOS SubwayStation."""

    IOS_KEYS = ["id", "name", "lat", "lon", "routes"]

    def test_all_ios_keys_present(self):
        data = _json(
            SubwayStation(
                id="A27",
                name="59 St-Columbus Circle",
                lat=40.768,
                lon=-73.981,
                routes=["A", "C", "B", "D", "1"],
            )
        )
        _assert_keys(data, self.IOS_KEYS, "SubwayStation")

    def test_field_types(self):
        data = _json(
            SubwayStation(
                id="X",
                name="N",
                lat=40.0,
                lon=-74.0,
                routes=["A"],
            )
        )
        _assert_type(data, "id", str)
        _assert_type(data, "name", str)
        _assert_type(data, "lat", (int, float))
        _assert_type(data, "lon", (int, float))
        _assert_type(data, "routes", list)


class TestAllSubwayStationsResponseContract:
    """Backend AllSubwayStationsResponse → iOS AllSubwayStationsResponse."""

    def test_structure(self):
        data = _json(
            AllSubwayStationsResponse(
                stations=[
                    SubwayStation(
                        id="A27", name="59 St", lat=40.768, lon=-73.981, routes=["A"]
                    ),
                ],
            )
        )
        assert "stations" in data
        assert len(data["stations"]) == 1


# ===================================================================
# 15. ProcessedStation ↔ ProcessedStation (iOS)
#     Endpoint: GET /subway/stations/processed
# ===================================================================


class TestProcessedStationContract:
    """Backend ProcessedStation → iOS ProcessedStation."""

    IOS_KEYS = ["station_id", "name", "is_transfer", "positions"]
    POSITION_KEYS = ["route_id", "lat", "lon"]

    def _make(self) -> dict:
        return _json(
            ProcessedStationsResponse(
                stations=[
                    ProcessedStation(
                        station_id="A27",
                        name="59 St-Columbus Circle",
                        is_transfer=True,
                        positions=[
                            StopPosition(route_id="A", lat=40.7681, lon=-73.9813),
                            StopPosition(route_id="1", lat=40.7680, lon=-73.9814),
                        ],
                    ),
                ],
            )
        )

    def test_response_structure(self):
        data = self._make()
        assert "stations" in data
        assert len(data["stations"]) == 1

    def test_station_keys(self):
        data = self._make()
        station = data["stations"][0]
        _assert_keys(station, self.IOS_KEYS, "ProcessedStation")

    def test_position_keys(self):
        data = self._make()
        pos = data["stations"][0]["positions"][0]
        _assert_keys(pos, self.POSITION_KEYS, "StopPosition")

    def test_field_types(self):
        data = self._make()
        station = data["stations"][0]
        _assert_type(station, "station_id", str)
        _assert_type(station, "name", str)
        _assert_type(station, "is_transfer", bool)
        _assert_type(station, "positions", list)
        pos = station["positions"][0]
        _assert_type(pos, "route_id", str)
        _assert_type(pos, "lat", (int, float))
        _assert_type(pos, "lon", (int, float))


# ===================================================================
# 16. CommuterRailLineOverlay ↔ CommuterRailLineOverlay (iOS)
#     Endpoints: GET /lirr/shapes/all, GET /mnr/shapes/all
# ===================================================================


class TestCommuterRailLineOverlayContract:
    """Backend CommuterRailLineOverlay → iOS CommuterRailLineOverlay."""

    IOS_KEYS = ["route_id", "name", "color_hex", "polylines", "mode", "stops"]
    STOP_KEYS = ["stop_id", "name", "lat", "lon"]

    def _make(self) -> dict:
        return _json(
            CommuterRailLineOverlay(
                route_id="LIRR_10",
                name="Babylon",
                color_hex="#00985F",
                polylines=["_p~iF~ps|U_ulLnnqC"],
                mode="lirr",
                stops=[
                    CommuterRailStop(
                        stop_id="1", name="Jamaica", lat=40.699, lon=-73.808
                    ),
                ],
            )
        )

    def test_all_ios_keys_present(self):
        data = self._make()
        _assert_keys(data, self.IOS_KEYS, "CommuterRailLineOverlay")

    def test_stop_keys(self):
        data = self._make()
        stop = data["stops"][0]
        _assert_keys(stop, self.STOP_KEYS, "CommuterRailStop")

    def test_defaults_explicit(self):
        data = _json(
            CommuterRailLineOverlay(
                route_id="X",
                name="N",
                color_hex="#C",
                polylines=[],
                mode="mnr",
            )
        )
        assert data["stops"] == []


class TestAllCommuterRailLinesResponseContract:
    """Backend AllCommuterRailLinesResponse → iOS AllCommuterRailLinesResponse."""

    def test_structure(self):
        data = _json(
            AllCommuterRailLinesResponse(
                lines=[
                    CommuterRailLineOverlay(
                        route_id="LIRR_10",
                        name="Babylon",
                        color_hex="#00985F",
                        polylines=["abc"],
                        mode="lirr",
                    ),
                ],
            )
        )
        assert "lines" in data
        assert len(data["lines"]) == 1


# ===================================================================
# 17. BusScheduleResponse ↔ BusScheduleResponse (iOS)
#     Endpoint: GET /bus/schedule/{route_id}
# ===================================================================


class TestBusScheduleContract:
    """Backend BusScheduleResponse → iOS BusScheduleResponse."""

    IOS_KEYS = ["route_id", "directions"]
    DIRECTION_KEYS = ["direction", "headsign", "departures"]
    DEPARTURE_KEYS = ["stop_name", "stop_id", "departure_time", "headsign", "trip_id"]

    def _make(self) -> dict:
        return _json(
            BusScheduleResponse(
                route_id="MTA NYCT_B63",
                directions=[
                    BusScheduleDirection(
                        route_id="MTA NYCT_B63",
                        direction="0",
                        headsign="Bay Ridge",
                        departures=[
                            BusScheduleDeparture(
                                stop_name="Atlantic Av / 4 Av",
                                stop_id="MTA_300456",
                                departure_time=int(time.time()) + 600,
                                headsign="Bay Ridge",
                                trip_id="trip_001",
                            ),
                        ],
                    ),
                ],
            )
        )

    def test_all_ios_keys_present(self):
        data = self._make()
        _assert_keys(data, self.IOS_KEYS, "BusScheduleResponse")

    def test_direction_keys(self):
        data = self._make()
        d = data["directions"][0]
        _assert_keys(d, self.DIRECTION_KEYS, "BusScheduleDirection")

    def test_departure_keys(self):
        data = self._make()
        dep = data["directions"][0]["departures"][0]
        _assert_keys(dep, self.DEPARTURE_KEYS, "BusScheduleDeparture")

    def test_departure_field_types(self):
        data = self._make()
        dep = data["directions"][0]["departures"][0]
        _assert_type(dep, "stop_name", str)
        _assert_type(dep, "stop_id", str)
        _assert_type(dep, "departure_time", int)
        _assert_type(dep, "headsign", str)
        _assert_type(dep, "trip_id", str)


# ===================================================================
# 18. DelayPrediction ↔ DelayPrediction (iOS)
#     Endpoint: GET /predict/delay
# ===================================================================


class TestDelayPredictionContract:
    """Backend DelayPrediction → iOS DelayPrediction.

    Note: The Pydantic model is not in models.py — it's defined inline
    in the predict router.  We test the expected JSON shape here.
    """

    IOS_KEYS = [
        "adjusted_minutes",
        "original_minutes",
        "delay_factor",
        "adjustment_reason",
        "model_source",
        "recency_error_seconds",
    ]

    def test_all_ios_keys_present(self):
        """Verify the expected JSON shape matches iOS CodingKeys."""
        data = {
            "adjusted_minutes": 7,
            "original_minutes": 5,
            "delay_factor": 1.4,
            "adjustment_reason": "Rain delay (+2m)",
            "model_source": "heuristic",
            "recency_error_seconds": 30.0,
        }
        _assert_keys(data, self.IOS_KEYS, "DelayPrediction")

    def test_field_types(self):
        data = {
            "adjusted_minutes": 7,
            "original_minutes": 5,
            "delay_factor": 1.4,
            "adjustment_reason": None,
            "model_source": "heuristic",
            "recency_error_seconds": 0.0,
        }
        _assert_type(data, "adjusted_minutes", int)
        _assert_type(data, "original_minutes", int)
        _assert_type(data, "delay_factor", (int, float))
        _assert_type(data, "adjustment_reason", str, nullable=True)
        _assert_type(data, "model_source", str)
        _assert_type(data, "recency_error_seconds", (int, float))


# ===================================================================
# 19. SNAKE_CASE CONSISTENCY — verify no camelCase leaks into JSON
# ===================================================================


class TestSnakeCaseConsistency:
    """All backend JSON keys must use snake_case (matching iOS CodingKeys)."""

    def _check_snake_case(self, data: dict | list, path: str = ""):
        """Recursively verify all keys are snake_case or non-compound."""
        if isinstance(data, list):
            for i, item in enumerate(data):
                if isinstance(item, (dict, list)):
                    self._check_snake_case(item, f"{path}[{i}]")
        elif isinstance(data, dict):
            for key, value in data.items():
                # Allow simple single-word keys (id, name, lat, lon, etc.)
                # Compound words must be snake_case, not camelCase
                if len(key) > 1 and any(c.isupper() for c in key[1:]):
                    raise AssertionError(f"CamelCase key found at {path}.{key}")
                if isinstance(value, (dict, list)):
                    self._check_snake_case(value, f"{path}.{key}")

    def test_track_arrival_snake_case(self):
        data = _json(TrackArrival(station="X", direction="N", minutes_away=5))
        self._check_snake_case(data, "TrackArrival")

    def test_grouped_nearby_transit_snake_case(self):
        data = _json(
            GroupedNearbyTransit(
                route_id="A",
                display_name="A",
                mode="subway",
                directions=[
                    DirectionArrivals(
                        direction="N",
                        arrivals=[
                            NearbyTransitArrival(
                                route_id="A",
                                stop_name="S",
                                direction="N",
                                minutes_away=5,
                                mode="subway",
                            ),
                        ],
                    ),
                ],
                alerts=[InlineAlert(title="T", severity="severe")],
            )
        )
        self._check_snake_case(data, "GroupedNearbyTransit")

    def test_bus_vehicle_snake_case(self):
        data = _json(
            BusVehicle(
                vehicle_id="V",
                route_id="R",
                lat=0,
                lon=0,
                onward_calls=[
                    BusArrival(
                        route_id="R", vehicle_id="V", stop_id="S", status_text="T"
                    ),
                ],
            )
        )
        self._check_snake_case(data, "BusVehicle")

    def test_all_subway_lines_response_snake_case(self):
        data = _json(
            AllSubwayLinesResponse(
                lines=[
                    SubwayLineOverlay(
                        route_id="A", color_hex="#0039A6", polylines=["abc"]
                    )
                ],
                trunk_polylines=[
                    TrunkGroupPolylines(
                        trunk_index=0,
                        color_hex="#C",
                        route_ids=["A"],
                        polylines=["abc"],
                        lane_offset=-12.0,
                        polyline_lane_offsets=[-12.0],
                    ),
                ],
            )
        )
        self._check_snake_case(data, "AllSubwayLinesResponse")

    def test_route_shape_snake_case(self):
        data = _json(
            RouteShape(
                route_id="L",
                polylines=["abc"],
                stops=[BusStop(id="S", name="N", lat=0, lon=0)],
                directions=[
                    DirectionShape(
                        direction_id=0,
                        headsign="H",
                        polylines=["abc"],
                        stops=[BusStop(id="S", name="N", lat=0, lon=0)],
                    ),
                ],
            )
        )
        self._check_snake_case(data, "RouteShape")

    def test_processed_stations_snake_case(self):
        data = _json(
            ProcessedStationsResponse(
                stations=[
                    ProcessedStation(
                        station_id="A27",
                        name="59 St",
                        is_transfer=True,
                        positions=[StopPosition(route_id="A", lat=40.0, lon=-74.0)],
                    ),
                ],
            )
        )
        self._check_snake_case(data, "ProcessedStationsResponse")


# ===================================================================
# 20. FULL ROUNDTRIP — build → serialize → verify every iOS field
# ===================================================================


class TestFullRoundtrip:
    """End-to-end: build every model the backend returns,
    serialize to JSON, verify all iOS-expected fields survive."""

    def test_complete_grouped_nearby_response(self):
        """Simulate a full /nearby/grouped response and verify every nested key."""
        ts = int(time.time()) + 300
        response = [
            GroupedNearbyTransit(
                route_id="A",
                display_name="A",
                mode="subway",
                color_hex="#0039A6",
                directions=[
                    DirectionArrivals(
                        direction="N",
                        direction_label="Inwood-207 St",
                        arrivals=[
                            NearbyTransitArrival(
                                route_id="A",
                                stop_name="Fulton St",
                                direction="N",
                                destination="Inwood-207 St",
                                minutes_away=3,
                                arrival_ts=ts,
                                status="On Time",
                                mode="subway",
                                stop_lat=40.71,
                                stop_lon=-74.0,
                                stop_id="A28N",
                                trip_id="trip_1",
                                is_real_time=True,
                            ),
                        ],
                    ),
                ],
                sorting_key="subway_01",
                alerts=[
                    InlineAlert(
                        title="Delays",
                        severity="severe",
                        affected_routes=["A"],
                        alert_type="Delays",
                        sort_order=26,
                    ),
                ],
            ),
            GroupedNearbyTransit(
                route_id="MTA NYCT_B63",
                display_name="B63",
                mode="bus",
                color_hex="#0039A6",
                directions=[
                    DirectionArrivals(
                        direction="0",
                        direction_label="BAY RIDGE via 5 AV",
                        arrivals=[
                            NearbyTransitArrival(
                                route_id="MTA NYCT_B63",
                                stop_name="Atlantic Av",
                                direction="0",
                                destination="BAY RIDGE via 5 AV",
                                minutes_away=7,
                                arrival_ts=ts + 240,
                                status="2 stops away",
                                mode="bus",
                                stop_lat=40.68,
                                stop_lon=-73.97,
                                stop_id="MTA_300456",
                                vehicle_id="MTABC_5678",
                                distance_m=400.0,
                                is_real_time=True,
                            ),
                        ],
                    ),
                ],
            ),
        ]

        for group in response:
            data = _json(group)
            _assert_keys(
                data,
                TestGroupedNearbyTransitContract.IOS_KEYS,
                f"group {data['route_id']}",
            )
            for direction in data["directions"]:
                _assert_keys(
                    direction,
                    TestGroupedNearbyTransitContract.DIRECTION_KEYS,
                    "direction",
                )
                for arrival in direction["arrivals"]:
                    _assert_keys(
                        arrival, TestNearbyTransitArrivalContract.IOS_KEYS, "arrival"
                    )
            for alert in data.get("alerts", []):
                _assert_keys(
                    alert, TestGroupedNearbyTransitContract.ALERT_KEYS, "alert"
                )

    def test_complete_system_map_response(self):
        """Simulate a full /subway/shapes/all response."""
        data = _json(
            AllSubwayLinesResponse(
                lines=[
                    SubwayLineOverlay(
                        route_id="A", color_hex="#0039A6", polylines=["abc"]
                    ),
                    SubwayLineOverlay(
                        route_id="L", color_hex="#A7A9AC", polylines=["def"]
                    ),
                ],
                trunk_polylines=[
                    TrunkGroupPolylines(
                        trunk_index=0,
                        color_hex="#0039A6",
                        route_ids=["A", "C", "E"],
                        polylines=["abc", "def"],
                        lane_offset=-12.0,
                        polyline_lane_offsets=[-12.0, 0.0],
                    ),
                ],
            )
        )
        _assert_keys(data, TestAllSubwayLinesResponseContract.IOS_KEYS)
        for line in data["lines"]:
            _assert_keys(line, TestSubwayLineOverlayContract.IOS_KEYS, "line")
        for trunk in data["trunk_polylines"]:
            _assert_keys(trunk, TestTrunkGroupPolylinesContract.IOS_KEYS, "trunk")

    def test_complete_commuter_rail_response(self):
        """Simulate a full /lirr/shapes/all response."""
        data = _json(
            AllCommuterRailLinesResponse(
                lines=[
                    CommuterRailLineOverlay(
                        route_id="LIRR_10",
                        name="Babylon",
                        color_hex="#00985F",
                        polylines=["abc"],
                        mode="lirr",
                        stops=[
                            CommuterRailStop(
                                stop_id="1",
                                name="Jamaica",
                                lat=40.699,
                                lon=-73.808,
                            )
                        ],
                    ),
                ],
            )
        )
        assert "lines" in data
        line = data["lines"][0]
        _assert_keys(line, TestCommuterRailLineOverlayContract.IOS_KEYS, "line")
        _assert_keys(
            line["stops"][0], TestCommuterRailLineOverlayContract.STOP_KEYS, "stop"
        )
