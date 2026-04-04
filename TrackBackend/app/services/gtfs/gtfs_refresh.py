"""Automatic GTFS static data refresh.  Detects when the MTA has published
updated GTFS feeds by checking HTTP Last-Modified headers, then:

1. Downloads new .zip files from rrgtfsfeeds.s3.amazonaws.com
2. Extracts into app/data/
3. Rebuilds transit_schedule.db (if bus/schedule feeds changed)
4. Uploads changed archives to Supabase Storage
5. Clears all @lru_cache'd GTFS data so live server uses fresh data

Can be run:
- At server startup  (await check_and_refresh_gtfs())
- Periodically       (background task every 24 hours)
- Manually           (python -m app.services.gtfs.gtfs_refresh)."""

from __future__ import annotations

import asyncio
import contextlib
import csv
import hashlib
import io
import os
import shutil
import sqlite3
import time
import zipfile
from pathlib import Path
from typing import Any

import httpx

from app.utils.logger import TrackLogger

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_DATA_DIR = Path(__file__).resolve().parent.parent.parent / "data"
_META_DIR = _DATA_DIR / ".gtfs_meta"

# MTA GTFS static feed URLs
GTFS_FEEDS: dict[str, dict[str, Any]] = {
    # ---- Feeds that affect shapes / routes / stops (uploaded to Supabase) ----
    "subway": {
        "url": "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip",
        "extract_to": _DATA_DIR / "subway" / "supplemented_GTFS",
        "supabase_archives": ["subway_core", "subway_routes", "subway_supplemented"],
        "rebuilds_db": True,
    },
    "lirr": {
        "url": "https://rrgtfsfeeds.s3.amazonaws.com/gtfslirr.zip",
        "extract_to": _DATA_DIR / "lirr" / "gtfslirr",
        "supabase_archives": ["lirr"],
        "rebuilds_db": True,
    },
    "metro_north": {
        "url": "https://rrgtfsfeeds.s3.amazonaws.com/gtfsmnr.zip",
        "extract_to": _DATA_DIR / "metro_north" / "gtfsmnr",
        "supabase_archives": ["mnr"],
        "rebuilds_db": True,
    },
    # ---- Bus feeds (only used for transit_schedule.db, not Supabase) ----
    "bus_bronx": {
        "url": "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_bx.zip",
        "extract_to": _DATA_DIR / "bus" / "Bronx",
        "supabase_archives": [],
        "rebuilds_db": True,
    },
    "bus_brooklyn": {
        "url": "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_b.zip",
        "extract_to": _DATA_DIR / "bus" / "Brooklyn",
        "supabase_archives": [],
        "rebuilds_db": True,
    },
    "bus_manhattan": {
        "url": "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_m.zip",
        "extract_to": _DATA_DIR / "bus" / "Manhattan",
        "supabase_archives": [],
        "rebuilds_db": True,
    },
    "bus_queens": {
        "url": "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_q.zip",
        "extract_to": _DATA_DIR / "bus" / "Queens",
        "supabase_archives": [],
        "rebuilds_db": True,
    },
    "bus_staten_island": {
        "url": "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_si.zip",
        "extract_to": _DATA_DIR / "bus" / "Staten Island",
        "supabase_archives": [],
        "rebuilds_db": True,
    },
    "bus_mta": {
        "url": "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_busco.zip",
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
# SHA1 tracking — skip re-extract if file content is unchanged
# ---------------------------------------------------------------------------


def _sha1_path(feed_name: str) -> Path:
    return _META_DIR / f"{feed_name}.sha1"


def _read_sha1(feed_name: str) -> str | None:
    p = _sha1_path(feed_name)
    if p.exists():
        return p.read_text().strip()
    return None


def _write_sha1(feed_name: str, value: str) -> None:
    _META_DIR.mkdir(parents=True, exist_ok=True)
    _sha1_path(feed_name).write_text(value)


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

        # SHA1 dedup — skip re-extraction when content is byte-for-byte
        # identical to the last successful download.  S3 can serve unchanged
        # files with a fresh Last-Modified timestamp when bucket ACLs reset.
        content_sha1 = hashlib.sha1(resp.content).hexdigest()
        if content_sha1 == _read_sha1(feed_name):
            TrackLogger.info(
                f"[GTFS] {feed_name}: SHA1 unchanged — skipping extraction",
                tag="GTFS",
            )
            return True

        dest.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
            zf.extractall(dest)

        _write_sha1(feed_name, content_sha1)

        TrackLogger.info(
            f"[GTFS] {feed_name}: {size_mb:.1f} MB downloaded + extracted in {elapsed:.1f}s",
            tag="GTFS",
        )

        # Also copy core subway files to DATA_DIR root for subway_shapes.py
        if feed_name == "subway":
            _copy_subway_root_files(dest)

        return True

    except Exception as exc:
        TrackLogger.error(f"[GTFS] Failed to download {feed_name}: {exc}", tag="GTFS")
        return False


def _copy_subway_root_files(subway_dir: Path) -> None:
    """Copy shapes.txt, trips.txt, stops.txt from supplemented_GTFS to DATA_DIR root.

    subway_shapes.py reads these from the root data dir, not the subway subdir.
    """
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
            "stop_id": "stop_id",
            "stop_name": "stop_name",
            "stop_lat": "stop_lat",
            "stop_lon": "stop_lon",
        },
        "routes": {
            "route_id": "route_id",
            "route_short_name": "route_short_name",
            "route_long_name": "route_long_name",
            "route_color": "route_color",
            "route_type": "route_type",
        },
        "trips": {
            "trip_id": "trip_id",
            "route_id": "route_id",
            "service_id": "service_id",
            "trip_headsign": "trip_headsign",
            "direction_id": "direction_id",
        },
        "stop_times": {
            "trip_id": "trip_id",
            "arrival_time": "arrival_time",
            "departure_time": "departure_time",
            "stop_id": "stop_id",
            "stop_sequence": "stop_sequence",
        },
        "calendar_dates": {
            "service_id": "service_id",
            "date": "date",
            "exception_type": "exception_type",
        },
        "calendar": {
            "service_id": "service_id",
            "monday": "monday",
            "tuesday": "tuesday",
            "wednesday": "wednesday",
            "thursday": "thursday",
            "friday": "friday",
            "saturday": "saturday",
            "sunday": "sunday",
            "start_date": "start_date",
            "end_date": "end_date",
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
        for feed_dir, _label in feed_dirs:
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
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_stop_times_stop ON stop_times(stop_id)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_stop_times_arrival ON stop_times(arrival_time)"
        )
        # Composite index for the "departures from stop X after time T" hot path
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_stop_times_stop_dept "
            "ON stop_times(stop_id, departure_time)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_trips_service ON trips(service_id)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_calendar_date ON calendar_dates(date)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_calendar_service ON calendar(service_id)"
        )
        conn.commit()
        conn.close()

        # Atomic swap
        shutil.move(str(db_tmp), str(db_path))

        # Enable WAL mode on the swapped-in database so concurrent readers
        # and the next rebuild cycle do not block each other.
        with sqlite3.connect(db_path) as wal_conn:
            wal_conn.execute("PRAGMA journal_mode=WAL")
            wal_conn.execute("PRAGMA synchronous=NORMAL")

        # Log the feed date range and warn if the schedule has expired.
        _compute_service_window(db_path)

        # Invalidate the lazy-loaded ServiceCalendar so rt_health.py picks
        # up the new calendar data on its next call.
        with contextlib.suppress(Exception):
            from app.services.gtfs.rt_health import (
                _invalidate_service_calendar,
            )
            _invalidate_service_calendar()

        elapsed = time.monotonic() - t0
        size_mb = db_path.stat().st_size / (1024 * 1024)
        TrackLogger.info(
            f"[GTFS] transit_schedule.db rebuilt: {total_rows:,} rows, "
            f"{size_mb:.0f} MB in {elapsed:.1f}s",
            tag="GTFS",
        )
        return True

    except Exception as exc:
        TrackLogger.error(
            f"[GTFS] Failed to rebuild schedule DB: {exc}", tag="GTFS", exc_info=True
        )
        if db_tmp.exists():
            db_tmp.unlink(missing_ok=True)
        return False


