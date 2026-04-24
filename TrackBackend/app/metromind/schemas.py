"""Pydantic schemas for MetroMind endpoints."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


ChatRole = Literal["user", "assistant", "system"]


class ChatMessage(BaseModel):
    """A single message in the chat history."""

    role: ChatRole
    content: str
    # Optional: data URL (``data:image/jpeg;base64,...``) attached to a
    # user turn. When present, the orchestrator routes the turn through
    # a vision-capable model.
    image_data_url: str | None = Field(
        default=None,
        description="Optional base64 data URL for an attached image.",
    )


class SavedPlace(BaseModel):
    """A user-saved destination (Home, Work, custom)."""

    label: str = Field(..., description='Display name (e.g. "Home", "Mom\'s house").')
    kind: str = Field(..., description='"home", "work", or "custom".')
    lat: float
    lon: float
    address: str | None = None


class RecentTrip(BaseModel):
    """A recently planned trip — used for personalised follow-ups."""

    origin_label: str
    destination_label: str
    summary: str | None = None
    requested_at: int | None = Field(
        None, description="Unix epoch seconds when the trip was last planned."
    )


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
    user_name: str | None = Field(
        None, description="The user's first name, if known (for friendly addressing)."
    )
    saved_places: list[SavedPlace] = Field(
        default_factory=list,
        description="User's saved places (Home, Work, custom). Used for queries like 'how do I get home'.",
    )
    recent_trips: list[RecentTrip] = Field(
        default_factory=list,
        description="Recently planned trips, newest first. Capped to ~10 by the client.",
    )
    top_routes: list[str] = Field(
        default_factory=list,
        description=(
            "User's most-interacted route IDs ranked by usage (newest first). "
            "Computed client-side from the local route-engagement log. "
            "Used by the suggestion-chip builder to personalise default chips "
            "(e.g. \"Any 7 delays?\" instead of always defaulting to L)."
        ),
    )
    # ── Location bias ("near me" / "around this pin") ─────────────────
    bias_lat: float | None = Field(
        None,
        description=(
            "Latitude the user wants 'near me' / 'around here' queries to "
            "focus on. Defaults to device GPS, but switches to a map-pin "
            "location when the user has dropped a drag-search pin."
        ),
    )
    bias_lon: float | None = Field(None, description="Longitude paired with bias_lat.")
    bias_source: Literal["gps", "map_pin"] | None = Field(
        None,
        description="Where the bias point came from — 'gps' (device) or 'map_pin' (drag-search).",
    )
    bias_label: str | None = Field(
        None,
        description="Human-readable label for the bias point (e.g. 'Union Square', 'Pinned spot').",
    )


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
    # ── Persistent threads (J) ─────────────────────────────────────────
    thread_id: str | None = Field(
        default=None,
        description=(
            "Opaque server-side thread id. When provided, the server "
            "loads recent messages from its store (overriding ``history`` "
            "if that is empty) and persists this turn after completion."
        ),
    )
    # ── Multimodal (L) ─────────────────────────────────────────────────
    image_data_url: str | None = Field(
        default=None,
        description=(
            "Optional ``data:image/...;base64,...`` URL attached to the "
            "current user message. Forces escalation to a vision model."
        ),
    )


class SuggestedAction(BaseModel):
    """A follow-up chip rendered under the assistant reply (D)."""

    label: str = Field(..., description="Short text shown on the chip.")
    kind: str = Field(
        ...,
        description=(
            "Action verb the client should perform when tapped. "
            "One of: ``send_prompt``, ``save_trip``, ``start_tracking``, "
            "``open_alerts``, ``open_place``."
        ),
    )
    payload: dict = Field(
        default_factory=dict,
        description="Free-form JSON the client uses to fulfil the action.",
    )


class ChatResponse(BaseModel):
    """Non-streamed response shape."""

    reply: str
    tool_calls: list[str] = Field(
        default_factory=list,
        description="Names of tools the model invoked (for telemetry/UI).",
    )
    suggested_actions: list[SuggestedAction] = Field(
        default_factory=list,
        description="Up to 3 follow-up chips for the UI.",
    )
    model_used: str | None = Field(
        default=None,
        description="Which LLM model handled the turn (for observability).",
    )
    thread_id: str | None = Field(
        default=None,
        description="Echoed back so the client can persist it.",
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


class SSESuggestionsEvent(BaseModel):
    """Emitted just before ``done`` so the UI can render chips (D)."""

    type: Literal["suggestions"] = "suggestions"
    actions: list[SuggestedAction] = Field(default_factory=list)


class SSEDoneEvent(BaseModel):
    type: Literal["done"] = "done"
    tool_calls: list[str] = Field(default_factory=list)
    model_used: str | None = None
    thread_id: str | None = None


class SSEErrorEvent(BaseModel):
    type: Literal["error"] = "error"
    message: str


__all__ = [
    "ChatMessage",
    "ChatRequest",
    "ChatResponse",
    "ChatRole",
    "RecentTrip",
    "SavedPlace",
    "SSEDoneEvent",
    "SSEErrorEvent",
    "SSESuggestionsEvent",
    "SSEToolCallEvent",
    "SSEToolResultEvent",
    "SSETokenEvent",
    "SuggestedAction",
    "UserContext",
]
