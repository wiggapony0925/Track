#
# gtfs_refresh.py
# TrackBackend
#
# Automatic GTFS static data refresh.  Detects when the MTA has published
# updated GTFS feeds by checking HTTP Last-Modified headers, then:
#
#   1. Downloads new .zip files from web.mta.info
#   2. Extracts into app/data/
#   3. Rebuilds transit_schedule.db (if bus/schedule feeds changed)
#   4. Uploads changed archives to Supabase Storage
#   5. Clears all @lru_cache'd GTFS data so live server uses fresh data
#
# Can be run:
#   - At server startup  (await check_and_refresh_gtfs())
#   - Periodically       (background task every 24 hours)
#   - Manually           (python -m app.services.gtfs_refresh)
#

from __future__ import annotations

import csv
import io
import json
import os
import sqlite3
import time
import zipfile
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any

import httpx

from app.utils.logger import TrackLogger

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_META_DIR = _DATA_DIR / ".gtfs_meta"

# MTA GTFS static feed URLs
GTFS_FEEDS: dict[str, dict[str, Any]] = {
    # ---- Feeds that affect shapes / routes / stops (uploaded to Supabase) ----
    "subway": {
        "url": "http://web.mta.info/developers/data/nyct/subway/google_transit.zip",
        "extract_to": _DATA_DIR / "subway" / "supplemented_GTFS",
        "supabase_archives": ["subway_core", "subway_routes", "subway_supplemented"],
        "rebuilds_db": True,
    },
    "lirr": {
        "url": "http://web.mta.info/developers/data/lirr/google_transit.zip",
        "extract_to": _DATA_DIR / "lirr" / "gtfslirr",
        "supabase_archives": ["lirr"],
        "rebuilds_db": True,
    },
    "metro_north": {
        "url": "http://web.mta.info/developers/data/mnr/google_transit.zip",
        "extract_to": _DATA_DIR / "metro_north" / "gtfsmnr",
        "supabase_archives": ["mnr"],
        "rebuilds_db": True,
    },
    # ---- Bus feeds (only used for transit_schedule.db, not Supabase) ----
    "bus_bronx": {
        "url": "http://web.mta.info/developers/data/nyct/bus/google_transit_bronx.zip",
        "extract_to": _DATA_DIR / "bus" / "Bronx",
        "supabase_archives": [],
        "rebuilds_db": True,
    },
    "bus_brooklyn": {
        "url": "http://web.mta.info/developers/data/nyct/bus/google_transit_brooklyn.zip",
        "extract_to": _DATA_DIR / "bus" / "Brooklyn",
        "supabase_archives": [],
        "rebuilds_db": True,
    },
    "bus_manhattan": {
        "url": "http://web.mta.info/developers/data/nyct/bus/google_transit_manhattan.zip",
        "extract_to": _DATA_DIR / "bus" / "Manhattan",
        "supabase_archives": [],
        "rebuilds_db": True,
    },
    "bus_queens": {
        "url": "http://web.mta.info/developers/data/nyct/bus/google_transit_queens.zip",
        "extract_to": _DATA_DIR / "bus" / "Queens",
        "supabase_archives": [],
        "rebuilds_db": True,
    },
    "bus_staten_island": {
        "url": "http://web.mta.info/developers/data/nyct/bus/google_transit_staten_island.zip",
        "extract_to": _DATA_DIR / "bus" / "Staten Island",
        "supabase_archives": [],
        "rebuilds_db": True,
    },
    "bus_mta": {
        "url": "http://web.mta.info/developers/data/busco/google_transit.zip",
        "extract_to": _DATA_DIR / "MTA Bus Company",
        "supabase_archives": [],
        "rebuilds_db": True,
    },
}

# Core feeds to check (skip bus to keep startup fast — bus data rarely
# affects user-facing shapes/routes, only the schedule DB)
QUICK_CHECK_FEEDS = ["subway", "lirr", "metro_north"]


# ---------------------------------------------------------------------------
# Last-Modified tracking
# ---------------------------------------------------------------------------

def _last_modified_path(feed_name: str) -> Path:
    return _META_DIR / f"{feed_name}.last_modified"


def _read_last_modified(feed_name: str) -> str | None:
    p = _last_modified_path(feed_name)
    if p.exists():
        return p.read_text().strip()
    return None


def _write_last_modified(feed_name: str, value: str) -> None:
    _META_DIR.mkdir(parents=True, exist_ok=True)
    _last_modified_path(feed_name).write_text(value)


