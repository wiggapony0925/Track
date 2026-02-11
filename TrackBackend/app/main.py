#
# main.py
# TrackBackend
#
# Application entry point. Registers all routers and serves the /config
# endpoint that the iOS app fetches on launch.
#

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Request

from app.config import get_settings
from app.routers import bus, lirr, status, subway
from app.utils.logger import TrackLogger

app = FastAPI(
    title="Track API",
    description="Proxy API for the Track NYC Transit iOS app",
    version="1.0.0",
)

# Register routers
app.include_router(subway.router)
app.include_router(lirr.router)
app.include_router(status.router)
app.include_router(bus.router)


@app.on_event("startup")
async def startup_event():
    TrackLogger.startup()


# Middleware to log every request with color
@app.middleware("http")
async def log_requests(request: Request, call_next):
    response = await call_next(request)
    TrackLogger.request(request.method, request.url.path, response.status_code)
    return response


@app.get("/config")
async def config() -> dict[str, Any]:
    """Return the *app_settings* block from settings.json."""
    settings = get_settings()
    return settings.app_settings.model_dump()
