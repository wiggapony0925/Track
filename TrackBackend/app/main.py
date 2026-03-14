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
    # On first boot with a fresh Render Disk, rebuild transit_schedule.db from
    # the GTFS files we just downloaded.  No-op if the DB already exists.
    await rebuild_schedule_db_if_missing()
    await _redis.init_redis()
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
    # Start background GTFS freshness checker
    _gtfs_refresh_task = asyncio.create_task(_periodic_gtfs_check())
    # Prime caches in background so first real user never eats a cold penalty
    asyncio.create_task(_warmup_caches())


@app.on_event("shutdown")
async def shutdown_event():
    global _gtfs_refresh_task
    if _gtfs_refresh_task:
        _gtfs_refresh_task.cancel()
    # Emit final cache stats before the process exits so Render logs capture
    # the lifetime activity summary for every cache kind (bus Redis + mta in-process).
    cache_stats.flush()
    await _redis.close_redis()


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


async def _warmup_caches():
    """Pre-fetch subway feeds and bus data during startup.

    Primes L3 (subway GTFS-RT feeds) and L4 (bus routes) caches so the
    very first user request is fast.  Runs in the background — the server
    accepts requests immediately while this completes.
    """
    from app.services.gtfs.data_cleaner import get_arrivals_for_line
    from app.clients.bus_client import get_routes as get_bus_routes

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
async def health() -> dict[str, str]:
    """Lightweight liveness probe for uptime monitors (Better Stack, etc.)."""
    return {"status": "ok"}


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
        mta_entries[short_key[:100]] = {"age_s": round(age, 1), "fresh": age < _HTTP_CACHE.ttl}
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
            "ttl_s": _HTTP_CACHE.ttl,
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
