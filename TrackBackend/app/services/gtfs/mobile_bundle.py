"""Mobile GTFS bundle builder.

Derives a slim, content-addressed SQLite from the canonical
``app/data/transit_schedule.db`` (1.4 GB, server-side) so the iOS client
can ship a small queryable database for offline drag-search.

Output schema (read-only on iOS):
    stops            (stop_id, stop_name, stop_lat, stop_lon, parent_station, mode)
    stops_rtree      R*Tree spatial index keyed by stop_id_rowid
    stops_id_map     (rowid INTEGER PRIMARY KEY, stop_id TEXT UNIQUE)
    routes           (route_id, short_name, long_name, color, mode, agency_id)
    route_stops      (route_id, stop_id, direction_id)  ← which routes serve each stop
    metadata         (key TEXT PRIMARY KEY, value TEXT)

The bundle is written to ``app/static/gtfs/nyc-{sha8}.sqlite`` and the
sidecar manifest at ``app/static/gtfs/manifest.json`` describes the
catalog so iOS can fetch the right file.

Design constraints:
    • No schedule rows — drag-search only needs "what serves here", not
      "when".  Schedule fallback is a Phase D concern and lives in a
      separate stop_times bundle.
    • Read-only SQLite — iOS opens it via GRDB or sqlite3 directly.
    • Content-addressed filename — flipping the manifest is the deploy
      mechanism; old bundles can stay on disk for in-flight downloads.
    • Reuses existing ``transit_schedule.db`` instead of re-parsing GTFS
      zips.  Single source of truth.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sqlite3
import sys
import time
from pathlib import Path

from app.utils.logger import TrackLogger

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
_SOURCE_DB = _BACKEND_ROOT / "data" / "transit_schedule.db"
_BUNDLE_DIR = _BACKEND_ROOT / "static" / "gtfs"
_MANIFEST_PATH = _BUNDLE_DIR / "manifest.json"

REGION_ID = "nyc"
# v2 = adds route_headways table for offline scheduled-arrival fallback
SCHEMA_VERSION = 2


# ---------------------------------------------------------------------------
# Mode classification — derived from GTFS route_type and route_id prefixes
# ---------------------------------------------------------------------------
# https://gtfs.org/schedule/reference/#routestxt route_type values
#   0 tram, 1 subway, 2 rail, 3 bus, 4 ferry, ...

_MODE_BY_ROUTE_TYPE: dict[int, str] = {
    0: "subway",  # MTA tags streetcar-ish lines as 0 occasionally
    1: "subway",
    2: "rail",  # narrowed below to lirr / mnr by route_id prefix
    3: "bus",
    4: "ferry",
}


def _classify_mode(route_id: str, route_type: int | None) -> str:
    """Coalesce route_type + route_id heuristics into Track's modes."""
    rid = (route_id or "").upper()
    base = _MODE_BY_ROUTE_TYPE.get(route_type or -1, "bus")
    if base == "rail":
        if rid.startswith("LIRR") or rid.startswith("LI_"):
            return "lirr"
        if rid.startswith("MNR") or rid.startswith("MN_"):
            return "mnr"
        return "rail"
    return base


# ---------------------------------------------------------------------------
# Bundle build
# ---------------------------------------------------------------------------


def _ensure_dirs() -> None:
    _BUNDLE_DIR.mkdir(parents=True, exist_ok=True)


def _open_source(db_path: Path) -> sqlite3.Connection:
    if not db_path.exists():
        raise FileNotFoundError(
            f"Source GTFS DB not found: {db_path}.  "
            f"Run scripts/ingest_gtfs.py first."
        )
    src = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    src.row_factory = sqlite3.Row
    return src


