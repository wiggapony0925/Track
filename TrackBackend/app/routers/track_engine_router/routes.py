"""FastAPI routes for the Track trip-planning engine."""

from __future__ import annotations

import os
import time
from typing import Annotated

from fastapi import APIRouter, Body, HTTPException, Query, Request
from fastapi.responses import FileResponse

from app.models.track_engine import (
    EngineCalendarEventInput,
    EngineGoAction,
    EngineGoRequest,
    EngineGoResponse,
    EngineGoStep,
    EngineGoTransfer,
    EngineGoTrip,
    EngineHealth,
    EngineItinerary,
    EngineLegLiveStatus,
    EnginePlanRequest,
    EnginePlanResponse,
    EngineRecentTrip,
    EngineRecommendation,
    EngineRouteChip,
    EngineSavedPlace,
    EngineSavedPlaceUpsert,
    EngineSavedTrip,
    EngineSavedTripUpsert,
    EngineSearchResult,
    EngineServiceAlert,
    EngineTripLeg,
)
from app.services.track_engine.integration import (
    CalendarEvent,
    LocationInput,
    PlanRequest,
    get_engine_service,
)
from app.utils.brand import mode_name as _mode_name, text_color_for_route as _text_color

router = APIRouter(prefix="/engine", tags=["engine"])


def _location_input_from_payload(payload) -> LocationInput:
    return LocationInput(
        label=payload.label,
        lat=payload.lat,
        lon=payload.lon,
        stop_id=payload.stop_id,
        address=payload.address,
    )


def _leg_model(leg) -> EngineTripLeg:
    return EngineTripLeg(
        mode=leg.mode,
        route_id=leg.route_id,
        route_name=leg.route_name,
        color_hex=leg.color_hex,
        text_color_hex=_text_color(leg.mode, leg.route_id),
        mode_name=_mode_name(leg.mode),
        headsign=leg.headsign,
        trip_id=leg.trip_id,
        board_stop_id=leg.board_stop_id,
        board_stop_name=leg.board_stop_name,
        alight_stop_id=leg.alight_stop_id,
        alight_stop_name=leg.alight_stop_name,
        departure_ts=leg.departure_ts,
        arrival_ts=leg.arrival_ts,
        duration_s=leg.duration_s,
        stop_count=leg.stop_count,
        walk_meters=leg.walk_meters,
        bus_service_type=getattr(leg, "bus_service_type", None),
        live_status=_leg_live_status_model(leg.live_status),
        alerts=[_service_alert_model(alert) for alert in leg.alerts],
    )


def _itinerary_model(itinerary) -> EngineItinerary:
    return EngineItinerary(
        itinerary_id=itinerary.itinerary_id,
        leave_at_ts=itinerary.leave_at_ts,
        arrive_at_ts=itinerary.arrive_at_ts,
        total_duration_s=itinerary.total_duration_s,
        in_vehicle_s=itinerary.in_vehicle_s,
        walking_s=itinerary.walking_s,
        waiting_s=itinerary.waiting_s,
        transfer_count=itinerary.transfer_count,
        walk_meters=itinerary.walk_meters,
        score=itinerary.score,
        summary=itinerary.summary,
        legs=[_leg_model(leg) for leg in itinerary.legs],
    )


def _route_chip_model(chip) -> EngineRouteChip:
    _chip_mode = chip.mode or "walk"
    return EngineRouteChip(
        kind=chip.kind,
        label=chip.label,
        route_id=chip.route_id,
        color_hex=chip.color_hex,
        text_color_hex=_text_color(_chip_mode, chip.route_id),
        mode=chip.mode,
        mode_name=_mode_name(_chip_mode) if chip.mode else None,
        duration_s=chip.duration_s,
        walk_meters=chip.walk_meters,
    )


def _service_alert_model(alert) -> EngineServiceAlert:
    return EngineServiceAlert(
        route_id=alert.route_id,
        severity=alert.severity,
        title=alert.title,
        description=alert.description,
        mode=alert.mode,
        alert_type=alert.alert_type,
        active_period_end=alert.active_period_end,
    )


def _leg_live_status_model(live_status) -> EngineLegLiveStatus | None:
    if live_status is None:
        return None
    return EngineLegLiveStatus(
        source=live_status.source,
        status=live_status.status,
        predicted_departure_ts=live_status.predicted_departure_ts,
        predicted_arrival_ts=live_status.predicted_arrival_ts,
        delay_s=live_status.delay_s,
        status_text=live_status.status_text,
        is_realtime=live_status.is_realtime,
        matched_trip_id=live_status.matched_trip_id,
    )


