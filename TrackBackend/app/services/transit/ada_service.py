"""ADA accessibility service.

Downloads and caches the MTA Subway Stations CSV to provide per-stop ADA
status, and merges the full elevator/escalator equipment inventory with
current outage data to build rich station accessibility profiles.

Both datasets are cached and refreshed in the background.
"""

from __future__ import annotations

import asyncio
import csv
import io
import time
from typing import Any

import httpx

from app.clients.mta_client import fetch_json
from app.config import get_settings
from app.models import (
    EquipmentDetail,
    EquipmentOutage,
    StationAccessibility,
)
from app.utils.logger import TrackLogger

# ---------------------------------------------------------------------------
# Cache configuration
# ---------------------------------------------------------------------------
_ADA_CSV_TTL = 3600  # Refresh station ADA CSV once per hour
_EQUIPMENT_TTL = 300  # Refresh full equipment list every 5 minutes

# ---------------------------------------------------------------------------
# ADA station data cache (from MTA Subway Stations CSV)
# ---------------------------------------------------------------------------
_ADA_FETCH_TIMEOUT = 30.0

# Key: GTFS stop ID (e.g. "127"); Value: dict of ADA fields
_ada_by_stop_id: dict[str, dict[str, Any]] = {}
# Key: normalized station name; Value: list of stop-level dicts
_ada_by_name: dict[str, list[dict[str, Any]]] = {}
_ada_cached_at: float = 0.0
_ada_refreshing: bool = False

# ---------------------------------------------------------------------------
# Equipment inventory cache (from MTA Equipment JSON)
# ---------------------------------------------------------------------------
_EQUIPMENT_FETCH_TIMEOUT = 30.0

# Key: GTFS stop ID; Value: list of equipment dicts
_equipment_by_stop_id: dict[str, list[dict[str, Any]]] = {}
# Key: normalized station name; Value: list of equipment dicts
_equipment_by_name: dict[str, list[dict[str, Any]]] = {}
_equipment_cached_at: float = 0.0
_equipment_refreshing: bool = False

# ---------------------------------------------------------------------------
# Outage index (from existing MTA outages feed, keyed by equipment ID)
# ---------------------------------------------------------------------------
_outages_by_equipment_id: dict[str, dict[str, Any]] = {}
_outages_cached_at: float = 0.0
_outages_refreshing: bool = False

# Background tasks
_background_tasks: set[asyncio.Task[Any]] = set()


def _normalize_name(name: str) -> str:
    """Normalize station name for fuzzy matching."""
    return (
        name.lower()
        .replace("-", " ")
        .replace("–", " ")
        .replace("—", " ")
        .replace("/", " ")
        .replace("  ", " ")
        .strip()
    )


# ---------------------------------------------------------------------------
# ADA CSV fetch & parse
# ---------------------------------------------------------------------------


async def _fetch_ada_csv() -> None:
    """Download the MTA Subway Stations CSV and index by stop ID and name."""
    global _ada_by_stop_id, _ada_by_name, _ada_cached_at, _ada_refreshing
    settings = get_settings()
    url = settings.urls.mta_stations_csv
    if not url:
        TrackLogger.warning("[ADA] No mta_stations_csv URL configured", tag="ADA")
        _ada_refreshing = False
        return

    try:
        async with httpx.AsyncClient(timeout=_ADA_FETCH_TIMEOUT) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            text = resp.text

        reader = csv.DictReader(io.StringIO(text))
        by_id: dict[str, dict[str, Any]] = {}
        by_name: dict[str, list[dict[str, Any]]] = {}

        for row in reader:
            stop_id = row.get("GTFS Stop ID", "").strip()
            if not stop_id:
                continue

            ada_val = int(row.get("ADA", "0") or "0")
            record = {
                "stop_id": stop_id,
                "station_name": row.get("Stop Name", ""),
                "ada_status": ada_val,
                "ada_notes": row.get("ADA Notes", "").strip(),
                "ada_northbound": row.get("ADA Northbound", "0") == "1",
                "ada_southbound": row.get("ADA Southbound", "0") == "1",
                "borough": row.get("Borough", ""),
                "daytime_routes": row.get("Daytime Routes", ""),
                "complex_id": row.get("Complex ID", ""),
            }
            by_id[stop_id] = record

            norm = _normalize_name(record["station_name"])
            by_name.setdefault(norm, []).append(record)

        _ada_by_stop_id = by_id
        _ada_by_name = by_name
        _ada_cached_at = time.monotonic()
        TrackLogger.info(
            f"[ADA] CSV loaded: {len(by_id)} stations indexed", tag="ADA"
        )
    except Exception as exc:
        TrackLogger.error(f"[ADA] CSV fetch failed: {exc}", tag="ADA", exc_info=True)
    finally:
        _ada_refreshing = False


