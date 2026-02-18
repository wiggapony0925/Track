#
# test_contract.py
# TrackBackend
#
# Contract tests that ensure data integrity between the backend API
# and the iOS frontend.  These tests verify:
#   1. Bus arrivals always have proper direction grouping (DirectionRef)
#   2. LIRR/MNR stop_id namespacing prevents cross-contamination
#   3. Rail direction inference works for feeds without direction_id
#   4. GroupedNearbyTransit schema matches iOS Codable contracts
#   5. Bus nearby reliability (OBA stops + SIRI arrivals)
#   6. Station lookup correctness with overlapping stop_ids
#

from __future__ import annotations

import asyncio
from collections import defaultdict
from datetime import datetime, timezone
from unittest.mock import AsyncMock, patch

import pytest

from app.models import (
    BusArrival,
    BusStop,
    BusVehicle,
    DirectionArrivals,
    GroupedNearbyTransit,
    NearbyTransitArrival,
    TrackArrival,
)
from app.routers.nearby import (
    _direction_label,
    _display_name,
    _group_arrivals,
    _soonest_minutes,
)
from app.services.station_lookup import (
    _load_stops,
    get_nearby_stop_ids,
    get_stop_info,
    get_stop_name,
)


# ===================================================================
# HELPERS
# ===================================================================

def _make_bus_arrival(
    route_id: str = "Q43",
    direction_ref: int | None = 0,
    destination_name: str | None = "JAMAICA via HILLSIDE AV",
    **kwargs,
) -> NearbyTransitArrival:
    """Build a NearbyTransitArrival for a bus with DirectionRef-based direction."""
    direction = str(direction_ref) if direction_ref is not None else "Loop"
    return NearbyTransitArrival(
        route_id=route_id,
        stop_name=kwargs.get("stop_name", "Test Stop"),
        direction=direction,
        destination=destination_name,
        minutes_away=kwargs.get("minutes_away", 5),
        arrival_ts=kwargs.get("arrival_ts", int(datetime.now(timezone.utc).timestamp())),
        status=kwargs.get("status", "1 stop away"),
        mode="bus",
        stop_lat=40.70,
        stop_lon=-73.80,
        stop_id=kwargs.get("stop_id", "MTA_500249"),
        vehicle_id=kwargs.get("vehicle_id", "MTABC_1234"),
    )


def _make_rail_arrival(
    route_id: str = "LIRR_10",
    direction: str = "Inbound",
    destination: str = "Penn Station",
    mode: str = "lirr",
    **kwargs,
) -> NearbyTransitArrival:
    """Build a NearbyTransitArrival for LIRR or MNR."""
    return NearbyTransitArrival(
        route_id=route_id,
        stop_name=kwargs.get("stop_name", "Jamaica"),
        direction=direction,
        destination=destination,
        minutes_away=kwargs.get("minutes_away", 10),
        arrival_ts=kwargs.get("arrival_ts", int(datetime.now(timezone.utc).timestamp())),
        status="On Time",
        mode=mode,
        stop_lat=40.70,
        stop_lon=-73.81,
        stop_id=kwargs.get("stop_id", "102"),
    )


# ===================================================================
# 2. BUS DIRECTION GROUPING CONTRACT
# ===================================================================