# ---------------------------------------------------------------------------
# Check for updates (HEAD request only — no download)
# ---------------------------------------------------------------------------

def _check_feed_freshness(
    client: httpx.Client, feed_name: str
) -> tuple[bool, str | None]:
    """Check if a GTFS feed has been updated since we last downloaded it.

    Returns (needs_update: bool, new_last_modified: str | None).
    """
    feed = GTFS_FEEDS[feed_name]
    url = feed["url"]
    saved = _read_last_modified(feed_name)

    try:
        resp = client.head(url, follow_redirects=True, timeout=15)
        remote_lm = resp.headers.get("Last-Modified", "")

        if not remote_lm:
            # No Last-Modified header — can't tell, assume stale if never downloaded
            return (saved is None, None)

        if saved and saved == remote_lm:
            return (False, remote_lm)

        return (True, remote_lm)

    except Exception as exc:
        TrackLogger.warning(
            f"[GTFS] Could not check {feed_name}: {type(exc).__name__}",
            tag="GTFS",
        )
        return (False, None)


# ---------------------------------------------------------------------------
# Download + extract a single feed
# ---------------------------------------------------------------------------

def _download_feed(client: httpx.Client, feed_name: str) -> bool:
    """Download and extract a single GTFS zip feed.  Returns True on success."""
    feed = GTFS_FEEDS[feed_name]
    url = feed["url"]
    dest = feed["extract_to"]

    try:
        TrackLogger.info(f"[GTFS] Downloading {feed_name} from {url}...", tag="GTFS")
        t0 = time.monotonic()
        resp = client.get(url, follow_redirects=True, timeout=120)
        resp.raise_for_status()

        elapsed = time.monotonic() - t0
        size_mb = len(resp.content) / (1024 * 1024)

        dest.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
            zf.extractall(dest)

        TrackLogger.info(
            f"[GTFS] {feed_name}: {size_mb:.1f} MB downloaded + extracted in {elapsed:.1f}s",
            tag="GTFS",
        )

        # Also copy core subway files to DATA_DIR root for subway_shapes.py
        if feed_name == "subway":
            _copy_subway_root_files(dest)

        return True

    except Exception as exc:
        TrackLogger.error(
            f"[GTFS] Failed to download {feed_name}: {exc}", tag="GTFS"
        )
        return False


def _copy_subway_root_files(subway_dir: Path) -> None:
    """Copy shapes.txt, trips.txt, stops.txt from supplemented_GTFS to DATA_DIR root.

    subway_shapes.py reads these from the root data dir, not the subway subdir.
    """
    import shutil
    for fname in ("shapes.txt", "trips.txt", "stops.txt"):
        src = subway_dir / fname
        dst = _DATA_DIR / fname
        if src.exists():
            shutil.copy2(src, dst)


# ---------------------------------------------------------------------------
# Rebuild transit_schedule.db
# ---------------------------------------------------------------------------