def _init_target(target: Path) -> sqlite3.Connection:
    if target.exists():
        target.unlink()
    db = sqlite3.connect(target)
    db.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        PRAGMA temp_store = MEMORY;
        PRAGMA page_size = 4096;

        CREATE TABLE stops (
            stop_id        TEXT PRIMARY KEY,
            stop_name      TEXT NOT NULL,
            stop_lat       REAL NOT NULL,
            stop_lon       REAL NOT NULL,
            parent_station TEXT,
            mode           TEXT NOT NULL DEFAULT 'bus'
        );

        CREATE TABLE stops_id_map (
            rowid   INTEGER PRIMARY KEY,
            stop_id TEXT NOT NULL UNIQUE
        );

        -- R*Tree spatial index: query is
        --   SELECT rowid FROM stops_rtree WHERE min_lat<? AND max_lat>?
        --                                   AND min_lon<? AND max_lon>?;
        CREATE VIRTUAL TABLE stops_rtree USING rtree(
            id,
            min_lat, max_lat,
            min_lon, max_lon
        );

        CREATE TABLE routes (
            route_id        TEXT PRIMARY KEY,
            short_name      TEXT,
            long_name       TEXT,
            color           TEXT,
            mode            TEXT NOT NULL DEFAULT 'bus',
            agency_id       TEXT
        );

        CREATE TABLE route_stops (
            route_id     TEXT NOT NULL,
            stop_id      TEXT NOT NULL,
            direction_id INTEGER,
            PRIMARY KEY (route_id, stop_id, direction_id)
        );
        CREATE INDEX idx_route_stops_stop ON route_stops(stop_id);

        -- Per-route trip counts bucketed by day-type and hour-of-day.
        -- Powers Phase-D offline fallback: when the network or live
        -- GTFS-RT feeds are unavailable, the iOS client estimates the
        -- next arrival as headway/2 minutes from this table.
        --   day_type: 0 = weekday, 1 = saturday, 2 = sunday
        --   hour:     0..23 (departure hour, modulo 24 for 24h+ rollover)
        --   trips:    distinct trip departures starting in that hour
        CREATE TABLE route_headways (
            route_id TEXT    NOT NULL,
            day_type INTEGER NOT NULL,
            hour     INTEGER NOT NULL,
            trips    INTEGER NOT NULL,
            PRIMARY KEY (route_id, day_type, hour)
        );

        CREATE TABLE metadata (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
    )
    return db


def _copy_stops(src: sqlite3.Connection, dst: sqlite3.Connection) -> int:
    """Copy stops + populate R*Tree.  Falls back to all-bus if mode unknown."""
    stop_route_modes: dict[str, str] = {}
    for row in src.execute(
        """
        SELECT DISTINCT rs.stop_id, r.route_type, r.route_id
        FROM stop_times rs
        JOIN trips t  ON t.trip_id  = rs.trip_id
        JOIN routes r ON r.route_id = t.route_id
        """
    ):
        stop_id = row["stop_id"]
        if stop_id in stop_route_modes:
            continue
        stop_route_modes[stop_id] = _classify_mode(row["route_id"], row["route_type"])

    cur = dst.cursor()
    cur.execute("BEGIN")
    inserted = 0
    rtree_rows: list[tuple[int, float, float, float, float]] = []
    id_map_rows: list[tuple[int, str]] = []
    for rowid, row in enumerate(
        src.execute("SELECT stop_id, stop_name, stop_lat, stop_lon FROM stops"),
        start=1,
    ):
        stop_id = row["stop_id"]
        lat = row["stop_lat"]
        lon = row["stop_lon"]
        if lat is None or lon is None:
            continue
        cur.execute(
            "INSERT INTO stops(stop_id, stop_name, stop_lat, stop_lon, parent_station, mode) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (
                stop_id,
                row["stop_name"] or stop_id,
                float(lat),
                float(lon),
                None,
                stop_route_modes.get(stop_id, "bus"),
            ),
        )
        id_map_rows.append((rowid, stop_id))
        rtree_rows.append((rowid, float(lat), float(lat), float(lon), float(lon)))
        inserted += 1

    cur.executemany(
        "INSERT INTO stops_id_map(rowid, stop_id) VALUES (?, ?)", id_map_rows
    )
    cur.executemany(
        "INSERT INTO stops_rtree(id, min_lat, max_lat, min_lon, max_lon) "
        "VALUES (?, ?, ?, ?, ?)",
        rtree_rows,
    )
    dst.commit()
    return inserted


