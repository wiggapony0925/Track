"""OpenAI-compatible chat completion client used by MetroMind.

Abstracted behind a thin interface so the orchestrator can be tested
with a fake. The real implementation uses the official ``openai``
AsyncClient (install on demand so the dependency stays optional until
MetroMind is actually enabled).

The client supports:

* Tool calling (required for the agent loop).
* Streaming (used for the SSE endpoint).
* Retries on transient failures via ``tenacity``.
"""

from __future__ import annotations

import os
from functools import lru_cache
from typing import Any, AsyncIterator

from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

from app.metromind.config import get_metromind_settings
from app.metromind.logger import get_logger

logger = get_logger("llm")


class LLMError(RuntimeError):
    """Any failure surfaced by the LLM client."""


class LLMNotConfigured(LLMError):
    """Raised when ``OPENAI_API_KEY`` is missing."""


class LLMClient:
    """Thin async wrapper around the OpenAI Python SDK."""

    def __init__(self, api_key: str | None = None) -> None:
        key = api_key or os.environ.get("OPENAI_API_KEY", "").strip()
        if not key:
            raise LLMNotConfigured(
                "OPENAI_API_KEY is not set — MetroMind cannot reach the LLM."
            )
        # Lazy import so openai stays optional until MetroMind is enabled.
        try:
            from openai import AsyncOpenAI
        except ImportError as exc:  # pragma: no cover — surfaces as clear error
            raise LLMNotConfigured(
                "openai package not installed. Run: pip install openai"
            ) from exc

        settings = get_metromind_settings()
        self._settings = settings
        self._client = AsyncOpenAI(api_key=key, timeout=settings.request_timeout_s)

    # ── Non-streaming -------------------------------------------------
    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=1, max=6),
        retry=retry_if_exception_type(LLMError),
        reraise=True,
    )
    async def complete(
        self,
        messages: list[dict[str, Any]],
        *,
        tools: list[dict[str, Any]] | None = None,
        model: str | None = None,
        tool_choice: str | dict[str, Any] | None = None,
    ) -> Any:
        """Single-shot chat completion, returning the raw SDK response.

        The orchestrator inspects ``response.choices[0].message`` to decide
        whether the turn is a tool call or a final assistant message.

        Pass ``model`` to override the configured default for one call
        (used by the complexity router to escalate to ``gpt-4o``).
        """
        kwargs: dict[str, Any] = {
            "model": model or self._settings.model,
            "temperature": self._settings.temperature,
            "max_tokens": self._settings.max_output_tokens,
            "messages": messages,
        }
        if tools:
            kwargs["tools"] = tools
        if tool_choice is not None:
            kwargs["tool_choice"] = tool_choice
        try:
            return await self._client.chat.completions.create(**kwargs)
        except Exception as exc:  # noqa: BLE001 — normalise via LLMError
            logger.warning("LLM call failed: %s", exc)
            raise LLMError(str(exc)) from exc

    # ── Streaming -----------------------------------------------------
    async def stream(
        self,
        messages: list[dict[str, Any]],
        *,
        tools: list[dict[str, Any]] | None = None,
        model: str | None = None,
        tool_choice: str | dict[str, Any] | None = None,
    ) -> AsyncIterator[Any]:
        """Async iterator over streaming chunks.

        Retries are *not* applied to streaming calls because partial
        output cannot be safely rewound; the orchestrator falls back to
        a non-streamed completion on failure.

        Pass ``model`` to override the configured default for one call.
        """
        kwargs: dict[str, Any] = {
            "model": model or self._settings.model,
            "temperature": self._settings.temperature,
            "max_tokens": self._settings.max_output_tokens,
            "messages": messages,
            "stream": True,
        }
        if tools:
            kwargs["tools"] = tools
        if tool_choice is not None:
            kwargs["tool_choice"] = tool_choice
        try:
            stream = await self._client.chat.completions.create(**kwargs)
        except Exception as exc:  # noqa: BLE001
            logger.warning("LLM stream open failed: %s", exc)
            raise LLMError(str(exc)) from exc

        async for chunk in stream:
            yield chunk

    # ── Audio transcription (Whisper) ─────────────────────────────────
    async def transcribe(
        self,
        audio_bytes: bytes,
        *,
        filename: str = "audio.m4a",
        language: str | None = "en",
    ) -> str:
        """Transcribe a short audio clip using OpenAI's audio API.

        ``audio_bytes`` is the raw file contents (m4a / mp3 / wav / webm).
        Returns the recognized text, or an empty string on a soft failure.
        """
        import io

        buf = io.BytesIO(audio_bytes)
        buf.name = filename  # OpenAI SDK uses .name to infer mime type
        try:
            kwargs: dict[str, Any] = {
                "model": self._settings.transcription_model,
                "file": buf,
            }
            if language:
                kwargs["language"] = language
            resp = await self._client.audio.transcriptions.create(**kwargs)
        except Exception as exc:  # noqa: BLE001
            logger.warning("Whisper transcription failed: %s", exc)
            raise LLMError(str(exc)) from exc

        text = getattr(resp, "text", "") or ""
        return text.strip()


@lru_cache(maxsize=1)
def get_llm_client() -> LLMClient:
    """Return the shared async LLM client (raises if key missing)."""
    return LLMClient()


def reset_llm_client() -> None:
    """Test helper — clear the cached singleton."""
    get_llm_client.cache_clear()


__all__ = [
    "LLMClient",
    "LLMError",
    "LLMNotConfigured",
    "get_llm_client",
    "reset_llm_client",
]
