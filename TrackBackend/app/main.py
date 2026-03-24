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
from app.clients.bus_client import clear_bus_cache
from app.services.gtfs.data_loader import ensure_data_available
from app.services.gtfs.gtfs_refresh import rebuild_schedule_db_if_missing
from app.utils import cache_stats
from app.utils import redis_client as _redis
from app.utils.logger import TrackLogger
from app.utils.metrics import setup_metrics, WARMUP_COMPLETE

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

from app.routers import weather
app.include_router(weather.router)

# ── Prometheus metrics ────────────────────────────────────────────────────
# Instruments all HTTP endpoints and exposes GET /metrics for scraping.
setup_metrics(app)


# Background task handle for periodic GTFS refresh
_gtfs_refresh_task: asyncio.Task | None = None
# Background task handle for continuous feed refresh (subway/rail keep-alive)
_feed_refresh_task: asyncio.Task | None = None
# arq connection pool (for enqueueing jobs from the web process)
_arq_pool: Any = None

# How often to check MTA for new GTFS data (default: 24 hours)
_GTFS_CHECK_INTERVAL = int(os.environ.get("GTFS_CHECK_INTERVAL", 86400))


@app.on_event("startup")
async def startup_event():
    global _gtfs_refresh_task, _feed_refresh_task
    TrackLogger.startup()
    # Download fresh GTFS data from Supabase (falls back to Docker-bundled files)
    await ensure_data_available()
    # On first boot with a fresh Render Disk, rebuild transit_schedule.db from
    # the GTFS files we just downloaded.  No-op if the DB already exists.
    await rebuild_schedule_db_if_missing()
    await _redis.init_redis()
    # Pre-fetch weather from Open-Meteo so the first ML prediction has real data
    from app.clients.weather_client import get_current_weather
    try:
        weather = await get_current_weather()
        TrackLogger.info(f"[STARTUP] Weather: {weather}", tag="STARTUP")
    except Exception:
        pass  # weather_client falls back to "clear" internally
    # Eagerly load the LightGBM delay model in a background thread.
    # Without this, the first /nearby/grouped request triggers a synchronous
    # joblib.load() that blocks the event loop for ~60s on Render cold start,
    # causing _collect_all to exceed its 45s timeout.
    from app.ml.delay_model import ensure_model_loaded
    try:
        await ensure_model_loaded()
    except Exception:
        pass  # delay_model falls back to heuristic internally
    # Log startup summary so Render logs clearly show what's active
    redis_status = "ACTIVE  bus · subway · LIRR · MNR" if _redis.get_client() else "DISABLED (in-process only)"
    # Check whether the ML prediction feature flag is active
    _ml_flag = os.environ.get("ARRIVING_PREDICTION_MODEL", "true").strip().lower()
    _ml_on = _ml_flag not in ("false", "0", "off", "no", "disabled")
    _ml_label = "ENABLED" if _ml_on else f"*** DISABLED *** (env={_ml_flag})"
    TrackLogger.info(
        f"[STARTUP] Track backend ready | "
        f"Redis={redis_status} | "
        f"ML={_ml_label} | "
        f"env=production",
        tag="STARTUP",
    )
    # Start background GTFS freshness checker.
    # If an arq worker is running separately (arq app.worker.WorkerSettings),
    # it handles GTFS cron + weather refresh.  The inline asyncio task is
    # kept as a resilient fallback — it's harmless alongside arq (both
    # check_and_refresh_gtfs calls are idempotent).
    _gtfs_refresh_task = asyncio.create_task(_resilient_loop(
        _periodic_gtfs_check, "GTFS_CHECK"
    ))
    # Prime caches in background so first real user never eats a cold penalty.
    # After the initial prime, _warmup_caches hands off to
    # _periodic_feed_refresh which keeps feeds hot every 10 seconds.
    _feed_refresh_task = asyncio.create_task(_resilient_loop(
        _warmup_caches, "FEED_REFRESH"
    ))


@app.on_event("shutdown")
async def shutdown_event():
    global _gtfs_refresh_task, _feed_refresh_task, _arq_pool
    if _gtfs_refresh_task:
        _gtfs_refresh_task.cancel()
    if _feed_refresh_task:
        _feed_refresh_task.cancel()
    if _arq_pool:
        await _arq_pool.close()
    # Emit final cache stats before the process exits so Render logs capture
    # the lifetime activity summary for every cache kind (bus Redis + mta in-process).
    cache_stats.flush()
    await _redis.close_redis()


