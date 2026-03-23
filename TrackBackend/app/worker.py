#
# worker.py
# TrackBackend
#
# arq worker configuration for background task scheduling.
#
# arq is a Redis-backed async task queue that provides:
#   • Cron-style scheduling for periodic jobs (GTFS refresh, weather, etc.)
#   • Automatic retries with exponential backoff on failure
#   • Job visibility — each run is logged with timing and status
#   • Graceful shutdown — in-progress jobs complete before exit
#
# Run the worker alongside the FastAPI server:
#   arq app.worker.WorkerSettings
#
# Or in development:
#   python -m arq app.worker.WorkerSettings
#
# The worker shares the same Redis instance as the main app (REDIS_URL env).
# If Redis is unavailable, the main.py fallback tasks still run via asyncio.
#

from __future__ import annotations

import os
import time
from typing import Any

from arq import cron
from arq.connections import RedisSettings

from app.utils.logger import TrackLogger


# ── Redis connection settings ─────────────────────────────────────────────
def _redis_settings() -> RedisSettings:
    """Build arq RedisSettings from environment."""
    url = os.getenv("REDIS_URL", "redis://localhost:6379")
    # arq uses its own connection pool, separate from redis-py
    return RedisSettings.from_dsn(url)


# ── Job: GTFS freshness check ────────────────────────────────────────────
async def check_gtfs_freshness(ctx: dict[str, Any]) -> dict[str, str]:
    """Check MTA feeds for GTFS static updates and rebuild the schedule DB.

    Runs daily via cron.  Equivalent to the old _periodic_gtfs_check()
    asyncio.create_task loop, but with arq's retry and visibility.
    """
    from app.services.gtfs.gtfs_refresh import check_and_refresh_gtfs

    t0 = time.perf_counter()
    TrackLogger.info("[ARQ] GTFS freshness check starting...", tag="ARQ")

    try:
        results = await check_and_refresh_gtfs(full_check=False)
        elapsed = time.perf_counter() - t0
        TrackLogger.info(
            f"[ARQ] GTFS check complete in {elapsed:.1f}s: {results}",
            tag="ARQ",
        )
        return results
    except Exception as exc:
        elapsed = time.perf_counter() - t0
        TrackLogger.error(
            f"[ARQ] GTFS check failed after {elapsed:.1f}s: {exc}",
            tag="ARQ",
            exc_info=True,
        )
        raise  # arq will retry based on retry config


# ── Job: Weather refresh ─────────────────────────────────────────────────
async def refresh_weather(ctx: dict[str, Any]) -> str:
    """Pre-fetch current weather from Open-Meteo.

    Runs every 5 minutes.  Keeps the weather cache warm so /predict/delay
    and /nearby/grouped never wait on a cold weather fetch.
    """
    from app.clients.weather_client import get_current_weather

    try:
        weather = await get_current_weather()
        TrackLogger.info(f"[ARQ] Weather refreshed: {weather}", tag="ARQ")
        return weather
    except Exception as exc:
        TrackLogger.warning(f"[ARQ] Weather refresh failed: {exc}", tag="ARQ")
        raise


# ── Job: Cache stats flush ───────────────────────────────────────────────
async def flush_cache_stats(ctx: dict[str, Any]) -> None:
    """Periodically log cache hit/miss statistics.

    Runs every 10 minutes.  Provides ongoing visibility into cache
    performance without waiting for shutdown.
    """
    from app.utils import cache_stats

    try:
        cache_stats.flush()
        TrackLogger.info("[ARQ] Cache stats flushed", tag="ARQ")
    except Exception as exc:
        TrackLogger.warning(f"[ARQ] Cache stats flush failed: {exc}", tag="ARQ")


# ── Worker startup / shutdown hooks ───────────────────────────────────────
async def on_startup(ctx: dict[str, Any]) -> None:
    """Called once when the arq worker starts."""
    TrackLogger.info("[ARQ] Worker started — jobs registered", tag="ARQ")


async def on_shutdown(ctx: dict[str, Any]) -> None:
    """Called once when the arq worker shuts down."""
    TrackLogger.info("[ARQ] Worker shutting down", tag="ARQ")


# ── Worker settings ──────────────────────────────────────────────────────
class WorkerSettings:
    """arq worker configuration.

    Run with: arq app.worker.WorkerSettings
    """

    # Redis connection
    redis_settings = _redis_settings()

    # Functions that can be called as on-demand jobs
    functions = [
        check_gtfs_freshness,
        refresh_weather,
        flush_cache_stats,
    ]

    # Cron schedule — these run automatically
    cron_jobs = [
        # GTFS freshness: daily at 4 AM UTC (midnight ET)
        cron(
            check_gtfs_freshness,
            hour=4,
            minute=0,
            run_at_startup=True,   # also run on first boot
            unique=True,           # skip if a previous run is still going
            timeout=600,           # 10 min max (GTFS download + DB rebuild)
        ),
        # Weather: every 5 minutes
        cron(
            refresh_weather,
            minute={0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55},
            run_at_startup=True,
            unique=True,
            timeout=30,
        ),
        # Cache stats: every 10 minutes
        cron(
            flush_cache_stats,
            minute={0, 10, 20, 30, 40, 50},
            unique=True,
            timeout=10,
        ),
    ]

    # Lifecycle hooks
    on_startup = on_startup
    on_shutdown = on_shutdown

    # Retry settings
    max_jobs = 10           # max concurrent jobs
    job_timeout = 600       # default per-job timeout (10 min)
    max_tries = 3           # retry failed jobs up to 3 times
    retry_delay = 30.0      # 30s between retries (arq uses exponential backoff)

    # Queue name — keep separate from any other arq workers
    queue_name = "track:arq"