class TestBusDirectionGrouping:
    """Verify buses group by SIRI DirectionRef (0/1) not stop compass direction."""

    def test_two_directions_per_route(self):
        """A bus route with arrivals in both directions should produce 2 direction groups."""
        arrivals = [
            _make_bus_arrival(route_id="Q43", direction_ref=0, destination_name="FLORAL PARK"),
            _make_bus_arrival(route_id="Q43", direction_ref=0, destination_name="FLORAL PARK", minutes_away=8),
            _make_bus_arrival(route_id="Q43", direction_ref=1, destination_name="JAMAICA LIRR"),
            _make_bus_arrival(route_id="Q43", direction_ref=1, destination_name="JAMAICA LIRR", minutes_away=12),
        ]
        groups = _group_arrivals(arrivals)
        assert len(groups) == 1, "Should be 1 route group for Q43"
        assert len(groups[0].directions) == 2, "Q43 should have 2 directions"

    def test_direction_labels_use_destination(self):
        """Direction labels for bus DirectionRef '0'/'1' should use DestinationName."""
        arrivals = [
            _make_bus_arrival(route_id="Q56", direction_ref=0, destination_name="JAMAICA 170 ST"),
            _make_bus_arrival(route_id="Q56", direction_ref=1, destination_name="BROADWAY JUNCTION"),
        ]
        groups = _group_arrivals(arrivals)
        labels = {d.direction_label for d in groups[0].directions}
        assert "JAMAICA 170 ST" in labels
        assert "BROADWAY JUNCTION" in labels

    def test_direction_ref_none_falls_back(self):
        """When DirectionRef is None, direction should fallback to 'Loop'."""
        arrivals = [
            _make_bus_arrival(route_id="X99", direction_ref=None, destination_name=None),
        ]
        # direction is "Loop" when direction_ref is None
        assert arrivals[0].direction == "Loop"
        groups = _group_arrivals(arrivals)
        assert groups[0].directions[0].direction == "Loop"
        assert groups[0].directions[0].direction_label == "Loop"

    def test_same_direction_ref_merges(self):
        """All arrivals from multiple stops with the same DirectionRef merge."""
        arrivals = [
            _make_bus_arrival(route_id="Q54", direction_ref=0, stop_id="MTA_001", stop_name="Stop A"),
            _make_bus_arrival(route_id="Q54", direction_ref=0, stop_id="MTA_002", stop_name="Stop B"),
            _make_bus_arrival(route_id="Q54", direction_ref=1, stop_id="MTA_003", stop_name="Stop C"),
        ]
        groups = _group_arrivals(arrivals)
        dir0 = [d for d in groups[0].directions if d.direction == "0"][0]
        assert len(dir0.arrivals) == 2, "Dir 0 should merge arrivals from both stops"

    def test_bus_mode_set_correctly(self):
        """Bus arrivals should have mode='bus'."""
        arrivals = [_make_bus_arrival()]
        groups = _group_arrivals(arrivals)
        assert groups[0].mode == "bus"

    def test_arrivals_sorted_by_minutes(self):
        """Within each direction, arrivals are sorted by minutes_away."""
        arrivals = [
            _make_bus_arrival(route_id="Q60", direction_ref=0, minutes_away=15),
            _make_bus_arrival(route_id="Q60", direction_ref=0, minutes_away=3),
            _make_bus_arrival(route_id="Q60", direction_ref=0, minutes_away=8),
        ]
        groups = _group_arrivals(arrivals)
        mins = [a.minutes_away for a in groups[0].directions[0].arrivals]
        assert mins == sorted(mins), "Arrivals should be sorted ascending"


# ===================================================================
# 3. DIRECTION LABEL CONTRACT
# ===================================================================


class TestDirectionLabel:
    """Verify _direction_label() resolves all known direction codes."""

    @pytest.mark.parametrize("code,expected", [
        ("N", "Northbound"),
        ("S", "Southbound"),
        ("E", "Eastbound"),
        ("W", "Westbound"),
        ("NE", "Northeast"),
        ("NW", "Northwest"),
        ("SE", "Southeast"),
        ("SW", "Southwest"),
        ("Inbound", "Inbound"),
        ("Outbound", "Outbound"),
    ])
    def test_compass_codes(self, code: str, expected: str):
        assert _direction_label(code) == expected

    def test_bus_direction_ref_with_arrivals(self):
        """DirectionRef '0' with arrivals should use destination as label."""
        arrivals = [_make_bus_arrival(destination_name="QUEENS VILLAGE")]
        label = _direction_label("0", arrivals)
        assert label == "QUEENS VILLAGE"

    def test_bus_direction_ref_without_arrivals(self):
        """DirectionRef '0' without arrivals should fallback."""
        label = _direction_label("0", [])
        assert label == "Direction A"
        label2 = _direction_label("1", [])
        assert label2 == "Direction B"

    def test_unknown_direction_passthrough(self):
        """Unknown direction strings pass through unchanged."""
        label = _direction_label("Far Rockaway")
        assert label == "Far Rockaway"


# ===================================================================
# 4. LIRR / MNR STOP_ID NAMESPACING
# ===================================================================