async def _resilient_loop(
    coro_fn,
    label: str,
    restart_delay: float = 5.0,
    max_restarts: int = 50,
) -> None:
    """Run an async coroutine with automatic restart on failure.

    If the coroutine crashes (anything except CancelledError), it is
    restarted after ``restart_delay`` seconds, up to ``max_restarts``
    times.  Every crash is logged with full traceback so failures are
    no longer silent.
    """
    restarts = 0
    while restarts < max_restarts:
        try:
            await coro_fn()
            return  # normal exit
        except asyncio.CancelledError:
            TrackLogger.info(
                f"[TASK] {label} cancelled — shutting down",
                tag="TASK",
            )
            return
        except Exception as exc:
            restarts += 1
            TrackLogger.error(
                f"[TASK] {label} crashed (restart {restarts}/{max_restarts}): {exc}",
                tag="TASK",
                exc_info=True,
            )
            if restarts >= max_restarts:
                TrackLogger.error(
                    f"[TASK] {label} exceeded max restarts — giving up",
                    tag="TASK",
                )
                return
            await asyncio.sleep(restart_delay)


async def _periodic_gtfs_check():
    """Background task: check MTA feeds for updates periodically."""
    from app.services.gtfs.gtfs_refresh import check_and_refresh_gtfs

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
                f"[GTFS] Periodic check failed: {exc}", tag="GTFS", exc_info=True
            )
        await asyncio.sleep(_GTFS_CHECK_INTERVAL)


# Whether the initial cache warmup has completed.  Checked by the
# /nearby/grouped endpoint to give early requests a better experience
# (return 503 + Retry-After instead of hanging for 30 s on cold feeds).
_warmup_complete = False


def is_warmed_up() -> bool:
    """Return True once initial feed warmup has finished."""
    return _warmup_complete


def _sync_prewarm_shapes() -> None:
    """Synchronous helper to pre-warm the corridor pipeline in a thread.

    Reuses the SAME ``_build_shapes_all_sync`` function that the
    ``/subway/shapes/all`` endpoint uses, then stores the result in the
    endpoint's in-memory cache AND writes it to disk.  This guarantees:

    1. The first client request is instant (in-memory cache hit).
    2. Future restarts/deploys load from disk instead of re-computing
       the 60-90s corridor pipeline.
    3. No duplicate computation — previously the warmup ran its own
       stripped-down pipeline that didn't populate the endpoint cache,
       causing the first client request to re-run the full pipeline.
    """
    from app.routers.subway import (
        _build_shapes_all_sync,
        _load_shapes_disk_cache,
        _save_shapes_disk_cache,
        set_shapes_all_cache,
    )

    # Try disk cache first — avoids the 60-90s CPU hit entirely
    disk_result = _load_shapes_disk_cache()
    if disk_result is not None:
        set_shapes_all_cache(disk_result)
        TrackLogger.info(
            "[WARMUP] Corridor pipeline: loaded from disk cache (instant)",
            tag="WARMUP",
        )
        return

    # No disk cache → run the full pipeline
    result = _build_shapes_all_sync()
    set_shapes_all_cache(result)
    _save_shapes_disk_cache(result)

    TrackLogger.info(
        f"[WARMUP] Corridor pipeline complete: {len(result.lines)} lines processed + saved to disk",
        tag="WARMUP",
    )


