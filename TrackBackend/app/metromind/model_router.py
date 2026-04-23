"""Heuristic model router for MetroMind (Batch 2 — E).

Decides whether to escalate from the cheap default model to the
stronger ``complex_model`` (or vision model) for a given turn.

Pure local logic, no LLM call. Cheap to run.
"""

from __future__ import annotations

import re

from app.metromind.config import get_metromind_settings
from app.metromind.schemas import ChatMessage


_LONG_THRESHOLD = 200          # chars
_DEEP_HISTORY = 8               # turns
_COMPLEXITY_HINTS = re.compile(
    r"\b(compare|why|explain|optimi[sz]e|cheapest|best.*and|"
    r"trade.?off|step.by.step|both|all options)\b",
    re.IGNORECASE,
)
_MULTI_DEST = re.compile(
    r"\b(?:and then|after that|then to|stop at|via)\b",
    re.IGNORECASE,
)


def pick_model(
    *,
    user_message: str,
    history: list[ChatMessage],
    has_image: bool,
) -> tuple[str, str]:
    """Return ``(model_name, reason)``.

    ``reason`` is a short tag for logging / SSE telemetry, e.g.
    ``"default"``, ``"long_prompt"``, ``"vision"``.
    """
    settings = get_metromind_settings()

    if has_image:
        return settings.vision_model, "vision"

    if not settings.auto_escalate_complex:
        return settings.model, "default"

    msg = user_message.strip()

    if len(msg) >= _LONG_THRESHOLD:
        return settings.complex_model, "long_prompt"

    if msg.count("?") >= 2:
        return settings.complex_model, "multi_question"

    if _COMPLEXITY_HINTS.search(msg):
        return settings.complex_model, "complexity_hint"

    if _MULTI_DEST.search(msg):
        return settings.complex_model, "multi_destination"

    if len(history) >= _DEEP_HISTORY:
        return settings.complex_model, "deep_history"

    return settings.model, "default"


__all__ = ["pick_model"]
