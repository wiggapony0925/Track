#
# main.py
# TrackBackend
#
# Application entry point. Registers all routers and serves the /config
# endpoint that the iOS app fetches on launch.
#

from __future__ import annotations

import time
from typing import Any

from fastapi import FastAPI, Request

from app.config import get_settings
from app.routers import analytics, bus, lirr, mnr, nearby, predict, status, subway, static_data
from app.services.bus_client import close_shared_cache, init_shared_cache
from app.utils.logger import TrackLogger

app = FastAPI(
    title="Track API",
    description="Proxy API for the Track NYC Transit iOS app",
    version="1.0.0",
)

# Register routers
app.include_router(subway.router)
app.include_router(lirr.router)
app.include_router(mnr.router)
app.include_router(status.router)
app.include_router(bus.router)
app.include_router(nearby.router)
app.include_router(predict.router)
app.include_router(analytics.router)
app.include_router(static_data.router)


@app.on_event("startup")
async def startup_event():
    TrackLogger.startup()
    await init_shared_cache()


@app.on_event("shutdown")
async def shutdown_event():
    await close_shared_cache()


# Middleware to log every request with color, query params, and timing
@app.middleware("http")
async def log_requests(request: Request, call_next):
    start = time.perf_counter()
    user_email = (
        request.headers.get("x-user-email")
        or request.headers.get("x-auth-email")
        or request.query_params.get("email")
        or "-"
    )
    TrackLogger.set_user_email(user_email)

    try:
        response = await call_next(request)
        elapsed_ms = (time.perf_counter() - start) * 1000
        query = f"?{request.url.query}" if request.url.query else ""
        TrackLogger.request(
            request.method,
            f"{request.url.path}{query}",
            response.status_code,
            elapsed_ms=elapsed_ms,
        )
        return response
    finally:
        TrackLogger.clear_user_email()


@app.get("/config")
async def config() -> dict[str, Any]:
    """Return the *app_settings* block from settings.json."""
    settings = get_settings()
    return settings.app_settings.model_dump()
