#!/usr/bin/env python3
"""
upload_gtfs_to_supabase.py
TrackBackend/scripts

Compresses and uploads GTFS data files to a Supabase Storage bucket so
the backend can download fresh data on startup instead of bundling
everything into the Docker image.

Usage:
    cd TrackBackend
    python scripts/upload_gtfs_to_supabase.py

    # Upload only specific archives:
    python scripts/upload_gtfs_to_supabase.py subway_core transit_schedule

Environment:
    SUPABASE_URL          - Your Supabase project URL
    SUPABASE_SERVICE_KEY  - Service role key (full write access)
    GTFS_BUCKET           - Bucket name (default: gtfs-data)

The script will:
  1. Compress each data group into a .tar.gz archive
  2. Upload to the Supabase Storage bucket
  3. Verify the upload succeeded
"""

from __future__ import annotations

import os
import sys
import tarfile
import tempfile
from pathlib import Path

import httpx

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "app" / "data"

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")
BUCKET = os.environ.get("GTFS_BUCKET", "gtfs-data")

# ---------------------------------------------------------------------------
# Archive definitions: name → list of (local_path, arcname_in_tar)
# ---------------------------------------------------------------------------
# Each archive maps to a manifest entry in data_loader.py.
# local_path is relative to DATA_DIR.
# arcname is what the file will be named inside the tar.

ARCHIVES: dict[str, list[tuple[str, str | None]]] = {
    "subway_core": [
        # Core subway shape/trip/stop files in DATA_DIR root
        ("shapes.txt", "shapes.txt"),
        ("trips.txt", "trips.txt"),
        ("stops.txt", "stops.txt"),
        ("shape_stops.json", "shape_stops.json"),
    ],
    "subway_routes": [
        # Just routes.txt — extract_to is subway/regular_GTFS
        ("subway/regular_GTFS/routes.txt", "routes.txt"),
    ],
    "subway_supplemented": [
        # Entire supplemented_GTFS dir — extract_to is subway/supplemented_GTFS
        ("subway/supplemented_GTFS", None),  # None = add entire directory
    ],
    "lirr": [
        ("lirr/gtfslirr", None),
    ],
    "mnr": [
        ("metro_north/gtfsmnr", None),
    ],
    "bus_config": [
        ("early_2026_buses_tag.json", "early_2026_buses_tag.json"),
    ],
}


def _build_archive(name: str, members: list[tuple[str, str | None]]) -> Path:
    """Create a .tar.gz archive and return its temp file path."""
    tmp = tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False)  # noqa: SIM115
    tmp_path = tmp.name
    tmp.close()

    with tarfile.open(tmp_path, "w:gz", compresslevel=6) as tar:
        for local_rel, arcname in members:
            full = DATA_DIR / local_rel
            if not full.exists():
                print(f"  ⚠️  Missing: {full} — skipping")
                continue

            if full.is_dir():
                # Add entire directory contents
                for child in sorted(full.rglob("*")):
                    if child.is_file():
                        arc = str(child.relative_to(full))
                        tar.add(str(child), arcname=arc)
                        print(f"  + {arc}")
            else:
                arc = arcname or local_rel
                tar.add(str(full), arcname=arc)
                print(f"  + {arc}")

    size_mb = os.path.getsize(tmp_path) / (1024 * 1024)
    print(f"  → {name}.tar.gz = {size_mb:.1f} MB compressed")
    return Path(tmp_path)


def _upload_to_supabase(file_path: Path, object_name: str) -> bool:
    """Upload a file to the Supabase Storage bucket."""
    url = f"{SUPABASE_URL.rstrip('/')}/storage/v1/object/{BUCKET}/{object_name}"
    headers = {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "Content-Type": "application/gzip",
        "x-upsert": "true",  # Overwrite if exists
    }

    size_mb = file_path.stat().st_size / (1024 * 1024)
    print(f"  Uploading {object_name} ({size_mb:.1f} MB)...")

    with open(file_path, "rb") as f:
        resp = httpx.post(
            url,
            headers=headers,
            content=f.read(),
            timeout=httpx.Timeout(connect=10, read=300, write=300, pool=10),
        )

    if resp.status_code in (200, 201):
        print(f"  ✅ Uploaded {object_name}")
        return True
    print(f"  ❌ Upload failed: HTTP {resp.status_code} — {resp.text[:200]}")
    return False


def _ensure_bucket_exists() -> bool:
    """Create the bucket if it doesn't exist."""
    url = f"{SUPABASE_URL.rstrip('/')}/storage/v1/bucket"
    headers = {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "Content-Type": "application/json",
    }

    # Check if bucket exists
    resp = httpx.get(f"{url}/{BUCKET}", headers=headers, timeout=10)
    if resp.status_code == 200:
        print(f"Bucket '{BUCKET}' exists.")
        return True

    # Create bucket
    print(f"Creating bucket '{BUCKET}'...")
    resp = httpx.post(
        url,
        headers=headers,
        json={
            "id": BUCKET,
            "name": BUCKET,
            "public": False,
        },
        timeout=10,
    )
    if resp.status_code in (200, 201):
        print(f"✅ Bucket '{BUCKET}' created.")
        return True
    print(f"❌ Could not create bucket: {resp.status_code} — {resp.text[:200]}")
    return False


def main():
    if not SUPABASE_SERVICE_KEY:
        print("❌ SUPABASE_SERVICE_KEY environment variable is required.")
        print("   Set it to your Supabase service role key (not the anon key).")
        print("   export SUPABASE_SERVICE_KEY='your-service-role-key'")
        sys.exit(1)

    # Filter to specific archives if args provided
    targets = sys.argv[1:] if len(sys.argv) > 1 else list(ARCHIVES.keys())
    invalid = [t for t in targets if t not in ARCHIVES]
    if invalid:
        print(f"❌ Unknown archive(s): {', '.join(invalid)}")
        print(f"   Available: {', '.join(ARCHIVES.keys())}")
        sys.exit(1)

    # Ensure bucket exists
    if not _ensure_bucket_exists():
        sys.exit(1)

    print(f"\nUploading {len(targets)} archive(s) to Supabase Storage...\n")

    results: dict[str, bool] = {}
    for name in targets:
        print(f"[{name}]")
        archive_path = _build_archive(name, ARCHIVES[name])
        try:
            ok = _upload_to_supabase(archive_path, f"{name}.tar.gz")
            results[name] = ok
        finally:
            archive_path.unlink(missing_ok=True)
        print()

    # Summary
    passed = sum(1 for v in results.values() if v)
    print(f"\n{'='*50}")
    print(f"Upload complete: {passed}/{len(results)} succeeded")
    for name, ok in results.items():
        status = "✅" if ok else "❌"
        print(f"  {status} {name}")

    if passed < len(results):
        sys.exit(1)


if __name__ == "__main__":
    main()
