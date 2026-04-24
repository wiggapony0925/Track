"""FastAPI router for MetroMind."""

from __future__ import annotations

import asyncio
import json
from typing import AsyncIterator

from fastapi import APIRouter, File, HTTPException, UploadFile
from fastapi.responses import StreamingResponse

from app.metromind import thread_store
from app.metromind import feedback_store
from app.metromind.config import get_metromind_settings
from app.metromind.llm import LLMError, LLMNotConfigured, get_llm_client
from app.metromind.logger import get_logger
from app.metromind.orchestrator import run_turn, stream_turn
from app.metromind.schemas import ChatMessage, ChatRequest, ChatResponse

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

    # ── Thread persistence (J) ──
    # When thread_id is provided AND the client did not include any
    # explicit history, hydrate from the store. Otherwise trust what
    # the client sent (allows offline/local edits to win).
    request = await _hydrate_thread_history(request, settings.thread_load_limit)

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
        reply, tools_used, chips, model_used = await run_turn(
            client=client,
            history=request.history,
            user_message=request.message,
            context=request.context,
            image_data_url=request.image_data_url,
        )
    except LLMError as exc:
        logger.warning("LLM call failed: %s", exc)
        raise HTTPException(status_code=502, detail=f"LLM error: {exc}") from exc

    if request.thread_id:
        await _persist_turn(request, reply)

    return ChatResponse(
        reply=reply,
        tool_calls=tools_used,
        suggested_actions=chips,
        model_used=model_used,
        thread_id=request.thread_id,
    )


async def _sse_event_stream(client, request: ChatRequest) -> AsyncIterator[bytes]:
    """Serialise orchestrator events into the SSE wire format."""
    assistant_buf: list[str] = []
    try:
        async for event in stream_turn(
            client=client,
            history=request.history,
            user_message=request.message,
            context=request.context,
            image_data_url=request.image_data_url,
            thread_id=request.thread_id,
        ):
            if event.get("type") == "token":
                assistant_buf.append(event.get("text") or "")
            payload = json.dumps(event, separators=(",", ":"))
            yield f"data: {payload}\n\n".encode("utf-8")
    except Exception as exc:  # noqa: BLE001 — keep the socket alive long enough to tell the client
        logger.exception("SSE stream crashed")
        err = json.dumps({"type": "error", "message": f"Internal error: {exc}"})
        yield f"data: {err}\n\n".encode("utf-8")
        return

    if request.thread_id and assistant_buf:
        await _persist_turn(request, "".join(assistant_buf))


# ── Thread CRUD (J) ────────────────────────────────────────────────────────

@router.post(
    "/threads",
    summary="Create a new chat thread",
    description="Returns an opaque ``thread_id`` to send with future /chat calls.",
)
async def create_thread(body: dict | None = None) -> dict:
    title = (body or {}).get("title") if isinstance(body, dict) else None
    tid = await asyncio.to_thread(thread_store.create_thread, title)
    return {"thread_id": tid}


@router.get(
    "/threads/{thread_id}",
    summary="Fetch persisted history for a thread",
)
async def get_thread(thread_id: str, limit: int = 50) -> dict:
    if not await asyncio.to_thread(thread_store.thread_exists, thread_id):
        raise HTTPException(status_code=404, detail="Thread not found")
    msgs = await asyncio.to_thread(thread_store.load_messages, thread_id, limit)
    return {
        "thread_id": thread_id,
        "messages": [m.model_dump() for m in msgs],
    }


@router.delete(
    "/threads/{thread_id}",
    summary="Delete a chat thread and its messages",
)
async def delete_thread(thread_id: str) -> dict:
    deleted = await asyncio.to_thread(thread_store.delete_thread, thread_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="Thread not found")
    return {"deleted": True}


# ── Voice (G) ──────────────────────────────────────────────────────────────

