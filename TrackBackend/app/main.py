"""Application entry point. Registers all routers and serves the /config
endpoint that the iOS app fetches on launch."""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from starlette.middleware.gzip import GZipMiddleware

from app.http_middleware import register_http_middleware
from app.lifecycle import is_warmed_up, register_lifecycle
from documentation.docs_auth import register_docs_routes
from documentation.render_openapi import build_api_description
from documentation.tag_docs import OPENAPI_TAGS
from app.routers import (
    analytics,
    bus,
    departures,
    gtfs_bundle,
    lirr,
    mnr,
    nearby,
    predict,
    status,
    subway,
    system,
    track_engine_router,
    user,
    weather,
)
from app.metromind import router as metromind_router
from app.utils.metrics import setup_metrics

# ---------------------------------------------------------------------------
# OpenAPI metadata — powers the /api-docs Scalar documentation page
# ---------------------------------------------------------------------------
_API_DESCRIPTION = build_api_description()

app = FastAPI(
    title="Track API",
    description=_API_DESCRIPTION,
    version="1.0.0",
    openapi_tags=OPENAPI_TAGS,
    openapi_url=None,  # disable built-in /openapi.json — we serve it gated below
    docs_url=None,  # disable default Swagger UI — we use Scalar
    redoc_url=None,  # disable default ReDoc — we use Scalar
    contact={
        "name": "Jeffrey Fernandez",
        "url": "https://github.com/jeffreyfernandez",
    },
    license_info={
        "name": "Private",
    },
)

# Register routers
app.include_router(subway.router)
app.include_router(lirr.router)
app.include_router(mnr.router)
app.include_router(status.router)
app.include_router(bus.router)
app.include_router(nearby.router)
app.include_router(departures.router)
app.include_router(predict.router)
app.include_router(weather.router)
app.include_router(track_engine_router.router)
app.include_router(user.router)
app.include_router(system.router)
app.include_router(analytics.router)
app.include_router(gtfs_bundle.router)
app.include_router(metromind_router)

# ── Static files (docs assets, favicon) ──────────────────────────────────
_STATIC_DIR = Path(__file__).resolve().parent / "static"
app.mount("/static", StaticFiles(directory=str(_STATIC_DIR)), name="static")
register_docs_routes(app, static_dir=_STATIC_DIR)


# ── GZip compression ──────────────────────────────────────────────────────
# Compress all responses >= 500 bytes.  The subway/shapes/all payload is
# 3-5 MB uncompressed; gzip shrinks it ~5x, slashing transfer time from
# seconds to sub-second.  URLSession on iOS handles Accept-Encoding: gzip
# transparently.
app.add_middleware(GZipMiddleware, minimum_size=500)

# ── Prometheus metrics ────────────────────────────────────────────────────
# Instruments all HTTP endpoints and exposes GET /metrics for scraping.
setup_metrics(app)
register_http_middleware(app)
register_lifecycle(app)
