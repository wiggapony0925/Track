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
    # Stronger model used when the user turn looks complex (long, multi-clause,
    # "compare", multiple destinations, attached image, deep history).
    complex_model: str = "gpt-4o"
    # Vision-capable model forced when the turn carries an image_data_url.
    vision_model: str = "gpt-4o"
    # Audio-to-text model used by /metromind/transcribe (G).
    transcription_model: str = "whisper-1"
    # Max audio bytes accepted by /metromind/transcribe (default 5 MB).
    max_audio_bytes: int = 5 * 1024 * 1024
    temperature: float = 0.3
    max_output_tokens: int = 800
    # Hard ceiling for tool-call hops per user turn. Prevents runaway loops.
    # Set to 6 (was 4) to absorb the rare double-replan on ambiguous trip
    # prompts ("fastest from soho to upper east side") that previously hit
    # the cap and erred out in production. The orchestrator also has a
    # per-turn dedupe (won't re-run an identical tool call) so a higher
    # cap doesn't translate to wasted spend.
    max_tool_iterations: int = 6
    # OpenAI request timeout (seconds).
    request_timeout_s: float = 30.0

    # ── Behaviour ───────────────────────────────────────────────────
    # Max messages of history kept in context on each turn.
    history_window: int = 12
    # Enable SSE streaming (set False for easier local debugging).
    streaming_enabled: bool = True
    # Auto-escalate complex turns to ``complex_model`` (E).
    auto_escalate_complex: bool = True

    # ── Persistence (J) ──────────────────────────────────────────────────
    # Server-side thread store DB path. Lives on the Render persistent
    # disk in production (mounted at /app/app/data).
    threads_db_path: str = "app/data/metromind_threads.db"
    # How many messages to load from the store when a thread_id is sent.
    thread_load_limit: int = 24

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
