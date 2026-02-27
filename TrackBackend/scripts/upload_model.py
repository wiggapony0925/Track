#!/usr/bin/env python3
"""
upload_model.py
TrackBackend/scripts

Packs the locally-trained LightGBM delay model (app/data/delay_model.pkl)
into a tar.gz and uploads it to the Supabase gtfs-data bucket so that
cold-start instances download the *correct* model instead of a stale copy.

Run this whenever you retrain the model locally:

    cd TrackBackend
    python scripts/upload_model.py

Environment:
    SUPABASE_URL         - Your Supabase project URL
    SUPABASE_SERVICE_KEY - Service role key (full write access)
    GTFS_BUCKET          - Bucket name (default: gtfs-data)
"""

from __future__ import annotations

import os
import sys
import tarfile
import tempfile
from pathlib import Path

import httpx

# ---------------------------------------------------------------------------
# Paths / config
# ---------------------------------------------------------------------------

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "app" / "data"
MODEL_PKL = DATA_DIR / "delay_model.pkl"
ARCHIVE_NAME = "delay_model.tar.gz"

SUPABASE_URL = os.environ.get(
    "SUPABASE_URL", "https://octpebjxadbufiplgjqg.supabase.co"
)
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")
BUCKET = os.environ.get("GTFS_BUCKET", "gtfs-data")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _auth_headers() -> dict[str, str]:
    return {
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "apikey": SUPABASE_SERVICE_KEY,
    }


def _pack_model(tmp_dir: Path) -> Path:
    """Create delay_model.tar.gz containing delay_model.pkl."""
    archive_path = tmp_dir / ARCHIVE_NAME
    with tarfile.open(archive_path, "w:gz") as tar:
        tar.add(MODEL_PKL, arcname="delay_model.pkl")
    size_kb = archive_path.stat().st_size / 1024
    print(f"  Packed {MODEL_PKL.name} → {ARCHIVE_NAME} ({size_kb:.1f} KB)")
    return archive_path


def _upload(client: httpx.Client, archive_path: Path) -> bool:
    """Upload archive_path to the Supabase bucket, overwriting any existing file."""
    object_path = f"{BUCKET}/{ARCHIVE_NAME}"
    storage_url = f"{SUPABASE_URL}/storage/v1/object/{object_path}"

    with open(archive_path, "rb") as fh:
        data = fh.read()

    # Try PATCH (update existing) first, fall back to POST (create new)
    for method in ("PATCH", "POST"):
        resp = client.request(
            method,
            storage_url,
            content=data,
            headers={
                **_auth_headers(),
                "Content-Type": "application/gzip",
                "x-upsert": "true",
            },
        )
        if resp.status_code in (200, 201):
            print(f"  Uploaded {ARCHIVE_NAME} → Supabase bucket '{BUCKET}' ({method} {resp.status_code})")
            return True
        if method == "PATCH" and resp.status_code in (400, 404):
            continue  # object doesn't exist yet, try POST
        print(f"  Upload failed ({method} {resp.status_code}): {resp.text[:200]}")
        return False

    return False


def _verify(client: httpx.Client) -> bool:
    """Head-request the object to verify it exists and is non-empty."""
    object_path = f"{BUCKET}/{ARCHIVE_NAME}"
    url = f"{SUPABASE_URL}/storage/v1/object/{object_path}"
    resp = client.head(url, headers=_auth_headers())
    if resp.status_code == 200:
        size = resp.headers.get("content-length", "?")
        print(f"  Verified: {ARCHIVE_NAME} is {size} bytes in bucket")
        return True
    print(f"  Verification failed ({resp.status_code})")
    return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    if not MODEL_PKL.exists():
        print(f"ERROR: model not found at {MODEL_PKL}")
        return 1

    if not SUPABASE_SERVICE_KEY:
        print("ERROR: SUPABASE_SERVICE_KEY is not set.")
        print("  export SUPABASE_SERVICE_KEY=<your service role key>")
        return 1

    # Show model info
    pkl_kb = MODEL_PKL.stat().st_size / 1024
    print(f"\nUploading delay model to Supabase")
    print(f"  Source : {MODEL_PKL}  ({pkl_kb:.1f} KB)")
    print(f"  Bucket : {BUCKET}")
    print(f"  Object : {ARCHIVE_NAME}\n")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        archive_path = _pack_model(tmp_dir)

        with httpx.Client(
            timeout=httpx.Timeout(connect=15, read=120, write=120, pool=10)
        ) as client:
            ok = _upload(client, archive_path)
            if not ok:
                return 1
            _verify(client)

    print("\nDone. Trigger a Render restart so the server downloads the new model.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