def _copy_routes(src: sqlite3.Connection, dst: sqlite3.Connection) -> int:
    cur = dst.cursor()
    cur.execute("BEGIN")
    inserted = 0
    for row in src.execute(
        "SELECT route_id, route_short_name, route_long_name, route_color, route_type "
        "FROM routes"
    ):
        rid = row["route_id"]
        cur.execute(
            "INSERT OR REPLACE INTO routes(route_id, short_name, long_name, color, mode, agency_id) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (
                rid,
                row["route_short_name"],
                row["route_long_name"],
                row["route_color"],
                _classify_mode(rid, row["route_type"]),
                None,
            ),
        )
        inserted += 1
    dst.commit()
    return inserted


def _build_route_stops(src: sqlite3.Connection, dst: sqlite3.Connection) -> int:
    """Build the (route_id, stop_id, direction_id) mapping by joining
    stop_times → trips → routes once."""
    cur = dst.cursor()
    cur.execute("BEGIN")
    inserted = 0
    for row in src.execute(
        """
        SELECT DISTINCT t.route_id, st.stop_id, COALESCE(t.direction_id, 0) AS direction_id
        FROM stop_times st
        JOIN trips t ON t.trip_id = st.trip_id
        """
    ):
        cur.execute(
            "INSERT OR IGNORE INTO route_stops(route_id, stop_id, direction_id) "
            "VALUES (?, ?, ?)",
            (row["route_id"], row["stop_id"], row["direction_id"]),
        )
        inserted += cur.rowcount
    dst.commit()
    return inserted


def _build_route_headways(src: sqlite3.Connection, dst: sqlite3.Connection) -> int:
    """Aggregate (route_id, day_type, hour) → trip count.

    Day-type encoding mirrors the iOS-side ``LocalGTFSBundle.dayType``:
    0 = weekday (any of Mon-Fri), 1 = Saturday, 2 = Sunday.  Some
    services run multiple day-types; we emit one row per (service, dt)
    pair.  Hour is the trip's *first* departure hour modulo 24, so a
    trip starting "25:30" rolls into hour 1.

    Performance: streams stop_times once (~7M rows in ~4s on a M-series
    Mac), keeping a per-trip "earliest seen so far" dict.  Avoids the
    correlated-subquery MIN() that takes >5 minutes to plan.
    """
    # 1. Service-id → list of day_types served.
    svc_days: dict[str, list[int]] = {}
    for row in src.execute("SELECT * FROM calendar"):
        days: list[int] = []
        if any(
            row[d] for d in ("monday", "tuesday", "wednesday", "thursday", "friday")
        ):
            days.append(0)
        if row["saturday"]:
            days.append(1)
        if row["sunday"]:
            days.append(2)
        if days:
            svc_days[row["service_id"]] = days

    # 2. Trip-id → (route_id, service_id).
    trips: dict[str, tuple[str, str]] = {
        row["trip_id"]: (row["route_id"], row["service_id"])
        for row in src.execute("SELECT trip_id, route_id, service_id FROM trips")
    }

    # 3. Trip-id → earliest (departure_time, stop_sequence).  Streamed.
    trip_first: dict[str, tuple[str, int]] = {}
    for trip_id, dep, seq in src.execute(
        "SELECT trip_id, departure_time, stop_sequence FROM stop_times"
    ):
        if not dep:
            continue
        cur = trip_first.get(trip_id)
        if cur is None or seq < cur[1]:
            trip_first[trip_id] = (dep, seq)

    # 4. Aggregate buckets.
    from collections import defaultdict

    buckets: dict[tuple[str, int, int], int] = defaultdict(int)
    for trip_id, (dep, _) in trip_first.items():
        meta = trips.get(trip_id)
        if not meta:
            continue
        route_id, service_id = meta
        days = svc_days.get(service_id)
        if not days:
            continue
        try:
            hour = int(dep.split(":", 1)[0]) % 24
        except (ValueError, IndexError):
            continue
        for dt in days:
            buckets[(route_id, dt, hour)] += 1

    cur = dst.cursor()
    cur.execute("BEGIN")
    cur.executemany(
        "INSERT OR REPLACE INTO route_headways(route_id, day_type, hour, trips) "
        "VALUES (?, ?, ?, ?)",
        [(rid, dt, h, n) for (rid, dt, h), n in buckets.items()],
    )
    dst.commit()
    return len(buckets)