def _go_step_model(step) -> EngineGoStep:
    _step_mode = getattr(step, "mode", None) or ("walk" if step.kind == "walk" else None)
    return EngineGoStep(
        kind=step.kind,
        title=step.title,
        subtitle=step.subtitle,
        start_ts=step.start_ts,
        end_ts=step.end_ts,
        route_id=step.route_id,
        route_name=step.route_name,
        color_hex=step.color_hex,
        text_color_hex=_text_color(_step_mode or "walk", step.route_id) if step.color_hex else None,
        stop_id=step.stop_id,
        stop_name=step.stop_name,
    )


def _go_transfer_model(transfer) -> EngineGoTransfer:
    return EngineGoTransfer(
        from_route_id=transfer.from_route_id,
        from_route_name=transfer.from_route_name,
        to_route_id=transfer.to_route_id,
        to_route_name=transfer.to_route_name,
        arrival_stop_id=transfer.arrival_stop_id,
        arrival_stop_name=transfer.arrival_stop_name,
        boarding_stop_id=transfer.boarding_stop_id,
        boarding_stop_name=transfer.boarding_stop_name,
        arrival_ts=transfer.arrival_ts,
        boarding_ts=transfer.boarding_ts,
        wait_s=transfer.wait_s,
        walk_s=transfer.walk_s,
        walk_meters=transfer.walk_meters,
    )


def _go_action_model(action) -> EngineGoAction | None:
    if action is None:
        return None
    return EngineGoAction(
        status=action.status,
        title=action.title,
        subtitle=action.subtitle,
        due_at_ts=action.due_at_ts,
        due_in_s=action.due_in_s,
    )


def _go_trip_model(go_trip) -> EngineGoTrip:
    return EngineGoTrip(
        itinerary=_itinerary_model(go_trip.itinerary),
        route_chips=[_route_chip_model(chip) for chip in go_trip.route_chips],
        steps=[_go_step_model(step) for step in go_trip.steps],
        transfers=[
            _go_transfer_model(transfer) for transfer in go_trip.transfers
        ],
        next_action=_go_action_model(go_trip.next_action),
        status=go_trip.status,
        leave_in_s=go_trip.leave_in_s,
        arrive_in_s=go_trip.arrive_in_s,
        duration_label=go_trip.duration_label,
        leave_label=go_trip.leave_label,
        arrive_label=go_trip.arrive_label,
        reliability_score=go_trip.reliability_score,
        ranking_score=go_trip.ranking_score,
        disruption_level=go_trip.disruption_level,
        service_alerts=[
            _service_alert_model(alert) for alert in go_trip.service_alerts
        ],
    )


@router.get(
    "/health",
    response_model=EngineHealth,
    summary="TrackEngine health",
    description=(
        "Returns Track engine status, resolved DB paths, the lightweight "
        "search indexes prepared by the backend, and remote C++ engine health."
    ),
)
def engine_health() -> EngineHealth:
    try:
        health = get_engine_service().health()
        return EngineHealth(
            version=health.version,
            schedule_db_path=health.schedule_db_path,
            state_db_path=health.state_db_path,
            state_backend=health.state_backend,
            prepared=health.prepared,
            prepared_indexes=list(health.prepared_indexes),
            schedule_db_error=health.schedule_db_error,
            routing_backend=health.routing_backend,
            remote_engine_url=health.remote_engine_url,
            remote_engine_healthy=health.remote_engine_healthy,
            remote_engine_version=health.remote_engine_version,
            remote_engine_error=health.remote_engine_error,
        )
    except Exception as exc:  # pragma: no cover - production safety net
        return EngineHealth(
            version="0.3.0",
            schedule_db_path=os.environ.get("TRACK_ENGINE_SCHEDULE_DB", "unknown"),
            state_db_path=os.environ.get("TRACK_ENGINE_STATE_DB", "unknown"),
            state_backend=os.environ.get("TRACK_ENGINE_STATE_BACKEND", "unknown"),
            prepared=False,
            prepared_indexes=[],
            schedule_db_error=str(exc),
            routing_backend="backend_state_only",
            remote_engine_url=(
                os.environ.get("TRACK_ENGINE_URL")
                or os.environ.get("TRACK_ENGINE_INTERNAL_URL")
            ),
            remote_engine_healthy=False,
            remote_engine_version=None,
            remote_engine_error=str(exc),
        )


@router.get(
    "/bootstrap/schedule-db.gz",
    include_in_schema=False,
    summary="Internal TrackEngine schedule artifact",
)
def download_engine_schedule_artifact(request: Request) -> FileResponse:
    del request
    artifact_path = get_engine_service().ensure_schedule_artifact()
    return FileResponse(
        path=artifact_path,
        filename="transit_schedule.db.gz",
        media_type="application/gzip",
        headers={"Cache-Control": "no-store"},
    )