class TestStopIdNamespacing:
    """Verify LIRR and MNR stops with overlapping IDs resolve correctly."""

    def test_no_cross_contamination(self):
        """stop_id '1' should return different names for LIRR vs MNR."""
        lirr_info = get_stop_info("1", agency="lirr")
        mnr_info = get_stop_info("1", agency="mnr")
        # Both should resolve, to different stations
        assert lirr_info is not None, "LIRR stop_id '1' not found"
        assert mnr_info is not None, "MNR stop_id '1' not found"
        assert lirr_info.name != mnr_info.name, (
            f"LIRR and MNR stop_id '1' resolved to same name: {lirr_info.name}"
        )
        # LIRR stop_id 1 = Albertson, MNR stop_id 1 = Grand Central
        assert lirr_info.agency == "lirr"
        assert mnr_info.agency == "mnr"

    def test_subway_stop_unaffected(self):
        """Subway stops (e.g. 'L12N') should resolve without agency hint."""
        # Subway stop_ids are alphanumeric with letter prefixes — no collision
        info = get_stop_info("A09")
        if info:
            assert info.agency == "subway"

    def test_get_stop_name_with_agency(self):
        """get_stop_name with agency hint returns correct name."""
        lirr_name = get_stop_name("1", agency="lirr")
        mnr_name = get_stop_name("1", agency="mnr")
        assert lirr_name != mnr_name

    def test_namespaced_keys_exist(self):
        """The stops dict should contain namespaced keys like 'lirr:1', 'mnr:1'."""
        stops = _load_stops()
        assert "lirr:1" in stops, "Namespaced key 'lirr:1' missing"
        assert "mnr:1" in stops, "Namespaced key 'mnr:1' missing"

    def test_nearby_stop_ids_agency_filter(self):
        """get_nearby_stop_ids with agency filter returns only that agency's stops."""
        # Jamaica area — should find LIRR stops, not MNR
        lirr_stops = get_nearby_stop_ids(40.699, -73.808, 5000.0, agency="lirr")
        mnr_stops = get_nearby_stop_ids(40.699, -73.808, 5000.0, agency="mnr")
        
        # Jamaica is an LIRR hub, not MNR
        assert len(lirr_stops) > 0, "Should find LIRR stops near Jamaica"
        # MNR might have 0 stops near Jamaica (it's mostly Manhattan/Bronx-north)
        
        # Grand Central area — should find MNR stops
        mnr_gc = get_nearby_stop_ids(40.753, -73.977, 2000.0, agency="mnr")
        assert len(mnr_gc) > 0, "Should find MNR stops near Grand Central"


# ===================================================================
# 5. RAIL DIRECTION INFERENCE
# ===================================================================


class TestRailDirectionInference:
    """Verify MNR direction is inferred when direction_id is absent."""

    def test_mnr_grouped_has_directions(self):
        """MNR arrivals should NOT all be in a single 'N/A' direction."""
        arrivals = [
            _make_rail_arrival(route_id="MNR_1", direction="Grand Central", destination="Grand Central", mode="mnr"),
            _make_rail_arrival(route_id="MNR_1", direction="Poughkeepsie", destination="Poughkeepsie", mode="mnr"),
        ]
        groups = _group_arrivals(arrivals)
        assert len(groups) == 1
        assert len(groups[0].directions) == 2, "MNR should have 2 directions (Inbound/Outbound)"

    def test_lirr_has_outbound_inbound(self):
        """LIRR arrivals should have Inbound and Outbound directions."""
        arrivals = [
            _make_rail_arrival(route_id="LIRR_10", direction="Penn Station", destination="Penn Station"),
            _make_rail_arrival(route_id="LIRR_10", direction="Babylon", destination="Babylon"),
        ]
        groups = _group_arrivals(arrivals)
        dirs = {d.direction for d in groups[0].directions}
        assert len(dirs) == 2, "LIRR should have 2 distinct directions"


# ===================================================================
# 6. GROUPED TRANSIT SCHEMA CONTRACT (matches iOS Codable)
# ===================================================================