async def _warmup_caches():
    """Pre-fetch subway feeds, bus data, and heavy static endpoints on startup.

    Primes L3 (subway GTFS-RT feeds), L4 (bus routes), AND the corridor
    pipeline (/subway/shapes/all + /subway/stations/all) so the very first
    user request is fast.  Runs in the background — the server accepts
    ``/health`` pings immediately while this completes.

    After the initial prime, hands off to ``_periodic_feed_refresh``
    which keeps feeds hot every 10 seconds so they NEVER go cold.

    **Concurrency:** Feeds are warmed SEQUENTIALLY with explicit event-loop
    yields between each feed.  On Standard plan (1 CPU) concurrent protobuf
    parsing causes severe GIL contention — health checks timeout and Render's
    proxy returns 502.  Sequential warmup takes ~20-25s but the server stays
    responsive to user requests throughout.
    """
    global _warmup_complete
    from app.services.gtfs.data_cleaner import get_arrivals_for_line
    from app.clients.bus_client import get_routes as get_bus_routes

    t0 = time.perf_counter()
    TrackLogger.info("[WARMUP] Priming subway GTFS-RT feeds + bus routes (sequential)...", tag="WARMUP")

    # Sequential warmup — one feed at a time with event-loop yields.
    # Concurrent protobuf parsing (sem(3)) was tried and CAUSED 502s:
    # GIL contention starves Uvicorn workers → Render proxy returns 502.
    # One representative per MTA feed URL.
    # "1" covers all numbered lines (1/2/3/4/5/6/7/GS) — no need
    # for a separate "7" entry (same subway_123456 URL).
    feed_lines = ["A", "B", "N", "1", "G", "L", "J", "SI"]
    feed_ok = 0

    for line in feed_lines:
        try:
            await get_arrivals_for_line(line)
            feed_ok += 1
        except Exception:
            pass
        # Yield to the event loop between feeds so health checks and
        # user requests are not starved during the warmup window.
        await asyncio.sleep(0.05)

    bus_ok = "FAIL"
    try:
        await get_bus_routes()
        bus_ok = "OK"
    except Exception:
        pass

    feed_elapsed = time.perf_counter() - t0
    TrackLogger.info(
        f"[WARMUP] Feeds done in {feed_elapsed:.1f}s — subway: {feed_ok}/{len(feed_lines)}, bus: {bus_ok}",
        tag="WARMUP",
    )

    # ── Mark server as healthy NOW ──
    # /health returns 200 once feeds are warm (~20-30s).  This lets
    # Render's zero-downtime deployer switch traffic from the old
    # container to the new one quickly.  The corridor pipeline
    # (60-90s CPU) runs AFTER this in the background — the iOS app
    # has a disk cache for map shapes so the first /subway/shapes/all
    # hit can wait; /nearby/grouped (critical path) is already fast.
    #
    # PREVIOUSLY _warmup_complete was set AFTER the corridor pipeline,
    # meaning /health returned 503 for ~90-120s.  Render killed the old
    # container before the new one passed health checks → 502 gap.
    _warmup_complete = True
    WARMUP_COMPLETE.set(1)
    TrackLogger.info(
        f"[WARMUP] Health check PASSING — feeds ready in {feed_elapsed:.1f}s.  "
        f"Corridor pipeline starting in background...",
        tag="WARMUP",
    )

    # ── Pre-compute the corridor pipeline (shapes/all + stations/all) ──
    # This is the HEAVIEST request on first call: parses GTFS CSVs and runs
    # the 2900-line topological corridor pipeline.  Without pre-warming,
    # the first /subway/shapes/all request takes 60-90s on 1 CPU, causing
    # Render's 60s proxy timeout → 502.  By running it here we guarantee
    # every user request hits warm lru_cache.
    shapes_ok = "FAIL"
    stations_ok = "FAIL"
    try:
        t_shapes = time.perf_counter()
        TrackLogger.info("[WARMUP] Pre-computing corridor pipeline (shapes/all)...", tag="WARMUP")
        # Run the CPU-heavy work in a thread to avoid blocking the event loop
        # (lru_cache file I/O + corridor pipeline are sync/CPU-bound)
        await asyncio.get_event_loop().run_in_executor(
            None,
            _sync_prewarm_shapes,
        )
        shapes_ok = f"OK ({time.perf_counter() - t_shapes:.1f}s)"
        await asyncio.sleep(0.05)  # yield

        t_stations = time.perf_counter()
        from app.services.mapping.subway_shapes import get_all_subway_stations
        get_all_subway_stations()  # populates the module-level cache
        stations_ok = f"OK ({time.perf_counter() - t_stations:.1f}s)"
    except Exception as exc:
        TrackLogger.error(
            f"[WARMUP] Shapes/stations pre-warm failed: {exc}",
            tag="WARMUP", exc_info=True,
        )

    elapsed = time.perf_counter() - t0
    TrackLogger.info(
        f"[WARMUP] Full warmup done in {elapsed:.1f}s — subway feeds: {feed_ok}/{len(feed_lines)}, "
        f"bus routes: {bus_ok}, shapes: {shapes_ok}, stations: {stations_ok}",
        tag="WARMUP",
    )

    # Transition to the keep-alive loop that continuously re-fetches
    # all transit feeds.  This ensures the L3 feed cache is ALWAYS
    # warm — no user request ever pays the cold-fetch penalty.
    await _periodic_feed_refresh()