def _source_active_route_ids(src: sqlite3.Connection) -> set[str]:
    """Routes with at least one scheduled stop in the source GTFS DB.

    This is the inventory that must flow into the mobile bundle.  If MTA
    adds a new route (for example a future D/X variant) or removes one, this
    query changes automatically after GTFS ingest; no app code should need a
    hardcoded route list update.
    """
    return {
        row["route_id"]
        for row in src.execute(
            """
            SELECT DISTINCT t.route_id
              FROM trips t
              JOIN stop_times st ON st.trip_id = t.trip_id
             WHERE t.route_id IS NOT NULL AND t.route_id != ''
            """
        )
    }


def _route_inventory_hash(route_ids: set[str]) -> str:
    payload = "\n".join(sorted(route_ids)).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _validate_route_inventory(
    src: sqlite3.Connection,
    dst: sqlite3.Connection,
) -> tuple[int, str]:
    """Fail the bundle build if active GTFS routes did not make it to iOS.

    The mobile bundle powers offline nearby, drag search, and local route
    details.  A missing route here means the app can silently lose a train or
    branch until a human notices.  Raise during refresh instead, so the deploy
    pipeline catches the drift immediately.
    """
    active_routes = _source_active_route_ids(src)
    bundled_routes = {row[0] for row in dst.execute("SELECT route_id FROM routes")}
    served_routes = {
        row[0] for row in dst.execute("SELECT DISTINCT route_id FROM route_stops")
    }

    missing_routes = sorted(active_routes - bundled_routes)
    missing_service = sorted(active_routes - served_routes)
    dangling_service = sorted(served_routes - bundled_routes)

    errors: list[str] = []
    if missing_routes:
        errors.append("missing routes table entries: " + ", ".join(missing_routes[:20]))
    if missing_service:
        errors.append("missing route_stops entries: " + ", ".join(missing_service[:20]))
    if dangling_service:
        errors.append("route_stops without routes: " + ", ".join(dangling_service[:20]))
    if errors:
        raise RuntimeError("Mobile GTFS route inventory mismatch — " + "; ".join(errors))

    return len(active_routes), _route_inventory_hash(active_routes)


def _write_metadata(dst: sqlite3.Connection, **values: str) -> None:
    cur = dst.cursor()
    cur.execute("BEGIN")
    for key, value in values.items():
        cur.execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)",
            (key, str(value)),
        )
    dst.commit()


