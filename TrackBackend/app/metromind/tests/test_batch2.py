"""Tests for Batch 2 — suggestions, model router, thread store."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

import pytest

from app.metromind.config import reset_metromind_settings
from app.metromind.model_router import pick_model
from app.metromind.schemas import ChatMessage, SavedPlace, UserContext
from app.metromind.suggestions import build_suggestions


# ── D — Suggestions ──────────────────────────────────────────────────


def test_suggestions_after_plan_route_includes_save_and_track() -> None:
    chips = build_suggestions(
        used_tools=["plan_route"],
        tool_payloads={
            "plan_route": {
                "origin": "Times Sq",
                "destination": "Brooklyn Bridge",
                "itineraries": [{
                    "summary": "W · 19 min",
                    "legs": [
                        {"mode": "walk", "route_id": None},
                        {"mode": "subway", "route_id": "W"},
                    ],
                }],
            }
        },
        context=None,
    )
    labels = [c.label for c in chips]
    kinds = [c.kind for c in chips]
    assert "Save this trip" in labels
    assert "save_trip" in kinds
    assert any("W" in lbl for lbl in labels)


def test_suggestions_default_when_no_tools() -> None:
    ctx = UserContext(
        saved_places=[SavedPlace(label="Home", kind="home", lat=0, lon=0)]
    )
    chips = build_suggestions(used_tools=[], tool_payloads={}, context=ctx)
    labels = [c.label for c in chips]
    assert any("home" in lbl.lower() for lbl in labels)
    assert 1 <= len(chips) <= 3


def test_suggestions_capped_at_three() -> None:
    chips = build_suggestions(
        used_tools=["plan_route", "get_service_alerts", "search_stations"],
        tool_payloads={
            "plan_route": {
                "itineraries": [{"legs": [{"mode": "subway", "route_id": "L"}]}]
            },
            "search_stations": {"stops": [{"stop_name": "Bedford Av"}]},
        },
        context=None,
    )
    assert len(chips) <= 3


def test_suggestions_use_personal_top_route_in_fallback() -> None:
    """Default chip should advertise the user's #1 line, not always L."""
    ctx = UserContext(top_routes=["7", "F", "L"])
    chips = build_suggestions(used_tools=[], tool_payloads={}, context=ctx)
    labels = [c.label for c in chips]
    assert any("7" in lbl for lbl in labels)
    # And we must not accidentally hardcode L when the user rides 7.
    assert not any(lbl == "Any L delays?" for lbl in labels)


def test_suggestions_strip_gtfs_prefix_from_route_id() -> None:
    """Route IDs from RouteAnalyticsManager arrive prefixed."""
    ctx = UserContext(top_routes=["MTA NYCT_B63"])
    chips = build_suggestions(used_tools=[], tool_payloads={}, context=ctx)
    assert any("B63" in c.label and "MTA" not in c.label for c in chips)


def test_suggestions_empty_itinerary_offers_recovery_chips() -> None:
    """Out-of-MTA destinations should still get actionable chips."""
    chips = build_suggestions(
        used_tools=["plan_route"],
        tool_payloads={
            "plan_route": {
                "origin": "Times Square",
                "destination": "Newark Penn Station",
                "itineraries": [],
            }
        },
        context=None,
    )
    assert len(chips) >= 1
    kinds = [c.kind for c in chips]
    # Either nudge to the Plan tab or ask for a different destination —
    # never strand the user with zero options.
    assert any(k in {"open_plan", "send_prompt"} for k in kinds)


def test_suggestions_walk_only_trip_skips_track_chip() -> None:
    """No Track chip when there's no transit leg to follow."""
    chips = build_suggestions(
        used_tools=["plan_route"],
        tool_payloads={
            "plan_route": {
                "origin": "Times Sq",
                "destination": "Bryant Park",
                "itineraries": [{
                    "summary": "Walk · 6 min",
                    "legs": [{"mode": "walk", "route_id": None}],
                }],
            }
        },
        context=None,
    )
    assert not any(c.kind == "start_tracking" for c in chips)
    # Save is still primary even for walk-only.
    assert any(c.kind == "save_trip" for c in chips)


def test_suggestions_arrivals_offers_track_and_alerts() -> None:
    chips = build_suggestions(
        used_tools=["get_live_arrivals"],
        tool_payloads={
            "get_live_arrivals": {
                "route_id": "6",
                "arrivals": [{"route_id": "6", "minutes_away": 3}],
            }
        },
        context=None,
    )
    kinds = {c.kind for c in chips}
    assert "start_tracking" in kinds
    assert any("6" in c.label for c in chips)


