"""Router for service alerts and elevator/escalator accessibility status."""

from __future__ import annotations

import asyncio
import time
from typing import Any

import httpx
from fastapi import APIRouter, HTTPException, Query

from app.models import RESP_502, ElevatorStatus, StationAccessibility, TransitAlert
from app.services.gtfs.realtime_parser import get_alerts, get_broken_elevators
from app.services.transit.ada_service import get_station_accessibility
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
    "/alerts/status",
    response_model=dict[str, str],
    summary="Per-route service status",
    description=(
        "Returns the worst active alert type for every affected route, "
        "keyed by route_id.  "
        "Routes absent from the response have no active alerts — treat them "
        "as 'No Active Alerts' (subway/bus) or 'On or Close to Schedule' "
        "(LIRR/MNR).  "
        "When a route has multiple active alerts the one with the highest "
        "sort_order wins, matching the MTA Status Box specification."
    ),
    responses={**RESP_502},
)
async def route_status(
    mode: str | None = Query(
        default=None,
        description="Filter by transit mode. Omit for all modes.",
        examples=["subway", "bus", "lirr", "mnr"],
    ),
) -> dict[str, str]:
    """Return worst active alert_type per route_id.

    Follows the MTA 'Status Box' algorithm:
    1. Fetch all currently active alerts (honouring display_before_active).
    2. For each route_id collect every matching alert.
    3. Pick the alert with the highest sort_order (most severe).
    4. Return its alert_type string as that route's status label.

    Routes not present in the response have no active alerts.
    """
    try:
        alerts_list = await asyncio.wait_for(
            get_alerts(mode=mode), timeout=_ALERTS_TIMEOUT
        )
    except TimeoutError:
        TrackLogger.info(
            f"[ALERTS] /alerts/status timed out after 8s (mode={mode}) "
            "-- returning empty",
            tag="ALERTS",
        )
        return {}
    except (OSError, ConnectionError, Exception) as exc:
        TrackLogger.warning(
            f"[ALERTS] /alerts/status error (mode={mode}): "
            f"{type(exc).__name__}: {exc}",
            tag="ALERTS",
        )
        return {}

    # worst[route_id] = (sort_order, alert_type)
    worst: dict[str, tuple[int, str]] = {}
    for alert in alerts_list:
        if not alert.alert_type:
            continue
        routes = alert.affected_routes or ([alert.route_id] if alert.route_id else [])
        for route_id in routes:
            current = worst.get(route_id)
            if current is None or alert.sort_order > current[0]:
                worst[route_id] = (alert.sort_order, alert.alert_type)

    result = {rid: label for rid, (_, label) in worst.items()}
    TrackLogger.info(
        f"[ALERTS] /alerts/status → {len(result)} routes affected (mode={mode})",
        tag="ALERTS",
    )
    return result


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


@router.get(
    "/accessibility/station",
    response_model=StationAccessibility,
    summary="Get station accessibility profile",
    description=(
        "Returns the full ADA accessibility profile for a station: "
        "ADA status (0=not accessible, 1=fully, 2=partially), direction notes, "
        "all elevators and escalators with their current in-service/out-of-service status, "
        "outage details, and travel alternatives. "
        "Provide GTFS stop IDs (preferred) or station name for matching."
    ),
    responses={
        404: {"description": "Station not found in accessibility datasets."},
        **RESP_502,
    },
)
async def station_accessibility(
    stop_ids: str | None = Query(
        default=None,
        description=(
            "Comma-separated GTFS stop IDs to look up "
            "(e.g. '127,127N,127S'). Direction suffixes are handled automatically."
        ),
        examples=["127,127N,127S", "L06"],
    ),
    name: str | None = Query(
        default=None,
        description="Station display name for fallback matching (e.g. 'Times Sq-42 St').",
        examples=["Times Sq-42 St", "1 Av"],
    ),
) -> StationAccessibility:
    """Return the full accessibility profile for a single station.

    Resolves by GTFS stop IDs first (stripping N/S direction suffixes),
    then falls back to fuzzy station-name matching.  Includes ADA status
    from the MTA Subway Stations CSV and the live elevator/escalator
    equipment inventory merged with current outage data.
    """
    ids = [s.strip() for s in stop_ids.split(",") if s.strip()] if stop_ids else None

    if not ids and not name:
        raise HTTPException(
            status_code=400,
            detail="Provide at least one of 'stop_ids' or 'name'.",
        )

    try:
        result = await get_station_accessibility(stop_ids=ids, station_name=name)
    except Exception as exc:
        TrackLogger.error(
            f"[ADA] Station accessibility lookup failed: {exc}",
            tag="ADA",
            exc_info=True,
        )
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    if result is None:
        raise HTTPException(
            status_code=404,
            detail=f"Station not found (stop_ids={stop_ids}, name={name}).",
        )
    return result