def _compute_service_window(db_path: Path) -> None:
    """Log the valid date range of the freshly rebuilt GTFS schedule.

    Reads ``start_date``/``end_date`` from the ``calendar`` table and
    warns when the data has already expired or starts in the future.
    Mirrors the ``FeedVersionServiceWindowBuilder`` concept from
    transitland-lib's ``stats/fvsw.go``.

    Args:
        db_path: Absolute path to the newly swapped-in transit_schedule.db.
    """
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        row = conn.execute(
            "SELECT MIN(start_date) AS earliest, MAX(end_date) AS latest "
            "FROM calendar"
        ).fetchone()
        conn.close()
    except Exception as exc:  # pragma: no cover
        TrackLogger.warning(
            f"[GTFS] Could not compute service window: {exc}", tag="GTFS"
        )
        return

    if row is None or row[0] is None:
        return

    earliest_str, latest_str = str(row[0]).replace("-", ""), str(row[1]).replace("-", "")
    try:
        from datetime import date

        today = date.today()
        earliest = date(int(earliest_str[:4]), int(earliest_str[4:6]), int(earliest_str[6:]))
        latest = date(int(latest_str[:4]), int(latest_str[4:6]), int(latest_str[6:]))

        if latest < today:
            TrackLogger.warning(
                f"[GTFS] Schedule EXPIRED — valid {earliest} to {latest} "
                f"(today is {today})",
                tag="GTFS",
            )
        elif earliest > today:
            TrackLogger.warning(
                f"[GTFS] Schedule starts in future — valid {earliest} to "
                f"{latest} (today is {today})",
                tag="GTFS",
            )
        else:
            TrackLogger.info(
                f"[GTFS] Schedule window: {earliest} → {latest}",
                tag="GTFS",
            )
    except (ValueError, IndexError) as exc:
        TrackLogger.warning(
            f"[GTFS] Could not parse service window dates: {exc}",
            tag="GTFS",
        )


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
    c.execute("DROP TABLE IF EXISTS calendar")
    c.execute("""CREATE TABLE calendar (
        service_id TEXT PRIMARY KEY,
        monday INTEGER, tuesday INTEGER, wednesday INTEGER,
        thursday INTEGER, friday INTEGER, saturday INTEGER, sunday INTEGER,
        start_date TEXT, end_date TEXT
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

    supabase_key = os.environ.get("SUPABASE_SERVICE_KEY") or os.environ.get(
        "SUPABASE_SERVICE_ROLE_KEY", ""
    )
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

        scripts_dir = Path(__file__).resolve().parent.parent.parent.parent / "scripts"
        sys.path.insert(0, str(scripts_dir))

        # We use a simpler inline approach instead
        import tarfile
        import tempfile

        from app.services.gtfs.data_loader import (
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
            # delay_model is NOT included here — the model is uploaded
            # explicitly via scripts/upload_model.py when retrained, not
            # on every GTFS refresh cycle (which would push whatever stale
            # pkl happens to be on the running server).
        }

        with httpx.Client(
            timeout=httpx.Timeout(connect=10, read=300, write=300, pool=10)
        ) as client:
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
                    TrackLogger.info(
                        f"[GTFS] Uploaded {obj_name} to Supabase", tag="GTFS"
                    )
                else:
                    TrackLogger.warning(
                        f"[GTFS] Supabase upload failed for {obj_name}: "
                        f"HTTP {resp.status_code}",
                        tag="GTFS",
                    )

    except Exception as exc:
        TrackLogger.error(
            f"[GTFS] Supabase upload error: {exc}", tag="GTFS", exc_info=True
        )


# ---------------------------------------------------------------------------
# Clear all GTFS @lru_cache entries
# ---------------------------------------------------------------------------


def _clear_gtfs_caches() -> None:
    """Clear all @lru_cache'd GTFS data so the running server picks up fresh files.

    Uses the central cache registry when available (new tracked_cache decorator),
    then falls back to manually-imported functions for any caches that haven't
    been migrated yet.
    """
    # ── Phase 1: central registry (covers all @tracked_cache functions) ──
    try:
        from app.utils.cache_registry import clear_all_caches

        registry_cleared = clear_all_caches()
    except ImportError:
        registry_cleared = 0

    # ── Phase 2: legacy manual list (safe to double-clear; .cache_clear is idempotent) ──
    from app.services.mapping.rail.shapes import (
        _lirr_routes,
        _lirr_shape_stop_map,
        _lirr_shapes,
        _lirr_stops,
        _lirr_trips,
        _mnr_routes,
        _mnr_shape_stop_map,
        _mnr_shapes,
        _mnr_stops,
        _mnr_trips,
    )
    from app.services.mapping.subway.shapes import (
        _get_stops_for_shape,
        _load_direction_headsigns,
        _load_route_shapes,
        _load_service_types,
        _load_shape_stops,
        _load_shapes,
        _parse_trips,
    )
    from app.services.transit.station_lookup import _load_stops

    caches = [
        _load_shapes,
        _parse_trips,
        _load_route_shapes,
        _load_shape_stops,
        _load_direction_headsigns,
        _get_stops_for_shape,
        _load_service_types,
        _load_stops,
        _lirr_shapes,
        _lirr_routes,
        _lirr_trips,
        _lirr_stops,
        _lirr_shape_stop_map,
        _mnr_shapes,
        _mnr_routes,
        _mnr_trips,
        _mnr_stops,
        _mnr_shape_stop_map,
    ]

    legacy_cleared = 0
    for fn in caches:
        if hasattr(fn, "cache_clear"):
            fn.cache_clear()
            legacy_cleared += 1

    TrackLogger.info(
        f"[GTFS] Cleared caches: {registry_cleared} via registry, "
        f"{legacy_cleared} via legacy imports",
        tag="GTFS",
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


_gtfs_refresh_lock: asyncio.Lock | None = None


def _get_gtfs_refresh_lock() -> asyncio.Lock:
    global _gtfs_refresh_lock
    if _gtfs_refresh_lock is None:
        _gtfs_refresh_lock = asyncio.Lock()
    return _gtfs_refresh_lock


async def check_and_refresh_gtfs(full_check: bool = False) -> dict[str, str]:
    """Check if MTA GTFS feeds have been updated and refresh if needed.

    Args:
        full_check: If True, check all feeds including bus. If False,
                    only check subway/lirr/mnr (faster).

    Returns:
        Dict of {feed_name: status} where status is one of:
        "up-to-date", "updated", "failed", "skipped"
    """
    lock = _get_gtfs_refresh_lock()
    if lock.locked():
        TrackLogger.info(
            "[GTFS] Refresh already in progress — skipping concurrent request",
            tag="GTFS",
        )
        return {"skipped": "refresh-in-progress"}
    async with lock:
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


async def rebuild_schedule_db_if_missing() -> None:
    """Rebuild transit_schedule.db if it is absent — e.g. a fresh Render Disk.

    Called once at startup *after* ``ensure_data_available()`` so that the
    GTFS source files (subway/lirr/mnr) are already on disk before we try
    to ingest them.  Bus GTFS is downloaded separately by the daily refresh;
    the initial build covers subway + commuter rail only.
    """
    db_path = _DATA_DIR / "transit_schedule.db"
    if db_path.exists():
        return  # Already present — Render Disk persisted it from a prior deploy
    TrackLogger.info(
        "[GTFS] transit_schedule.db not found — first-boot rebuild starting "
        "(subway + LIRR + MNR; bus data added on next daily refresh).",
        tag="GTFS",
    )
    import asyncio

    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, _rebuild_schedule_db)


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
        icon = {
            "up-to-date": "✅",
            "updated": "🔄",
            "failed": "❌",
            "skipped": "⏭️",
        }.get(status, "?")
        print(f"  {icon} {name}: {status}")
