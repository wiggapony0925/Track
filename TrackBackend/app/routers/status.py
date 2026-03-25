#
# status.py
# TrackBackend
#
# Router for service alerts and elevator/escalator accessibility status.
#

from __future__ import annotations

import asyncio
import time

from fastapi import APIRouter, HTTPException, Query

from app.models import ElevatorStatus, TransitAlert
from app.services.gtfs.data_cleaner import get_alerts, get_broken_elevators
from app.utils.logger import TrackLogger

router = APIRouter(tags=["status"])

# ── Accessibility cache ───────────────────────────────────────────────────
# The MTA elevator/escalator JSON feed can be extremely slow (50+ seconds).
# Cache results for 5 minutes so only one request per period pays that cost.
_ACCESSIBILITY_CACHE_TTL = 300  # 5 minutes
_accessibility_cache: list[ElevatorStatus] | None = None
_accessibility_cached_at: float = 0.0
_accessibility_lock = asyncio.Lock()


@router.get("/alerts", response_model=list[TransitAlert])
async def alerts(
    mode: str | None = Query(
        default=None,
        description="Filter by transit mode: subway, bus, lirr, mnr. Omit for all.",
    ),
) -> list[TransitAlert]:
    """Return critical MTA service alerts, optionally filtered by mode."""
    try:
        return await asyncio.wait_for(get_alerts(mode=mode), timeout=8.0)
    except asyncio.TimeoutError:
        TrackLogger.warning(
            f"[ALERTS] /alerts timed out after 8s (mode={mode}) — returning empty",
            tag="ALERTS",
        )
        return []
    except Exception as exc:
        TrackLogger.error(f"[ALERTS] Failed to fetch alerts (mode={mode}): {exc}", tag="ALERTS", exc_info=True)
        return []  # return empty instead of 502 to avoid middleware crash


@router.get("/accessibility", response_model=list[ElevatorStatus])
async def accessibility() -> list[ElevatorStatus]:
    """Return currently broken elevators and escalators (cached 5 min)."""
    global _accessibility_cache, _accessibility_cached_at

    now = time.monotonic()
    if _accessibility_cache is not None and (now - _accessibility_cached_at) < _ACCESSIBILITY_CACHE_TTL:
        return _accessibility_cache

    # Use a lock so concurrent requests don't all hit MTA simultaneously
    async with _accessibility_lock:
        # Double-check after acquiring lock (another request may have populated)
        now = time.monotonic()
        if _accessibility_cache is not None and (now - _accessibility_cached_at) < _ACCESSIBILITY_CACHE_TTL:
            return _accessibility_cache

        try:
            result = await asyncio.wait_for(get_broken_elevators(), timeout=30.0)
            _accessibility_cache = result
            _accessibility_cached_at = time.monotonic()
            return result
        except asyncio.TimeoutError:
            TrackLogger.warning(
                "[ALERTS] Elevator status fetch timed out (30s) — returning stale/empty",
                tag="ALERTS",
            )
            return _accessibility_cache or []
        except Exception as exc:
            TrackLogger.error(f"[ALERTS] Failed to fetch elevator status: {exc}", tag="ALERTS", exc_info=True)
            if _accessibility_cache is not None:
                return _accessibility_cache  # serve stale on error
            raise HTTPException(status_code=502, detail=str(exc)) from exc
