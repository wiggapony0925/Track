"""Tests for service-variant classification and headsign similarity."""

from __future__ import annotations

import pytest

from app.models import NearbyTransitArrival
from app.services.transit.service_variant import (
    ServiceVariant,
    classify_variant,
    derive_display_label,
)
from app.services.transit.headsign_similarity import (
    cluster_arrivals_by_terminus,
    cluster_headsigns,
    headsigns_describe_same_terminus,
    normalise_headsign,
)


def _arr(
    *,
    route_id: str = "7",
    mode: str = "subway",
    destination: str | None = None,
    bus_service_type: str | None = None,
    direction: str = "Northbound",
) -> NearbyTransitArrival:
    return NearbyTransitArrival(
        route_id=route_id,
        stop_name="Test Stop",
        direction=direction,
        destination=destination,
        minutes_away=3,
        status="On Time",
        mode=mode,
        bus_service_type=bus_service_type,
    )


# ──────────────────────────── ServiceVariant ───────────────────────────────


class TestSubwayVariantClassification:
    def test_local_subway_route(self):
        assert classify_variant(_arr(route_id="7", mode="subway")) == ServiceVariant.LOCAL

    def test_express_variant_route(self):
        assert classify_variant(_arr(route_id="7X", mode="subway")) == ServiceVariant.EXPRESS
        assert classify_variant(_arr(route_id="6X", mode="subway")) == ServiceVariant.EXPRESS
        assert classify_variant(_arr(route_id="FX", mode="subway")) == ServiceVariant.EXPRESS

    def test_shuttle_routes(self):
        assert classify_variant(_arr(route_id="GS", mode="subway")) == ServiceVariant.SHUTTLE
        assert classify_variant(_arr(route_id="H", mode="subway")) == ServiceVariant.SHUTTLE
        assert classify_variant(_arr(route_id="FS", mode="subway")) == ServiceVariant.SHUTTLE

    def test_route_id_with_agency_prefix(self):
        assert classify_variant(
            _arr(route_id="MTA NYCT_7X", mode="subway")
        ) == ServiceVariant.EXPRESS

    def test_express_parent_routes_stay_local(self):
        # The A/B/D/E run express in segments but the *route* is express;
        # they shouldn't render an Express pill on every arrival.
        for rid in ["A", "B", "D", "E", "2", "3", "4", "5", "N", "Q"]:
            assert classify_variant(_arr(route_id=rid, mode="subway")) == ServiceVariant.LOCAL


class TestBusVariantClassification:
    def test_local_bus(self):
        assert classify_variant(
            _arr(route_id="B63", mode="bus", bus_service_type="Local")
        ) == ServiceVariant.LOCAL

    def test_limited_bus(self):
        assert classify_variant(
            _arr(route_id="Bx1", mode="bus", bus_service_type="Limited")
        ) == ServiceVariant.LIMITED

    def test_local_limited_normalised_to_limited(self):
        assert classify_variant(
            _arr(route_id="B41", mode="bus", bus_service_type="Local / Limited")
        ) == ServiceVariant.LIMITED

    def test_sbs_bus(self):
        assert classify_variant(
            _arr(route_id="M15+", mode="bus", bus_service_type="Select Bus Service")
        ) == ServiceVariant.SBS

    def test_express_bus(self):
        assert classify_variant(
            _arr(route_id="X27", mode="bus", bus_service_type="Express")
        ) == ServiceVariant.EXPRESS

    def test_headsign_super_express_overrides_express(self):
        a = _arr(
            route_id="BM3",
            mode="bus",
            bus_service_type="Express",
            destination="SUPER EXPRESS MIDTOWN 57 ST via MADISON AV",
        )
        assert classify_variant(a) == ServiceVariant.SUPER_EXPRESS

    def test_headsign_limited_promotes_local_to_limited(self):
        a = _arr(
            route_id="Bx36",
            mode="bus",
            bus_service_type="Local",
            destination="LIMITED SOUNDVIEW via TREMONT AV",
        )
        assert classify_variant(a) == ServiceVariant.LIMITED

    def test_unknown_service_type_falls_back_unknown(self):
        a = _arr(
            route_id="ZZ1",
            mode="bus",
            bus_service_type="UnrecognisedTypeXYZ",
            destination="Somewhere",
        )
        assert classify_variant(a) == ServiceVariant.UNKNOWN


class TestRailVariantClassification:
    def test_lirr_returns_local(self):
        assert classify_variant(_arr(route_id="LIRR_9", mode="lirr")) == ServiceVariant.LOCAL

    def test_mnr_returns_local(self):
        assert classify_variant(_arr(route_id="MNR_1", mode="mnr")) == ServiceVariant.LOCAL


class TestDeriveDisplayLabel:
    def test_super_express_extracts_via_suffix(self):
        a = _arr(
            route_id="BM3",
            mode="bus",
            bus_service_type="Express",
            destination="SUPER EXPRESS MIDTOWN 57 ST via MADISON AV",
        )
        label = derive_display_label(ServiceVariant.SUPER_EXPRESS, a)
        assert label is not None
        assert "via" in label.lower()

    def test_local_returns_none(self):
        a = _arr(route_id="7", mode="subway", destination="Flushing-Main St")
        assert derive_display_label(ServiceVariant.LOCAL, a) is None