async def _ensure_ada_cache() -> None:
    """Ensure ADA CSV is loaded, refreshing if stale."""
    global _ada_refreshing
    now = time.monotonic()
    if _ada_by_stop_id and (now - _ada_cached_at) < _ADA_CSV_TTL:
        return  # Fresh cache

    if _ada_by_stop_id and not _ada_refreshing:
        # Stale -- kick background refresh
        _ada_refreshing = True
        task = asyncio.create_task(_fetch_ada_csv())
        _background_tasks.add(task)
        task.add_done_callback(_background_tasks.discard)
        return

    if not _ada_by_stop_id and not _ada_refreshing:
        # Cold start -- fetch synchronously
        _ada_refreshing = True
        await _fetch_ada_csv()


# ---------------------------------------------------------------------------
# Equipment inventory fetch & index
# ---------------------------------------------------------------------------


async def _fetch_equipment() -> None:
    """Download the full elevator/escalator equipment list and index."""
    global _equipment_by_stop_id, _equipment_by_name
    global _equipment_cached_at, _equipment_refreshing
    settings = get_settings()
    url = settings.urls.elevators_equipment_json
    if not url:
        TrackLogger.warning(
            "[ADA] No elevators_equipment_json URL configured", tag="ADA"
        )
        _equipment_refreshing = False
        return

    try:
        data: Any = await fetch_json(url)
        items = data if isinstance(data, list) else data.get("results", [])

        by_id: dict[str, list[dict[str, Any]]] = {}
        by_name: dict[str, list[dict[str, Any]]] = {}

        for item in items:
            if not isinstance(item, dict):
                continue
            record = {
                "equipment_id": item.get("equipmentno", ""),
                "equipment_type": item.get("equipmenttype", "EL"),
                "station": item.get("station", ""),
                "serving": item.get("serving", "").strip(),
                "short_description": item.get("shortdescription", "").strip(),
                "is_ada": str(item.get("ADA", "N")).upper() == "Y",
                "is_active": str(item.get("isactive", "Y")).upper() == "Y",
                "lines": item.get("linesservedbyelevator", ""),
                "gtfs_stop_id": item.get("elevatorsgtfsstopid", ""),
                "complex_id": item.get("stationcomplexid", ""),
                "next_ada_north": item.get("nextadanorth", ""),
                "next_ada_south": item.get("nextadasouth", ""),
                "alternative_route": item.get("alternativeroute", ""),
                "bus_connections": item.get("busconnections", ""),
                "redundant": item.get("redundant", 0),
            }

            stop_id = record["gtfs_stop_id"]
            if stop_id:
                by_id.setdefault(stop_id, []).append(record)

            norm = _normalize_name(record["station"])
            if norm:
                by_name.setdefault(norm, []).append(record)

        _equipment_by_stop_id = by_id
        _equipment_by_name = by_name
        _equipment_cached_at = time.monotonic()
        TrackLogger.info(
            f"[ADA] Equipment inventory loaded: {sum(len(v) for v in by_id.values())} items "
            f"across {len(by_id)} stops",
            tag="ADA",
        )
    except Exception as exc:
        TrackLogger.error(
            f"[ADA] Equipment fetch failed: {exc}", tag="ADA", exc_info=True
        )
    finally:
        _equipment_refreshing = False


async def _ensure_equipment_cache() -> None:
    """Ensure equipment inventory is loaded, refreshing if stale."""
    global _equipment_refreshing
    now = time.monotonic()
    if _equipment_by_stop_id and (now - _equipment_cached_at) < _EQUIPMENT_TTL:
        return

    if _equipment_by_stop_id and not _equipment_refreshing:
        _equipment_refreshing = True
        task = asyncio.create_task(_fetch_equipment())
        _background_tasks.add(task)
        task.add_done_callback(_background_tasks.discard)
        return

    if not _equipment_by_stop_id and not _equipment_refreshing:
        _equipment_refreshing = True
        await _fetch_equipment()


