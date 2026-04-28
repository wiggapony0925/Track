"""Tests for the Supabase-backed engine store."""

from __future__ import annotations

import json
from datetime import UTC, datetime

import httpx

from app.services.track_engine.domain import (
    CalendarEvent,
    Itinerary,
    SavedPlace,
    TransitLeg,
)
from app.services.track_engine.store_supabase import SupabaseEngineStore


def _iso(timestamp_s: int) -> str:
    return (
        datetime.fromtimestamp(timestamp_s, tz=UTC)
        .isoformat()
        .replace("+00:00", "Z")
    )


def test_supabase_store_round_trips_engine_state() -> None:
    now_ts = 1_775_908_800
    rows: dict[str, list[dict]] = {
        "engine_saved_places": [],
        "engine_saved_trips": [],
        "engine_recent_trips": [],
        "engine_calendar_events": [],
    }
    sequences = {
        "engine_saved_places": 0,
        "engine_saved_trips": 0,
        "engine_recent_trips": 0,
    }

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path.removeprefix("/rest/v1/")

        if path == "engine_saved_places" and request.method == "POST":
            payload = json.loads(request.content)
            sequences["engine_saved_places"] += 1
            row = {
                "id": sequences["engine_saved_places"],
                "created_at": _iso(now_ts),
                "updated_at": _iso(now_ts),
                "last_used_at": None,
                **payload,
            }
            rows["engine_saved_places"].append(row)
            return httpx.Response(201, json=[row])

        if path == "engine_saved_places" and request.method == "PATCH":
            payload = json.loads(request.content)
            place_id = int(request.url.params["id"].removeprefix("eq."))
            user_id = request.url.params["user_id"].removeprefix("eq.")
            for row in rows["engine_saved_places"]:
                if row["id"] == place_id and row["user_id"] == user_id:
                    row.update(payload)
                    row["updated_at"] = _iso(now_ts + 60)
                    return httpx.Response(200, json=[row])
            return httpx.Response(404, json=[])

        if path == "engine_saved_places" and request.method == "GET":
            return httpx.Response(200, json=rows["engine_saved_places"])

        if path == "engine_saved_trips" and request.method == "POST":
            payload = json.loads(request.content)
            sequences["engine_saved_trips"] += 1
            row = {
                "id": sequences["engine_saved_trips"],
                "created_at": _iso(now_ts),
                "updated_at": _iso(now_ts),
                "last_used_at": None,
                **payload,
            }
            rows["engine_saved_trips"].append(row)
            return httpx.Response(201, json=[row])

        if path == "engine_saved_trips" and request.method == "GET":
            return httpx.Response(200, json=rows["engine_saved_trips"])

        if path == "engine_recent_trips" and request.method == "POST":
            payload = json.loads(request.content)
            sequences["engine_recent_trips"] += 1
            row = {
                "id": sequences["engine_recent_trips"],
                **payload,
            }
            rows["engine_recent_trips"].append(row)
            return httpx.Response(201, json=[row])

        if path == "engine_recent_trips" and request.method == "GET":
            return httpx.Response(200, json=rows["engine_recent_trips"])

        if path == "rpc/engine_trim_recent_trips" and request.method == "POST":
            return httpx.Response(200, json=0)

        if path == "rpc/engine_recent_destinations" and request.method == "POST":
            payload = json.loads(request.content)
            user_rows = [
                row
                for row in rows["engine_recent_trips"]
                if row["user_id"] == payload["p_user_id"]
            ]
            grouped: dict[tuple[str, float, float], dict] = {}
            for row in user_rows:
                key = (
                    row["destination_label"],
                    round(float(row["destination_lat"]), 4),
                    round(float(row["destination_lon"]), 4),
                )
                entry = grouped.setdefault(
                    key,
                    {
                        "label": row["destination_label"],
                        "lat": row["destination_lat"],
                        "lon": row["destination_lon"],
                        "trip_count": 0,
                        "last_used_at": int(
                            datetime.fromisoformat(
                                row["requested_at"].replace("Z", "+00:00")
                            ).timestamp()
                        ),
                    },
                )
                entry["trip_count"] += 1
            return httpx.Response(200, json=list(grouped.values()))

        if path == "engine_calendar_events" and request.method == "DELETE":
            user_id = request.url.params.get("user_id", "").removeprefix("eq.")
            rows["engine_calendar_events"] = [
                row for row in rows["engine_calendar_events"] if row["user_id"] != user_id
            ]
            return httpx.Response(204)

        if path == "engine_calendar_events" and request.method == "POST":
            payload = json.loads(request.content)
            rows["engine_calendar_events"].extend(payload)
            return httpx.Response(201, json=payload)

        if path == "engine_calendar_events" and request.method == "GET":
            return httpx.Response(200, json=rows["engine_calendar_events"])

        raise AssertionError(f"Unhandled request: {request.method} {request.url}")

    client = httpx.Client(
        base_url="https://octpebjxadbufiplgjqg.supabase.co/rest/v1",
        transport=httpx.MockTransport(handler),
    )
    store = SupabaseEngineStore(
        supabase_url="https://octpebjxadbufiplgjqg.supabase.co",
        service_key="service-role",
        client=client,
    )

    place = store.upsert_saved_place(
        user_id="user-1",
        label="Home",
        kind="home",
        lat=40.7,
        lon=-73.9,
        address="117-13 125th St",
    )
    assert isinstance(place, SavedPlace)
    assert place.visible_on_map is True

    hidden_place = store.upsert_saved_place(
        user_id="user-1",
        label="Home",
        kind="home",
        lat=40.7,
        lon=-73.9,
        address="117-13 125th St",
        visible_on_map=False,
        place_id=place.place_id,
    )
    assert hidden_place.visible_on_map is False
    listed_place = store.list_saved_places("user-1")[0]
    assert listed_place.label == "Home"
    assert listed_place.visible_on_map is False

    trip = store.upsert_saved_trip(
        user_id="user-1",
        name="Morning commute",
        origin_label="Home",
        origin_lat=40.7,
        origin_lon=-73.9,
        destination_label="Work",
        destination_lat=40.75,
        destination_lon=-73.99,
        preferred_departure_hour=8,
        preferred_arrival_hour=9,
        preferred_modes=("subway", "bus"),
    )
    assert trip.name == "Morning commute"
    assert store.list_saved_trips("user-1")[0].preferred_modes == ("subway", "bus")

    itinerary = Itinerary(
        itinerary_id="test-itinerary",
        leave_at_ts=now_ts + 60,
        arrive_at_ts=now_ts + 1_260,
        total_duration_s=1_200,
        in_vehicle_s=1_000,
        walking_s=200,
        waiting_s=0,
        transfer_count=0,
        walk_meters=180.0,
        score=1.0,
        summary="Walk 2m -> E -> Walk 1m",
        legs=[
            TransitLeg(
                mode="walk",
                route_id="walk",
                route_name="Walk",
                color_hex=None,
                headsign=None,
                trip_id=None,
                board_stop_id="origin",
                board_stop_name="Home",
                alight_stop_id="A",
                alight_stop_name="Station A",
                departure_ts=now_ts + 60,
                arrival_ts=now_ts + 180,
                duration_s=120,
                stop_count=0,
                walk_meters=120.0,
            ),
            TransitLeg(
                mode="subway",
                route_id="E",
                route_name="E",
                color_hex="#0062CF",
                headsign="World Trade Center",
                trip_id="trip-e",
                board_stop_id="A",
                board_stop_name="Station A",
                alight_stop_id="B",
                alight_stop_name="Station B",
                departure_ts=now_ts + 180,
                arrival_ts=now_ts + 1_140,
                duration_s=960,
                stop_count=6,
                walk_meters=0.0,
            ),
            TransitLeg(
                mode="walk",
                route_id="walk",
                route_name="Walk",
                color_hex=None,
                headsign=None,
                trip_id=None,
                board_stop_id="B",
                board_stop_name="Station B",
                alight_stop_id="destination",
                alight_stop_name="Work",
                departure_ts=now_ts + 1_140,
                arrival_ts=now_ts + 1_260,
                duration_s=120,
                stop_count=0,
                walk_meters=60.0,
            ),
        ],
    )
    recent = store.record_recent_trip(
        "user-1",
        origin_label="Home",
        origin_lat=40.7,
        origin_lon=-73.9,
        destination_label="Work",
        destination_lat=40.75,
        destination_lon=-73.99,
        itinerary=itinerary,
    )
    assert recent.route_tokens == ("Walk 2 min", "E", "Walk 2 min")
    assert store.list_recent_destinations("user-1")[0].label == "Work"

    events = store.replace_calendar_events(
        "user-1",
        [
            CalendarEvent(
                external_id="event-1",
                title="Standup",
                location_label="Work",
                starts_at=now_ts + 3_600,
                ends_at=now_ts + 7_200,
                lat=40.75,
                lon=-73.99,
                notes="Bring laptop",
            )
        ],
    )
    assert events[0].title == "Standup"
    listed_events = store.list_calendar_events("user-1", limit=5)
    assert listed_events[0].location_label == "Work"
