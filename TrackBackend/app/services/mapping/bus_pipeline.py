"""Bus polyline pipeline using the MTA Bus Routes open data dataset.

Fetches clean street-level polylines from the NYS Open Data portal instead of
raw GTFS shapes.txt, which has platform-jag artefacts and is updated only
4x/year.  The open data dataset (h2wf-afav) is pre-filtered to currently
in-effect routes and is updated with each schedule bundle release.

Dataset: MTA Current Bus Routes
URL:     https://data.ny.gov/Transportation/MTA-Current-Bus-Routes/h2wf-afav
API:     https://data.ny.gov/resource/h2wf-afav.json

Each row represents one unique route shape (route_id + direction_id +
shape_id + trip_type). Geometry is returned by Socrata as GeoJSON and may
also appear as legacy WKT in older exports. Coordinates use EPSG:4326 with
**longitude-first** order.

Usage::

    from app.services.mapping.bus.routes import get_bus_open_data_shapes

    shapes = await get_bus_open_data_shapes()  # dict[route_id, RouteShape]
    shape = shapes.get("B63")
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

import httpx

from app.models import DirectionShape, RouteShape
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import encode_polyline

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Pre-filtered Socrata view: in_effect = true, current bundle only.
_OPEN_DATA_URL = (
    "https://data.ny.gov/resource/h2wf-afav.json"
    "?$limit=50000&$order=route_id,direction_id"
)

# Page size for paginated fallback (only used if the dataset grows past 50 k).
_PAGE_SIZE = 50_000

# Disk cache keeps the processed index so server restarts are instant.
_CACHE_VERSION = 1
_DATA_DIR = Path(__file__).resolve().parent.parent.parent / "data"
_CACHE_PATH = _DATA_DIR / f"_cache_bus_shapes_v{_CACHE_VERSION}.json"

# Preferred trip_type for picking the canonical shape per route+direction.
# 1 = Normal Local, 12 = Limited, 13 = Express, 14 = SBS.
# Lower index = higher preference.
_TRIP_TYPE_PREFERENCE: list[int] = [1, 11, 12, 13, 14, 10]

# Human-readable cardinal direction → headsign label.
_DIRECTION_LABEL: dict[str, str] = {
    "N": "Northbound",
    "S": "Southbound",
    "E": "Eastbound",
    "W": "Westbound",
}

# Maximum seconds a cached result is considered fresh without re-fetching.
_CACHE_MAX_AGE_S = 6 * 3_600  # 6 hours

# Module-level in-memory index (populated on first call).
_index: dict[str, RouteShape] | None = None


# ---------------------------------------------------------------------------
# WKT parser
# ---------------------------------------------------------------------------

# Matches a single linestring's coordinate block inside a MULTILINESTRING or
# a bare LINESTRING: one or more "lon lat" pairs separated by ", ".
_COORD_PAIR_RE = re.compile(r"(-?\d+\.\d+)\s+(-?\d+\.\d+)")


def _parse_wkt_geometry(geometry_raw: Any) -> list[list[tuple[float, float]]]:
    """Parse Socrata geometry into lat/lon polyline lists.

    Socrata currently returns GeoJSON geometry objects for this dataset, but
    older exports may still surface WKT strings. This function accepts both
    forms and converts them to the (lat, lon) convention used elsewhere in the
    codebase.

    Args:
        geometry_raw: Geometry payload from the Socrata API.

    Returns:
        A list of polylines; each polyline is a list of (lat, lon) tuples.
        Returns an empty list if the geometry is malformed or empty.
    """
    if not geometry_raw:
        return []

    if isinstance(geometry_raw, dict):
        geometry_type = str(geometry_raw.get("type") or "").strip().upper()
        coordinates = geometry_raw.get("coordinates")
        if not isinstance(coordinates, list):
            return []

        if geometry_type == "LINESTRING":
            raw_segments = [coordinates]
        elif geometry_type == "MULTILINESTRING":
            raw_segments = coordinates
        else:
            return []

        polylines: list[list[tuple[float, float]]] = []
        for segment in raw_segments:
            if not isinstance(segment, list):
                continue
            coords = []
            for pair in segment:
                if not isinstance(pair, list) or len(pair) < 2:
                    continue
                try:
                    lon = float(pair[0])
                    lat = float(pair[1])
                except (TypeError, ValueError):
                    continue
                coords.append((lat, lon))
            if len(coords) >= 2:  # noqa: PLR2004 — minimum viable polyline
                polylines.append(coords)
        return polylines

    if not isinstance(geometry_raw, str):
        return []

    wkt = geometry_raw
    wkt = wkt.strip()

    if wkt.upper().startswith("MULTILINESTRING"):
        # Strip outer "MULTILINESTRING ((" / "))" and split on "), (" boundaries.
        inner = re.sub(r"^MULTILINESTRING\s*\(\(", "", wkt, flags=re.IGNORECASE)
        inner = re.sub(r"\)\)\s*$", "", inner)
        raw_segments = inner.split("),(")
    elif wkt.upper().startswith("LINESTRING"):
        inner = re.sub(r"^LINESTRING\s*\(", "", wkt, flags=re.IGNORECASE)
        inner = re.sub(r"\)\s*$", "", inner)
        raw_segments = [inner]
    else:
        return []

    polylines: list[list[tuple[float, float]]] = []
    for seg in raw_segments:
        coords = [
            # WKT is lon lat → swap to (lat, lon).
            (float(m.group(2)), float(m.group(1)))
            for m in _COORD_PAIR_RE.finditer(seg)
        ]
        if len(coords) >= 2:  # noqa: PLR2004 — minimum viable polyline
            polylines.append(coords)

    return polylines


# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------


async def _fetch_all_rows() -> list[dict[str, Any]]:
    """Fetch all rows from the MTA Current Bus Routes Socrata endpoint.

    Uses $limit=50000 to retrieve everything in a single request.  If the
    dataset ever exceeds 50 k rows, falls back to offset pagination.

    Returns:
        List of raw row dicts from the JSON API.

    Raises:
        httpx.HTTPError: On network or HTTP-level failures.
    """
    rows: list[dict[str, Any]] = []
    offset = 0

    async with httpx.AsyncClient(timeout=60.0) as client:
        while True:
            url = f"{_OPEN_DATA_URL}&$offset={offset}"
            response = await client.get(url)
            response.raise_for_status()
            page: list[dict[str, Any]] = response.json()
            rows.extend(page)
            if len(page) < _PAGE_SIZE:
                break
            offset += _PAGE_SIZE

    return rows


# ---------------------------------------------------------------------------
# Index builder
# ---------------------------------------------------------------------------


def _trip_type_rank(trip_type_raw: Any) -> int:
    """Return a sort key for trip_type; lower = more preferred.

    Args:
        trip_type_raw: The raw ``trip_type`` value from the API row (may be
            a string or int).

    Returns:
        Integer rank; types not in the preference list sort to the end.
    """
    try:
        tt = int(trip_type_raw)
    except (TypeError, ValueError):
        return len(_TRIP_TYPE_PREFERENCE)
    try:
        return _TRIP_TYPE_PREFERENCE.index(tt)
    except ValueError:
        return len(_TRIP_TYPE_PREFERENCE)


def _build_index(rows: list[dict[str, Any]]) -> dict[str, RouteShape]:
    """Build a route_id → RouteShape index from raw API rows.

    Strategy per route + direction:
    1. Prefer trip_type=1 (Normal Local) over variants.
    2. Among equal trip types, pick the shape with the most WKT vertices
       (most complete coverage).

    Args:
        rows: Raw row dicts from the Socrata JSON API.

    Returns:
        Dict mapping short route_id (e.g. "B63") to a RouteShape with
        per-direction data and merged polylines.  Stops are left empty
        because stop data comes from OBA / GTFS, not this dataset.
    """
    # Collect candidates: (route_id, direction_id) → best row so far.
    # Key: (route_id, direction_id)
    # Value: (trip_type_rank, vertex_count, parsed_polylines, row)
    BestEntry = tuple[int, int, list[list[tuple[float, float]]], dict[str, Any]]
    best: dict[tuple[str, int], BestEntry] = {}

    for row in rows:
        route_id = (row.get("route_id") or "").strip()
        if not route_id:
            continue

        dir_raw = row.get("direction_id", "0")
        try:
            direction_id = int(dir_raw)
        except (TypeError, ValueError):
            direction_id = 0

        wkt = row.get("geometry") or ""
        polylines = _parse_wkt_geometry(wkt)
        if not polylines:
            continue

        vertex_count = sum(len(p) for p in polylines)
        rank = _trip_type_rank(row.get("trip_type"))
        key = (route_id, direction_id)

        existing = best.get(key)
        if existing is None:
            best[key] = (rank, vertex_count, polylines, row)
        else:
            ex_rank, ex_vertices, _, _ = existing
            # Lower rank (= more preferred trip_type) wins; break ties by
            # vertex count (more = more complete shape).
            if rank < ex_rank or (rank == ex_rank and vertex_count > ex_vertices):
                best[key] = (rank, vertex_count, polylines, row)

    # Assemble per-route DirectionShape entries.
    route_directions: dict[str, list[DirectionShape]] = {}
    for (route_id, direction_id), (_, _, polylines, row) in sorted(best.items()):
        cardinal = (row.get("direction") or "").strip().upper()
        headsign = _DIRECTION_LABEL.get(cardinal, cardinal or str(direction_id))
        service_type = (row.get("route_type") or "").strip().lower() or None

        encoded = [encode_polyline(poly) for poly in polylines if len(poly) >= 2]
        if not encoded:
            continue

        direction_shape = DirectionShape(
            direction_id=direction_id,
            headsign=headsign,
            polylines=encoded,
            stops=[],
            service_type=service_type,
        )
        route_directions.setdefault(route_id, []).append(direction_shape)

    # Build final RouteShape per route.
    index: dict[str, RouteShape] = {}
    for route_id, directions in route_directions.items():
        merged_polylines: list[str] = []
        seen: set[str] = set()
        for ds in directions:
            for enc in ds.polylines:
                if enc not in seen:
                    merged_polylines.append(enc)
                    seen.add(enc)

        index[route_id] = RouteShape(
            route_id=route_id,
            polylines=merged_polylines,
            stops=[],
            directions=directions,
            service_type=directions[0].service_type if directions else None,
        )

    return index


# ---------------------------------------------------------------------------
# Disk cache
# ---------------------------------------------------------------------------


def _load_disk_cache() -> dict[str, RouteShape] | None:
    """Load the processed index from disk if it exists and is still fresh.

    Returns:
        Parsed index dict, or None if the cache is missing, stale, or corrupt.
    """
    if not _CACHE_PATH.exists():
        return None

    age_s = time.time() - _CACHE_PATH.stat().st_mtime
    if age_s > _CACHE_MAX_AGE_S:
        TrackLogger.bus(
            f"Bus shapes disk cache expired ({age_s / 3600:.1f} h old), refreshing"
        )
        return None

    try:
        raw = json.loads(_CACHE_PATH.read_text(encoding="utf-8"))
        index: dict[str, RouteShape] = {
            rid: RouteShape.model_validate(shape) for rid, shape in raw.items()
        }
        TrackLogger.bus(
            f"Bus shapes loaded from disk cache: {len(index)} routes "
            f"({age_s / 3600:.1f} h old)"
        )
        return index
    except Exception as exc:  # noqa: BLE001 — treat any parse error as miss
        TrackLogger.bus(f"Bus shapes disk cache unreadable, rebuilding: {exc}")
        return None


def _save_disk_cache(index: dict[str, RouteShape]) -> None:
    """Persist the processed index to disk for fast subsequent restarts.

    Args:
        index: The built route index to cache.
    """
    try:
        _DATA_DIR.mkdir(parents=True, exist_ok=True)
        payload = {rid: shape.model_dump() for rid, shape in index.items()}
        _CACHE_PATH.write_text(
            json.dumps(payload, separators=(",", ":")), encoding="utf-8"
        )
        TrackLogger.bus(f"Bus shapes disk cache written: {len(index)} routes")
    except Exception as exc:  # noqa: BLE001 — non-fatal
        TrackLogger.bus(f"Bus shapes disk cache write failed: {exc}")


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def get_bus_open_data_shapes() -> dict[str, RouteShape]:
    """Return the open data route-shape index, fetching and caching as needed.

    On the first call (or after cache expiry) this downloads all current bus
    route shapes from NYS Open Data and builds the index.  Subsequent calls
    within ``_CACHE_MAX_AGE_S`` return from the in-memory index instantly.

    Returns:
        Dict mapping route_id (e.g. ``"B63"``, ``"M15+"``) to a
        :class:`~app.models.RouteShape` with per-direction polylines.
        Returns an empty dict on network failure if no disk cache is available.
    """
    global _index

    if _index is not None:
        return _index

    cached = _load_disk_cache()
    if cached is not None:
        _index = cached
        return _index

    TrackLogger.bus("Fetching MTA Bus Routes from NYS Open Data…")
    try:
        rows = await _fetch_all_rows()
        TrackLogger.bus(f"Fetched {len(rows)} rows from MTA Bus Routes dataset")
    except Exception as exc:  # noqa: BLE001 — degrade gracefully
        TrackLogger.bus(f"MTA Bus Routes fetch failed, falling back to GTFS: {exc}")
        _index = {}
        return _index

    _index = _build_index(rows)
    TrackLogger.bus(f"Bus shapes index built: {len(_index)} routes")
    _save_disk_cache(_index)
    return _index


def invalidate_bus_shapes_cache() -> None:
    """Clear the in-memory index so the next call re-fetches from the API.

    Also removes the disk cache file.  Useful for testing and for forced
    refreshes triggered by a schedule bundle change.
    """
    global _index
    _index = None
    if _CACHE_PATH.exists():
        _CACHE_PATH.unlink(missing_ok=True)
        TrackLogger.bus("Bus shapes cache invalidated")
