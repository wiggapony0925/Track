"""
FastAPI routers — one per transit mode / feature.

All routers expose a ``router`` attribute that is registered in
``app.main`` via ``app.include_router()``.
"""

__all__ = [
    "analytics",
    "bus",
    "lirr",
    "mnr",
    "nearby",
    "predict",
    "static_data",
    "status",
    "subway",
]
