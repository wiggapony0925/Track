from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
AUDIT_PATH = ROOT / "scripts" / "audit_live_tracking.py"

spec = importlib.util.spec_from_file_location("audit_live_tracking", AUDIT_PATH)
assert spec is not None
audit_live_tracking = importlib.util.module_from_spec(spec)
sys.modules["audit_live_tracking"] = audit_live_tracking
assert spec.loader is not None
spec.loader.exec_module(audit_live_tracking)


def test_scorecard_refuses_better_than_transit_without_transit_sample() -> None:
    track = [
        audit_live_tracking.TrackVehicleSummary(
            mode="bus",
            route_id="B63",
            endpoint="/bus/live-vehicles/B63",
            vehicle_count=1,
            with_stable_identity_count=1,
            with_position_count=1,
            with_confidence_count=1,
            elapsed_ms=120,
        )
    ]

    scorecard = audit_live_tracking.build_superiority_scorecard(track, None)

    assert scorecard["verdict"] == "not_proven_yet"
    assert scorecard["proven_better_than_transit"] is False
    assert scorecard["can_claim_publicly"] is False


def test_scorecard_proves_only_when_quality_and_transit_gate_pass() -> None:
    track = [
        audit_live_tracking.TrackVehicleSummary(
            mode="subway",
            route_id="A",
            endpoint="/subway/live-vehicles/A",
            vehicle_count=2,
            with_stable_identity_count=2,
            with_position_count=2,
            with_confidence_count=2,
            elapsed_ms=90,
        )
    ]
    transit = audit_live_tracking.TransitNearbySummary(
        lat=40.75529,
        lon=-73.987495,
        route_count=8,
        departure_count=20,
        realtime_departure_count=18,
        elapsed_ms=250,
    )

    scorecard = audit_live_tracking.build_superiority_scorecard(track, transit)

    assert scorecard["verdict"] == "proven_for_measured_categories"
    assert scorecard["proven_better_than_transit"] is True
    assert scorecard["can_claim_publicly"] is True


def test_scorecard_fails_when_track_contract_has_missing_confidence() -> None:
    track = [
        audit_live_tracking.TrackVehicleSummary(
            mode="bus",
            route_id="B63",
            endpoint="/bus/live-vehicles/B63",
            vehicle_count=2,
            with_stable_identity_count=2,
            with_position_count=2,
            with_confidence_count=1,
            elapsed_ms=90,
        )
    ]
    transit = audit_live_tracking.TransitNearbySummary(
        lat=40.75529,
        lon=-73.987495,
        route_count=8,
        departure_count=20,
        realtime_departure_count=18,
        elapsed_ms=250,
    )

    scorecard = audit_live_tracking.build_superiority_scorecard(track, transit)

    assert scorecard["proven_better_than_transit"] is False
    confidence_gate = next(
        gate for gate in scorecard["gates"] if gate["name"] == "confidence_transparency"
    )
    assert confidence_gate["passed"] is False