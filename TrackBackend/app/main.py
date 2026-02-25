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
from app.services.bus_client import close_shared_cache, init_shared_cache, clear_bus_cache
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
    # Prime caches in background so first real user never eats a cold penalty
    asyncio.create_task(_warmup_caches())


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


async def _warmup_caches():
    """Pre-fetch subway feeds and bus data during startup.

    Primes L3 (subway GTFS-RT feeds) and L4 (bus routes) caches so the
    very first user request is fast.  Runs in the background — the server
    accepts requests immediately while this completes.
    """
    from app.services.data_cleaner import get_arrivals_for_line
    from app.services.bus_client import get_routes as get_bus_routes

    t0 = time.perf_counter()
    TrackLogger.info("[WARMUP] Priming subway GTFS-RT feeds + bus routes...", tag="WARMUP")

    # One representative line per feed → primes all 9 subway feeds
    feed_lines = ["A", "B", "N", "1", "G", "L", "J", "7", "SI"]
    results = await asyncio.gather(
        *[get_arrivals_for_line(line) for line in feed_lines],
        get_bus_routes(),
        return_exceptions=True,
    )
    feed_ok = sum(1 for r in results[:9] if isinstance(r, list))
    bus_ok = "OK" if isinstance(results[9], list) else "FAIL"
    elapsed = time.perf_counter() - t0
    TrackLogger.info(
        f"[WARMUP] Done in {elapsed:.1f}s — subway feeds: {feed_ok}/9, bus routes: {bus_ok}",
        tag="WARMUP",
    )


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


@app.post("/admin/cache/clear")
async def clear_all_caches(request: Request) -> dict[str, Any]:
    """Clear all in-memory caches. Localhost only — used by speed tests.

    Returns counts of cleared entries per cache layer.
    """
    client = request.client
    if client and client.host not in ("127.0.0.1", "::1", "localhost"):
        from fastapi import HTTPException
        raise HTTPException(status_code=403, detail="localhost only")

    from app.routers.nearby import clear_nearby_cache
    from app.services.mta_client import clear_mta_cache

    counts = {
        "nearby_response": clear_nearby_cache(),
        "mta_feeds": clear_mta_cache(),
        "bus": clear_bus_cache(),
    }
    TrackLogger.info(f"[ADMIN] All caches cleared: {counts}", tag="ADMIN")
    return {"cleared": counts}
