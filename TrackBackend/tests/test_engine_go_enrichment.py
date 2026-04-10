"""Realtime/alert enrichment tests for the Go endpoint service layer."""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime
from typing import TYPE_CHECKING

from app.models import TrackArrival, TransitAlert
from app.services.track_engine.domain import (
    GoResponse,
    GoTrip,
    Itinerary,
    LocationInput,
    PlanRequest,
    TransitLeg,
)
from app.services.track_engine.service import TrackEngineService

if TYPE_CHECKING:
    from pathlib import Path


def _timestamp(hour: int, minute: int) -> int:
    return int(datetime(2026, 4, 11, hour, minute, tzinfo=UTC).timestamp())


def _empty_db(path: Path) -> None:
    sqlite3.connect(path).close()


def test_go_enrichment_reranks_live_trip_above_delayed_trip(
    tmp_path: Path,
    monkeypatch,
) -> None:
    schedule_db = tmp_path / "schedule.db"
    state_db = tmp_path / "state.db"
    _empty_db(schedule_db)

    monkeypatch.setenv("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "1")
    service = TrackEngineService(schedule_db=schedule_db, state_db=state_db)

    bad_trip = GoTrip(
        itinerary=Itinerary(
            itinerary_id="bad-trip",
            leave_at_ts=_timestamp(8, 0),
            arrive_at_ts=_timestamp(8, 20),
            total_duration_s=20 * 60,
            in_vehicle_s=20 * 60,
            walking_s=0,
            waiting_s=0,
            transfer_count=0,
            walk_meters=0.0,
            score=1.0,
            summary="E",
            legs=[
                TransitLeg(
                    mode="subway",
                    route_id="R_BAD",
                    route_name="E",
                    color_hex="#2850AD",
                    headsign="World Trade Center",
                    trip_id="TRIP_BAD",
                    board_stop_id="STOP_BOARD_BAD",
                    board_stop_name="Jamaica Center-Parsons/Archer",
                    alight_stop_id="STOP_ALIGHT_BAD",
                    alight_stop_name="34 St-Penn Station",
                    departure_ts=_timestamp(8, 0),
                    arrival_ts=_timestamp(8, 20),
                    duration_s=20 * 60,
                    stop_count=8,
                )
            ],
        )
    )
    good_trip = GoTrip(
        itinerary=Itinerary(
            itinerary_id="good-trip",
            leave_at_ts=_timestamp(8, 3),
            arrive_at_ts=_timestamp(8, 24),
            total_duration_s=21 * 60,
            in_vehicle_s=21 * 60,
            walking_s=0,
            waiting_s=0,
            transfer_count=0,
            walk_meters=0.0,
            score=2.0,
            summary="E",
            legs=[
                TransitLeg(
                    mode="subway",
                    route_id="R_GOOD",
                    route_name="E",
                    color_hex="#2850AD",
                    headsign="World Trade Center",
                    trip_id="TRIP_GOOD",
                    board_stop_id="STOP_BOARD_GOOD",
                    board_stop_name="Jamaica Center-Parsons/Archer",
                    alight_stop_id="STOP_ALIGHT_GOOD",
                    alight_stop_name="34 St-Penn Station",
                    departure_ts=_timestamp(8, 3),
                    arrival_ts=_timestamp(8, 24),
                    duration_s=21 * 60,
                    stop_count=8,
                )
            ],
        )
    )

    remote_response = GoResponse(
        engine_version="0.3.0",
        requested_at_ts=_timestamp(7, 59),
        now_ts=_timestamp(7, 58),
        origin=LocationInput(label="Home", lat=40.7, lon=-73.8),
        destination=LocationInput(label="Work", lat=40.75, lon=-73.99),
        session_kind="depart_at",
        primary_trip=bad_trip,
        alternatives=[good_trip],
    )
    monkeypatch.setattr(service, "_remote_go", lambda request, now_ts: remote_response)

    async def fake_get_alerts():
        return [
            TransitAlert(
                route_id="E",
                title="[E] Trains Delayed",
                description="Signal problems are causing minor delays.",
                severity="warning",
                mode="subway",
                affected_routes=["E"],
                alert_type="Delays",
                active_period_end=_timestamp(10, 0),
            )
        ]

    async def fake_get_arrivals_for_line(line_id: str, *, force_refresh: bool = False):
        assert line_id == "E"
        return [
            TrackArrival(
                route_id="E",
                station="STOP_BOARD_BAD",
                station_name="Jamaica Center-Parsons/Archer",
                direction="Northbound",
                destination="World Trade Center",
                minutes_away=2,
                arrival_ts=_timestamp(8, 10),
                status="Delayed",
                trip_id="TRIP_BAD",
            ),
            TrackArrival(
                route_id="E",
                station="STOP_ALIGHT_BAD",
                station_name="34 St-Penn Station",
                direction="Northbound",
                destination="World Trade Center",
                minutes_away=22,
                arrival_ts=_timestamp(8, 30),
                status="Delayed",
                trip_id="TRIP_BAD",
            ),
            TrackArrival(
                route_id="E",
                station="STOP_BOARD_GOOD",
                station_name="Jamaica Center-Parsons/Archer",
                direction="Northbound",
                destination="World Trade Center",
                minutes_away=5,
                arrival_ts=_timestamp(8, 3),
                status="On Time",
                trip_id="TRIP_GOOD",
            ),
            TrackArrival(
                route_id="E",
                station="STOP_ALIGHT_GOOD",
                station_name="34 St-Penn Station",
                direction="Northbound",
                destination="World Trade Center",
                minutes_away=26,
                arrival_ts=_timestamp(8, 24),
                status="On Time",
                trip_id="TRIP_GOOD",
            ),
        ]

    async def fake_get_bus_arrivals(stop_id: str):
        return []

    async def fake_fetch_rail_arrivals(agency: str):
        return []

    monkeypatch.setattr(
        "app.services.gtfs.realtime_parser.get_alerts",
        fake_get_alerts,
    )
    monkeypatch.setattr(
        "app.services.gtfs.realtime_parser.get_arrivals_for_line",
        fake_get_arrivals_for_line,
    )
    monkeypatch.setattr(
        "app.clients.bus_client.get_realtime_arrivals",
        fake_get_bus_arrivals,
    )
    monkeypatch.setattr(
        "app.clients.rail_client.fetch_rail_arrivals",
        fake_fetch_rail_arrivals,
    )

    request = PlanRequest(
        origin=LocationInput(label="Home", lat=40.7, lon=-73.8),
        destination=LocationInput(label="Work", lat=40.75, lon=-73.99),
        depart_at_ts=_timestamp(8, 0),
        num_itineraries=2,
    )
    response = service.go(request, now_ts=_timestamp(7, 58))

    assert response.primary_trip is not None
    assert response.primary_trip.itinerary.itinerary_id == "good-trip"
    assert response.primary_trip.reliability_score > response.alternatives[0].reliability_score
    assert response.primary_trip.ranking_score < response.alternatives[0].ranking_score
    assert response.primary_trip.disruption_level == "watch"
    assert response.primary_trip.itinerary.legs[0].live_status is not None
    assert response.primary_trip.itinerary.legs[0].live_status.status == "live"
    assert response.alternatives[0].itinerary.legs[0].live_status is not None
    assert response.alternatives[0].itinerary.legs[0].live_status.status == "delayed"
    assert response.primary_trip.service_alerts
    assert response.primary_trip.service_alerts[0].title == "[E] Trains Delayed"
