"""Application startup, shutdown, and feed warmup lifecycle."""

from __future__ import annotations

import asyncio
import contextlib
import dataclasses
import os
import time
from typing import Any

from fastapi import FastAPI

from app.clients import redis_client as _redis
from app.services.gtfs.data_loader import ensure_data_available
from app.services.gtfs.gtfs_refresh import rebuild_schedule_db_if_missing
from app.utils import cache_stats
from app.utils.logger import TrackLogger
from app.utils.metrics import WARMUP_COMPLETE


@dataclasses.dataclass
class AppState:
    """Mutable application lifecycle state."""

    gtfs_refresh_task: asyncio.Task | None = None
    feed_refresh_task: asyncio.Task | None = None
    arq_pool: Any = None
    warmup_complete: bool = False


_app_state = AppState()

_GTFS_CHECK_INTERVAL = int(os.environ.get("GTFS_CHECK_INTERVAL", "86400"))
_FEED_REFRESH_INTERVAL = int(os.environ.get("FEED_REFRESH_INTERVAL", "10"))
_FEED_LINES = ["A", "B", "N", "1", "G", "L", "J", "SI"]


def register_lifecycle(app: FastAPI) -> None:
    """Attach startup and shutdown handlers to the app."""

    @app.on_event("startup")
    async def startup_event():
        TrackLogger.startup()
        TrackLogger.section("DATA SYNC")
        await ensure_data_available()
        await rebuild_schedule_db_if_missing()

        TrackLogger.section("SERVICES")
        await _redis.init_redis()
        from app.clients.weather_client import get_current_weather

        try:
            weather = await get_current_weather()
            TrackLogger.info(f"[STARTUP] Weather: {weather}", tag="STARTUP")
        except Exception:
            pass

        from app.ml.delay_model import ensure_model_loaded

        with contextlib.suppress(Exception):
            await ensure_model_loaded()

        redis_status = (
            "ACTIVE  bus · subway · LIRR · MNR"
            if _redis.get_client()
            else "DISABLED (in-process only)"
        )
        ml_flag = os.environ.get("ARRIVING_PREDICTION_MODEL", "true").strip().lower()
        ml_on = ml_flag not in ("false", "0", "off", "no", "disabled")
        ml_label = "ENABLED" if ml_on else f"*** DISABLED *** (env={ml_flag})"
        TrackLogger.ready(
            f"Services initialized | Redis={redis_status} | ML={ml_label}"
            " -- starting warmup"
        )

        _app_state.gtfs_refresh_task = asyncio.create_task(
            _resilient_loop(_periodic_gtfs_check, "GTFS_CHECK")
        )
        _app_state.feed_refresh_task = asyncio.create_task(
            _resilient_loop(_warmup_caches, "FEED_REFRESH")
        )

    @app.on_event("shutdown")
    async def shutdown_event():
        if _app_state.gtfs_refresh_task:
            _app_state.gtfs_refresh_task.cancel()
        if _app_state.feed_refresh_task:
            _app_state.feed_refresh_task.cancel()
        if _app_state.arq_pool:
            await _app_state.arq_pool.close()
        cache_stats.flush()
        await _redis.close_redis()


def is_warmed_up() -> bool:
    """Return True once initial feed warmup has finished."""
    return _app_state.warmup_complete


async def _resilient_loop(
    coro_fn,
    label: str,
    restart_delay: float = 5.0,
    max_restarts: int = 50,
) -> None:
    restarts = 0
    while restarts < max_restarts:
        try:
            await coro_fn()
            return
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
    from app.services.gtfs.gtfs_refresh import check_and_refresh_gtfs

    await asyncio.sleep(300)

    while True:
        try:
            TrackLogger.info(
                f"[GTFS] Periodic check starting (interval={_GTFS_CHECK_INTERVAL}s)",
                tag="GTFS",
            )
            await check_and_refresh_gtfs(full_check=True)
        except asyncio.CancelledError:
            break
        except Exception as exc:
            TrackLogger.error(
                f"[GTFS] Periodic check failed: {exc}", tag="GTFS", exc_info=True
            )
        await asyncio.sleep(_GTFS_CHECK_INTERVAL)


def _sync_prewarm_shapes() -> None:
    import app.routers.subway as subway_module
    from app.routers.subway import (
        _build_shapes_all_sync,
        _load_shapes_disk_cache,
        _save_shapes_disk_cache,
        set_shapes_all_cache,
    )

    disk_result = _load_shapes_disk_cache()
    if disk_result is not None:
        set_shapes_all_cache(disk_result)
        TrackLogger.info(
            "[WARMUP] Corridor pipeline: loaded from disk cache (instant)",
            tag="WARMUP",
        )
        return

    subway_module._shapes_all_building = True
    try:
        result = _build_shapes_all_sync()
        set_shapes_all_cache(result)
        _save_shapes_disk_cache(result)
    finally:
        subway_module._shapes_all_building = False

    TrackLogger.info(
        f"[WARMUP] Corridor pipeline complete: {len(result.lines)} lines processed + saved to disk",
        tag="WARMUP",
    )


