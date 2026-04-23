"""Tests for the MetroMind orchestrator and router.

These stub out the LLM client so the agent loop can be exercised
deterministically.
"""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from app.metromind.orchestrator import run_turn
from app.metromind.schemas import ChatRequest


def _make_response(content: str | None, tool_calls: list[dict] | None = None):
    """Build a minimal object matching the OpenAI SDK's response shape."""
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
    message = SimpleNamespace(content=content, tool_calls=tcs)
    return SimpleNamespace(choices=[SimpleNamespace(message=message)])


@pytest.mark.asyncio
async def test_run_turn_no_tools_returns_reply() -> None:
    client = SimpleNamespace(
        complete=AsyncMock(return_value=_make_response("Hello from MetroMind!"))
    )

    reply, tools_used, _chips, _model = await run_turn(
        client=client,
        history=[],
        user_message="Hi",
        context=None,
    )

    assert reply == "Hello from MetroMind!"
    assert tools_used == []
    client.complete.assert_awaited()


@pytest.mark.asyncio
async def test_run_turn_single_tool_then_final_reply() -> None:
    # First call: model asks for a tool. Second call: model replies.
    responses = [
        _make_response(
            content=None,
            tool_calls=[{"name": "get_service_alerts", "arguments": {"mode": "subway"}}],
        ),
        _make_response("No major alerts right now."),
    ]
    client = SimpleNamespace(complete=AsyncMock(side_effect=responses))

    fake_result = SimpleNamespace(
        name="get_service_alerts",
        content=json.dumps({"alerts": []}),
        ok=True,
        ui_label="Checking subway alerts",
    )

    with patch(
        "app.metromind.orchestrator.dispatch",
        AsyncMock(return_value=fake_result),
    ):
        reply, tools_used, _chips, _model = await run_turn(
            client=client,
            history=[],
            user_message="any delays?",
            context=None,
        )

    assert reply == "No major alerts right now."
    assert tools_used == ["get_service_alerts"]
    assert client.complete.await_count == 2


@pytest.mark.asyncio
async def test_run_turn_hits_max_iterations_gracefully() -> None:
    # Model keeps asking for tools forever.
    looping = _make_response(
        content=None,
        tool_calls=[{"name": "get_service_alerts", "arguments": {}}],
    )
    client = SimpleNamespace(complete=AsyncMock(return_value=looping))

    fake_result = SimpleNamespace(
        name="get_service_alerts",
        content="{}",
        ok=True,
        ui_label="",
    )
    with patch(
        "app.metromind.orchestrator.dispatch",
        AsyncMock(return_value=fake_result),
    ):
        reply, tools_used, _chips, _model = await run_turn(
            client=client,
            history=[],
            user_message="loop pls",
            context=None,
        )

    assert "trouble" in reply.lower() or "rephrasing" in reply.lower()
    # Should have stopped at the cap (default 4).
    assert len(tools_used) <= 8


# ── Router health check ────────────────────────────────────────────────

def test_health_reports_missing_api_key(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    from app.metromind.llm import reset_llm_client
    from app.metromind.router import router

    reset_llm_client()

    from fastapi import FastAPI

    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)

    resp = client.get("/metromind/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["llm"] == "missing_api_key"
    assert body["enabled"] is True


def test_chat_503_when_api_key_missing(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    from app.metromind.llm import reset_llm_client
    from app.metromind.router import router

    reset_llm_client()

    from fastapi import FastAPI

    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)

    resp = client.post(
        "/metromind/chat",
        json={"message": "hi", "stream": False},
    )
    assert resp.status_code == 503
