"""Bus stop index built from the MTA Bus Stops open data dataset.

Fetches every in-effect revenue stop from the NYS Open Data portal and
builds two look-up structures:

* A **global stop index** keyed by stop ID – useful for rendering a stop
  marker anywhere on the map.
* A **route-direction stop list** keyed by ``"route_id|direction_id"`` –
  gives the ordered stops for one direction of a route, ready to attach to
  a :class:`~app.models.DirectionShape`.

The dataset is published on data.ny.gov and is updated automatically with
each MTA schedule bundle, so this module never needs a GTFS redeploy to
stay current.

Dataset: MTA Bus Stops
URL:     https://data.ny.gov/Transportation/MTA-Bus-Stops/2ucp-7wg5
API:     https://data.ny.gov/resource/2ucp-7wg5.json

Usage::

    from app.services.mapping.bus.stops import (
        get_bus_stop_index,
        get_bus_route_stops,
    )

    stop_index = await get_bus_stop_index()      # dict[stop_id, BusStop]
    stops = await get_bus_route_stops("B63", 0)  # list[BusStop] northbound
"""

from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path
from typing import Any

import httpx

from app.config import get_settings
from app.models import BusStop
from app.utils.logger import TrackLogger

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# In-effect revenue stops only — this is the primary filter that keeps the
# result set small (~20–30 k rows for the whole system).
#
# Socrata exposes ``in_effect`` as "true"/"false" strings but
# ``revenue_stop`` as "1"/"0" strings, not booleans.  Filtering on
# revenue_stop='true' returns zero rows from the live dataset.
_OPEN_DATA_URL = get_settings().urls.bus_open_data_stops_api

_PAGE_SIZE = 50_000

_CACHE_VERSION = 1
_DATA_DIR = Path(__file__).resolve().parents[3] / "data"
_CACHE_PATH = _DATA_DIR / f"_cache_bus_stops_v{_CACHE_VERSION}.json"

# 6-hour TTL — same as bus/routes.py so both caches expire together.
_CACHE_MAX_AGE_S = 6 * 3_600

# ---------------------------------------------------------------------------
# In-memory caches
# ---------------------------------------------------------------------------

# stop_id (e.g. "MTA_308214") → BusStop
_stop_index: dict[str, BusStop] | None = None

# "route_id|direction_id" (e.g. "B63|0") → ordered list[BusStop]
_route_dir_index: dict[str, list[BusStop]] | None = None

# Prevents multiple concurrent coroutines from each firing an independent
# HTTP fetch when both indexes are None (thundering-herd guard).
# Lazy — must be created inside the running event loop to avoid
# "Lock is bound to a different event loop" errors with gunicorn workers.
_fetch_lock: asyncio.Lock | None = None


def _get_fetch_lock() -> asyncio.Lock:
    global _fetch_lock
    if _fetch_lock is None:
        _fetch_lock = asyncio.Lock()
    return _fetch_lock


# ---------------------------------------------------------------------------
# Internal fetch helpers
# ---------------------------------------------------------------------------


async def _fetch_all_rows() -> list[dict[str, Any]]:
    """Fetch all in-effect revenue stop rows, paginating if needed.

    Returns:
        A list of raw Socrata row dicts.
    """
    rows: list[dict[str, Any]] = []
    offset = 0
    async with httpx.AsyncClient(timeout=30.0) as client:
        while True:
            url = f"{_OPEN_DATA_URL}&$offset={offset}"
            resp = await client.get(url)
            resp.raise_for_status()
            page: list[dict[str, Any]] = resp.json()
            rows.extend(page)
            if len(page) < _PAGE_SIZE:
                break
            offset += _PAGE_SIZE
    return rows