class TestModelAutoBackfill:
    def test_arrival_auto_classifies_variant(self):
        a = NearbyTransitArrival(
            route_id="7X",
            stop_name="Times Sq",
            direction="Queensbound",
            destination="Flushing",
            minutes_away=2,
            status="On Time",
            mode="subway",
        )
        assert a.service_variant == ServiceVariant.EXPRESS.value

    def test_arrival_with_explicit_variant_preserved(self):
        a = NearbyTransitArrival(
            route_id="B63",
            stop_name="Atlantic Av",
            direction="Bay Ridge",
            destination="Bay Ridge - 95 St",
            minutes_away=4,
            status="On Time",
            mode="bus",
            service_variant="limited",
        )
        # Explicit variant should NOT be overwritten by post-init.
        assert a.service_variant == "limited"


# ────────────────────────── Headsign Similarity ────────────────────────────


class TestNormaliseHeadsign:
    def test_strips_via_suffix(self):
        assert normalise_headsign("KINGS PLAZA via FLATBUSH AV") == "KINGS PLAZA"

    def test_strips_limited_prefix(self):
        assert normalise_headsign("LIMITED SOUNDVIEW") == "SOUNDVIEW"
        assert normalise_headsign("LTD KINGS PLAZA") == "KINGS PLAZA"

    def test_strips_sbs_prefix(self):
        assert normalise_headsign("SBS AVENUE U") == "AVENUE U"
        assert normalise_headsign("SELECT BUS SERVICE AVE X") == "AVE X"

    def test_strips_super_express_prefix(self):
        assert normalise_headsign("SUPER EXPRESS MIDTOWN 57 ST") == "MIDTOWN 57 ST"

    def test_handles_punctuation(self):
        assert normalise_headsign("Inwood-207 St") == "INWOOD 207 ST"
        assert normalise_headsign("Far Rockaway-Mott Av") == "FAR ROCKAWAY MOTT AV"

    def test_empty_input(self):
        assert normalise_headsign("") == ""
        assert normalise_headsign(None) == ""

    def test_collapses_whitespace(self):
        assert normalise_headsign("LIMITED   SOUNDVIEW   via   TREMONT") == "SOUNDVIEW"


class TestHeadsignsDescribeSameTerminus:
    def test_identical(self):
        assert headsigns_describe_same_terminus("Flushing", "Flushing")

    def test_short_form_vs_long_form(self):
        # The 7 train bug: collapses these into one.
        assert headsigns_describe_same_terminus("Flushing", "Flushing-Main St")
        assert headsigns_describe_same_terminus("Ditmars Blvd", "Astoria-Ditmars Blvd")

    def test_distinct_branches_stay_split(self):
        # The A train: should NOT merge.
        assert not headsigns_describe_same_terminus(
            "Inwood-207 St", "Far Rockaway-Mott Av"
        )
        assert not headsigns_describe_same_terminus(
            "Ozone Park-Lefferts Blvd", "Far Rockaway-Mott Av"
        )

    def test_limited_vs_local_same_terminus(self):
        # Bus: B41 limited vs local to same place should merge.
        assert headsigns_describe_same_terminus(
            "KINGS PLAZA via FLATBUSH AV",
            "LIMITED KINGS PLAZA via FLATBUSH AV",
        )

    def test_empty_inputs_dont_match(self):
        assert not headsigns_describe_same_terminus("", "Flushing")
        assert not headsigns_describe_same_terminus("Flushing", "")
        assert not headsigns_describe_same_terminus(None, None)

    def test_distinct_compass_termini_stay_split(self):
        assert not headsigns_describe_same_terminus(
            "Crown Hts-Utica Av", "Flatbush Av-Brooklyn College"
        )


class TestClusterHeadsigns:
    def test_single_terminus_one_cluster(self):
        result = cluster_headsigns(["Flushing", "Flushing-Main St", "Flushing"])
        assert result == [[0, 1, 2]]

    def test_a_train_three_branches(self):
        result = cluster_headsigns(
            [
                "Inwood-207 St",
                "Far Rockaway-Mott Av",
                "Ozone Park-Lefferts Blvd",
                "Far Rockaway-Mott Av",
            ]
        )
        # Inwood alone, then Far Rockaway + dup, then Lefferts.
        assert len(result) == 3
        assert [0] in result
        assert [2] in result
        assert sorted([1, 3]) in [sorted(c) for c in result]

    def test_empty_input(self):
        assert cluster_headsigns([]) == []


class TestClusterArrivalsByTerminus:
    def test_clusters_by_destination(self):
        arrs = [
            _arr(destination="Flushing"),
            _arr(destination="Flushing-Main St"),
            _arr(destination="34 St-Hudson Yards"),
        ]
        result = cluster_arrivals_by_terminus(arrs, key="destination")
        assert len(result) == 2

    def test_falls_back_to_direction_when_destination_missing(self):
        arrs = [
            _arr(destination=None, direction="Inwood-207 St"),
            _arr(destination=None, direction="Inwood-207 St"),
        ]
        result = cluster_arrivals_by_terminus(arrs, key="destination")
        assert len(result) == 1

    def test_empty_input(self):
        assert cluster_arrivals_by_terminus([]) == []