def _rebuild_schedule_db() -> bool:
    """Rebuild the SQLite schedule database from extracted GTFS files.

    This is an inlined version of scripts/ingest_gtfs.py that runs
    in-process so we don't need to shell out.
    """
    db_path = _DATA_DIR / "transit_schedule.db"
    db_tmp = _DATA_DIR / "transit_schedule.db.tmp"

    TABLE_MAPPINGS = {
        "stops": {
            "stop_id": "stop_id", "stop_name": "stop_name",
            "stop_lat": "stop_lat", "stop_lon": "stop_lon",
        },
        "routes": {
            "route_id": "route_id", "route_short_name": "route_short_name",
            "route_long_name": "route_long_name", "route_color": "route_color",
            "route_type": "route_type",
        },
        "trips": {
            "trip_id": "trip_id", "route_id": "route_id",
            "service_id": "service_id", "trip_headsign": "trip_headsign",
            "direction_id": "direction_id",
        },
        "stop_times": {
            "trip_id": "trip_id", "arrival_time": "arrival_time",
            "departure_time": "departure_time", "stop_id": "stop_id",
            "stop_sequence": "stop_sequence",
        },
        "calendar_dates": {
            "service_id": "service_id", "date": "date",
            "exception_type": "exception_type",
        },
    }

    try:
        TrackLogger.info("[GTFS] Rebuilding transit_schedule.db...", tag="GTFS")
        t0 = time.monotonic()

        # Build into a temp file, then atomic-swap
        if db_tmp.exists():
            db_tmp.unlink()

        conn = sqlite3.connect(db_tmp)
        conn.execute("PRAGMA synchronous = OFF")
        conn.execute("PRAGMA journal_mode = MEMORY")

        # Create schema
        _create_db_schema(conn)

        # Ingest each GTFS directory
        feed_dirs = [
            (_DATA_DIR / "subway" / "supplemented_GTFS", "subway"),
            (_DATA_DIR / "lirr" / "gtfslirr", "lirr"),
            (_DATA_DIR / "metro_north" / "gtfsmnr", "mnr"),
            (_DATA_DIR / "bus" / "Bronx", "bus-bronx"),
            (_DATA_DIR / "bus" / "Brooklyn", "bus-brooklyn"),
            (_DATA_DIR / "bus" / "Manhattan", "bus-manhattan"),
            (_DATA_DIR / "bus" / "Queens", "bus-queens"),
            (_DATA_DIR / "bus" / "Staten Island", "bus-si"),
            (_DATA_DIR / "MTA Bus Company", "bus-mta"),
        ]

        total_rows = 0
        for feed_dir, label in feed_dirs:
            if not feed_dir.exists():
                continue
            for table_name, mapping in TABLE_MAPPINGS.items():
                csv_path = feed_dir / f"{table_name}.txt"
                if table_name == "stop_times":
                    csv_path = feed_dir / "stop_times.txt"
                elif table_name == "calendar_dates":
                    csv_path = feed_dir / "calendar_dates.txt"
                else:
                    csv_path = feed_dir / f"{table_name}.txt"

                rows = _ingest_csv(conn, csv_path, table_name, mapping)
                total_rows += rows

        # Create indices
        conn.execute("CREATE INDEX IF NOT EXISTS idx_stop_times_stop ON stop_times(stop_id)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_stop_times_arrival ON stop_times(arrival_time)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_trips_service ON trips(service_id)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_calendar_date ON calendar_dates(date)")
        conn.commit()
        conn.close()

        # Atomic swap
        import shutil
        shutil.move(str(db_tmp), str(db_path))

        elapsed = time.monotonic() - t0
        size_mb = db_path.stat().st_size / (1024 * 1024)
        TrackLogger.info(
            f"[GTFS] transit_schedule.db rebuilt: {total_rows:,} rows, "
            f"{size_mb:.0f} MB in {elapsed:.1f}s",
            tag="GTFS",
        )
        return True

    except Exception as exc:
        TrackLogger.error(f"[GTFS] Failed to rebuild schedule DB: {exc}", tag="GTFS")
        if db_tmp.exists():
            db_tmp.unlink(missing_ok=True)
        return False


def _create_db_schema(conn: sqlite3.Connection) -> None:
    c = conn.cursor()
    c.execute("DROP TABLE IF EXISTS stops")
    c.execute("""CREATE TABLE stops (
        stop_id TEXT PRIMARY KEY, stop_name TEXT, stop_lat REAL, stop_lon REAL
    )""")
    c.execute("DROP TABLE IF EXISTS routes")
    c.execute("""CREATE TABLE routes (
        route_id TEXT PRIMARY KEY, route_short_name TEXT,
        route_long_name TEXT, route_color TEXT, route_type INTEGER
    )""")
    c.execute("DROP TABLE IF EXISTS trips")
    c.execute("""CREATE TABLE trips (
        trip_id TEXT PRIMARY KEY, route_id TEXT, service_id TEXT,
        trip_headsign TEXT, direction_id INTEGER
    )""")
    c.execute("DROP TABLE IF EXISTS stop_times")
    c.execute("""CREATE TABLE stop_times (
        trip_id TEXT, arrival_time TEXT, departure_time TEXT,
        stop_id TEXT, stop_sequence INTEGER
    )""")
    c.execute("DROP TABLE IF EXISTS calendar_dates")
    c.execute("""CREATE TABLE calendar_dates (
        service_id TEXT, date TEXT, exception_type INTEGER
    )""")
    conn.commit()