class TestGroupedTransitSchema:
    """Verify GroupedNearbyTransit JSON matches iOS GroupedNearbyTransitResponse."""

    def test_required_fields_present(self):
        """All fields expected by iOS Codable must be in the JSON output."""
        group = GroupedNearbyTransit(
            route_id="Q43",
            display_name="Q43",
            mode="bus",
            color_hex="#0039A6",
            directions=[
                DirectionArrivals(
                    direction="0",
                    direction_label="FLORAL PARK",
                    arrivals=[],
                )
            ],
        )
        data = group.model_dump()
        # These keys map to iOS CodingKeys
        ios_expected_keys = ["route_id", "display_name", "mode", "color_hex", "directions"]
        for key in ios_expected_keys:
            assert key in data, f"Missing key for iOS contract: {key}"

    def test_direction_arrivals_schema(self):
        """DirectionArrivals must contain direction, direction_label, arrivals."""
        da = DirectionArrivals(
            direction="N",
            direction_label="Northbound",
            arrivals=[],
        )
        data = da.model_dump()
        assert "direction" in data
        assert "direction_label" in data
        assert "arrivals" in data

    def test_nearby_transit_arrival_schema(self):
        """NearbyTransitArrival fields must match iOS NearbyTransitArrivalResponse."""
        arrival = NearbyTransitArrival(
            route_id="A",
            stop_name="Fulton St",
            direction="N",
            destination="Inwood-207 St",
            minutes_away=3,
            arrival_ts=1700000000,
            status="On Time",
            mode="subway",
            stop_lat=40.71,
            stop_lon=-74.0,
            stop_id="A28N",
            vehicle_id=None,
            trip_id="trip123",
        )
        data = arrival.model_dump()
        ios_keys = [
            "route_id", "stop_name", "direction", "destination",
            "minutes_away", "arrival_ts", "status", "mode",
            "stop_lat", "stop_lon", "stop_id", "vehicle_id", "trip_id",
        ]
        for key in ios_keys:
            assert key in data, f"Missing key for iOS contract: {key}"

    def test_bus_arrival_has_direction_fields(self):
        """BusArrival model must include direction_ref and destination_name."""
        arrival = BusArrival(
            route_id="Q43",
            vehicle_id="MTABC_1234",
            stop_id="MTA_500249",
            status_text="1 stop away",
            direction_ref=0,
            destination_name="FLORAL PARK via HILLSIDE AV",
        )
        data = arrival.model_dump()
        assert "direction_ref" in data
        assert "destination_name" in data
        assert data["direction_ref"] == 0
        assert data["destination_name"] == "FLORAL PARK via HILLSIDE AV"

    def test_bus_vehicle_has_expected_arrival(self):
        """BusVehicle model must include expected_arrival for marker ETA display."""
        vehicle = BusVehicle(
            vehicle_id="MTABC_5678",
            route_id="MTA NYCT_Q10",
            lat=40.6602,
            lon=-73.8306,
            bearing=180.0,
            next_stop="Lefferts Blvd/Rockaway Blvd",
            status_text="< 1 stop away",
            direction_ref=0,
            expected_arrival=datetime(2026, 2, 18, 1, 0, 0, tzinfo=timezone.utc),
        )
        data = vehicle.model_dump()
        assert "expected_arrival" in data
        assert data["expected_arrival"] is not None

    def test_bus_vehicle_expected_arrival_optional(self):
        """BusVehicle expected_arrival should be optional (None when unavailable)."""
        vehicle = BusVehicle(
            vehicle_id="MTABC_9999",
            route_id="MTA NYCT_B63",
            lat=40.68,
            lon=-73.97,
        )
        data = vehicle.model_dump()
        assert "expected_arrival" in data
        assert data["expected_arrival"] is None


# ===================================================================
# 7. DISPLAY NAME RESOLUTION
# ===================================================================


class TestDisplayName:
    """Verify _display_name() strips prefixes and resolves names."""

    def test_subway_strip_prefix(self):
        assert _display_name("MTA NYCT_A") == "A"
        assert _display_name("MTA NYCT_7X") == "7X"

    def test_bus_plain_id(self):
        assert _display_name("Q43") == "Q43"

    def test_mtabc_strip_prefix(self):
        assert _display_name("MTABC_Q112") == "Q112"
        assert _display_name("MTABC_QM1") == "QM1"

    def test_mta_bus_strip_prefix(self):
        assert _display_name("MTA BUS_Q10") == "Q10"

    def test_lirr_prefix(self):
        name = _display_name("LIRR_10")
        assert name != "LIRR_10", "Should resolve to branch name"
        assert isinstance(name, str)

    def test_mnr_prefix(self):
        name = _display_name("MNR_1")
        assert name != "MNR_1", "Should resolve to line name"
        assert isinstance(name, str)


