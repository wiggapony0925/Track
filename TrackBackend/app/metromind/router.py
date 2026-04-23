"""FastAPI router for MetroMind."""

from __future__ import annotations

import json
from typing import AsyncIterator

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse

from app.metromind.config import get_metromind_settings
from app.metromind.llm import LLMError, LLMNotConfigured, get_llm_client
from app.metromind.logger import get_logger
from app.metromind.orchestrator import run_turn, stream_turn
from app.metromind.schemas import ChatRequest, ChatResponse

router = APIRouter(prefix="/metromind", tags=["metromind"])
logger = get_logger("router")


@router.get(
    "/health",
    summary="Service health for MetroMind",
    description="Reports whether MetroMind is enabled and reachable.",
)
async def health() -> dict[str, object]:
    settings = get_metromind_settings()
    status: dict[str, object] = {
        "enabled": settings.enabled,
        "model": settings.model,
        "streaming_enabled": settings.streaming_enabled,
    }
    try:
        get_llm_client()
        status["llm"] = "ready"
    except LLMNotConfigured as exc:
        status["llm"] = "missing_api_key"
        status["detail"] = str(exc)
    return status


@router.post(
    "/chat",
    summary="Chat with MetroMind",
    description=(
        "Send a message to the MetroMind AI assistant. When ``stream=true`` "
        "(default) the response is a Server-Sent Events stream with event "
        "types: ``token``, ``tool_call``, ``tool_result``, ``done``, ``error``."
    ),
)
async def chat(request: ChatRequest):
    settings = get_metromind_settings()
    if not settings.enabled:
        raise HTTPException(status_code=503, detail="MetroMind is disabled.")

    try:
        client = get_llm_client()
    except LLMNotConfigured as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    if request.stream and settings.streaming_enabled:
        return StreamingResponse(
            _sse_event_stream(client, request),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",  # Disable Nginx buffering.
            },
        )

    # Non-streaming JSON response.
    try:
        reply, tools_used = await run_turn(
            client=client,
            history=request.history,
            user_message=request.message,
            context=request.context,
        )
    except LLMError as exc:
        logger.warning("LLM call failed: %s", exc)
        raise HTTPException(status_code=502, detail=f"LLM error: {exc}") from exc
    return ChatResponse(reply=reply, tool_calls=tools_used)


async def _sse_event_stream(client, request: ChatRequest) -> AsyncIterator[bytes]:
    """Serialise orchestrator events into the SSE wire format."""
    try:
        async for event in stream_turn(
            client=client,
            history=request.history,
            user_message=request.message,
            context=request.context,
        ):
            payload = json.dumps(event, separators=(",", ":"))
            yield f"data: {payload}\n\n".encode("utf-8")
    except Exception as exc:  # noqa: BLE001 — keep the socket alive long enough to tell the client
        logger.exception("SSE stream crashed")
        err = json.dumps({"type": "error", "message": f"Internal error: {exc}"})
        yield f"data: {err}\n\n".encode("utf-8")


__all__ = ["router"]
