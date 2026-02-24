#
# main.py
# TrackBackend
#
# Application entry point. Registers all routers and serves the /config
# endpoint that the iOS app fetches on launch.
#

from __future__ import annotations

import asyncio
import os
import time
from typing import Any

from fastapi import FastAPI, Request

from app.config import get_settings
from app.routers import bus, lirr, mnr, nearby, predict, status, subway
from app.services.bus_client import close_shared_cache, init_shared_cache
from app.services.data_loader import ensure_data_available
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


# Background task handle for periodic GTFS refresh
_gtfs_refresh_task: asyncio.Task | None = None

# How often to check MTA for new GTFS data (default: 24 hours)
_GTFS_CHECK_INTERVAL = int(os.environ.get("GTFS_CHECK_INTERVAL", 86400))


@app.on_event("startup")
async def startup_event():
    global _gtfs_refresh_task
    TrackLogger.startup()
    # Download fresh GTFS data from Supabase (falls back to Docker-bundled files)
    await ensure_data_available()
    await init_shared_cache()
    # Start background GTFS freshness checker
    _gtfs_refresh_task = asyncio.create_task(_periodic_gtfs_check())


@app.on_event("shutdown")
async def shutdown_event():
    global _gtfs_refresh_task
    if _gtfs_refresh_task:
        _gtfs_refresh_task.cancel()
    await close_shared_cache()


async def _periodic_gtfs_check():
    """Background task: check MTA feeds for updates periodically."""
    from app.services.gtfs_refresh import check_and_refresh_gtfs

    # Wait 5 minutes after startup before first check (let server warm up)
    await asyncio.sleep(300)

    while True:
        try:
            TrackLogger.info(
                f"[GTFS] Periodic check starting (interval={_GTFS_CHECK_INTERVAL}s)",
                tag="GTFS",
            )
            await check_and_refresh_gtfs(full_check=False)
        except asyncio.CancelledError:
            break
        except Exception as exc:
            TrackLogger.error(
                f"[GTFS] Periodic check failed: {exc}", tag="GTFS"
            )
        await asyncio.sleep(_GTFS_CHECK_INTERVAL)


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


@app.get("/data/status")
async def data_status() -> dict[str, Any]:
    """Check which GTFS data groups are available and their freshness."""
    from app.services.data_loader import check_local_data_status
    from app.services.gtfs_refresh import get_gtfs_freshness
    return {
        "data_groups": check_local_data_status(),
        "gtfs_feeds": get_gtfs_freshness(),
    }


@app.post("/data/refresh")
async def data_refresh(full: bool = False) -> dict[str, Any]:
    """Manually trigger a GTFS data refresh check.

    Query params:
        full: If true, check all feeds including bus (slower).
              Default checks only subway/lirr/mnr.
    """
    from app.services.gtfs_refresh import check_and_refresh_gtfs
    results = await check_and_refresh_gtfs(full_check=full)
    return {"results": results}
