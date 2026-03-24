#
# alert_service.py
# app/services/alert_service.py
#
# In-process alert index for the ML correction pipeline.
#
# Fetches active MTA service alerts every 2 minutes and maintains
# a dict {route_id → boost} used by _ml_corrected() to inflate the
# GBR factor when a route has an active disruption.
#
# ── Boost table ────────────────────────────────────────────────────────────
#   severe  → +25%  (service suspended / major gap / signal failure)
#   warning → +10%  (delays reported but service running)
#   (INFO alerts are already filtered out by data_cleaner.py)
#
# ── Usage in _ml_corrected ─────────────────────────────────────────────────
#   await maybe_refresh()
#   boost = get_alert_boost(route_id)           # O(1), synchronous
#   effective_factor = min(2.0, factor * (1 + boost))
#
# ── Design ─────────────────────────────────────────────────────────────────
#   - Refresh is cooperative: first caller after TTL triggers the fetch;
#     concurrent callers see the stale index rather than wait.
#   - An asyncio.Lock prevents duplicate fetches under burst traffic.
#   - All errors are silently swallowed — stale or empty index is safe
#     (ML just runs without the alert signal until next refresh).
#

from __future__ import annotations

import asyncio
import time as _time

from app.utils.logger import TrackLogger

_REFRESH_INTERVAL = 120.0   # seconds between alert re-fetches
_SEVERE_BOOST     = 0.25    # factor × 1.25 for SEVERE alerts
_WARNING_BOOST    = 0.10    # factor × 1.10 for WARNING alerts

# Module-level state — intentionally simple (no class needed).
_boost_by_route: dict[str, float] = {}
_last_refresh: float = 0.0
_refresh_lock: asyncio.Lock | None = None   # created lazily inside event loop


def _get_lock() -> asyncio.Lock:
    global _refresh_lock
    if _refresh_lock is None:
        _refresh_lock = asyncio.Lock()
    return _refresh_lock


def get_alert_boost(route_id: str) -> float:
    """Return the severity-based boost for *route_id*.

    Synchronous and O(1) — safe to call from the hot request path.
    Returns 0.0 when no active alert exists for the route.
    """
    key = route_id.upper().strip()
    # Strip agency prefix (e.g. "MTA NYCT_Q10" → "Q10")
    if "_" in key:
        key = key.split("_")[-1]
    return _boost_by_route.get(key, 0.0)


async def maybe_refresh() -> None:
    """Refresh the alert index if it's stale.

    Non-blocking: if another coroutine already holds the lock, returns
    immediately so the caller proceeds with the current (stale) index.
    """
    if _time.time() - _last_refresh < _REFRESH_INTERVAL:
        return

    lock = _get_lock()
    if lock.locked():
        return  # another coroutine is refreshing — use stale data

    async with lock:
        # Double-check after acquiring lock
        if _time.time() - _last_refresh < _REFRESH_INTERVAL:
            return
        await _do_refresh()


async def _do_refresh() -> None:
    global _boost_by_route, _last_refresh
    try:
        from app.services.gtfs.data_cleaner import get_alerts  # avoid circular at module level
        alerts = await asyncio.wait_for(get_alerts(), timeout=3.0)
        new_index: dict[str, float] = {}
        for alert in alerts:
            sev = (alert.severity or "").lower()
            boost = _SEVERE_BOOST if sev == "severe" else (
                    _WARNING_BOOST if sev == "warning" else 0.0)
            if boost == 0.0:
                continue
            # Apply boost to every affected route, keeping the worst per route
            for rid in alert.affected_routes:
                key = rid.upper().strip()
                if "_" in key:
                    key = key.split("_")[-1]
                new_index[key] = max(new_index.get(key, 0.0), boost)
            # Also cover the primary route_id field
            if alert.route_id:
                key = alert.route_id.upper().strip()
                if "_" in key:
                    key = key.split("_")[-1]
                new_index[key] = max(new_index.get(key, 0.0), boost)

        _boost_by_route = new_index
        _last_refresh = _time.time()
        severe_count  = sum(1 for v in new_index.values() if v >= _SEVERE_BOOST)
        warning_count = sum(1 for v in new_index.values() if v < _SEVERE_BOOST)
        TrackLogger.info(
            f"[ALERTS] Index refreshed — {severe_count} SEVERE, "
            f"{warning_count} WARNING routes affected",
            tag="ML",
        )
    except asyncio.TimeoutError:
        TrackLogger.warning("[ALERTS] Refresh timed out after 3s — using stale index", tag="ML")
        _last_refresh = _time.time()  # back off, don't hammer on repeated timeouts
    except Exception as exc:
        TrackLogger.warning(f"[ALERTS] Refresh failed ({exc}) — using stale index", tag="ML")
        _last_refresh = _time.time()  # back off, don't hammer on repeated errors
