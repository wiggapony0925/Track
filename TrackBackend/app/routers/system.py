"""System and admin diagnostic routes."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import JSONResponse

from app.clients import redis_client as _redis
from app.clients.bus_client import clear_bus_cache
from app.config import get_settings
from app.lifecycle import is_warmed_up
from app.utils import cache_stats
from app.utils.logger import TrackLogger

router = APIRouter(tags=["system"])
_EPOCH_THRESHOLD = 1_000_000_000


@router.get(
    "/health",
    summary="Health check",
    description=(
        "Liveness and readiness probe for load-balancer health checks. "
        'Returns HTTP 200 with `{"status": "ok", "weather": {...}}` once all '
        "GTFS-RT feeds have been fetched at least once (~20–30 s after cold boot). "
        "During the warmup window the endpoint returns HTTP 503 with a `Retry-After: 10` header."
    ),
    responses={
        503: {
            "description": "Service unavailable — server is warming up. Retry after the `Retry-After` header value."
        }
    },
)
async def health():
    """Return backend liveness/readiness state."""
    if not is_warmed_up():
        return JSONResponse(
            status_code=503,
            content={"status": "warming_up"},
            headers={"Retry-After": "10"},
        )
    from app.clients.weather_client import get_cached_weather_details

    return {"status": "ok", "weather": get_cached_weather_details()}


@router.get(
    "/config",
    summary="Get app configuration",
    description=(
        "Returns the `app_settings` block from the server configuration file. "
        "Includes `search_radius_meters`, `max_arrival_minutes`, `max_arrivals_per_line`, "
        "feature flags, and other client-facing tunables the iOS app reads at launch."
    ),
)
async def config() -> dict[str, Any]:
    """Return client-facing app settings."""
    return get_settings().app_settings.model_dump()


@router.get(
    "/data/status",
    summary="Get GTFS data status",
    description=(
        "Returns the availability and freshness of every GTFS static data group "
        "(stops, routes, shapes, transfers, calendar). Includes per-feed last-update "
        "timestamps so operators can verify that scheduled data refreshes are running."
    ),
)
async def data_status() -> dict[str, Any]:
    """Check GTFS data availability and freshness."""
    from app.services.gtfs.data_loader import check_local_data_status
    from app.services.gtfs.gtfs_refresh import get_gtfs_freshness

    return {
        "data_groups": check_local_data_status(),
        "gtfs_feeds": get_gtfs_freshness(),
    }


@router.post(
    "/data/refresh",
    summary="Trigger GTFS data refresh",
    description=(
        "Manually triggers a GTFS static-data refresh against upstream MTA feeds. "
        "Compares local file hashes with the remote server and re-downloads only "
        "changed archives. Use `full=true` to include bus GTFS data (adds ~15 s)."
    ),
)
async def data_refresh(
    full: bool = Query(
        False,
        description=(
            "When `true`, checks all feeds including bus GTFS (slower, ~15 s). "
            "When `false` (default), checks only subway, LIRR, and Metro-North feeds."
        ),
        examples=[False, True],
    ),
) -> dict[str, Any]:
    """Manually trigger a GTFS data refresh."""
    from app.services.gtfs.gtfs_refresh import check_and_refresh_gtfs

    results = await check_and_refresh_gtfs(full_check=full)
    return {"results": results}


@router.get(
    "/admin/cache/inspect",
    summary="Inspect cache layers",
    description=(
        "Returns a detailed diagnostic snapshot of every cache layer: MTA feed cache "
        "(entry counts and per-feed age), bus caches (arrivals, vehicles, stops, routes, shapes), "
        "nearby response cache, Redis L3 state (memory, eviction policy, sample keys), "
        "and cumulative hit/miss/stale counters with hit-rate percentages."
    ),
)
async def inspect_caches(request: Request) -> dict[str, Any]:
    """Inspect all cache layers."""
    del request
    import time as _t

    from app.clients.bus_client import (
        _arrivals_cache,
        _nearby_stops_cache,
        _route_shape_cache,
        _routes_cache,
        _stops_cache,
        _vehicle_cache,
    )
    from app.clients.mta_client import _HTTP_CACHE
    from app.routers.nearby import _nearby_resp_cache

    now = _t.time()
    now_mono = _t.monotonic()

    def _summarise_ttl_dict(
        cache: dict, time_field_index: int = 0, mono: bool = False
    ) -> dict[str, Any]:
        if not cache:
            return {"entries": 0, "keys": []}
        ages = []
        keys_info = []
        ref = now_mono if mono else now
        for key, value in cache.items():
            ts = value[time_field_index] if isinstance(value, tuple) else 0
            age = ref - ts
            key_str = str(key) if not isinstance(key, str) else key
            keys_info.append({"key": key_str[:120], "age_s": round(age, 1)})
            ages.append(age)
        return {
            "entries": len(cache),
            "oldest_age_s": round(max(ages), 1) if ages else 0,
            "newest_age_s": round(min(ages), 1) if ages else 0,
            "keys": sorted(keys_info, key=lambda item: item["age_s"]),
        }

    def _summarise_entry_dict(cache: dict) -> dict[str, Any]:
        if not cache:
            return {"entries": 0, "keys": []}
        ages = []
        keys_info = []
        for key, entry in cache.items():
            ts = entry.ts
            ref = now if ts > _EPOCH_THRESHOLD else now_mono
            age = max(0, ref - ts)
            keys_info.append({"key": str(key)[:120], "age_s": round(age, 1)})
            ages.append(age)
        return {
            "entries": len(cache),
            "oldest_age_s": round(max(ages), 1) if ages else 0,
            "newest_age_s": round(min(ages), 1) if ages else 0,
            "keys": sorted(keys_info, key=lambda item: item["age_s"]),
        }

    mta_entries = {}
    for key, (ts, _) in _HTTP_CACHE._cache.items():
        age = now - ts
        short_key = key.split("?")[0] if "?" in key else key
        mta_entries[short_key[:100]] = {
            "age_s": round(age, 1),
            "fresh": age < _HTTP_CACHE.fresh_ttl,
        }

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
                    "key": str(key),
                    "age_s": round(
                        max(
                            0,
                            (now if value[0] > _EPOCH_THRESHOLD else now_mono)
                            - value[0],
                        ),
                        1,
                    ),
                }
                for key, value in _nearby_stops_cache.items()
            ][:50],
        },
    }

    nearby = _summarise_ttl_dict(_nearby_resp_cache)

    redis_info: dict[str, Any] = {"connected": False}
    redis_client = _redis.get_client()
    if redis_client:
        try:
            info = await redis_client.info("memory")
            db_size = await redis_client.dbsize()
            redis_info = {
                "connected": True,
                "db_size_keys": db_size,
                "used_memory_human": info.get("used_memory_human", "?"),
                "used_memory_peak_human": info.get("used_memory_peak_human", "?"),
                "maxmemory_human": info.get("maxmemory_human", "?"),
                "eviction_policy": info.get("maxmemory_policy", "?"),
            }
            sample_keys = []
            _cursor, keys = await redis_client.scan(cursor=0, count=50)
            for raw_key in keys[:50]:
                key_str = raw_key.decode() if isinstance(raw_key, bytes) else str(raw_key)
                ttl = await redis_client.ttl(key_str)
                sample_keys.append({"key": key_str[:120], "ttl_s": ttl})
            redis_info["sample_keys"] = sorted(sample_keys, key=lambda item: item["key"])
        except Exception as exc:
            redis_info["error"] = str(exc)

    stats_snapshot = {}
    for kind, stats in sorted(cache_stats._stats.items()):
        stats_snapshot[kind] = {
            "gets": stats.total_gets,
            "fresh": stats.fresh,
            "stale": stats.stale,
            "miss": stats.miss,
            "sets": stats.sets,
            "hit_pct": round(stats.hit_pct, 1),
            "errors": stats.errors,
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


@router.post(
    "/admin/cache/clear",
    summary="Clear all caches",
    description=(
        "Purges every in-memory cache layer (MTA feeds, bus data, nearby responses) "
        "and returns the number of entries cleared per layer. "
        "**Restricted to localhost** — remote callers receive HTTP 403."
    ),
    responses={403: {"description": "Forbidden — endpoint restricted to localhost."}},
)
async def clear_all_caches(request: Request) -> dict[str, Any]:
    """Clear all in-memory caches."""
    client = request.client
    if client and client.host not in ("127.0.0.1", "::1", "localhost"):
        raise HTTPException(status_code=403, detail="localhost only")

    from app.clients.mta_client import clear_mta_cache
    from app.routers.nearby import clear_nearby_cache

    counts = {
        "nearby_response": clear_nearby_cache(),
        "mta_feeds": clear_mta_cache(),
        "bus": clear_bus_cache(),
    }
    TrackLogger.info(f"[ADMIN] All caches cleared: {counts}", tag="ADMIN")
    return {"cleared": counts}