@router.get(
    "/search",
    response_model=list[EngineSearchResult],
    summary="Search saved places, recents, and stops",
    description=(
        "Unified search used by the planner's destination/origin picker. Merges saved places, "
        "recent destinations, and indexed transit stops into one ranked list. Optional `lat`/`lon` "
        "bias results toward the rider's current area."
    ),
)
def search_engine_places(
    q: str = Query(..., min_length=1, description="Search query."),
    user_id: str | None = Query(
        None,
        description="Stable user identifier for saved places and recents.",
    ),
    lat: float | None = Query(None, description="Optional current latitude."),
    lon: float | None = Query(None, description="Optional current longitude."),
    limit: int = Query(12, ge=1, le=50, description="Maximum number of results."),
) -> list[EngineSearchResult]:
    results = get_engine_service().search(
        query=q,
        user_id=user_id,
        near_lat=lat,
        near_lon=lon,
        limit=limit,
    )
    return [
        EngineSearchResult(
            source=result.source,
            label=result.label,
            subtitle=result.subtitle,
            lat=result.lat,
            lon=result.lon,
            score=result.score,
            stop_id=result.stop_id,
            place_id=result.place_id,
            icon=result.icon,
            mode=result.mode,
        )
        for result in results
    ]


@router.get(
    "/places",
    response_model=list[EngineSavedPlace],
    summary="List saved places",
    description="Returns all saved places for a user, such as Home, Work, or custom pins shown in planner shortcuts.",
)
def list_saved_places(
    user_id: str = Query(..., description="Stable user identifier."),
) -> list[EngineSavedPlace]:
    return [
        EngineSavedPlace(
            place_id=place.place_id,
            user_id=place.user_id,
            label=place.label,
            kind=place.kind,
            lat=place.lat,
            lon=place.lon,
            address=place.address,
            icon=place.icon,
            created_at=place.created_at,
            updated_at=place.updated_at,
            last_used_at=place.last_used_at,
        )
        for place in get_engine_service().list_saved_places(user_id)
    ]


@router.post(
    "/places",
    response_model=EngineSavedPlace,
    summary="Create or update a saved place",
    description=(
        "Creates a new saved place or updates an existing one. Used by the planner's saved-place editor "
        "and shortcut management UI."
    ),
)
def upsert_saved_place(payload: EngineSavedPlaceUpsert) -> EngineSavedPlace:
    place = get_engine_service().upsert_saved_place(
        user_id=payload.user_id,
        label=payload.label,
        kind=payload.kind,
        lat=payload.lat,
        lon=payload.lon,
        address=payload.address,
        icon=payload.icon,
        place_id=payload.place_id,
    )
    return EngineSavedPlace(
        place_id=place.place_id,
        user_id=place.user_id,
        label=place.label,
        kind=place.kind,
        lat=place.lat,
        lon=place.lon,
        address=place.address,
        icon=place.icon,
        created_at=place.created_at,
        updated_at=place.updated_at,
        last_used_at=place.last_used_at,
    )


@router.delete(
    "/places/{place_id}",
    summary="Delete a saved place",
    description="Deletes a saved place for the given user. The app should remove the shortcut locally after success.",
)
def delete_saved_place(
    place_id: int,
    user_id: str = Query(..., description="Stable user identifier."),
) -> dict[str, str]:
    get_engine_service().delete_saved_place(user_id, place_id)
    return {"status": "deleted"}


@router.get(
    "/trips/saved",
    response_model=list[EngineSavedTrip],
    summary="List saved trips",
    description="Returns saved trip templates such as commute presets that the planner can reopen with one tap.",
)
def list_saved_trips(
    user_id: str = Query(..., description="Stable user identifier."),
) -> list[EngineSavedTrip]:
    return [
        EngineSavedTrip(
            trip_id=trip.trip_id,
            user_id=trip.user_id,
            name=trip.name,
            origin_label=trip.origin_label,
            origin_lat=trip.origin_lat,
            origin_lon=trip.origin_lon,
            destination_label=trip.destination_label,
            destination_lat=trip.destination_lat,
            destination_lon=trip.destination_lon,
            preferred_departure_hour=trip.preferred_departure_hour,
            preferred_arrival_hour=trip.preferred_arrival_hour,
            preferred_modes=list(trip.preferred_modes),
            created_at=trip.created_at,
            updated_at=trip.updated_at,
            last_used_at=trip.last_used_at,
        )
        for trip in get_engine_service().list_saved_trips(user_id)
    ]


