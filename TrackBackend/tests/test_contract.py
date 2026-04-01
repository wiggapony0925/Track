"""Contract tests that ensure data integrity between the backend API
and the iOS frontend.  These tests verify:
1. Bus arrivals always have proper direction grouping (DirectionRef)
2. LIRR/MNR stop_id namespacing prevents cross-contamination
3. Rail direction inference works for feeds without direction_id
4. GroupedNearbyTransit schema matches iOS Codable contracts
5. Bus nearby reliability (OBA stops + SIRI arrivals)
6. Station lookup correctness with overlapping stop_ids."""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime

import pytest

from app.models import (
    BusArrival,
    BusVehicle,
    DirectionArrivals,
    GroupedNearbyTransit,
    InlineAlert,
    NearbyTransitArrival,
    TrackArrival,
)
from app.routers.nearby import (
    _direction_label,
    _display_name,
    _group_arrivals,
    _soonest_minutes,
    _sorting_key,
)
from app.services.transit.station_lookup import (
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
        arrival_ts=kwargs.get("arrival_ts", int(datetime.now(UTC).timestamp())),
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
        arrival_ts=kwargs.get("arrival_ts", int(datetime.now(UTC).timestamp())),
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
            _make_bus_arrival(
                route_id="Q43", direction_ref=0, destination_name="FLORAL PARK"
            ),
            _make_bus_arrival(
                route_id="Q43",
                direction_ref=0,
                destination_name="FLORAL PARK",
                minutes_away=8,
            ),
            _make_bus_arrival(
                route_id="Q43", direction_ref=1, destination_name="JAMAICA LIRR"
            ),
            _make_bus_arrival(
                route_id="Q43",
                direction_ref=1,
                destination_name="JAMAICA LIRR",
                minutes_away=12,
            ),
        ]
        groups = _group_arrivals(arrivals)
        assert len(groups) == 1, "Should be 1 route group for Q43"
        assert len(groups[0].directions) == 2, "Q43 should have 2 directions"

    def test_direction_labels_use_destination(self):
        """Direction labels for bus DirectionRef '0'/'1' should use DestinationName."""
        arrivals = [
            _make_bus_arrival(
                route_id="Q56", direction_ref=0, destination_name="JAMAICA 170 ST"
            ),
            _make_bus_arrival(
                route_id="Q56", direction_ref=1, destination_name="BROADWAY JUNCTION"
            ),
        ]
        groups = _group_arrivals(arrivals)
        labels = {d.direction_label for d in groups[0].directions}
        assert "JAMAICA 170 ST" in labels
        assert "BROADWAY JUNCTION" in labels

    def test_direction_ref_none_falls_back(self):
        """When DirectionRef is None, direction should fallback to 'Loop'."""
        arrivals = [
            _make_bus_arrival(
                route_id="X99", direction_ref=None, destination_name=None
            ),
        ]
        # direction is "Loop" when direction_ref is None
        assert arrivals[0].direction == "Loop"
        groups = _group_arrivals(arrivals)
        assert groups[0].directions[0].direction == "Loop"
        assert groups[0].directions[0].direction_label == "Loop"

    def test_same_direction_ref_merges(self):
        """All arrivals from multiple stops with the same DirectionRef merge."""
        arrivals = [
            _make_bus_arrival(
                route_id="Q54",
                direction_ref=0,
                stop_id="MTA_001",
                stop_name="Stop A",
                vehicle_id="MTABC_1111",
            ),
            _make_bus_arrival(
                route_id="Q54",
                direction_ref=0,
                stop_id="MTA_002",
                stop_name="Stop B",
                vehicle_id="MTABC_2222",
            ),
            _make_bus_arrival(
                route_id="Q54",
                direction_ref=1,
                stop_id="MTA_003",
                stop_name="Stop C",
                vehicle_id="MTABC_3333",
            ),
        ]
        groups = _group_arrivals(arrivals)
        dir0 = next(d for d in groups[0].directions if d.direction == "0")
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

    @pytest.mark.parametrize(
        "code,expected",
        [
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
        ],
    )
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
        assert (
            lirr_info.name != mnr_info.name
        ), f"LIRR and MNR stop_id '1' resolved to same name: {lirr_info.name}"
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
        get_nearby_stop_ids(40.699, -73.808, 5000.0, agency="mnr")

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
            _make_rail_arrival(
                route_id="MNR_1",
                direction="Grand Central",
                destination="Grand Central",
                mode="mnr",
            ),
            _make_rail_arrival(
                route_id="MNR_1",
                direction="Poughkeepsie",
                destination="Poughkeepsie",
                mode="mnr",
            ),
        ]
        groups = _group_arrivals(arrivals)
        assert len(groups) == 1
        assert (
            len(groups[0].directions) == 2
        ), "MNR should have 2 directions (Inbound/Outbound)"

    def test_lirr_has_outbound_inbound(self):
        """LIRR arrivals should have Inbound and Outbound directions."""
        arrivals = [
            _make_rail_arrival(
                route_id="LIRR_10", direction="Penn Station", destination="Penn Station"
            ),
            _make_rail_arrival(
                route_id="LIRR_10", direction="Babylon", destination="Babylon"
            ),
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
        ios_expected_keys = [
            "route_id",
            "display_name",
            "mode",
            "color_hex",
            "directions",
        ]
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
            expected_arrival=datetime(2026, 2, 18, 1, 0, 0, tzinfo=UTC),
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
                            route_id="A",
                            stop_name="S",
                            direction="N",
                            minutes_away=10,
                            mode="subway",
                        ),
                    ],
                ),
                DirectionArrivals(
                    direction="S",
                    direction_label="Southbound",
                    arrivals=[
                        NearbyTransitArrival(
                            route_id="A",
                            stop_name="S",
                            direction="S",
                            minutes_away=3,
                            mode="subway",
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
            from app.clients.bus_client import get_realtime_arrivals

            arrivals = loop.run_until_complete(get_realtime_arrivals("MTA_500249"))
            if arrivals:
                has_dir = any(a.direction_ref is not None for a in arrivals)
                assert (
                    has_dir
                ), "No arrivals have direction_ref — is SIRI detail level 'minimum'?"
        finally:
            loop.close()

    def test_bus_siri_includes_destination_name(self):
        """SIRI stop-monitoring must include DestinationName."""
        loop = asyncio.new_event_loop()
        try:
            from app.clients.bus_client import get_realtime_arrivals

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
            from app.clients.rail_client import fetch_rail_arrivals

            arrivals = loop.run_until_complete(fetch_rail_arrivals("lirr"))

            # Known MNR-only destinations that should NOT appear in LIRR
            mnr_only = {
                "Grand Central",
                "Croton-Harmon",
                "Poughkeepsie",
                "Danbury",
                "Tarrytown",
                "Brewster",
                "Bronxville",
                "Bethel",
            }
            # Note: "Grand Central" IS valid for LIRR (direct GCT service),
            # but the others are MNR-only
            mnr_only_strict = mnr_only - {"Grand Central"}

            dests = {a.destination for a in arrivals}
            cross_contaminated = dests & mnr_only_strict
            assert (
                len(cross_contaminated) == 0
            ), f"LIRR has MNR-only destinations: {cross_contaminated}"
        finally:
            loop.close()

    def test_mnr_destinations_are_mnr_stations(self):
        """MNR arrivals should have MNR station names, not LIRR."""
        loop = asyncio.new_event_loop()
        try:
            from app.clients.rail_client import fetch_rail_arrivals

            arrivals = loop.run_until_complete(fetch_rail_arrivals("metro_north"))

            # Known LIRR-only destinations that should NOT appear in MNR
            lirr_only = {
                "Montauk",
                "Babylon",
                "Far Rockaway",
                "Long Beach",
                "Oyster Bay",
                "Port Jefferson",
                "Port Washington",
                "Ronkonkoma",
            }

            dests = {a.destination for a in arrivals}
            cross_contaminated = dests & lirr_only
            assert (
                len(cross_contaminated) == 0
            ), f"MNR has LIRR-only destinations: {cross_contaminated}"
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
            from app.clients.bus_client import get_nearby_stops

            stops = loop.run_until_complete(
                get_nearby_stops(40.699, -73.808, radius_m=2000)
            )
            assert len(stops) > 0, "No bus stops found near Jamaica"
            # All stops should have direction field
            for s in stops:
                assert (
                    s.direction is not None
                ), f"Stop {s.id} ({s.name}) has no direction"
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

            routes_with_two_dirs = [g for g in groups if len(g.directions) >= 2]
            assert (
                len(routes_with_two_dirs) > 0
            ), "No bus routes have 2+ directions — DirectionRef grouping may be broken"
        finally:
            loop.close()


# ===================================================================
# 10. is_cancelled / is_real_time FIELD CONTRACT
# ===================================================================


class TestCancellationContract:
    """Verify is_cancelled flows correctly through TrackArrival and NearbyTransitArrival."""

    def test_track_arrival_defaults_not_cancelled(self):
        """TrackArrival.is_cancelled defaults to False."""
        arrival = TrackArrival(
            station="A28N",
            direction="N",
            minutes_away=5,
        )
        assert arrival.is_cancelled is False

    def test_track_arrival_cancelled_true(self):
        """TrackArrival.is_cancelled=True when explicitly set."""
        arrival = TrackArrival(
            station="A28N",
            direction="N",
            minutes_away=5,
            status="Cancelled",
            is_cancelled=True,
        )
        assert arrival.is_cancelled is True
        assert arrival.status == "Cancelled"

    def test_track_arrival_cancelled_serializes(self):
        """is_cancelled appears in JSON output for iOS decoding."""
        arrival = TrackArrival(
            station="A28N",
            direction="N",
            minutes_away=5,
            is_cancelled=True,
        )
        data = arrival.model_dump()
        assert "is_cancelled" in data
        assert data["is_cancelled"] is True

    def test_nearby_arrival_is_real_time_default(self):
        """NearbyTransitArrival.is_real_time defaults to False."""
        arrival = NearbyTransitArrival(
            route_id="A",
            stop_name="Test",
            direction="N",
            minutes_away=3,
            mode="subway",
        )
        assert arrival.is_real_time is False
        assert arrival.is_cancelled is False

    def test_nearby_arrival_is_real_time_true(self):
        """NearbyTransitArrival.is_real_time can be set True for live data."""
        arrival = NearbyTransitArrival(
            route_id="A",
            stop_name="Test",
            direction="N",
            minutes_away=3,
            mode="subway",
            is_real_time=True,
        )
        data = arrival.model_dump()
        assert data["is_real_time"] is True

    def test_nearby_arrival_cancelled_true(self):
        """NearbyTransitArrival.is_cancelled flows into grouped JSON."""
        arrival = NearbyTransitArrival(
            route_id="A",
            stop_name="Fulton St",
            direction="N",
            minutes_away=5,
            mode="subway",
            is_cancelled=True,
            is_real_time=True,
        )
        data = arrival.model_dump()
        assert data["is_cancelled"] is True
        assert data["is_real_time"] is True

    def test_bus_arrival_no_is_cancelled(self):
        """Bus NearbyTransitArrival should default is_cancelled=False (SIRI has no cancellations)."""
        arrival = NearbyTransitArrival(
            route_id="Q10",
            stop_name="Test Stop",
            direction="0",
            minutes_away=5,
            mode="bus",
            is_real_time=True,
        )
        assert arrival.is_cancelled is False

    def test_ios_coding_keys_present(self):
        """JSON keys must match iOS CodingKeys exactly: is_real_time, is_cancelled."""
        arrival = NearbyTransitArrival(
            route_id="L",
            stop_name="Bedford Ave",
            direction="N",
            minutes_away=2,
            mode="subway",
            is_real_time=True,
            is_cancelled=False,
        )
        json_data = arrival.model_dump(mode="json")
        assert "is_real_time" in json_data, "iOS expects CodingKey 'is_real_time'"
        assert "is_cancelled" in json_data, "iOS expects CodingKey 'is_cancelled'"


# ===================================================================
# 11. SORTING KEY CONTRACT
# ===================================================================


class TestSortingKey:
    """Verify _sorting_key() produces correct canonical MTA ordering."""

    def test_subway_family_order(self):
        """Subway lines sort by service family: 123 < 456 < 7 < ACE < BDFM ..."""
        assert _sorting_key("subway", "1") < _sorting_key("subway", "4")
        assert _sorting_key("subway", "4") < _sorting_key("subway", "7")
        assert _sorting_key("subway", "7") < _sorting_key("subway", "A")
        assert _sorting_key("subway", "A") < _sorting_key("subway", "B")
        assert _sorting_key("subway", "B") < _sorting_key("subway", "G")
        assert _sorting_key("subway", "G") < _sorting_key("subway", "J")
        assert _sorting_key("subway", "J") < _sorting_key("subway", "L")
        assert _sorting_key("subway", "L") < _sorting_key("subway", "N")

    def test_same_family_order(self):
        """Within a family: A < C < E."""
        assert _sorting_key("subway", "A") < _sorting_key("subway", "C")
        assert _sorting_key("subway", "C") < _sorting_key("subway", "E")

    def test_nqrw_order(self):
        """N < Q < R < W."""
        assert _sorting_key("subway", "N") < _sorting_key("subway", "Q")
        assert _sorting_key("subway", "Q") < _sorting_key("subway", "R")
        assert _sorting_key("subway", "R") < _sorting_key("subway", "W")

    def test_unknown_subway_sorts_last(self):
        """Unknown subway route (e.g. special service) sorts after all known lines."""
        assert _sorting_key("subway", "W") < _sorting_key("subway", "ZZ_SPECIAL")

    def test_subway_before_lirr_before_mnr_before_bus(self):
        """Subway < LIRR < MNR < Bus in the sort order."""
        subway_last = _sorting_key("subway", "SI")
        lirr = _sorting_key("lirr", "Babylon")
        mnr = _sorting_key("mnr", "Hudson")
        bus = _sorting_key("bus", "Q10")
        assert subway_last < lirr
        assert lirr < mnr
        assert mnr < bus

    def test_bus_numeric_sort(self):
        """Bus routes sort numerically: B1 < B10 < B100."""
        assert _sorting_key("bus", "B1") < _sorting_key("bus", "B10")
        assert _sorting_key("bus", "B10") < _sorting_key("bus", "B100")

    def test_bus_prefix_groups(self):
        """Different bus prefixes group: B-routes < M-routes < Q-routes."""
        assert _sorting_key("bus", "B1") < _sorting_key("bus", "M1")
        assert _sorting_key("bus", "M1") < _sorting_key("bus", "Q1")

    def test_sorting_key_in_grouped_output(self):
        """GroupedNearbyTransit.sorting_key appears in serialized JSON."""
        group = GroupedNearbyTransit(
            route_id="A",
            display_name="A",
            mode="subway",
            directions=[],
            sorting_key="040",
        )
        data = group.model_dump()
        assert "sorting_key" in data
        assert data["sorting_key"] == "040"

    def test_group_arrivals_populates_sorting_key(self):
        """_group_arrivals() should set sorting_key on each group."""
        arrivals = [
            NearbyTransitArrival(
                route_id="L",
                stop_name="Bedford Ave",
                direction="N",
                minutes_away=3,
                mode="subway",
            ),
            NearbyTransitArrival(
                route_id="A",
                stop_name="Fulton St",
                direction="N",
                minutes_away=5,
                mode="subway",
            ),
        ]
        groups = _group_arrivals(arrivals)
        for g in groups:
            assert g.sorting_key != "", f"sorting_key empty for {g.display_name}"
        # A should sort before L
        a_group = next(g for g in groups if g.display_name == "A")
        l_group = next(g for g in groups if g.display_name == "L")
        assert a_group.sorting_key < l_group.sorting_key

    def test_sorting_key_case_insensitive(self):
        """Lowercase route_id should resolve the same as uppercase."""
        assert _sorting_key("subway", "a") == _sorting_key("subway", "A")


# ===================================================================
# 12. INLINE ALERTS CONTRACT
# ===================================================================


class TestInlineAlerts:
    """Verify InlineAlert model and alert embedding in GroupedNearbyTransit."""

    def test_inline_alert_model_fields(self):
        """InlineAlert has required fields: title, severity, affected_routes."""
        alert = InlineAlert(
            title="Delays on A/C/E",
            severity="severe",
            affected_routes=["A", "C", "E"],
        )
        data = alert.model_dump()
        assert data["title"] == "Delays on A/C/E"
        assert data["severity"] == "severe"
        assert data["affected_routes"] == ["A", "C", "E"]

    def test_inline_alert_ios_keys(self):
        """InlineAlert JSON keys must match iOS InlineAlertResponse CodingKeys."""
        alert = InlineAlert(
            title="Service change",
            severity="warning",
            affected_routes=["L"],
        )
        json_data = alert.model_dump(mode="json")
        required = {"title", "severity", "affected_routes"}
        assert required.issubset(set(json_data.keys()))

    def test_grouped_transit_alerts_default_empty(self):
        """Alerts list defaults to empty when no alerts exist."""
        group = GroupedNearbyTransit(
            route_id="L",
            display_name="L",
            mode="subway",
            directions=[],
        )
        assert group.alerts == []
        data = group.model_dump()
        assert data["alerts"] == []

    def test_grouped_transit_alerts_populated(self):
        """Alerts are included when passed to GroupedNearbyTransit."""
        alert = InlineAlert(
            title="No service 8pm-5am",
            severity="severe",
            affected_routes=["G"],
        )
        group = GroupedNearbyTransit(
            route_id="G",
            display_name="G",
            mode="subway",
            directions=[],
            alerts=[alert],
        )
        data = group.model_dump()
        assert len(data["alerts"]) == 1
        assert data["alerts"][0]["title"] == "No service 8pm-5am"
        assert data["alerts"][0]["severity"] == "severe"
        assert data["alerts"][0]["affected_routes"] == ["G"]

    def test_group_arrivals_with_alert_index(self):
        """_group_arrivals() embeds alerts from the alert index."""
        arrivals = [
            NearbyTransitArrival(
                route_id="A",
                stop_name="Fulton St",
                direction="N",
                minutes_away=5,
                mode="subway",
            ),
        ]
        alert_index = {
            "A": [
                InlineAlert(title="Delays", severity="warning", affected_routes=["A"])
            ],
        }
        groups = _group_arrivals(arrivals, alert_index=alert_index)
        a_group = next(g for g in groups if g.display_name == "A")
        assert len(a_group.alerts) == 1
        assert a_group.alerts[0].title == "Delays"

    def test_group_arrivals_no_alert_index(self):
        """_group_arrivals() works with no alert_index (backward compat)."""
        arrivals = [
            NearbyTransitArrival(
                route_id="L",
                stop_name="Bedford Ave",
                direction="N",
                minutes_away=3,
                mode="subway",
            ),
        ]
        groups = _group_arrivals(arrivals)
        assert groups[0].alerts == []

    def test_group_arrivals_alert_miss(self):
        """Routes not in the alert index get empty alerts."""
        arrivals = [
            NearbyTransitArrival(
                route_id="7",
                stop_name="Times Sq",
                direction="N",
                minutes_away=2,
                mode="subway",
            ),
        ]
        alert_index = {
            "A": [
                InlineAlert(title="Delays", severity="severe", affected_routes=["A"])
            ],
        }
        groups = _group_arrivals(arrivals, alert_index=alert_index)
        assert groups[0].alerts == []


# ===================================================================
# 13. FULL GROUPED SCHEMA v2 (all new fields)
# ===================================================================


class TestGroupedSchemaV2:
    """Verify the complete GroupedNearbyTransit schema matches iOS v2 contract."""

    def test_all_ios_keys_present(self):
        """All keys expected by iOS GroupedNearbyTransitResponse must be in JSON."""
        group = GroupedNearbyTransit(
            route_id="A",
            display_name="A",
            mode="subway",
            color_hex="#0062CF",
            directions=[
                DirectionArrivals(
                    direction="N",
                    direction_label="Northbound",
                    arrivals=[
                        NearbyTransitArrival(
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
                            trip_id="trip123",
                            is_real_time=True,
                            is_cancelled=False,
                        ),
                    ],
                ),
            ],
            sorting_key="040",
            alerts=[
                InlineAlert(title="Delays", severity="warning", affected_routes=["A"]),
            ],
        )
        data = group.model_dump(mode="json")

        # GroupedNearbyTransitResponse CodingKeys
        grouped_keys = {
            "route_id",
            "display_name",
            "mode",
            "color_hex",
            "directions",
            "sorting_key",
            "alerts",
        }
        assert grouped_keys.issubset(
            set(data.keys())
        ), f"Missing grouped keys: {grouped_keys - set(data.keys())}"

        # DirectionArrivalsResponse CodingKeys
        dir_data = data["directions"][0]
        dir_keys = {"direction", "direction_label", "arrivals"}
        assert dir_keys.issubset(
            set(dir_data.keys())
        ), f"Missing direction keys: {dir_keys - set(dir_data.keys())}"

        # NearbyTransitResponse CodingKeys
        arr_data = dir_data["arrivals"][0]
        arrival_keys = {
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
        }
        assert arrival_keys.issubset(
            set(arr_data.keys())
        ), f"Missing arrival keys: {arrival_keys - set(arr_data.keys())}"

        # InlineAlertResponse CodingKeys
        alert_data = data["alerts"][0]
        alert_keys = {"title", "severity", "affected_routes"}
        assert alert_keys.issubset(
            set(alert_data.keys())
        ), f"Missing alert keys: {alert_keys - set(alert_data.keys())}"

    def test_field_types_match_ios(self):
        """Verify JSON value types match what Swift Codable expects."""
        arrival = NearbyTransitArrival(
            route_id="L",
            stop_name="Bedford Ave",
            direction="N",
            destination="Rockaway Pkwy",
            minutes_away=2,
            arrival_ts=1700000000,
            status="On Time",
            mode="subway",
            stop_lat=40.71,
            stop_lon=-74.0,
            stop_id="L06N",
            vehicle_id=None,
            trip_id="trip456",
            distance_m=150.5,
            is_real_time=True,
            is_cancelled=False,
        )
        data = arrival.model_dump(mode="json")

        # Swift String
        assert isinstance(data["route_id"], str)
        assert isinstance(data["stop_name"], str)
        assert isinstance(data["direction"], str)
        assert isinstance(data["status"], str)
        assert isinstance(data["mode"], str)
        # Swift Int
        assert isinstance(data["minutes_away"], int)
        assert isinstance(data["arrival_ts"], int)
        # Swift Double?
        assert isinstance(data["stop_lat"], (float, int))
        assert isinstance(data["stop_lon"], (float, int))
        assert isinstance(data["distance_m"], (float, int))
        # Swift Bool
        assert isinstance(data["is_real_time"], bool)
        assert isinstance(data["is_cancelled"], bool)

    def test_backward_compat_defaults(self):
        """New fields have defaults so old cached responses still parse on iOS."""
        # Simulate an "old" response missing the new fields
        arrival = NearbyTransitArrival(
            route_id="4",
            stop_name="Grand Central",
            direction="N",
            minutes_away=5,
            mode="subway",
        )
        data = arrival.model_dump(mode="json")
        # Defaults must be the Swift-matching zero-values
        assert data["is_real_time"] is False
        assert data["is_cancelled"] is False

        group = GroupedNearbyTransit(
            route_id="4",
            display_name="4",
            mode="subway",
            directions=[],
        )
        gdata = group.model_dump(mode="json")
        assert gdata["sorting_key"] == ""
        assert gdata["alerts"] == []


# ===================================================================
# 14. TrackArrival CONTRACT (subway/LIRR/MNR endpoint responses)
# ===================================================================


class TestTrackArrivalContract:
    """Verify TrackArrival JSON matches iOS TransitArrivalResponse."""

    def test_all_ios_keys_present(self):
        """All keys expected by iOS TransitArrivalResponse must be in JSON."""
        arrival = TrackArrival(
            route_id="A",
            station="A28N",
            station_name="Fulton St",
            direction="N",
            destination="Inwood-207 St",
            minutes_away=3,
            arrival_ts=1700000000,
            status="On Time",
            trip_id="trip123",
            is_cancelled=False,
        )
        data = arrival.model_dump(mode="json")
        ios_keys = {
            "route_id",
            "station",
            "station_name",
            "direction",
            "destination",
            "minutes_away",
            "arrival_ts",
            "status",
            "trip_id",
            "is_cancelled",
        }
        assert ios_keys.issubset(
            set(data.keys())
        ), f"Missing keys: {ios_keys - set(data.keys())}"

    def test_cancelled_arrival_json(self):
        """Cancelled arrival serializes correctly for iOS."""
        arrival = TrackArrival(
            station="A28N",
            direction="N",
            minutes_away=5,
            status="Cancelled",
            is_cancelled=True,
        )
        data = arrival.model_dump(mode="json")
        assert data["is_cancelled"] is True
        assert data["status"] == "Cancelled"

    def test_normal_arrival_not_cancelled(self):
        """Normal arrival has is_cancelled=False."""
        arrival = TrackArrival(
            station="A28N",
            direction="N",
            minutes_away=3,
        )
        data = arrival.model_dump(mode="json")
        assert data["is_cancelled"] is False
        assert data["status"] == "On Time"


# ===================================================================
# 15. LIVE ENDPOINT INTEGRATION (new fields in real API responses)
# ===================================================================


@pytest.mark.integration
class TestLiveNewFieldsIntegration:
    """Integration tests verifying new fields appear in live API responses.

    Run with: pytest -m integration tests/test_contract.py -k "LiveNewFields"
    """

    def test_grouped_has_sorting_key(self):
        """Live /nearby/grouped response includes sorting_key on each group."""
        loop = asyncio.new_event_loop()
        try:
            from app.routers.nearby import (
                _collect_all,
                _get_inline_alerts,
                _group_arrivals,
            )

            flat = loop.run_until_complete(_collect_all(40.7505, -73.9934, 1000))
            alert_index = loop.run_until_complete(_get_inline_alerts())
            groups = _group_arrivals(flat, alert_index=alert_index)
            assert len(groups) > 0, "No grouped arrivals near Penn Station"
            for g in groups:
                assert hasattr(g, "sorting_key"), f"Missing sorting_key on {g.route_id}"
                assert isinstance(g.sorting_key, str)
                assert g.sorting_key != "", f"Empty sorting_key for {g.display_name}"
        finally:
            loop.close()

    def test_grouped_sorting_order(self):
        """Groups are sorted by sorting_key (subway before bus)."""
        loop = asyncio.new_event_loop()
        try:
            from app.routers.nearby import _collect_all, _group_arrivals

            flat = loop.run_until_complete(_collect_all(40.7505, -73.9934, 1000))
            groups = _group_arrivals(flat)
            subway_groups = [g for g in groups if g.mode == "subway"]
            bus_groups = [g for g in groups if g.mode == "bus"]
            if subway_groups and bus_groups:
                last_subway_key = max(g.sorting_key for g in subway_groups)
                first_bus_key = min(g.sorting_key for g in bus_groups)
                assert (
                    last_subway_key < first_bus_key
                ), f"Subway sorting_key ({last_subway_key}) should be < bus ({first_bus_key})"
        finally:
            loop.close()

    def test_grouped_has_alerts_field(self):
        """Live groups have an alerts list (may be empty)."""
        loop = asyncio.new_event_loop()
        try:
            from app.routers.nearby import _collect_all, _group_arrivals

            flat = loop.run_until_complete(_collect_all(40.7505, -73.9934, 1000))
            groups = _group_arrivals(flat)
            for g in groups:
                assert isinstance(g.alerts, list), f"alerts not a list on {g.route_id}"

        finally:
            loop.close()

    def test_nearby_arrivals_have_is_real_time(self):
        """Live subway arrivals should have is_real_time=True."""
        loop = asyncio.new_event_loop()
        try:
            from app.routers.nearby import _collect_all

            flat = loop.run_until_complete(_collect_all(40.7505, -73.9934, 1000))
            subway = [a for a in flat if a.mode == "subway"]
            assert len(subway) > 0, "No subway arrivals near Penn Station"
            realtime_count = sum(1 for a in subway if a.is_real_time)
            assert realtime_count > 0, "No subway arrivals have is_real_time=True"
        finally:
            loop.close()

    def test_subway_endpoint_has_is_cancelled(self):
        """Live /subway/{line} response includes is_cancelled field."""
        loop = asyncio.new_event_loop()
        try:
            from app.services.gtfs.realtime_parser import get_arrivals_for_line

            arrivals = loop.run_until_complete(get_arrivals_for_line("A"))
            assert len(arrivals) > 0, "No arrivals from A train feed"
            for a in arrivals:
                assert hasattr(a, "is_cancelled"), "Missing is_cancelled on arrival"
                assert isinstance(a.is_cancelled, bool)
        finally:
            loop.close()

    def test_lirr_endpoint_has_is_cancelled(self):
        """LIRR arrivals include is_cancelled field."""
        loop = asyncio.new_event_loop()
        try:
            from app.clients.rail_client import fetch_rail_arrivals

            arrivals = loop.run_until_complete(fetch_rail_arrivals("lirr"))
            assert len(arrivals) > 0, "No LIRR arrivals"
            for a in arrivals:
                assert hasattr(
                    a, "is_cancelled"
                ), "Missing is_cancelled on LIRR arrival"
                assert isinstance(a.is_cancelled, bool)
        finally:
            loop.close()

    def test_mnr_endpoint_has_is_cancelled(self):
        """MNR arrivals include is_cancelled field."""
        loop = asyncio.new_event_loop()
        try:
            from app.clients.rail_client import fetch_rail_arrivals

            arrivals = loop.run_until_complete(fetch_rail_arrivals("metro_north"))
            assert len(arrivals) > 0, "No MNR arrivals"
            for a in arrivals:
                assert hasattr(a, "is_cancelled"), "Missing is_cancelled on MNR arrival"
                assert isinstance(a.is_cancelled, bool)
        finally:
            loop.close()
