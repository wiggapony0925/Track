"""Router for service alerts and elevator/escalator accessibility status."""

from __future__ import annotations

import asyncio
import time
from typing import Any

import httpx
from fastapi import APIRouter, HTTPException, Query

from app.models import RESP_502, ElevatorStatus, TransitAlert
from app.services.gtfs.realtime_parser import get_alerts, get_broken_elevators
from app.utils.logger import TrackLogger

# Strong references to fire-and-forget tasks so the GC won't collect them.
_background_tasks: set[asyncio.Task[Any]] = set()

_ACCESSIBILITY_FETCH_TIMEOUT = 30.0
_ALERTS_TIMEOUT = 8.0

router = APIRouter(tags=["status"])

# -- Accessibility cache ---------------------------------------------------
# The MTA elevator/escalator JSON feed can be extremely slow (50+ seconds).
# Uses stale-while-revalidate: always return cached data instantly to the
# user, then refresh in the background.  No user ever blocks on the MTA.
_ACCESSIBILITY_CACHE_TTL = 300  # 5 minutes
_accessibility_cache: list[ElevatorStatus] | None = None
_accessibility_cached_at: float = 0.0
_accessibility_refreshing: bool = False  # True while a bg refresh is running


async def _refresh_accessibility_cache() -> None:
    """Background task: fetch elevator status and update the cache.

    If the fetch fails or times out, the stale cache is preserved so
    subsequent requests still return data.
    """
    global _accessibility_cache, _accessibility_cached_at, _accessibility_refreshing
    try:
        result = await asyncio.wait_for(
            get_broken_elevators(), timeout=_ACCESSIBILITY_FETCH_TIMEOUT
        )
        _accessibility_cache = result
        _accessibility_cached_at = time.monotonic()
        TrackLogger.info(
            f"[ACCESSIBILITY] Cache refreshed -- {len(result)} outages",
            tag="ALERTS",
        )
    except TimeoutError:
        TrackLogger.warning(
            "[ACCESSIBILITY] Background refresh timed out (30s) -- keeping stale cache",
            tag="ALERTS",
        )
    except (httpx.HTTPError, OSError, ValueError, KeyError) as exc:
        TrackLogger.error(
            f"[ACCESSIBILITY] Background refresh failed: {exc}",
            tag="ALERTS",
            exc_info=True,
        )
    finally:
        _accessibility_refreshing = False


@router.get(
    "/alerts",
    response_model=list[TransitAlert],
    summary="Get service alerts",
    description=(
        "Returns critical MTA service alerts (delays, suspensions, planned work) with severity ranking. "
        "Each alert includes affected routes, alert type, and MTA severity sort order. "
        "Optionally filter by transit mode."
    ),
    responses={**RESP_502},
)
async def alerts(
    mode: str | None = Query(
        default=None,
        description="Filter by transit mode. Omit for all modes.",
        examples=["subway", "bus", "lirr", "mnr"],
    ),
) -> list[TransitAlert]:
    """Return critical MTA service alerts.

    Each alert includes title, description, severity, alert_type
    (e.g. Delays, Planned - Suspended), affected_routes, and
    sort_order (MTA severity rank -- higher = more severe).

    Modes: subway, bus, lirr, mnr -- omit for all.

    Returns an empty array (not an error) if the MTA feed times out.
    """
    try:
        return await asyncio.wait_for(get_alerts(mode=mode), timeout=_ALERTS_TIMEOUT)
    except TimeoutError:
        TrackLogger.info(
            f"[ALERTS] /alerts timed out after 8s (mode={mode}) -- returning empty",
            tag="ALERTS",
        )
        return []
    except (OSError, ConnectionError) as exc:
        # Network-level failures -- expected when MTA is down
        TrackLogger.info(
            f"[ALERTS] Upstream unreachable (mode={mode}): {exc}", tag="ALERTS"
        )
        return []
    except Exception as exc:
        # Unexpected errors (parsing bugs, KeyError, etc.) -- log at warning
        # so they surface in monitoring, but still degrade gracefully.
        TrackLogger.warning(
            f"[ALERTS] Unexpected error fetching alerts (mode={mode}): {type(exc).__name__}: {exc}",
            tag="ALERTS",
        )
        return []


@router.get(
    "/accessibility",
    response_model=list[ElevatorStatus],
    summary="Get elevator & escalator outages",
    description=(
        "Returns currently out-of-service elevators and escalators across the MTA system. "
        "Each entry includes station, equipment type (`EL` or `ES`), description, and when "
        "the outage began. Refreshed every 5 minutes in the background."
    ),
    responses={**RESP_502},
)
async def accessibility() -> list[ElevatorStatus]:
    """Return currently broken elevators and escalators.

    Each entry includes station, equipment_type (elevator or escalator),
    description, and outage_since.

    Uses stale-while-revalidate: always returns instantly from cache.
    A background task refreshes the data every 5 minutes.
    On first cold request (no cache), fetches synchronously with a 30s timeout.
    """
    global _accessibility_cache, _accessibility_cached_at, _accessibility_refreshing

    now = time.monotonic()
    age = now - _accessibility_cached_at

    # Fast path: cache is fresh -- return immediately
    if _accessibility_cache is not None and age < _ACCESSIBILITY_CACHE_TTL:
        return _accessibility_cache

    # Stale cache exists -- return it instantly, kick bg refresh if not already running
    if _accessibility_cache is not None:
        if not _accessibility_refreshing:
            _accessibility_refreshing = True
            task = asyncio.create_task(_refresh_accessibility_cache())
            _background_tasks.add(task)
            task.add_done_callback(_background_tasks.discard)
            TrackLogger.info(
                f"[ACCESSIBILITY] Serving stale cache (age={age:.0f}s), bg refresh started",
                tag="ALERTS",
            )
        return _accessibility_cache

    # Cold start: no cache at all -- must fetch synchronously (first request only)
    if not _accessibility_refreshing:
        _accessibility_refreshing = True
        try:
            result = await asyncio.wait_for(
                get_broken_elevators(), timeout=_ACCESSIBILITY_FETCH_TIMEOUT
            )
            _accessibility_cache = result
            _accessibility_cached_at = time.monotonic()
            return result
        except TimeoutError:
            TrackLogger.warning(
                "[ACCESSIBILITY] Cold-start fetch timed out (30s) -- returning empty",
                tag="ALERTS",
            )
            return []
        except Exception as exc:
            TrackLogger.error(
                f"[ACCESSIBILITY] Cold-start fetch failed: {exc}",
                tag="ALERTS",
                exc_info=True,
            )
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        finally:
            _accessibility_refreshing = False

    # Another request is already doing the cold-start fetch -- return empty
    # rather than blocking.  The next request after the fetch completes
    # will return the populated cache.
    return []
