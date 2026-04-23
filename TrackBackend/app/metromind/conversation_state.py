"""Heuristic slot extraction for conversational continuity.

Pulls structured state out of recent chat history so the LLM can answer
follow-ups like "what about now?", "and back?", "how about Brooklyn instead?"
without re-asking the user every time.

Pure local logic — no extra LLM call. Cheap and deterministic.
"""

from __future__ import annotations

import re
from typing import Any

from pydantic import BaseModel, Field

from app.metromind.schemas import ChatMessage


# Words that signal the user is referring back to a prior trip.
_REFER_BACK = re.compile(
    r"\b(now|again|same|that|it|what about|how about|and back|return)\b",
    re.IGNORECASE,
)
# Common trip phrasings.
_TRIP_RE = re.compile(
    r"(?:from|leaving|starting at)\s+([A-Z][\w\s\-\.&']{2,40})\s+(?:to|→|->)\s+([A-Z][\w\s\-\.&']{2,40})",
    re.IGNORECASE,
)
# "going to X" / "get to X" / "head to X"
_DEST_ONLY_RE = re.compile(
    r"\b(?:going to|get(?:ting)? to|head(?:ing)? to|take me to|how do i get to)\s+([A-Z][\w\s\-\.&']{2,40})",
    re.IGNORECASE,
)
# Saved-place keywords.
_SAVED_REFS = re.compile(r"\b(home|work|office|school|mom'?s|dad'?s)\b", re.IGNORECASE)


class ConversationState(BaseModel):
    """Compact, structured memory of the active conversation."""

    last_origin: str | None = Field(
        None, description="Most recent origin the user mentioned (free text)."
    )
    last_destination: str | None = Field(
        None, description="Most recent destination the user mentioned (free text)."
    )
    intent: str | None = Field(
        None, description="One of: routing | alerts | trivia | personal | unknown."
    )
    refers_back: bool = Field(
        False,
        description=(
            "True when the current message likely references a prior trip "
            "('what about now?', 'and back?', 'same trip later')."
        ),
    )
    mentions_saved_place: str | None = Field(
        None, description='Saved place keyword present in current msg ("home", "work"...).'
    )

    def is_empty(self) -> bool:
        return not (
            self.last_origin
            or self.last_destination
            or self.intent
            or self.refers_back
            or self.mentions_saved_place
        )

    def render_block(self) -> str:
        """Render as a markdown block for the system prompt."""
        if self.is_empty():
            return ""
        lines = ["## Conversation state"]
        if self.last_origin:
            lines.append(f"- Last origin discussed: **{self.last_origin}**")
        if self.last_destination:
            lines.append(f"- Last destination discussed: **{self.last_destination}**")
        if self.intent:
            lines.append(f"- Inferred intent: {self.intent}")
        if self.mentions_saved_place:
            lines.append(
                f"- Current message references saved place: "
                f"**{self.mentions_saved_place}** (resolve via Saved places block)."
            )
        if self.refers_back:
            lines.append(
                "- This message likely refers to the previous trip. "
                "Reuse the last origin/destination unless the user clearly switches topic."
            )
        return "\n".join(lines)


def _classify_intent(text: str) -> str:
    t = text.lower()
    if any(k in t for k in ("alert", "delay", "suspend", "service change", "running")):
        return "alerts"
    if any(
        k in t
        for k in (
            "how do i get",
            "best way to",
            "route to",
            "get to",
            "going to",
            "take me",
            "directions",
            "trip",
        )
    ):
        return "routing"
    if any(
        k in t
        for k in ("history", "when was", "who built", "r211", "r46", "trivia", "fleet")
    ):
        return "trivia"
    if any(k in t for k in ("saved", "my places", "my trips", "recent")):
        return "personal"
    return "unknown"


def _extract_endpoints(text: str) -> tuple[str | None, str | None]:
    m = _TRIP_RE.search(text)
    if m:
        return m.group(1).strip(), m.group(2).strip()
    m = _DEST_ONLY_RE.search(text)
    if m:
        return None, m.group(1).strip()
    return None, None


def extract_state(
    history: list[ChatMessage],
    user_message: str,
    *,
    history_window: int = 8,
) -> ConversationState:
    """Build a ConversationState from history + current message."""
    state = ConversationState()
    state.intent = _classify_intent(user_message)
    state.refers_back = bool(_REFER_BACK.search(user_message))
    saved = _SAVED_REFS.search(user_message)
    if saved:
        state.mentions_saved_place = saved.group(1).lower().rstrip("'s")

    # Look back through recent history for the latest origin/destination
    # mention (user messages preferred, but assistant rephrasings count too).
    recent = history[-history_window:] if history else []
    for msg in (*recent, ChatMessage(role="user", content=user_message)):
        origin, dest = _extract_endpoints(msg.content)
        if origin:
            state.last_origin = origin
        if dest:
            state.last_destination = dest
    return state


__all__ = ["ConversationState", "extract_state"]
