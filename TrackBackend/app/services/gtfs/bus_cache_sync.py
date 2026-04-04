"""Upload bus Socrata cache files to Supabase Storage after a fresh rebuild.

Called from app.services.mapping.bus.routes and .stops after each successful
cache rebuild from the open data API.  Runs in a daemon thread so it never
blocks the event loop or the caller.

On the next cold start, data_loader.py downloads these objects from Supabase
so the bus indexes are warm immediately — no Socrata warmup penalty, no
rate-limit exposure.

Supabase objects written:
    bus_shapes_cache.tar.gz  — wraps _cache_bus_shapes_v1.json
    bus_stops_cache.tar.gz   — wraps _cache_bus_stops_v1.json
"""

from __future__ import annotations

import os
import tarfile
import tempfile
import threading
import time
from pathlib import Path

import httpx

from app.utils.logger import TrackLogger

# ---------------------------------------------------------------------------
# Supabase config — mirrors data_loader.py without importing it
# ---------------------------------------------------------------------------

_SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
_SUPABASE_KEY = (
    os.environ.get("SUPABASE_SERVICE_KEY")
    or os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    or os.environ.get("SUPABASE_KEY", "")
)
_BUCKET = os.environ.get("GTFS_BUCKET", "gtfs-data")

_UPLOAD_TIMEOUT = httpx.Timeout(connect=10.0, read=180.0, write=180.0, pool=10.0)


# ---------------------------------------------------------------------------
# Internal upload worker (runs in a daemon thread)
# ---------------------------------------------------------------------------


def _do_upload(object_name: str, cache_path: Path) -> None:
    """Package cache_path as a tar.gz and upload to Supabase Storage.

    Silently skips when Supabase is not configured (local dev) or the
    cache file has already been removed.

    Args:
        object_name: The Supabase storage object name, e.g.
            ``"bus_shapes_cache.tar.gz"``.
        cache_path: Path to the local JSON cache file to package.
    """
    # Re-read at call time in case .env was loaded after module import.
    url_base = os.environ.get("SUPABASE_URL", _SUPABASE_URL).rstrip("/")
    key = (
        os.environ.get("SUPABASE_SERVICE_KEY")
        or os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        or os.environ.get("SUPABASE_KEY", _SUPABASE_KEY)
    )
    bucket = os.environ.get("GTFS_BUCKET", _BUCKET)

    if not url_base or not key:
        return  # Supabase not configured — silent skip in local dev

    if not cache_path.exists():
        TrackLogger.warning(
            f"[BUS_CACHE] Cache file gone before upload: {cache_path.name}",
            tag="BUS_CACHE",
        )
        return

    tmp_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp:
            tmp_path = tmp.name

        with tarfile.open(tmp_path, "w:gz", compresslevel=6) as tar:
            tar.add(str(cache_path), arcname=cache_path.name)

        with open(tmp_path, "rb") as f:
            data = f.read()

        size_kb = len(data) // 1024
        url = f"{url_base}/storage/v1/object/{bucket}/{object_name}"
        headers = {
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/gzip",
            "x-upsert": "true",
        }

        t_upload = time.monotonic()
        with httpx.Client(timeout=_UPLOAD_TIMEOUT) as client:
            resp = client.post(url, headers=headers, content=data)
        upload_s = time.monotonic() - t_upload

        if resp.status_code in (200, 201):
            TrackLogger.info(
                f"[BUS_CACHE] Uploaded {object_name} → Supabase"
                f" ({size_kb} KB, {upload_s:.1f}s)",
                tag="BUS_CACHE",
            )
        else:
            TrackLogger.warning(
                f"[BUS_CACHE] Upload {object_name} failed: HTTP {resp.status_code}",
                tag="BUS_CACHE",
            )

    except Exception as exc:  # noqa: BLE001 — non-fatal background op
        TrackLogger.warning(
            f"[BUS_CACHE] Upload {object_name} error: {exc}",
            tag="BUS_CACHE",
        )
    finally:
        if tmp_path:
            try:
                Path(tmp_path).unlink(missing_ok=True)
            except Exception:  # noqa: BLE001
                pass


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def upload_bus_cache(object_name: str, cache_path: Path) -> None:
    """Upload a bus Socrata cache file to Supabase Storage in the background.

    Non-blocking — spawns a daemon thread and returns immediately.
    Safe to call from synchronous ``_save_disk_cache`` functions.

    Args:
        object_name: The Supabase storage object name, e.g.
            ``"bus_shapes_cache.tar.gz"``.
        cache_path: Path to the local JSON cache file to package and upload.
    """
    t = threading.Thread(
        target=_do_upload,
        args=(object_name, cache_path),
        daemon=True,
        name=f"bus-cache-upload-{object_name}",
    )
    t.start()