def _ingest_csv(
    conn: sqlite3.Connection,
    csv_path: Path,
    table_name: str,
    mapping: dict[str, str],
) -> int:
    """Ingest a single CSV file into a table.  Returns row count."""
    if not csv_path.exists():
        return 0

    columns = ", ".join(mapping.keys())
    placeholders = ", ".join(["?"] * len(mapping))
    sql = f"INSERT OR REPLACE INTO {table_name} ({columns}) VALUES ({placeholders})"

    cursor = conn.cursor()
    count = 0
    batch: list[tuple] = []

    with open(csv_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            vals = tuple(row.get(csv_col, "").strip() for csv_col in mapping.values())
            batch.append(vals)
            if len(batch) >= 10_000:
                cursor.executemany(sql, batch)
                count += len(batch)
                batch = []

        if batch:
            cursor.executemany(sql, batch)
            count += len(batch)

    conn.commit()
    return count


# ---------------------------------------------------------------------------
# Upload changed archives to Supabase
# ---------------------------------------------------------------------------

def _upload_to_supabase(archive_names: set[str]) -> None:
    """Upload specific archives to Supabase Storage after a data refresh."""
    if not archive_names:
        return

    supabase_key = os.environ.get("SUPABASE_SERVICE_KEY", "")
    if not supabase_key:
        TrackLogger.warning(
            "[GTFS] SUPABASE_SERVICE_KEY not set — skipping Supabase upload. "
            "Data is updated locally but won't be available on next cold start.",
            tag="GTFS",
        )
        return

    try:
        # Import from the upload script
        import sys
        scripts_dir = Path(__file__).resolve().parent.parent.parent / "scripts"
        sys.path.insert(0, str(scripts_dir))

        # We use a simpler inline approach instead
        import tarfile
        import tempfile

        from app.services.data_loader import (
            BUCKET_NAME,
            SUPABASE_URL,
            _auth_headers,
        )

        # Archive definitions (subset from upload_gtfs_to_supabase.py)
        ARCHIVE_DEFS: dict[str, list[tuple[str, str | None]]] = {
            "subway_core": [
                ("shapes.txt", "shapes.txt"),
                ("trips.txt", "trips.txt"),
                ("stops.txt", "stops.txt"),
                ("shape_stops.json", "shape_stops.json"),
            ],
            "subway_routes": [
                ("subway/regular_GTFS/routes.txt", "routes.txt"),
            ],
            "subway_supplemented": [
                ("subway/supplemented_GTFS", None),
            ],
            "lirr": [
                ("lirr/gtfslirr", None),
            ],
            "mnr": [
                ("metro_north/gtfsmnr", None),
            ],
        }

        with httpx.Client(timeout=httpx.Timeout(connect=10, read=300, write=300, pool=10)) as client:
            for name in archive_names:
                members = ARCHIVE_DEFS.get(name)
                if not members:
                    continue

                # Build tar.gz
                with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp:
                    tmp_path = tmp.name

                with tarfile.open(tmp_path, "w:gz", compresslevel=6) as tar:
                    for local_rel, arcname in members:
                        full = _DATA_DIR / local_rel
                        if not full.exists():
                            continue
                        if full.is_dir():
                            for child in sorted(full.rglob("*")):
                                if child.is_file():
                                    arc = str(child.relative_to(full))
                                    tar.add(str(child), arcname=arc)
                        else:
                            tar.add(str(full), arcname=arcname or local_rel)

                # Upload
                obj_name = f"{name}.tar.gz"
                url = f"{SUPABASE_URL.rstrip('/')}/storage/v1/object/{BUCKET_NAME}/{obj_name}"
                headers = _auth_headers()
                headers["Content-Type"] = "application/gzip"
                headers["x-upsert"] = "true"

                with open(tmp_path, "rb") as f:
                    resp = client.post(url, headers=headers, content=f.read())

                os.unlink(tmp_path)

                if resp.status_code in (200, 201):
                    TrackLogger.info(f"[GTFS] Uploaded {obj_name} to Supabase", tag="GTFS")
                else:
                    TrackLogger.warning(
                        f"[GTFS] Supabase upload failed for {obj_name}: "
                        f"HTTP {resp.status_code}",
                        tag="GTFS",
                    )

    except Exception as exc:
        TrackLogger.error(f"[GTFS] Supabase upload error: {exc}", tag="GTFS")


# ---------------------------------------------------------------------------
# Clear all GTFS @lru_cache entries
# ---------------------------------------------------------------------------

def _clear_gtfs_caches() -> None:
    """Clear all @lru_cache'd GTFS data so the running server picks up fresh files."""
    from app.services.subway_shapes import (
        _load_shapes,
        _parse_trips,
        _load_route_shapes,
        _load_shape_stops,
        _load_direction_headsigns,
        _get_stops_for_shape,
        _load_service_types,
    )
    from app.services.station_lookup import _load_stops
    from app.services.commuter_rail_shapes import (
        _lirr_shapes, _lirr_routes, _lirr_trips,
        _mnr_shapes, _mnr_routes, _mnr_trips,
    )
    from app.services.gtfs_parser import _get_shape_to_route_map

    caches = [
        _load_shapes, _parse_trips, _load_route_shapes,
        _load_shape_stops, _load_direction_headsigns,
        _get_stops_for_shape, _load_service_types,
        _load_stops,
        _lirr_shapes, _lirr_routes, _lirr_trips,
        _mnr_shapes, _mnr_routes, _mnr_trips,
        _get_shape_to_route_map,
    ]

    cleared = 0
    for fn in caches:
        if hasattr(fn, "cache_clear"):
            fn.cache_clear()
            cleared += 1

    TrackLogger.info(f"[GTFS] Cleared {cleared} cached data functions", tag="GTFS")


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

async def check_and_refresh_gtfs(full_check: bool = False) -> dict[str, str]:
    """Check if MTA GTFS feeds have been updated and refresh if needed.

    Args:
        full_check: If True, check all feeds including bus. If False,
                    only check subway/lirr/mnr (faster).

    Returns:
        Dict of {feed_name: status} where status is one of:
        "up-to-date", "updated", "failed", "skipped"
    """
    import asyncio
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, _sync_check_and_refresh, full_check)