# ---------------------------------------------------------------------------
# Outages fetch & index (by equipment ID for merging)
# ---------------------------------------------------------------------------


async def _fetch_outages() -> None:
    """Download current outages and index by equipment ID."""
    global _outages_by_equipment_id, _outages_cached_at, _outages_refreshing
    settings = get_settings()
    url = settings.urls.elevators_json
    if not url:
        _outages_refreshing = False
        return

    try:
        data: Any = await fetch_json(url)
        items = data if isinstance(data, list) else data.get("results", [])

        index: dict[str, dict[str, Any]] = {}
        for item in items:
            if not isinstance(item, dict):
                continue
            eq_id = item.get("equipment", "")
            index[eq_id] = {
                "since": item.get("outagedate", ""),
                "estimated_return": item.get("estimatedreturntoservice", ""),
                "reason": item.get("reason", ""),
                "is_upcoming": item.get("isupcomingoutage", "N"),
                "is_maintenance": item.get("ismaintenanceoutage", "N"),
            }

        _outages_by_equipment_id = index
        _outages_cached_at = time.monotonic()
        TrackLogger.info(
            f"[ADA] Outages indexed: {len(index)} items", tag="ADA"
        )
    except Exception as exc:
        TrackLogger.error(
            f"[ADA] Outages fetch failed: {exc}", tag="ADA", exc_info=True
        )
    finally:
        _outages_refreshing = False


async def _ensure_outages_cache() -> None:
    """Ensure outages are loaded, refreshing if stale."""
    global _outages_refreshing
    now = time.monotonic()
    if _outages_by_equipment_id and (now - _outages_cached_at) < _EQUIPMENT_TTL:
        return

    if _outages_by_equipment_id and not _outages_refreshing:
        _outages_refreshing = True
        task = asyncio.create_task(_fetch_outages())
        _background_tasks.add(task)
        task.add_done_callback(_background_tasks.discard)
        return

    if not _outages_by_equipment_id and not _outages_refreshing:
        _outages_refreshing = True
        await _fetch_outages()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def _build_equipment_detail(raw: dict[str, Any]) -> EquipmentDetail:
    """Convert raw equipment dict + outage data into an EquipmentDetail model."""
    eq_id = raw["equipment_id"]
    outage_raw = _outages_by_equipment_id.get(eq_id)

    is_active = raw.get("is_active", True)
    outage: EquipmentOutage | None = None

    if outage_raw:
        is_active = False
        outage = EquipmentOutage(
            since=outage_raw.get("since") or None,
            estimated_return=outage_raw.get("estimated_return") or None,
            reason=outage_raw.get("reason") or None,
        )

    return EquipmentDetail(
        equipment_id=eq_id,
        equipment_type=raw.get("equipment_type", "EL"),
        short_description=raw.get("short_description", ""),
        serving=raw.get("serving", ""),
        is_ada=raw.get("is_ada", False),
        is_active=is_active,
        lines=raw.get("lines", ""),
        alternative_route=raw.get("alternative_route", ""),
        outage=outage,
    )


def lookup_ada_batch(stop_ids: list[str]) -> dict[str, int]:
    """Synchronous batch ADA lookup from the in-memory cache.

    Accepts GTFS stop IDs (e.g. ``"127N"``, ``"127S"``, ``"127"``) and
    returns a dict mapping each *base* stop ID to its ``ada_status``
    (0 = not accessible, 1 = fully, 2 = partially).  IDs not found in
    the cache are omitted from the result.

    This intentionally reads the cache dict directly — it is only useful
    *after* the cache has been populated at startup or by a prior async
    call.  It never triggers a network fetch.
    """
    result: dict[str, int] = {}
    for raw_id in stop_ids:
        clean = raw_id.strip().upper()
        if not clean:
            continue
        # Strip directional N/S suffix to get the base stop ID
        base = clean
        if len(clean) > 1 and clean[-1] in ("N", "S") and clean[:-1].isalnum():
            base = clean[:-1]
        record = _ada_by_stop_id.get(base)
        if record is not None:
            result[base] = record["ada_status"]
    return result


