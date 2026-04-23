"""Pydantic schemas for MetroMind endpoints."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


ChatRole = Literal["user", "assistant", "system"]


class ChatMessage(BaseModel):
    """A single message in the chat history."""

    role: ChatRole
    content: str


class UserContext(BaseModel):
    """Optional client-provided context attached to each turn.

    The iOS app sends these hints so MetroMind can answer location- and
    time-aware questions without the user restating them.
    """

    lat: float | None = Field(None, description="Device latitude.")
    lon: float | None = Field(None, description="Device longitude.")
    timezone: str = Field(
        default="America/New_York",
        description="IANA timezone for relative time answers.",
    )
    current_station_id: str | None = Field(
        None, description="GTFS stop_id of the station the user is near, if any."
    )
    locale: str = Field(default="en-US", description="Preferred response language.")


class ChatRequest(BaseModel):
    """Body of ``POST /metromind/chat``."""

    message: str = Field(..., min_length=1, max_length=2000)
    history: list[ChatMessage] = Field(
        default_factory=list,
        description=(
            "Prior conversation turns the client wants to keep in scope. "
            "The server will truncate to the configured history_window."
        ),
    )
    context: UserContext | None = None
    stream: bool = Field(
        default=True,
        description="If true, response is SSE. If false, a single JSON blob.",
    )


class ChatResponse(BaseModel):
    """Non-streamed response shape."""

    reply: str
    tool_calls: list[str] = Field(
        default_factory=list,
        description="Names of tools the model invoked (for telemetry/UI).",
    )


# ── SSE event payloads ────────────────────────────────────────────────
# Each event is serialised as `data: {json}\n\n` on the wire.


class SSETokenEvent(BaseModel):
    type: Literal["token"] = "token"
    text: str


class SSEToolCallEvent(BaseModel):
    """Sent when the model decides to call a tool (before execution)."""

    type: Literal["tool_call"] = "tool_call"
    name: str
    # A short human-readable status string for the UI ("Checking alerts…").
    label: str


class SSEToolResultEvent(BaseModel):
    type: Literal["tool_result"] = "tool_result"
    name: str
    ok: bool
    # Tool-result JSON payload, surfaced to the UI so it can render
    # rich cards (itineraries, station lists). Omitted for tools whose
    # raw output isn't useful for the client (e.g. service alerts blob).
    payload: dict | None = None


class SSEDoneEvent(BaseModel):
    type: Literal["done"] = "done"
    tool_calls: list[str] = Field(default_factory=list)


class SSEErrorEvent(BaseModel):
    type: Literal["error"] = "error"
    message: str


__all__ = [
    "ChatMessage",
    "ChatRequest",
    "ChatResponse",
    "ChatRole",
    "SSEDoneEvent",
    "SSEErrorEvent",
    "SSEToolCallEvent",
    "SSEToolResultEvent",
    "SSETokenEvent",
    "UserContext",
]