@router.post(
    "/transcribe",
    summary="Transcribe a short voice clip to text",
    description=(
        "Accepts an audio file (m4a / mp3 / wav / webm, up to ~5 MB) and "
        "returns the recognized text. Used by the iOS chat composer's "
        "hold-to-talk button. Powered by OpenAI Whisper."
    ),
)
async def transcribe(
    audio: UploadFile = File(..., description="Audio clip to transcribe."),
    language: str | None = "en",
) -> dict:
    settings = get_metromind_settings()
    if not settings.enabled:
        raise HTTPException(status_code=503, detail="MetroMind is disabled.")

    # Read and size-check the upload.
    data = await audio.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty audio upload.")
    if len(data) > settings.max_audio_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"Audio too large (>{settings.max_audio_bytes // 1024} KB).",
        )

    try:
        client = get_llm_client()
    except LLMNotConfigured as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    filename = audio.filename or "clip.m4a"
    try:
        text = await client.transcribe(data, filename=filename, language=language)
    except LLMError as exc:
        raise HTTPException(status_code=502, detail=f"Transcription failed: {exc}") from exc

    return {
        "text": text,
        "model": settings.transcription_model,
        "duration_bytes": len(data),
    }

# ── Feedback (thumbs up / down) ────────────────────────────────────────────

@router.post(
    "/feedback",
    summary="Record a thumbs-up / thumbs-down on an assistant reply",
    description=(
        "Lightweight analytics endpoint the iOS chat calls when the user "
        "taps the thumbs button on a MetroMind reply. Stores rating, the "
        "prompt + reply text (truncated), the optional reason, and the "
        "app version + model so we can later filter regressions."
    ),
)
async def submit_feedback(body: dict) -> dict:
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Body must be JSON object.")
    raw_rating = body.get("rating")
    try:
        rating = int(raw_rating)
    except (TypeError, ValueError) as exc:
        raise HTTPException(
            status_code=400, detail="`rating` must be 1 or -1."
        ) from exc
    if rating not in (1, -1):
        raise HTTPException(status_code=400, detail="`rating` must be 1 or -1.")

    def _str(field: str) -> str | None:
        v = body.get(field)
        if v is None:
            return None
        if not isinstance(v, str):
            return str(v)
        return v.strip() or None

    try:
        row_id = await asyncio.to_thread(
            feedback_store.record_feedback,
            rating=rating,
            thread_id=_str("thread_id"),
            client_msg_id=_str("client_msg_id"),
            user_prompt=_str("user_prompt"),
            assistant_text=_str("assistant_text"),
            reason=_str("reason"),
            app_version=_str("app_version"),
            model_used=_str("model_used"),
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        logger.exception("feedback insert failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    return {"ok": True, "id": row_id}


@router.get(
    "/feedback/summary",
    summary="Aggregate feedback counts + recent rows",
    description="Returns thumbs-up / thumbs-down totals and the latest entries.",
)
async def feedback_summary(limit: int = 100) -> dict:
    try:
        return await asyncio.to_thread(feedback_store.feedback_summary, limit)
    except Exception as exc:  # noqa: BLE001
        logger.exception("feedback summary failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc

# ── Helpers ────────────────────────────────────────────────────────────────

async def _hydrate_thread_history(
    request: ChatRequest, limit: int
) -> ChatRequest:
    """If thread_id is set and the client sent no history, load from store."""
    if not request.thread_id or request.history:
        return request
    msgs = await asyncio.to_thread(
        thread_store.load_messages, request.thread_id, limit
    )
    return request.model_copy(update={"history": msgs})


async def _persist_turn(request: ChatRequest, reply: str) -> None:
    """Append the user turn and assistant reply to the thread store."""
    if not request.thread_id:
        return
    try:
        await asyncio.to_thread(
            thread_store.append_message,
            request.thread_id,
            "user",
            request.message,
            image_data_url=request.image_data_url,
        )
        await asyncio.to_thread(
            thread_store.append_message,
            request.thread_id,
            "assistant",
            reply,
        )
    except Exception as exc:  # noqa: BLE001 — persistence must never break the reply
        logger.warning("thread persist failed: %s", exc)


__all__ = ["router"]
