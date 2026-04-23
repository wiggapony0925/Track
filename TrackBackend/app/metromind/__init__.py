"""MetroMind — conversational AI layer for Track.

Wraps a cheap LLM (default: gpt-4o-mini) with tool-calling access to the
existing Track backend: route planning, service alerts, nearby stops,
live arrivals, and station search.

The package is self-contained under ``app/metromind``:

    config.py       — settings (model, temperature, key names)
    logger.py       — scoped "MetroMind" logger
    schemas.py      — request/response Pydantic models
    prompts/        — system prompts
    llm/            — OpenAI client wrapper
    tools/          — tool definitions + dispatch into Track services
    orchestrator.py — the agent loop (LLM → tool → LLM → stream)
    router.py       — FastAPI endpoints, including /metromind/chat (SSE)
    tests/          — unit tests for tools and orchestrator
"""

from app.metromind.router import router

__all__ = ["router"]