def test_suggestions_no_personal_route_rotates_popular_lines() -> None:
    """Without top_routes we must still surface *some* delay chip."""
    chips = build_suggestions(used_tools=[], tool_payloads={}, context=None)
    delay_chips = [c for c in chips if " delays?" in c.label]
    assert len(delay_chips) == 1
    # Whatever route shows up must be a real, popular NYC line.
    route = delay_chips[0].label.replace("Any ", "").replace(" delays?", "")
    assert route in {"6", "F", "L", "7", "A", "N", "E", "G"}


def test_suggestions_use_dropped_pin_for_nearby_chip() -> None:
    """When a map pin is dropped, the "nearby" chip should name it."""
    ctx = UserContext(
        bias_lat=40.7359,
        bias_lon=-73.9911,
        bias_source="map_pin",
        bias_label="Union Square",
    )
    chips = build_suggestions(used_tools=[], tool_payloads={}, context=ctx)
    assert any("Union Square" in c.label for c in chips)


def test_suggestions_use_gps_for_nearby_chip_without_pin_label() -> None:
    """Plain GPS (no pin) still produces a 'near me' chip."""
    ctx = UserContext(
        bias_lat=40.7359,
        bias_lon=-73.9911,
        bias_source="gps",
    )
    chips = build_suggestions(used_tools=[], tool_payloads={}, context=ctx)
    assert any("near me" in c.label.lower() for c in chips)


def test_suggestions_pin_plus_home_offers_get_home_from_pin() -> None:
    """Pin + saved Home should produce a 'Get home from {pin}' shortcut."""
    ctx = UserContext(
        saved_places=[SavedPlace(label="Home", kind="home", lat=0, lon=0)],
        bias_lat=40.7359,
        bias_lon=-73.9911,
        bias_source="map_pin",
        bias_label="Union Sq",
    )
    chips = build_suggestions(used_tools=[], tool_payloads={}, context=ctx)
    assert any(
        "Union Sq" in c.label and "home" in c.label.lower() for c in chips
    )


# ── E — Model router ─────────────────────────────────────────────────


def test_pick_model_default_for_short_simple_prompt() -> None:
    reset_metromind_settings()
    model, reason = pick_model(
        user_message="any L delays?", history=[], has_image=False
    )
    assert model.endswith("mini")
    assert reason == "default"


def test_pick_model_escalates_on_long_prompt() -> None:
    reset_metromind_settings()
    long_msg = "Compare the trade-offs between the L, J, and M trains for going from "
    long_msg += "Williamsburg to Midtown including transfer counts and live delays. " * 2
    model, reason = pick_model(user_message=long_msg, history=[], has_image=False)
    assert model == "gpt-4o" or "4o" in model
    assert reason in {"long_prompt", "complexity_hint", "multi_destination"}


def test_pick_model_forces_vision_when_image_present() -> None:
    reset_metromind_settings()
    model, reason = pick_model(
        user_message="what train is this?", history=[], has_image=True
    )
    assert reason == "vision"
    assert "4o" in model


def test_pick_model_escalates_on_multi_question() -> None:
    reset_metromind_settings()
    model, reason = pick_model(
        user_message="how do I get to JFK? what's the cheapest option?",
        history=[],
        has_image=False,
    )
    assert reason == "multi_question"


# ── J — Thread store ─────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def _isolated_thread_db(monkeypatch, tmp_path):
    """Point the thread store at a tmp DB so tests don't touch real data."""
    db_path = tmp_path / "threads.db"
    monkeypatch.setenv("METROMIND_THREADS_DB_PATH", str(db_path))
    reset_metromind_settings()
    yield
    reset_metromind_settings()


def test_thread_store_roundtrip() -> None:
    from app.metromind import thread_store

    tid = thread_store.create_thread(title="Morning commute")
    assert thread_store.thread_exists(tid)

    thread_store.append_message(tid, "user", "How do I get home?")
    thread_store.append_message(tid, "assistant", "Take the L.")
    thread_store.append_message(
        tid, "user", "What's that train?", image_data_url="data:image/jpeg;base64,xxx"
    )

    msgs = thread_store.load_messages(tid, limit=10)
    assert len(msgs) == 3
    assert msgs[0].role == "user"
    assert msgs[0].content == "How do I get home?"
    assert msgs[1].role == "assistant"
    assert msgs[2].image_data_url == "data:image/jpeg;base64,xxx"


def test_thread_store_load_limit_trims_oldest() -> None:
    from app.metromind import thread_store

    tid = thread_store.create_thread()
    for i in range(10):
        thread_store.append_message(tid, "user", f"msg-{i}")
    msgs = thread_store.load_messages(tid, limit=3)
    assert len(msgs) == 3
    assert [m.content for m in msgs] == ["msg-7", "msg-8", "msg-9"]


def test_thread_store_delete_returns_true_only_once() -> None:
    from app.metromind import thread_store

    tid = thread_store.create_thread()
    assert thread_store.delete_thread(tid) is True
    assert thread_store.delete_thread(tid) is False
