"""GTFS mobile-bundle distribution endpoints.

Two responsibilities:

* ``GET /gtfs/manifest`` — tiny JSON catalog the iOS app polls to learn
  which regions are available and what content-addressed filename to
  download for each.  Cheap, cacheable.
* ``GET /gtfs/bundle/{filename}`` — streams a content-addressed SQLite
  bundle.  iOS treats the URL as immutable and caches forever.

The bundle itself is built by ``app.services.gtfs.mobile_bundle.build_bundle``
(or the CLI ``python -m app.services.gtfs.mobile_bundle build``) and lives
under ``app/static/gtfs/``.  This router never builds — only serves — so
restarts are instant.
"""

from __future__ import annotations

import re
from pathlib import Path

from fastapi import APIRouter, HTTPException, Response
from fastapi.responses import FileResponse, JSONResponse

from app.services.gtfs.mobile_bundle import (
    REGION_ID,
    SCHEMA_VERSION,
    read_manifest,
)

router = APIRouter(prefix="/gtfs", tags=["gtfs"])

_BACKEND_ROOT = Path(__file__).resolve().parent.parent
_BUNDLE_DIR = _BACKEND_ROOT / "static" / "gtfs"

# Filenames are ``{region}-{sha8}.sqlite`` — strict pattern blocks any
# path traversal and rejects unrelated files in the static dir.
_FILENAME_RE = re.compile(r"^[a-z0-9]+-[0-9a-f]{8}\.sqlite$")


@router.get(
    "/manifest",
    summary="GTFS bundle catalog",
    description=(
        "Returns the list of mobile bundle regions currently available, "
        "their content-addressed download URLs and SHA256 digests.  iOS "
        "polls this on launch and on app-resume to detect new bundles."
    ),
)
async def manifest() -> JSONResponse:
    data = read_manifest(_BUNDLE_DIR)
    # Tell the client this manifest is *catalog-versioned* — it changes
    # only when a region's bundle is regenerated.  Short cache so iOS
    # picks up new bundles within a few minutes.
    return JSONResponse(
        content={
            "schema_version": SCHEMA_VERSION,
            "default_region": REGION_ID,
            **data,
        },
        headers={"Cache-Control": "public, max-age=300"},
    )


@router.get(
    "/bundle/{filename}",
    summary="Download a mobile bundle",
    description=(
        "Streams a content-addressed SQLite bundle.  Filename must match "
        "the value returned by ``/gtfs/manifest`` exactly."
    ),
)
async def bundle(filename: str) -> Response:
    if not _FILENAME_RE.match(filename):
        raise HTTPException(status_code=400, detail="invalid bundle filename")

    path = _BUNDLE_DIR / filename
    # `resolve` forces a path traversal check even if the regex was bypassed.
    if not path.resolve().is_file() or _BUNDLE_DIR.resolve() not in path.resolve().parents:
        raise HTTPException(status_code=404, detail="bundle not found")

    # The filename is the content hash → caller can cache forever.
    return FileResponse(
        str(path),
        media_type="application/vnd.sqlite3",
        filename=filename,
        headers={
            "Cache-Control": "public, max-age=31536000, immutable",
            "X-Bundle-Filename": filename,
        },
    )