@router.post(
    "/trips/saved",
    response_model=EngineSavedTrip,
    summary="Create or update a saved trip",
    description=(
        "Creates or updates a saved trip template containing origin, destination, and preferred planning constraints."
    ),
)
def upsert_saved_trip(payload: EngineSavedTripUpsert) -> EngineSavedTrip:
    trip = get_engine_service().upsert_saved_trip(
        user_id=payload.user_id,
        name=payload.name,
        origin_label=payload.origin.label,
        origin_lat=float(payload.origin.lat or 0.0),
        origin_lon=float(payload.origin.lon or 0.0),
        destination_label=payload.destination.label,
        destination_lat=float(payload.destination.lat or 0.0),
        destination_lon=float(payload.destination.lon or 0.0),
        preferred_departure_hour=payload.preferred_departure_hour,
        preferred_arrival_hour=payload.preferred_arrival_hour,
        preferred_modes=tuple(payload.preferred_modes),
        trip_id=payload.trip_id,
    )
    return EngineSavedTrip(
        trip_id=trip.trip_id,
        user_id=trip.user_id,
        name=trip.name,
        origin_label=trip.origin_label,
        origin_lat=trip.origin_lat,
        origin_lon=trip.origin_lon,
        destination_label=trip.destination_label,
        destination_lat=trip.destination_lat,
        destination_lon=trip.destination_lon,
        preferred_departure_hour=trip.preferred_departure_hour,
        preferred_arrival_hour=trip.preferred_arrival_hour,
        preferred_modes=list(trip.preferred_modes),
        created_at=trip.created_at,
        updated_at=trip.updated_at,
        last_used_at=trip.last_used_at,
    )


@router.delete(
    "/trips/saved/{trip_id}",
    summary="Delete a saved trip",
    description="Deletes a saved trip template for the given user.",
)
def delete_saved_trip(
    trip_id: int,
    user_id: str = Query(..., description="Stable user identifier."),
) -> dict[str, str]:
    get_engine_service().delete_saved_trip(user_id, trip_id)
    return {"status": "deleted"}


@router.get(
    "/trips/recent",
    response_model=list[EngineRecentTrip],
    summary="List recent trips",
    description="Returns recently planned trips so the app can render quick re-run cards in the planning experience.",
)
def list_recent_trips(
    user_id: str = Query(..., description="Stable user identifier."),
    limit: int = Query(20, ge=1, le=50, description="Maximum number of recent trips."),
) -> list[EngineRecentTrip]:
    return [
        EngineRecentTrip(
            recent_trip_id=trip.recent_trip_id,
            user_id=trip.user_id,
            origin_label=trip.origin_label,
            origin_lat=trip.origin_lat,
            origin_lon=trip.origin_lon,
            destination_label=trip.destination_label,
            destination_lat=trip.destination_lat,
            destination_lon=trip.destination_lon,
            requested_at=trip.requested_at,
            leave_at_ts=trip.leave_at_ts,
            arrive_at_ts=trip.arrive_at_ts,
            summary=trip.summary,
            route_tokens=list(trip.route_tokens),
        )
        for trip in get_engine_service().list_recent_trips(user_id, limit=limit)
    ]


@router.put(
    "/calendar/events",
    response_model=list[EngineCalendarEventInput],
    summary="Replace upcoming calendar events",
    description=(
        "Replaces the backend's cached set of upcoming calendar events for a user. These events feed destination "
        "recommendations and calendar-aware commute suggestions."
    ),
)
def replace_calendar_events(
    events: Annotated[list[EngineCalendarEventInput], Body(...)],
    user_id: str = Query(..., description="Stable user identifier."),
) -> list[EngineCalendarEventInput]:
    normalized = [
        CalendarEvent(
            external_id=event.external_id,
            title=event.title,
            location_label=event.location_label,
            starts_at=event.starts_at,
            ends_at=event.ends_at,
            lat=event.lat,
            lon=event.lon,
            notes=event.notes,
        )
        for event in events
    ]
    get_engine_service().replace_calendar_events(user_id=user_id, events=normalized)
    return events