async def get_station_accessibility(
    stop_ids: list[str] | None = None,
    station_name: str | None = None,
) -> StationAccessibility | None:
    """Build a full accessibility profile for a station.

    Looks up by GTFS stop IDs first (stripping N/S suffixes), then falls back
    to fuzzy name matching.

    Args:
        stop_ids: GTFS stop IDs (e.g. ["127", "127N", "127S"]).
        station_name: Station display name for fallback matching.

    Returns:
        StationAccessibility if the station is found, else None.
    """
    await asyncio.gather(
        _ensure_ada_cache(),
        _ensure_equipment_cache(),
        _ensure_outages_cache(),
    )

    # ---- Resolve ADA record by stop ID ---------------------------------
    ada_record: dict[str, Any] | None = None

    # Strip N/S suffixes from stop IDs to get the base stop ID
    base_ids: set[str] = set()
    if stop_ids:
        for sid in stop_ids:
            clean = sid.strip().upper()
            # Remove trailing N/S (direction suffixes in GTFS)
            if clean and clean[-1] in ("N", "S") and len(clean) > 1 and clean[:-1].isalnum():
                base_ids.add(clean[:-1])
            base_ids.add(clean)

        for bid in base_ids:
            if bid in _ada_by_stop_id:
                ada_record = _ada_by_stop_id[bid]
                break

    # Fallback: name match
    if not ada_record and station_name:
        norm = _normalize_name(station_name)
        candidates = _ada_by_name.get(norm, [])
        if candidates:
            ada_record = candidates[0]

    # ---- Collect equipment for this station ----------------------------
    equipment_raw: list[dict[str, Any]] = []
    seen_eq_ids: set[str] = set()

    # By stop ID first
    for bid in base_ids:
        for eq in _equipment_by_stop_id.get(bid, []):
            if eq["equipment_id"] not in seen_eq_ids:
                equipment_raw.append(eq)
                seen_eq_ids.add(eq["equipment_id"])

    # By name fallback if no equipment found by stop ID
    if not equipment_raw and station_name:
        norm = _normalize_name(station_name)
        for eq in _equipment_by_name.get(norm, []):
            if eq["equipment_id"] not in seen_eq_ids:
                equipment_raw.append(eq)
                seen_eq_ids.add(eq["equipment_id"])

    # If we found nothing at all, return None
    if not ada_record and not equipment_raw:
        return None

    # ---- Build response ------------------------------------------------
    equipment_details = [_build_equipment_detail(eq) for eq in equipment_raw]

    # Sort: ADA elevators first, then by type (EL before ES), then by description
    equipment_details.sort(
        key=lambda e: (
            not e.is_ada,       # ADA equipment first
            e.equipment_type != "EL",  # Elevators before escalators
            not e.is_active,    # Active before inactive
            e.short_description,
        )
    )

    outage_count = sum(1 for e in equipment_details if not e.is_active)
    total_el = sum(1 for e in equipment_details if e.equipment_type == "EL")
    total_es = sum(1 for e in equipment_details if e.equipment_type == "ES")

    # Next ADA stations from equipment data
    next_north = ""
    next_south = ""
    for eq in equipment_raw:
        if eq.get("next_ada_north") and not next_north:
            next_north = eq["next_ada_north"]
        if eq.get("next_ada_south") and not next_south:
            next_south = eq["next_ada_south"]

    return StationAccessibility(
        station_name=ada_record["station_name"] if ada_record else (station_name or ""),
        gtfs_stop_id=ada_record["stop_id"] if ada_record else "",
        ada_status=ada_record["ada_status"] if ada_record else 0,
        ada_notes=ada_record["ada_notes"] if ada_record else "",
        ada_northbound=ada_record["ada_northbound"] if ada_record else False,
        ada_southbound=ada_record["ada_southbound"] if ada_record else False,
        equipment=equipment_details,
        outage_count=outage_count,
        total_elevators=total_el,
        total_escalators=total_es,
        next_accessible_north=next_north,
        next_accessible_south=next_south,
    )