# How often (seconds) to re-fetch all transit feeds in the background.
# MTA updates GTFS-RT feeds every ~10-30s, so 10s keeps us within the
# 12s fresh TTL and guarantees every user request hits a warm cache.
_FEED_REFRESH_INTERVAL = int(os.environ.get("FEED_REFRESH_INTERVAL", 10))


async def _periodic_feed_refresh():
    """Background loop: keep ALL transit feeds hot in-memory forever.

    Re-fetches every ``_FEED_REFRESH_INTERVAL`` seconds (default 10s):
      - 9 subway GTFS-RT feeds  (one per feed family)
      - LIRR GTFS-RT feed
      - Metro-North GTFS-RT feed

    Without this, feeds expire after ``MTA_FEED_STALE_TTL`` (60-120s)
    and the next user request eats a 2-5 second cold penalty per feed.
    With 7-9 feeds cold simultaneously, that snowballs to 15-25 seconds.
    This loop eliminates that entirely — every feed fetch from the hot
    path resolves from the in-process TTL cache in <1ms.
    """
    from app.services.gtfs.data_cleaner import get_arrivals_for_line
    from app.clients.rail_client import fetch_rail_arrivals
    from app.utils.metrics import FEED_REFRESH_TOTAL, FEED_REFRESH_DURATION, ACTIVE_FEEDS

    # One representative per MTA feed URL — "1" covers 1/2/3/4/5/6/7/GS.
    # Previously included "7" separately, but it resolves to the same
    # subway_123456 URL as "1", causing duplicate protobuf parsing
    # every refresh cycle (wasting ~200ms of CPU on 1-CPU Render plan).
    feed_lines = ["A", "B", "N", "1", "G", "L", "J", "SI"]

    while True:
        await asyncio.sleep(_FEED_REFRESH_INTERVAL)
        try:
            t0 = time.perf_counter()
            ok = 0
            total = len(feed_lines) + 2  # subway feeds + LIRR + MNR

            # ── Process feeds with bounded concurrency ──
            # Standard plan (1 CPU, 2 GB) — use sem(2) to keep GIL
            # contention manageable.  sem(3) caused 502s.
            sem = asyncio.Semaphore(2)

            async def _refresh_feed(line: str) -> bool:
                async with sem:
                    t_feed = time.perf_counter()
                    try:
                        await get_arrivals_for_line(line, force_refresh=True)
                        FEED_REFRESH_TOTAL.labels(line=line, status="ok").inc()
                        FEED_REFRESH_DURATION.labels(line=line).observe(time.perf_counter() - t_feed)
                        return True
                    except Exception:
                        FEED_REFRESH_TOTAL.labels(line=line, status="error").inc()
                        return False

            async def _refresh_rail(rail: str) -> bool:
                async with sem:
                    t_feed = time.perf_counter()
                    try:
                        await fetch_rail_arrivals(rail, force_refresh=True)
                        FEED_REFRESH_TOTAL.labels(line=rail, status="ok").inc()
                        FEED_REFRESH_DURATION.labels(line=rail).observe(time.perf_counter() - t_feed)
                        return True
                    except Exception:
                        FEED_REFRESH_TOTAL.labels(line=rail, status="error").inc()
                        return False

            feed_results = await asyncio.gather(
                *[_refresh_feed(ln) for ln in feed_lines],
                *[_refresh_rail(r) for r in ("lirr", "metro_north")],
            )
            ok = sum(1 for r in feed_results if r)
            ACTIVE_FEEDS.set(ok)

            elapsed = time.perf_counter() - t0
            if elapsed > 5.0 or ok < total:
                TrackLogger.warning(
                    f"[FEED_REFRESH] {ok}/{total} feeds OK in {elapsed:.1f}s",
                    tag="FEED_REFRESH",
                )
        except asyncio.CancelledError:
            break
        except Exception as exc:
            TrackLogger.error(
                f"[FEED_REFRESH] Loop error: {exc}", tag="FEED_REFRESH",
                exc_info=True,
            )