# ===================================================================
# 8. SOONEST MINUTES SORTING
# ===================================================================


class TestSoonestMinutes:
    """Verify _soonest_minutes() picks the smallest minutes_away."""

    def test_picks_minimum(self):
        group = GroupedNearbyTransit(
            route_id="A",
            display_name="A",
            mode="subway",
            directions=[
                DirectionArrivals(
                    direction="N",
                    direction_label="Northbound",
                    arrivals=[
                        NearbyTransitArrival(
                            route_id="A", stop_name="S", direction="N",
                            minutes_away=10, mode="subway",
                        ),
                    ],
                ),
                DirectionArrivals(
                    direction="S",
                    direction_label="Southbound",
                    arrivals=[
                        NearbyTransitArrival(
                            route_id="A", stop_name="S", direction="S",
                            minutes_away=3, mode="subway",
                        ),
                    ],
                ),
            ],
        )
        assert _soonest_minutes(group) == 3

    def test_empty_directions(self):
        group = GroupedNearbyTransit(
            route_id="X",
            display_name="X",
            mode="bus",
            directions=[],
        )
        assert _soonest_minutes(group) == 999


# ===================================================================
# 9. LIVE DATA INTEGRATION TESTS (hit real APIs)
# ===================================================================


@pytest.mark.integration
class TestLiveDataIntegration:
    """These tests hit real MTA APIs to verify data contracts.
    
    Run with: pytest -m integration tests/test_contract.py
    Skip in CI with: pytest -m "not integration"
    """

    def test_lirr_feed_stop_ids_match_gtfs(self):
        """All stop_ids from LIRR GTFS-RT feed should exist in stops.txt."""
        import httpx
        from google.transit import gtfs_realtime_pb2

        url = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/lirr%2Fgtfs-lirr"
        resp = httpx.get(url, timeout=15)
        feed = gtfs_realtime_pb2.FeedMessage()
        feed.ParseFromString(resp.content)

        feed_stop_ids = set()
        for entity in feed.entity:
            if entity.HasField("trip_update"):
                for stu in entity.trip_update.stop_time_update:
                    feed_stop_ids.add(stu.stop_id)

        # Every feed stop_id should resolve via get_stop_info with agency
        unresolved = []
        for sid in feed_stop_ids:
            info = get_stop_info(sid, agency="lirr")
            if info is None:
                unresolved.append(sid)

        assert len(unresolved) == 0, f"LIRR feed has unresolved stop_ids: {unresolved}"

    def test_mnr_feed_stop_ids_match_gtfs(self):
        """All stop_ids from MNR GTFS-RT feed should exist in stops.txt."""
        import httpx
        from google.transit import gtfs_realtime_pb2

        url = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/mnr%2Fgtfs-mnr"
        resp = httpx.get(url, timeout=15)
        feed = gtfs_realtime_pb2.FeedMessage()
        feed.ParseFromString(resp.content)

        feed_stop_ids = set()
        for entity in feed.entity:
            if entity.HasField("trip_update"):
                for stu in entity.trip_update.stop_time_update:
                    feed_stop_ids.add(stu.stop_id)

        unresolved = []
        for sid in feed_stop_ids:
            info = get_stop_info(sid, agency="mnr")
            if info is None:
                unresolved.append(sid)

        assert len(unresolved) == 0, f"MNR feed has unresolved stop_ids: {unresolved}"

    def test_bus_siri_includes_direction_ref(self):
        """SIRI stop-monitoring (normal detail) must include DirectionRef."""
        loop = asyncio.new_event_loop()
        try:
            from app.services.bus_client import get_realtime_arrivals
            arrivals = loop.run_until_complete(get_realtime_arrivals("MTA_500249"))
            if arrivals:
                has_dir = any(a.direction_ref is not None for a in arrivals)
                assert has_dir, "No arrivals have direction_ref — is SIRI detail level 'minimum'?"
        finally:
            loop.close()

    def test_bus_siri_includes_destination_name(self):
        """SIRI stop-monitoring must include DestinationName."""
        loop = asyncio.new_event_loop()
        try:
            from app.services.bus_client import get_realtime_arrivals
            arrivals = loop.run_until_complete(get_realtime_arrivals("MTA_500249"))
            if arrivals:
                has_dest = any(a.destination_name is not None for a in arrivals)
                assert has_dest, "No arrivals have destination_name"
        finally:
            loop.close()

    def test_lirr_destinations_are_lirr_stations(self):
        """LIRR arrivals should have LIRR station names, not MNR."""
        loop = asyncio.new_event_loop()
        try:
            from app.services.rail_client import fetch_rail_arrivals
            arrivals = loop.run_until_complete(fetch_rail_arrivals("lirr"))
            
            # Known MNR-only destinations that should NOT appear in LIRR
            mnr_only = {
                "Grand Central", "Croton-Harmon", "Poughkeepsie", "Danbury",
                "Tarrytown", "Brewster", "Bronxville", "Bethel",
            }
            # Note: "Grand Central" IS valid for LIRR (direct GCT service),
            # but the others are MNR-only
            mnr_only_strict = mnr_only - {"Grand Central"}
            
            dests = {a.destination for a in arrivals}
            cross_contaminated = dests & mnr_only_strict
            assert len(cross_contaminated) == 0, (
                f"LIRR has MNR-only destinations: {cross_contaminated}"
            )
        finally:
            loop.close()

    def test_mnr_destinations_are_mnr_stations(self):
        """MNR arrivals should have MNR station names, not LIRR."""
        loop = asyncio.new_event_loop()
        try:
            from app.services.rail_client import fetch_rail_arrivals
            arrivals = loop.run_until_complete(fetch_rail_arrivals("metro_north"))
            
            # Known LIRR-only destinations that should NOT appear in MNR
            lirr_only = {
                "Montauk", "Babylon", "Far Rockaway", "Long Beach",
                "Oyster Bay", "Port Jefferson", "Port Washington", "Ronkonkoma",
            }
            
            dests = {a.destination for a in arrivals}
            cross_contaminated = dests & lirr_only
            assert len(cross_contaminated) == 0, (
                f"MNR has LIRR-only destinations: {cross_contaminated}"
            )
        finally:
            loop.close()

    def test_lirr_nearby_returns_results(self):
        """Nearby LIRR near Jamaica should return arrivals."""
        loop = asyncio.new_event_loop()
        try:
            from app.routers.nearby import _fetch_nearby_rail
            results = loop.run_until_complete(
                _fetch_nearby_rail(40.699, -73.808, 5000, "lirr")
            )
            assert len(results) > 0, "No LIRR arrivals near Jamaica"
        finally:
            loop.close()

    def test_mnr_nearby_returns_results(self):
        """Nearby MNR near Grand Central should return arrivals."""
        loop = asyncio.new_event_loop()
        try:
            from app.routers.nearby import _fetch_nearby_rail
            results = loop.run_until_complete(
                _fetch_nearby_rail(40.753, -73.977, 5000, "mnr")
            )
            assert len(results) > 0, "No MNR arrivals near Grand Central"
        finally:
            loop.close()

    def test_bus_nearby_returns_stops(self):
        """Nearby bus stops around Jamaica should return stops."""
        loop = asyncio.new_event_loop()
        try:
            from app.services.bus_client import get_nearby_stops
            stops = loop.run_until_complete(
                get_nearby_stops(40.699, -73.808, radius_m=2000)
            )
            assert len(stops) > 0, "No bus stops found near Jamaica"
            # All stops should have direction field
            for s in stops:
                assert s.direction is not None, f"Stop {s.id} ({s.name}) has no direction"
        finally:
            loop.close()

    def test_bus_grouped_has_two_directions(self):
        """At least some bus routes near Jamaica should have 2 directions."""
        loop = asyncio.new_event_loop()
        try:
            from app.routers.nearby import _fetch_nearby_buses, _group_arrivals
            arrivals = loop.run_until_complete(
                _fetch_nearby_buses(40.699, -73.808, 2000)
            )
            groups = _group_arrivals(arrivals)
            
            routes_with_two_dirs = [
                g for g in groups if len(g.directions) >= 2
            ]
            assert len(routes_with_two_dirs) > 0, (
                "No bus routes have 2+ directions — DirectionRef grouping may be broken"
            )
        finally:
            loop.close()