def _build_indexes(
    rows: list[dict[str, Any]],
) -> tuple[dict[str, BusStop], dict[str, list[BusStop]]]:
    """Build both stop-index and route-direction index from raw API rows.

    Args:
        rows: Raw Socrata rows from the MTA Bus Stops dataset.

    Returns:
        A tuple of:
            - stop_index: ``{stop_id → BusStop}``
            - route_dir_index: ``{"route_id|direction_id" → [BusStop, ...]}``
    """
    # Pass 1: build global stop index, accumulating route_ids per stop.
    # Each row is one (route_id, direction_id, stop_id) combination so a
    # busy stop like 34 St & 8 Av appears dozens of times.
    stop_raw: dict[str, dict[str, Any]] = {}
    stop_routes: dict[str, list[str]] = {}

    for row in rows:
        raw_stop_id = str(row.get("stop_id", "")).strip()
        if not raw_stop_id:
            continue

        oba_id = f"MTA_{raw_stop_id}"

        if oba_id not in stop_raw:
            lat_raw = row.get("latitude")
            lon_raw = row.get("longitude")
            try:
                lat = float(lat_raw)
                lon = float(lon_raw)
            except (TypeError, ValueError):
                continue

            stop_raw[oba_id] = {
                "id": oba_id,
                "name": str(row.get("stop_name", "")).strip(),
                "lat": lat,
                "lon": lon,
                # direction from the first route-direction that uses this stop.
                "direction": str(row.get("direction", "")).strip() or None,
            }
            stop_routes[oba_id] = []

        route_id = str(row.get("route_id", "")).strip()
        if route_id and route_id not in stop_routes[oba_id]:
            stop_routes[oba_id].append(route_id)

    stop_index: dict[str, BusStop] = {
        oba_id: BusStop(
            id=oba_id,
            name=data["name"],
            lat=data["lat"],
            lon=data["lon"],
            direction=data["direction"],
            route_ids=stop_routes[oba_id],
        )
        for oba_id, data in stop_raw.items()
    }

    # Pass 2: build per-route-direction stop list.
    # Rows are already ordered by route_id, direction_id, stop_id from the
    # API (see _OPEN_DATA_URL) so we just collect in insertion order.
    route_dir_index: dict[str, list[BusStop]] = {}

    for row in rows:
        route_id = str(row.get("route_id", "")).strip()
        direction_id = str(row.get("direction_id", "")).strip()
        raw_stop_id = str(row.get("stop_id", "")).strip()

        if not route_id or not direction_id or not raw_stop_id:
            continue

        oba_id = f"MTA_{raw_stop_id}"
        stop = stop_index.get(oba_id)
        if stop is None:
            continue

        key = f"{route_id}|{direction_id}"
        if key not in route_dir_index:
            route_dir_index[key] = []

        # Avoid duplicates — the open data can have multiple bundle rows for
        # the same stop on the same route+direction.
        if all(s.id != oba_id for s in route_dir_index[key]):
            route_dir_index[key].append(stop)

    return stop_index, route_dir_index


# ---------------------------------------------------------------------------
# Disk cache helpers
# ---------------------------------------------------------------------------


def _load_disk_cache(
    allow_stale: bool = False,
) -> tuple[dict[str, BusStop], dict[str, list[BusStop]]] | None:
    """Load indexes from disk if the cache file exists and is still fresh.

    Args:
        allow_stale: If True, returns the cache even if it is older than
            _CACHE_MAX_AGE_S. Useful as a fallback when the API is down.

    Returns:
        A tuple of (stop_index, route_dir_index), or None if the cache is
        missing or (not allow_stale and stale).
    """
    if not _CACHE_PATH.exists():
        return None

    age = time.time() - _CACHE_PATH.stat().st_mtime
    if not allow_stale and age > _CACHE_MAX_AGE_S:
        return None

    try:
        raw = json.loads(_CACHE_PATH.read_text())
        stop_index = {k: BusStop(**v) for k, v in raw["stops"].items()}
        if not stop_index:
            # Cache was written during a failed previous fetch — discard it.
            TrackLogger.warning(
                "[BUS_STOPS] Disk cache has 0 stops — discarding and re-fetching.",
                tag="BUS_STOPS",
            )
            return None
        route_dir_index: dict[str, list[BusStop]] = {}
        for key, stop_list in raw["route_dirs"].items():
            route_dir_index[key] = [BusStop(**s) for s in stop_list]
        return stop_index, route_dir_index
    except Exception as exc:
        TrackLogger.warning(
            f"[BUS_STOPS] Disk cache read failed ({exc}); will re-fetch.",
            tag="BUS_STOPS",
        )
        return None