# ---------------------------------------------------------------------------
# HTTP Cache-Control policy map
# ---------------------------------------------------------------------------
# Maps URL path prefixes → Cache-Control header values.  Tuned to each
# endpoint's data volatility so iOS URLCache (and any future CDN) can
# serve responses without hitting the network when data is still fresh.
#
# References:
#   - "API Caching Best Practices" — client-side caching layer
#   - stale-while-revalidate lets URLCache serve a stale copy instantly
#     while revalidating in the background (supported by URLSession on
#     iOS 15+ and all modern CDN/proxy caches).
#   - stale-if-error lets the client use a cached copy when the server
#     returns 5xx — improves resilience during deploys / outages.

_CACHE_CONTROL_RULES: list[tuple[str, str]] = [
    # ── Static / semi-static geometry (changes on deploy, not per-request) ──
    ("/subway/shapes/all",  "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"),
    ("/subway/stations/all", "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"),
    ("/subway/stations/processed", "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"),
    ("/subway/shape/",      "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"),
    ("/lirr/shapes/all",    "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"),
    ("/lirr/shape/",        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"),
    ("/mnr/shapes/all",     "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"),
    ("/mnr/shape/",         "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"),
    # Bus routes list and route shapes (already partially covered in bus.py)
    ("/bus/routes",         "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"),
    ("/bus/route-shape/",   "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"),
    # Bus stops per route — semi-static
    ("/bus/stops/",         "public, max-age=600, stale-while-revalidate=86400, stale-if-error=604800"),
    # ── Real-time transit data (seconds-level freshness) ──
    ("/nearby/grouped",     "private, max-age=5, stale-while-revalidate=15, stale-if-error=60"),
    ("/subway/",            "private, max-age=8, stale-while-revalidate=20, stale-if-error=60"),
    ("/lirr",               "private, max-age=8, stale-while-revalidate=20, stale-if-error=60"),
    ("/mnr",                "private, max-age=8, stale-while-revalidate=20, stale-if-error=60"),
    ("/bus/live/",          "private, max-age=8, stale-while-revalidate=20, stale-if-error=60"),
    ("/bus/vehicles/",      "public, max-age=5, stale-while-revalidate=30, stale-if-error=120"),
    ("/bus/nearby",         "private, max-age=60, stale-while-revalidate=300, stale-if-error=600"),
    # ── Alerts & accessibility (moderate refresh) ──
    ("/alerts",             "public, max-age=30, stale-while-revalidate=120, stale-if-error=600"),
    ("/accessibility",      "public, max-age=60, stale-while-revalidate=300, stale-if-error=600"),
    # ── ML predictions (stable for minutes) ──
    ("/predict/delay",      "private, max-age=60, stale-while-revalidate=300, stale-if-error=600"),
    # ── Config / health (short or no cache) ──
    ("/config",             "public, max-age=300, stale-while-revalidate=600"),
    ("/health",             "no-store"),
]


def _resolve_cache_control(path: str) -> str | None:
    """Find the best-matching Cache-Control value for a request path."""
    for prefix, value in _CACHE_CONTROL_RULES:
        if path == prefix or path.startswith(prefix):
            return value
    return None


# Middleware to log every request with color, query params, and timing,
# AND inject Cache-Control headers based on the policy map above.
@app.middleware("http")
async def log_requests(request: Request, call_next):
    start = time.perf_counter()
    user_email = (
        request.headers.get("x-user-email")
        or request.headers.get("x-auth-email")
        or request.query_params.get("email")
        or "-"
    )
    # Render injects Rndr-Id on every inbound request — bind it so every log
    # line for this request carries the same ID (traceable in Render dashboard
    # and any syslog stream like Better Stack).
    request_id = request.headers.get("Rndr-Id") or "-"
    TrackLogger.set_user_email(user_email)
    TrackLogger.set_request_id(request_id)

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
        # Inject Cache-Control if the endpoint hasn't already set one.
        # Endpoint-level headers (e.g. bus.py vehicles) take precedence.
        if "cache-control" not in response.headers:
            cc = _resolve_cache_control(request.url.path)
            if cc:
                response.headers["Cache-Control"] = cc
        # Vary header: real-time endpoints use lat/lon query params, so
        # each (lat,lon,radius,mode) combo is a distinct cacheable resource.
        # This tells any intermediate cache to key on the full query string.
        if request.url.query and "cache-control" in response.headers:
            response.headers.setdefault("Vary", "Accept-Encoding")
        return response
    except Exception:
        # Log unhandled exceptions that crash the request handler — these
        # would otherwise only appear in uvicorn's default 500 traceback
        # without our structured context (user, rndr_id, timing, tag).
        elapsed_ms = (time.perf_counter() - start) * 1000
        query = f"?{request.url.query}" if request.url.query else ""
        TrackLogger.error(
            f"{request.method} {request.url.path}{query} → 500 UNHANDLED ({elapsed_ms:.1f}ms)",
            tag="HTTP",
            exc_info=True,
        )
        raise
    finally:
        TrackLogger.clear_user_email()
        TrackLogger.clear_request_id()


@app.get("/health")
async def health():
    """Liveness / readiness probe for Render zero-downtime deploys.

    Returns 503 only during the initial feed warmup (~20-30s).
    Returns 200 as soon as GTFS-RT feeds + bus routes are cached,
    even if the corridor pipeline (60-90s CPU) is still running.

    The corridor pipeline only affects ``/subway/shapes/all`` — the iOS
    app has a disk cache for map shapes, so a slow first shapes request
    is acceptable.  ``/nearby/grouped`` (critical path) is fast as soon
    as feeds are warm.

    **Why this matters for 502s:**
    Render keeps the OLD container serving traffic until the NEW one's
    health check returns 200.  If health is gated behind the full
    corridor pipeline (~90-120s), Render may time out and kill the old
    container — creating a 502 gap where neither instance serves.
    By passing health after feeds (~20-30s), the traffic cutover happens
    quickly and users never see a 502.
    """
    if not _warmup_complete:
        from fastapi.responses import JSONResponse
        return JSONResponse(
            status_code=503,
            content={"status": "warming_up"},
            headers={"Retry-After": "10"},
        )
    from app.clients.weather_client import get_cached_weather_details
    return {"status": "ok", "weather": get_cached_weather_details()}


@app.get("/config")
async def config() -> dict[str, Any]:
    """Return the *app_settings* block from settings.json."""
    settings = get_settings()
    return settings.app_settings.model_dump()


@app.get("/data/status")
async def data_status() -> dict[str, Any]:
    """Check which GTFS data groups are available and their freshness."""
    from app.services.gtfs.data_loader import check_local_data_status
    from app.services.gtfs.gtfs_refresh import get_gtfs_freshness
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
    from app.services.gtfs.gtfs_refresh import check_and_refresh_gtfs
    results = await check_and_refresh_gtfs(full_check=full)
    return {"results": results}


@app.get("/admin/cache/inspect")
async def inspect_caches(request: Request) -> dict[str, Any]:
    """Return a snapshot of every cache layer: sizes, keys, ages, hit rates.

    Works both locally and on Render — hit your Render URL at
    ``/admin/cache/inspect`` to see production cache state.
    """
    import time as _t

    from app.clients.mta_client import _HTTP_CACHE
    from app.clients.bus_client import (
        _arrivals_cache, _vehicle_cache, _stops_cache,
        _routes_cache, _route_shape_cache, _nearby_stops_cache,
    )
    from app.routers.nearby import _nearby_resp_cache

    now = _t.time()
    now_mono = _t.monotonic()

    def _summarise_ttl_dict(
        cache: dict, time_field_index: int = 0, mono: bool = False
    ) -> dict[str, Any]:
        """Summarise a { key: (timestamp, value) } style cache dict."""
        if not cache:
            return {"entries": 0, "keys": []}
        ages = []
        keys_info = []
        ref = now_mono if mono else now
        for k, v in cache.items():
            ts = v[time_field_index] if isinstance(v, tuple) else 0
            age = ref - ts
            key_str = str(k) if not isinstance(k, str) else k
            keys_info.append({"key": key_str[:120], "age_s": round(age, 1)})
            ages.append(age)
        return {
            "entries": len(cache),
            "oldest_age_s": round(max(ages), 1) if ages else 0,
            "newest_age_s": round(min(ages), 1) if ages else 0,
            "keys": sorted(keys_info, key=lambda x: x["age_s"]),
        }

    def _summarise_entry_dict(
        cache: dict, mono: bool = True
    ) -> dict[str, Any]:
        """Summarise a { key: _TTLCacheEntry } dict (bus caches).

        Auto-detects whether timestamps are monotonic (~222k range on a
        machine with 2.5 days uptime) or epoch (~1.77B).  Uses the
        appropriate reference clock.
        """
        if not cache:
            return {"entries": 0, "keys": []}
        ages = []
        keys_info = []
        for k, entry in cache.items():
            ts = entry.ts
            # Heuristic: epoch timestamps are > 1 billion, monotonic < 1 million
            ref = now if ts > 1_000_000_000 else now_mono
            age = max(0, ref - ts)
            keys_info.append({"key": str(k)[:120], "age_s": round(age, 1)})
            ages.append(age)
        return {
            "entries": len(cache),
            "oldest_age_s": round(max(ages), 1) if ages else 0,
            "newest_age_s": round(min(ages), 1) if ages else 0,
            "keys": sorted(keys_info, key=lambda x: x["age_s"]),
        }

    # ── MTA feed cache (AsyncTTLCache) ──
    mta_entries = {}
    for k, (ts, _) in _HTTP_CACHE._cache.items():
        age = now - ts
        short_key = k.split("?")[0] if "?" in k else k
        mta_entries[short_key[:100]] = {"age_s": round(age, 1), "fresh": age < _HTTP_CACHE.fresh_ttl}
    mta_stats = cache_stats._stats.get("mta.feed")

    # ── Bus caches (_TTLCacheEntry uses monotonic timestamps) ──
    bus = {
        "arrivals": _summarise_entry_dict(_arrivals_cache),
        "vehicles": _summarise_entry_dict(_vehicle_cache),
        "stops": _summarise_entry_dict(_stops_cache),
        "routes": _summarise_entry_dict(_routes_cache),
        "route_shapes": _summarise_entry_dict(_route_shape_cache),
        "nearby_stops": {
            "entries": len(_nearby_stops_cache),
            "keys": [
                {
                    "key": str(k),
                    "age_s": round(
                        max(0, (now if v[0] > 1_000_000_000 else now_mono) - v[0]), 1
                    ),
                }
                for k, v in _nearby_stops_cache.items()
            ][:50],
        },
    }

    # ── Nearby response cache ──
    nearby = _summarise_ttl_dict(_nearby_resp_cache)

    # ── Redis (L3) ──
    redis_info: dict[str, Any] = {"connected": False}
    rc = _redis.get_client()
    if rc:
        try:
            info = await rc.info("memory")
            db_size = await rc.dbsize()
            redis_info = {
                "connected": True,
                "db_size_keys": db_size,
                "used_memory_human": info.get("used_memory_human", "?"),
                "used_memory_peak_human": info.get("used_memory_peak_human", "?"),
                "maxmemory_human": info.get("maxmemory_human", "?"),
                "eviction_policy": info.get("maxmemory_policy", "?"),
            }
            # Sample some keys to show what's stored
            sample_keys = []
            cursor, keys = await rc.scan(cursor=0, count=50)
            for raw_key in keys[:50]:
                key_str = raw_key.decode() if isinstance(raw_key, bytes) else str(raw_key)
                ttl = await rc.ttl(key_str)
                sample_keys.append({"key": key_str[:120], "ttl_s": ttl})
            redis_info["sample_keys"] = sorted(sample_keys, key=lambda x: x["key"])
        except Exception as exc:
            redis_info["error"] = str(exc)

    # ── Cache stats (hit/miss counters) ──
    stats_snapshot = {}
    for kind, s in sorted(cache_stats._stats.items()):
        stats_snapshot[kind] = {
            "gets": s.total_gets,
            "fresh": s.fresh,
            "stale": s.stale,
            "miss": s.miss,
            "sets": s.sets,
            "hit_pct": round(s.hit_pct, 1),
            "errors": s.errors,
        }

    return {
        "mta_feed_cache": {
            "entries": len(_HTTP_CACHE._cache),
            "fresh_ttl_s": _HTTP_CACHE.fresh_ttl,
            "stale_ttl_s": _HTTP_CACHE.stale_ttl,
            "max_size": _HTTP_CACHE.max_size,
            "feeds": mta_entries,
        },
        "bus_caches": bus,
        "nearby_response_cache": nearby,
        "redis": redis_info,
        "cache_stats": stats_snapshot,
    }


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
    from app.clients.mta_client import clear_mta_cache

    counts = {
        "nearby_response": clear_nearby_cache(),
        "mta_feeds": clear_mta_cache(),
        "bus": clear_bus_cache(),
    }
    TrackLogger.info(f"[ADMIN] All caches cleared: {counts}", tag="ADMIN")
    return {"cleared": counts}