def _sync_check_and_refresh(full_check: bool) -> dict[str, str]:
    """Synchronous implementation of the GTFS refresh check."""
    feeds_to_check = list(GTFS_FEEDS.keys()) if full_check else QUICK_CHECK_FEEDS
    results: dict[str, str] = {}
    updated_feeds: list[str] = []
    supabase_archives: set[str] = set()
    needs_db_rebuild = False

    TrackLogger.info(
        f"[GTFS] Checking {len(feeds_to_check)} feeds for updates...",
        tag="GTFS",
    )
    t0 = time.monotonic()

    with httpx.Client(follow_redirects=True) as client:
        # Phase 1: Check freshness
        stale: list[tuple[str, str | None]] = []
        for name in feeds_to_check:
            needs_update, new_lm = _check_feed_freshness(client, name)
            if needs_update:
                stale.append((name, new_lm))
            else:
                results[name] = "up-to-date"

        if not stale:
            elapsed = time.monotonic() - t0
            TrackLogger.info(
                f"[GTFS] All {len(feeds_to_check)} feeds up-to-date ({elapsed:.1f}s)",
                tag="GTFS",
            )
            return results

        TrackLogger.info(
            f"[GTFS] {len(stale)} feed(s) need updating: "
            f"{', '.join(n for n, _ in stale)}",
            tag="GTFS",
        )

        # Phase 2: Download updated feeds
        for name, new_lm in stale:
            ok = _download_feed(client, name)
            if ok:
                results[name] = "updated"
                updated_feeds.append(name)
                if new_lm:
                    _write_last_modified(name, new_lm)

                feed = GTFS_FEEDS[name]
                supabase_archives.update(feed["supabase_archives"])
                if feed["rebuilds_db"]:
                    needs_db_rebuild = True
            else:
                results[name] = "failed"

    # Phase 3: Rebuild schedule DB if any feed that affects it was updated
    if needs_db_rebuild:
        _rebuild_schedule_db()

    # Phase 4: Upload changed archives to Supabase
    if supabase_archives:
        _upload_to_supabase(supabase_archives)

    # Phase 5: Clear in-memory caches so server uses fresh data
    if updated_feeds:
        _clear_gtfs_caches()

    elapsed = time.monotonic() - t0
    updated_list = [n for n, s in results.items() if s == "updated"]
    TrackLogger.info(
        f"[GTFS] Refresh complete in {elapsed:.1f}s — "
        f"{len(updated_list)} updated: {', '.join(updated_list) or 'none'}",
        tag="GTFS",
    )

    return results


def get_gtfs_freshness() -> dict[str, dict[str, str | None]]:
    """Return the last-known update timestamp for each feed.

    Useful for the /data/status endpoint.
    """
    return {
        name: {
            "last_modified": _read_last_modified(name),
            "url": feed["url"],
        }
        for name, feed in GTFS_FEEDS.items()
    }


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import asyncio
    import sys

    full = "--full" in sys.argv
    print(f"Checking GTFS feeds ({'all' if full else 'subway/lirr/mnr'})...\n")

    results = asyncio.run(check_and_refresh_gtfs(full_check=full))
    for name, status in results.items():
        icon = {"up-to-date": "✅", "updated": "🔄", "failed": "❌", "skipped": "⏭️"}.get(status, "?")
        print(f"  {icon} {name}: {status}")