def _save_disk_cache(
    stop_index: dict[str, BusStop],
    route_dir_index: dict[str, list[BusStop]],
) -> None:
    """Persist both indexes to disk.

    Does not write if the indexes are empty — an empty result means the
    upstream fetch failed and we don't want to poison the cache.

    Args:
        stop_index: Global stop index.
        route_dir_index: Per-route-direction stop lists.
    """
    if not stop_index:
        TrackLogger.warning(
            "[BUS_STOPS] Skipping disk cache write — stop index is empty.",
            tag="BUS_STOPS",
        )
        return
    try:
        _DATA_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "stops": {k: v.model_dump() for k, v in stop_index.items()},
            "route_dirs": {
                key: [s.model_dump() for s in stop_list]
                for key, stop_list in route_dir_index.items()
            },
        }
        _CACHE_PATH.write_text(json.dumps(payload))
        # Upload to Supabase in the background — eliminates the Socrata
        # rate-limit warmup on cold starts.
        from app.services.gtfs.bus_cache_sync import upload_bus_cache

        upload_bus_cache("bus_stops_cache.tar.gz", _CACHE_PATH)
    except Exception as exc:
        TrackLogger.warning(
            f"[BUS_STOPS] Disk cache write failed ({exc}).",
            tag="BUS_STOPS",
        )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def _ensure_indexes() -> (
    tuple[dict[str, BusStop], dict[str, list[BusStop]]]
):
    """Return both indexes, fetching and caching as needed.

    Returns:
        A tuple of (stop_index, route_dir_index).
    """
    global _stop_index, _route_dir_index  # noqa: PLW0603

    # Fast path — both indexes already loaded in this process.
    if _stop_index is not None and _route_dir_index is not None:
        return _stop_index, _route_dir_index

    # Only one coroutine fetches; all others wait here, then read the result.
    async with _get_fetch_lock():
        # Re-check after acquiring the lock — another coroutine may have
        # already populated the indexes while we were waiting.
        if _stop_index is not None and _route_dir_index is not None:
            return _stop_index, _route_dir_index

        cached = _load_disk_cache()
        if cached is not None:
            _stop_index, _route_dir_index = cached
            TrackLogger.info(
                f"[BUS_STOPS] Loaded {len(_stop_index)} stops from disk cache.",
                tag="BUS_STOPS",
            )
            return _stop_index, _route_dir_index

        t0 = time.perf_counter()
        TrackLogger.info(
            "[BUS_STOPS] Fetching from MTA open data…", tag="BUS_STOPS"
        )

        try:
            rows = await _fetch_all_rows()
            _stop_index, _route_dir_index = _build_indexes(rows)
            _save_disk_cache(_stop_index, _route_dir_index)
        except Exception as exc:
            TrackLogger.error(
                f"[BUS_STOPS] Upstream fetch failed: {exc}. Attempting stale fallback.",
                tag="BUS_STOPS",
            )
            # Fallback: try to load the disk cache even if it is stale.
            stale_cached = _load_disk_cache(allow_stale=True)
            if stale_cached is not None:
                _stop_index, _route_dir_index = stale_cached
                TrackLogger.warning(
                    f"[BUS_STOPS] Using stale disk cache ({len(_stop_index)} stops) "
                    "due to upstream failure.",
                    tag="BUS_STOPS",
                )
                return _stop_index, _route_dir_index
            # No cache at all — let the error propagate or return empty.
            # Given tile-data's scale, an empty result is better than a 500 crash.
            TrackLogger.error(
                "[BUS_STOPS] No disk cache available for fallback. Returning empty.",
                tag="BUS_STOPS",
            )
            _stop_index, _route_dir_index = {}, {}

        TrackLogger.info(
            f"[BUS_STOPS] Indexed {len(_stop_index)} stops across"
            f" {len(_route_dir_index)} route-directions"
            f" in {time.perf_counter() - t0:.1f}s.",
            tag="BUS_STOPS",
        )
        return _stop_index, _route_dir_index


async def get_bus_stop_index() -> dict[str, BusStop]:
    """Return a mapping of stop ID to BusStop for every in-effect revenue stop.

    The dictionary is keyed by OBA-style stop IDs (e.g. ``"MTA_308214"``).
    Results are cached in memory and refreshed from disk / the API at most
    every 6 hours.

    Returns:
        A dict mapping stop ID strings to :class:`~app.models.BusStop` objects.
    """
    stop_index, _ = await _ensure_indexes()
    return stop_index


async def get_bus_route_stops(
    route_id: str,
    direction_id: int,
) -> list[BusStop]:
    """Return the ordered stop list for one route direction.

    Args:
        route_id: Short route identifier, e.g. ``"B63"`` or ``"MTA NYCT_B63"``.
            If a prefixed form is provided, the prefix is stripped before
            look-up.
        direction_id: ``0`` for outbound / northbound, ``1`` for inbound /
            southbound.

    Returns:
        An ordered list of :class:`~app.models.BusStop` objects, or an empty
        list if the route/direction is not found in the index.
    """
    _, route_dir_index = await _ensure_indexes()

    # Normalise to short form (e.g. "MTA NYCT_B63" → "B63").
    short = route_id.split("_", 1)[-1].strip() if "_" in route_id else route_id

    return route_dir_index.get(f"{short}|{direction_id}", [])


def invalidate_bus_stops_cache() -> None:
    """Clear the in-memory stop cache and remove the disk cache file.

    The next call to :func:`get_bus_stop_index` or
    :func:`get_bus_route_stops` will re-fetch from the API.
    """
    global _stop_index, _route_dir_index  # noqa: PLW0603

    _stop_index = None
    _route_dir_index = None

    try:
        if _CACHE_PATH.exists():
            _CACHE_PATH.unlink()
    except Exception as exc:
        TrackLogger.warning(
            f"[BUS_STOPS] Failed to delete disk cache ({exc}).",
            tag="BUS_STOPS",
        )
