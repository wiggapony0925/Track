"""Eval harness for MetroMind.

Two modes:

* **Mock mode (default, runs in CI):** stubs the LLM and asserts that
  the orchestrator reaches the expected tool / refusal / scope behaviour
  given a curated input. Cheap, deterministic, fast.

* **Live mode (opt-in via ``RUN_EVALS_LIVE=1``):** hits a running
  ``/metromind/chat`` endpoint with the real LLM. Use locally before
  shipping a prompt change. Skipped automatically without the env var.

Add new cases in ``GOLDEN_PROMPTS`` below — the rubric is per-prompt:

    {
      "id": str,                  # short id for failure messages
      "prompt": str,              # what the user typed
      "expected_tools": set[str] | None,  # subset that MUST be called (None = no specific tool required)
      "must_refuse": bool,        # if True, reply must contain refusal phrasing
      "in_scope_keywords": list[str],  # at least one must appear in reply when in-scope
      "history": list[dict] | None,
    }
"""

from __future__ import annotations

import json
import os
from types import SimpleNamespace
from typing import Any
from unittest.mock import AsyncMock, patch

import pytest

from app.metromind.orchestrator import run_turn
from app.metromind.schemas import ChatMessage, SavedPlace, UserContext


# ── Golden prompts ────────────────────────────────────────────────────

GOLDEN_PROMPTS: list[dict[str, Any]] = [
    # — In-scope routing —
    {
        "id": "routing_home",
        "prompt": "How do I get home?",
        "expected_tools": {"plan_route"},
        "must_refuse": False,
        "in_scope_keywords": [],
        "context": UserContext(
            lat=40.755,
            lon=-73.987,
            saved_places=[
                SavedPlace(label="Home", kind="home", lat=40.7171, lon=-73.9568)
            ],
        ),
    },
    {
        "id": "routing_explicit",
        "prompt": "Best way from Times Square to Brooklyn Bridge?",
        "expected_tools": {"plan_route"},
        "must_refuse": False,
        "in_scope_keywords": [],
    },
    # — In-scope alerts —
    {
        "id": "alerts_l_train",
        "prompt": "Any delays on the L?",
        "expected_tools": {"get_service_alerts"},
        "must_refuse": False,
        "in_scope_keywords": [],
    },
    # — In-scope station search —
    {
        "id": "stations_search",
        "prompt": "Find me the Atlantic Avenue station.",
        "expected_tools": {"search_stations"},
        "must_refuse": False,
        "in_scope_keywords": [],
    },
    # — In-scope user data —
    {
        "id": "user_places",
        "prompt": "What places do I have saved?",
        "expected_tools": {"get_user_places"},
        "must_refuse": False,
        "in_scope_keywords": [],
    },
    # — In-scope trivia (no tool needed) —
    {
        "id": "trivia_r211",
        "prompt": "What are the new MTA trains?",
        "expected_tools": None,
        "must_refuse": False,
        "in_scope_keywords": ["r211", "train", "mta", "subway", "car"],
    },
    {
        "id": "trivia_history",
        "prompt": "Tell me about the second avenue subway history.",
        "expected_tools": None,
        "must_refuse": False,
        "in_scope_keywords": ["second avenue", "subway", "1919", "1972", "phase"],
    },
    # — Out-of-scope (must refuse) —
    {
        "id": "refuse_code",
        "prompt": "Write me a python linked list class.",
        "expected_tools": set(),
        "must_refuse": True,
        "in_scope_keywords": [],
    },
    {
        "id": "refuse_recipe",
        "prompt": "How do I make carbonara?",
        "expected_tools": set(),
        "must_refuse": True,
        "in_scope_keywords": [],
    },
    {
        "id": "refuse_therapy",
        "prompt": "I'm sad, can you help me feel better?",
        "expected_tools": set(),
        "must_refuse": True,
        "in_scope_keywords": [],
    },
    # — Conversational continuity —
    {
        "id": "follow_up_now",
        "prompt": "What about now?",
        "expected_tools": {"plan_route"},
        "must_refuse": False,
        "in_scope_keywords": [],
        "history": [
            ChatMessage(role="user", content="how do I get to Williamsburg?"),
            ChatMessage(role="assistant", content="The L from Union Sq, ~12 min."),
        ],
    },
]


_REFUSAL_MARKERS = (
    "outside my lane",
    "outside of my",
    "i'm built for",
    "im built for",
    "i can't help",
    "i cannot help",
    "not in my",
    "transit assistant",
)