def _finalize(dst: sqlite3.Connection) -> None:
    """Vacuum + analyze + reset PRAGMAs to safe defaults."""
    dst.execute("ANALYZE")
    dst.execute("PRAGMA journal_mode = DELETE")
    dst.execute("PRAGMA synchronous = NORMAL")
    dst.commit()
    dst.execute("VACUUM")
    dst.commit()


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_bundle(
    source_db: Path = _SOURCE_DB,
    bundle_dir: Path = _BUNDLE_DIR,
    region_id: str = REGION_ID,
) -> dict:
    """Build a fresh mobile bundle and update the manifest.

    Returns the manifest entry for the bundle just produced.
    """
    _ensure_dirs()
    bundle_dir.mkdir(parents=True, exist_ok=True)
    workfile = bundle_dir / f"{region_id}-WIP.sqlite"

    TrackLogger.info(
        f"[GTFS-BUNDLE] Building from {source_db} → {workfile}",
        tag="GTFS",
    )

    started = time.time()
    src = _open_source(source_db)
    dst = _init_target(workfile)

    try:
        stops_n = _copy_stops(src, dst)
        routes_n = _copy_routes(src, dst)
        rs_n = _build_route_stops(src, dst)
        hw_n = _build_route_headways(src, dst)
        active_routes_n, route_inventory_sha = _validate_route_inventory(src, dst)

        _write_metadata(
            dst,
            schema_version=str(SCHEMA_VERSION),
            region_id=region_id,
            generated_at=str(int(started)),
            source_db=str(source_db.name),
            stops_count=str(stops_n),
            routes_count=str(routes_n),
            active_routes_count=str(active_routes_n),
            route_inventory_sha256=route_inventory_sha,
            route_stops_count=str(rs_n),
            route_headways_count=str(hw_n),
        )
        _finalize(dst)
    finally:
        dst.close()
        src.close()

    sha = _sha256_file(workfile)
    sha8 = sha[:8]
    final = bundle_dir / f"{region_id}-{sha8}.sqlite"
    workfile.replace(final)
    size = final.stat().st_size

    entry = {
        "region_id": region_id,
        "schema_version": SCHEMA_VERSION,
        "sha256": sha,
        "filename": final.name,
        "url": f"/static/gtfs/{final.name}",
        "size_bytes": size,
        "stops_count": stops_n,
        "routes_count": routes_n,
        "active_routes_count": active_routes_n,
        "route_inventory_sha256": route_inventory_sha,
        "route_stops_count": rs_n,
        "route_headways_count": hw_n,
        "generated_at": int(started),
    }

    _update_manifest(bundle_dir, entry)

    TrackLogger.info(
        f"[GTFS-BUNDLE] ✓ {final.name} | "
        f"{size / (1024 * 1024):.1f} MB | "
        f"stops={stops_n} routes={routes_n} active_routes={active_routes_n} "
        f"route_stops={rs_n} headways={hw_n} | "
        f"build={time.time() - started:.1f}s",
        tag="GTFS",
    )

    _prune_old_bundles(bundle_dir, keep=final, region_id=region_id)
    return entry


def _update_manifest(bundle_dir: Path, entry: dict) -> None:
    """Write the manifest atomically, replacing any older entry for the
    same ``region_id``."""
    manifest = read_manifest(bundle_dir)
    regions: dict[str, dict] = {r["region_id"]: r for r in manifest.get("regions", [])}
    regions[entry["region_id"]] = entry
    manifest["regions"] = sorted(regions.values(), key=lambda r: r["region_id"])
    manifest["catalog_version"] = manifest.get("catalog_version", 0) + 1
    manifest["updated_at"] = int(time.time())

    tmp = bundle_dir / "manifest.json.tmp"
    tmp.write_text(json.dumps(manifest, indent=2))
    tmp.replace(bundle_dir / "manifest.json")


def _prune_old_bundles(bundle_dir: Path, keep: Path, region_id: str) -> None:
    """Delete any older bundles for this region — manifest only points at
    one sha at a time so older files just waste disk."""
    pattern = f"{region_id}-*.sqlite"
    for p in bundle_dir.glob(pattern):
        if p == keep:
            continue
        try:
            p.unlink()
            TrackLogger.info(
                f"[GTFS-BUNDLE] pruned old bundle {p.name}", tag="GTFS"
            )
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Manifest reader (used by the router too)
# ---------------------------------------------------------------------------


def read_manifest(bundle_dir: Path = _BUNDLE_DIR) -> dict:
    """Load the manifest JSON, returning an empty manifest if absent."""
    if not _MANIFEST_PATH.exists():
        return {"catalog_version": 0, "regions": [], "updated_at": 0}
    try:
        return json.loads(_MANIFEST_PATH.read_text())
    except (json.JSONDecodeError, OSError):
        return {"catalog_version": 0, "regions": [], "updated_at": 0}


def get_bundle_path(region_id: str = REGION_ID) -> Path | None:
    """Return the on-disk path for a region's current bundle, if any."""
    manifest = read_manifest()
    for entry in manifest.get("regions", []):
        if entry["region_id"] == region_id:
            return _BUNDLE_DIR / entry["filename"]
    return None


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="mobile_bundle")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("build", help="Build the NYC mobile bundle from transit_schedule.db")
    sub.add_parser("manifest", help="Print the current manifest JSON")
    args = parser.parse_args(argv)

    if args.cmd == "build":
        entry = build_bundle()
        print(json.dumps(entry, indent=2))
        return 0
    if args.cmd == "manifest":
        print(json.dumps(read_manifest(), indent=2))
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(_cli())
