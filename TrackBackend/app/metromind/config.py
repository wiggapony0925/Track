"""MetroMind configuration — tunable LLM + orchestration knobs."""

from __future__ import annotations

import os
from functools import lru_cache

from pydantic import BaseModel


class MetroMindSettings(BaseModel):
    """Runtime knobs for the MetroMind chatbot.

    Read once at startup; override any value via environment variables
    prefixed ``METROMIND_`` (e.g. ``METROMIND_MODEL=gpt-4o-mini``).
    """

    # ── LLM ────────────────────────────────────────────────────────────
    model: str = "gpt-4o-mini"
    temperature: float = 0.3
    max_output_tokens: int = 800
    # Hard ceiling for tool-call hops per user turn. Prevents runaway loops.
    max_tool_iterations: int = 4
    # OpenAI request timeout (seconds).
    request_timeout_s: float = 30.0

    # ── Behaviour ──────────────────────────────────────────────────────
    # Max messages of history kept in context on each turn.
    history_window: int = 12
    # Enable SSE streaming (set False for easier local debugging).
    streaming_enabled: bool = True

    # ── Feature flags ──────────────────────────────────────────────────
    # Master kill switch. When False, /metromind/chat returns 503.
    enabled: bool = True


_ENV_PREFIX = "METROMIND_"


def _env_overrides() -> dict[str, object]:
    """Collect ``METROMIND_*`` env vars and coerce to model field types."""
    overrides: dict[str, object] = {}
    schema = MetroMindSettings.model_fields
    for field_name, info in schema.items():
        env_key = f"{_ENV_PREFIX}{field_name.upper()}"
        raw = os.environ.get(env_key)
        if raw is None:
            continue
        annotation = info.annotation
        try:
            if annotation is bool:
                overrides[field_name] = raw.lower() in {"1", "true", "yes", "on"}
            elif annotation is int:
                overrides[field_name] = int(raw)
            elif annotation is float:
                overrides[field_name] = float(raw)
            else:
                overrides[field_name] = raw
        except (TypeError, ValueError):
            # Malformed env var — ignore and use default.
            continue
    return overrides


@lru_cache(maxsize=1)
def get_metromind_settings() -> MetroMindSettings:
    """Singleton settings instance."""
    return MetroMindSettings(**_env_overrides())


def reset_metromind_settings() -> None:
    """Test helper — clear the cached singleton."""
    get_metromind_settings.cache_clear()


__all__ = [
    "MetroMindSettings",
    "get_metromind_settings",
    "reset_metromind_settings",
]