@router.get(
    "/recommendations",
    response_model=list[EngineRecommendation],
    summary="Recommend likely destinations",
    description=(
        "Returns ranked destination suggestions derived from saved places, saved trips, recent trips, and synced calendar events. "
        "Used for the planner's smart recommendations surface."
    ),
)
def get_engine_recommendations(
    user_id: str = Query(..., description="Stable user identifier."),
    origin_lat: float | None = Query(None, description="Optional current latitude."),
    origin_lon: float | None = Query(None, description="Optional current longitude."),
    origin_label: str = Query("Current location", description="Origin display label."),
    now_ts: int | None = Query(None, description="Unix timestamp override for testing."),
    limit: int = Query(6, ge=1, le=20, description="Maximum number of recommendations."),
) -> list[EngineRecommendation]:
    origin = None
    if origin_lat is not None and origin_lon is not None:
        origin = LocationInput(label=origin_label, lat=origin_lat, lon=origin_lon)
    recommendations = get_engine_service().recommendations(
        user_id=user_id,
        origin=origin,
        limit=limit,
        now_ts=now_ts,
    )
    return [
        EngineRecommendation(
            source=item.source,
            label=item.label,
            subtitle=item.subtitle,
            lat=item.lat,
            lon=item.lon,
            score=item.score,
            reason=item.reason,
            upcoming_at=item.upcoming_at,
            place_id=item.place_id,
            saved_trip_id=item.saved_trip_id,
        )
        for item in recommendations
    ]


@router.post(
    "/plan",
    response_model=EnginePlanResponse,
    summary="Plan a trip",
    description=(
        "Plans a trip through the standalone C++ TrackEngine service and returns ranked itineraries with transit legs, "
        "walking segments, colors, alerts, and timing. When `user_id` is provided, the best itinerary can also be recorded "
        "into recent trips for planner shortcuts."
    ),
)
def plan_trip(payload: EnginePlanRequest) -> EnginePlanResponse:
    service = get_engine_service()
    request = PlanRequest(
        origin=_location_input_from_payload(payload.origin),
        destination=_location_input_from_payload(payload.destination),
        user_id=payload.user_id,
        depart_at_ts=payload.depart_at_ts,
        arrive_by_ts=payload.arrive_by_ts,
        max_transfers=payload.max_transfers,
        max_origin_walk_m=payload.max_origin_walk_m,
        max_destination_walk_m=payload.max_destination_walk_m,
        max_transfer_walk_m=payload.max_transfer_walk_m,
        search_window_minutes=payload.search_window_minutes,
        num_itineraries=payload.num_itineraries,
        modes=tuple(payload.modes),
        record_recent=payload.record_recent,
    )
    try:
        itineraries, schedule_note = service.plan(request)
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - production safety net
        raise HTTPException(
            status_code=503,
            detail=f"TrackEngine plan is unavailable: {exc}",
        ) from exc
    return EnginePlanResponse(
        engine_version=service.planner_version,
        requested_at_ts=int(time.time()),
        origin=payload.origin,
        destination=payload.destination,
        depart_at_ts=payload.depart_at_ts,
        arrive_by_ts=payload.arrive_by_ts,
        itineraries=[_itinerary_model(item) for item in itineraries],
        schedule_note=schedule_note,
    )


@router.post(
    "/go",
    response_model=EngineGoResponse,
    summary="Build a Transit-style Go session",
    description=(
        "Builds a frontend-ready live trip session for the Go experience. The response adds route chips, step-by-step instructions, "
        "transfer timing, aggregated alerts, and a 'next action' block on top of the core planner result."
    ),
)
def build_go_trip(payload: EngineGoRequest) -> EngineGoResponse:
    service = get_engine_service()
    request = PlanRequest(
        origin=_location_input_from_payload(payload.origin),
        destination=_location_input_from_payload(payload.destination),
        user_id=payload.user_id,
        depart_at_ts=payload.depart_at_ts,
        arrive_by_ts=payload.arrive_by_ts,
        max_transfers=payload.max_transfers,
        max_origin_walk_m=payload.max_origin_walk_m,
        max_destination_walk_m=payload.max_destination_walk_m,
        max_transfer_walk_m=payload.max_transfer_walk_m,
        search_window_minutes=payload.search_window_minutes,
        num_itineraries=payload.num_itineraries,
        modes=tuple(payload.modes),
        record_recent=payload.record_recent,
    )
    try:
        go_response = service.go(request, now_ts=payload.now_ts)
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - production safety net
        raise HTTPException(
            status_code=503,
            detail=f"TrackEngine go is unavailable: {exc}",
        ) from exc
    return EngineGoResponse(
        engine_version=go_response.engine_version,
        requested_at_ts=go_response.requested_at_ts,
        now_ts=go_response.now_ts,
        origin=payload.origin,
        destination=payload.destination,
        session_kind=go_response.session_kind,
        primary_trip=(
            _go_trip_model(go_response.primary_trip)
            if go_response.primary_trip is not None
            else None
        ),
        alternatives=[_go_trip_model(item) for item in go_response.alternatives],
        schedule_note=go_response.schedule_note,
    )