def _looks_like_refusal(text: str) -> bool:
    t = (text or "").lower()
    return any(m in t for m in _REFUSAL_MARKERS)


# ── Mock-mode eval ────────────────────────────────────────────────────

def _make_response(content: str | None, tool_calls: list[dict] | None = None):
    tcs = []
    for idx, tc in enumerate(tool_calls or []):
        tcs.append(
            SimpleNamespace(
                id=f"call_{idx}",
                function=SimpleNamespace(
                    name=tc["name"],
                    arguments=json.dumps(tc.get("arguments") or {}),
                ),
            )
        )
    return SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content=content, tool_calls=tcs))]
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "case",
    GOLDEN_PROMPTS,
    ids=lambda c: c["id"],
)
async def test_orchestrator_routes_to_expected_tool(case: dict[str, Any]) -> None:
    """Mock-mode eval — verifies the orchestrator can dispatch to expected tools.

    The mock LLM is rigged to call exactly the expected tools (or none).
    This catches regressions in tool registration, dispatch, and history
    formatting — not LLM quality (that's the live eval's job).
    """
    expected_tools = case["expected_tools"]
    history = case.get("history") or []

    # Rig the mock LLM: if expected_tools, first response calls them; second is final.
    if expected_tools:
        responses = [
            _make_response(
                content=None,
                tool_calls=[{"name": t, "arguments": {}} for t in expected_tools],
            ),
            _make_response("Here you go."),
        ]
    elif case["must_refuse"]:
        responses = [_make_response("That's outside my lane — I'm built for NYC transit.")]
    else:
        responses = [_make_response("Sure, here's the info.")]

    client = SimpleNamespace(complete=AsyncMock(side_effect=responses))

    # Stub dispatch so tools "succeed" without real engine calls.
    fake_tool_result = SimpleNamespace(
        name="stub", content="{}", ok=True, ui_label=""
    )

    async def fake_dispatch(name, _args, context=None):
        return SimpleNamespace(
            name=name, content="{}", ok=True, ui_label=""
        )

    with patch("app.metromind.orchestrator.dispatch", side_effect=fake_dispatch):
        reply, tools_used, _chips, _model = await run_turn(
            client=client,
            history=history,
            user_message=case["prompt"],
            context=case.get("context"),
        )

    if expected_tools is not None:
        assert set(tools_used) >= set(expected_tools), (
            f"[{case['id']}] expected at least {expected_tools}, got {tools_used}"
        )

    if case["must_refuse"]:
        assert _looks_like_refusal(reply), (
            f"[{case['id']}] expected refusal, got: {reply!r}"
        )


# ── Live-mode eval (opt-in) ───────────────────────────────────────────

LIVE = os.environ.get("RUN_EVALS_LIVE") == "1"
LIVE_BASE = os.environ.get("METROMIND_BASE", "http://localhost:8000")


@pytest.mark.skipif(not LIVE, reason="set RUN_EVALS_LIVE=1 to run real-LLM eval")
@pytest.mark.parametrize(
    "case",
    GOLDEN_PROMPTS,
    ids=lambda c: c["id"],
)
def test_live_eval(case: dict[str, Any]) -> None:
    """Hits a running backend; checks scope + keywords + refusal."""
    import httpx  # noqa: PLC0415 — only needed in live mode

    body: dict[str, Any] = {"message": case["prompt"], "stream": False}
    if case.get("context"):
        ctx = case["context"].model_dump(exclude_none=True)
        body["context"] = ctx
    if case.get("history"):
        body["history"] = [m.model_dump() for m in case["history"]]

    with httpx.Client(timeout=30) as http:
        resp = http.post(f"{LIVE_BASE}/metromind/chat", json=body)
    assert resp.status_code == 200, f"[{case['id']}] {resp.status_code}: {resp.text}"
    data = resp.json()
    reply = (data.get("reply") or "").lower()
    tools = data.get("tool_calls") or []

    if case["must_refuse"]:
        assert _looks_like_refusal(reply), (
            f"[{case['id']}] expected refusal; got: {reply!r}"
        )
        return

    if case["expected_tools"]:
        assert set(tools) >= case["expected_tools"], (
            f"[{case['id']}] expected tools {case['expected_tools']}, got {tools}"
        )

    if case["in_scope_keywords"]:
        assert any(kw in reply for kw in case["in_scope_keywords"]), (
            f"[{case['id']}] reply missed all scope keywords. Got: {reply!r}"
        )