async def _warmup_caches():
    from app.clients.bus_client import get_routes as get_bus_routes
    from app.services.gtfs.realtime_parser import get_arrivals_for_line

    TrackLogger.section("WARMUP")
    t0 = time.perf_counter()
    TrackLogger.info(
        "[WARMUP] Priming subway GTFS-RT feeds + bus routes (sequential)...",
        tag="WARMUP",
    )

    feed_ok = 0
    for line in _FEED_LINES:
        try:
            await get_arrivals_for_line(line)
            feed_ok += 1
        except Exception:
            pass
        await asyncio.sleep(0.05)

    bus_ok = "FAIL"
    try:
        await get_bus_routes()
        bus_ok = "OK"
    except Exception:
        pass

    bus_shapes_ok = "FAIL"
    try:
        from app.services.mapping.bus.routes import get_bus_open_data_shapes

        await get_bus_open_data_shapes()
        bus_shapes_ok = "OK"
    except Exception:
        pass

    bus_stops_ok = "FAIL"
    try:
        from app.services.mapping.bus.stops import get_bus_stop_index

        await get_bus_stop_index()
        bus_stops_ok = "OK"
    except Exception:
        pass

    feed_elapsed = time.perf_counter() - t0
    TrackLogger.info(
        f"[WARMUP] Feeds done in {feed_elapsed:.1f}s — subway: {feed_ok}/{len(_FEED_LINES)}, "
        f"bus routes: {bus_ok}, bus shapes: {bus_shapes_ok}",
        tag="WARMUP",
    )

    _app_state.warmup_complete = True
    WARMUP_COMPLETE.set(1)
    TrackLogger.info(
        f"[WARMUP] Health check PASSING — feeds ready in {feed_elapsed:.1f}s.  "
        f"Corridor pipeline starting in background...",
        tag="WARMUP",
    )

    shapes_ok = "FAIL"
    stations_ok = "FAIL"
    try:
        t_shapes = time.perf_counter()
        TrackLogger.info(
            "[WARMUP] Pre-computing corridor pipeline (shapes/all)...", tag="WARMUP"
        )
        await asyncio.get_running_loop().run_in_executor(None, _sync_prewarm_shapes)
        shapes_ok = f"OK ({time.perf_counter() - t_shapes:.1f}s)"
        await asyncio.sleep(0.05)

        t_stations = time.perf_counter()
        from app.services.mapping.subway.shapes import get_all_subway_stations

        get_all_subway_stations()
        stations_ok = f"OK ({time.perf_counter() - t_stations:.1f}s)"
    except Exception as exc:
        TrackLogger.error(
            f"[WARMUP] Shapes/stations pre-warm failed: {exc}",
            tag="WARMUP",
            exc_info=True,
        )

    elapsed = time.perf_counter() - t0
    TrackLogger.info(
        f"[WARMUP] Full warmup done in {elapsed:.1f}s — subway feeds: {feed_ok}/{len(_FEED_LINES)}, "
        f"bus routes: {bus_ok}, bus shapes: {bus_shapes_ok}, bus stops: {bus_stops_ok}, "
        f"shapes: {shapes_ok}, stations: {stations_ok}",
        tag="WARMUP",
    )

    await _periodic_feed_refresh()


async def _periodic_feed_refresh():
    from app.clients.rail_client import fetch_rail_arrivals
    from app.services.gtfs.realtime_parser import get_arrivals_for_line
    from app.utils.metrics import (
        ACTIVE_FEEDS,
        FEED_REFRESH_DURATION,
        FEED_REFRESH_TOTAL,
    )

    cycle = 0
    while True:
        await asyncio.sleep(_FEED_REFRESH_INTERVAL)
        try:
            t0 = time.perf_counter()
            total = len(_FEED_LINES) + 2
            sem = asyncio.Semaphore(2)

            async def _refresh_feed(line: str, sem: asyncio.Semaphore = sem) -> bool:
                async with sem:
                    t_feed = time.perf_counter()
                    try:
                        await get_arrivals_for_line(line, force_refresh=True)
                        FEED_REFRESH_TOTAL.labels(line=line, status="ok").inc()
                        FEED_REFRESH_DURATION.labels(line=line).observe(
                            time.perf_counter() - t_feed
                        )
                        return True
                    except Exception:
                        FEED_REFRESH_TOTAL.labels(line=line, status="error").inc()
                        return False

            async def _refresh_rail(rail: str, sem: asyncio.Semaphore = sem) -> bool:
                async with sem:
                    t_feed = time.perf_counter()
                    try:
                        await fetch_rail_arrivals(rail, force_refresh=True)
                        FEED_REFRESH_TOTAL.labels(line=rail, status="ok").inc()
                        FEED_REFRESH_DURATION.labels(line=rail).observe(
                            time.perf_counter() - t_feed
                        )
                        return True
                    except Exception:
                        FEED_REFRESH_TOTAL.labels(line=rail, status="error").inc()
                        return False

            feed_results = await asyncio.gather(
                *[_refresh_feed(line) for line in _FEED_LINES],
                *[_refresh_rail(rail) for rail in ("lirr", "metro_north")],
            )
            ok = sum(1 for result in feed_results if result)
            ACTIVE_FEEDS.set(ok)
            cycle += 1

            elapsed = time.perf_counter() - t0
            if elapsed > 5.0 or ok < total:
                TrackLogger.info(
                    f"[FEED_REFRESH] {ok}/{total} feeds OK in {elapsed:.1f}s",
                    tag="FEED_REFRESH",
                )
            elif cycle % 30 == 0:
                TrackLogger.info(
                    f"[FEED_REFRESH] feeds healthy {ok}/{total}"
                    f" (cycle #{cycle}, {elapsed:.1f}s)",
                    tag="FEED_REFRESH",
                )
        except asyncio.CancelledError:
            break
        except Exception as exc:
            TrackLogger.info(
                f"[FEED_REFRESH] Loop error: {exc}",
                tag="FEED_REFRESH",
            )
