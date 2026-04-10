"""
FastAPI routers — one per transit mode / feature.

All routers expose a ``router`` attribute that is registered in
``app.main`` via ``app.include_router()``.
"""

from __future__ import annotations

__all__ = [
    "bus",
    "lirr",
    "mnr",
    "nearby",
    "predict",
    "status",
    "subway",
    "track_engine_router",
    "weather",
]
