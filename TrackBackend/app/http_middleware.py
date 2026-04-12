"""HTTP middleware and cache policy helpers."""

from __future__ import annotations

import time

from fastapi import FastAPI, Request

from app.utils.logger import TrackLogger

_EPOCH_THRESHOLD = 1_000_000_000

_CACHE_CONTROL_RULES: list[tuple[str, str]] = [
    (
        "/subway/shapes/all",
        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800",
    ),
    (
        "/subway/stations/all",
        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800",
    ),
    (
        "/subway/stations/processed",
        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800",
    ),
    (
        "/subway/shape/",
        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800",
    ),
    (
        "/lirr/shapes/all",
        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800",
    ),
    (
        "/lirr/shape/",
        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800",
    ),
    (
        "/mnr/shapes/all",
        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800",
    ),
    (
        "/mnr/shape/",
        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800",
    ),
    (
        "/bus/routes",
        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800",
    ),
    (
        "/bus/route-shape/",
        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800",
    ),
    (
        "/bus/stops/",
        "public, max-age=600, stale-while-revalidate=86400, stale-if-error=604800",
    ),
    (
        "/nearby/grouped",
        "private, max-age=5, stale-while-revalidate=15, stale-if-error=60",
    ),
    ("/subway/", "private, max-age=8, stale-while-revalidate=20, stale-if-error=60"),
    ("/lirr", "private, max-age=8, stale-while-revalidate=20, stale-if-error=60"),
    ("/mnr", "private, max-age=8, stale-while-revalidate=20, stale-if-error=60"),
    ("/bus/live/", "private, max-age=8, stale-while-revalidate=20, stale-if-error=60"),
    (
        "/bus/vehicles/",
        "public, max-age=5, stale-while-revalidate=30, stale-if-error=120",
    ),
    (
        "/bus/nearby",
        "private, max-age=60, stale-while-revalidate=300, stale-if-error=600",
    ),
    ("/alerts", "public, max-age=30, stale-while-revalidate=120, stale-if-error=600"),
    (
        "/accessibility",
        "public, max-age=60, stale-while-revalidate=300, stale-if-error=600",
    ),
    (
        "/predict/delay",
        "private, max-age=60, stale-while-revalidate=300, stale-if-error=600",
    ),
    ("/config", "public, max-age=300, stale-while-revalidate=600"),
    ("/health", "no-store"),
]


def register_http_middleware(app: FastAPI) -> None:
    """Register request logging and cache header middleware."""

    @app.middleware("http")
    async def log_requests(request: Request, call_next):
        start = time.perf_counter()
        user_email = (
            request.headers.get("x-user-email")
            or request.headers.get("x-auth-email")
            or request.query_params.get("email")
            or "-"
        )
        request_id = request.headers.get("Rndr-Id") or "-"
        TrackLogger.set_user_email(user_email)
        TrackLogger.set_request_id(request_id)

        try:
            response = await call_next(request)
            elapsed_ms = (time.perf_counter() - start) * 1000
            query = f"?{request.url.query}" if request.url.query else ""
            TrackLogger.request(
                request.method,
                f"{request.url.path}{query}",
                response.status_code,
                elapsed_ms=elapsed_ms,
            )
            if "cache-control" not in response.headers:
                cache_control = resolve_cache_control(request.url.path)
                if cache_control:
                    response.headers["Cache-Control"] = cache_control
            if request.url.query and "cache-control" in response.headers:
                response.headers.setdefault("Vary", "Accept-Encoding")
            return response
        except Exception:
            elapsed_ms = (time.perf_counter() - start) * 1000
            query = f"?{request.url.query}" if request.url.query else ""
            TrackLogger.error(
                f"{request.method} {request.url.path}{query} → 500 UNHANDLED ({elapsed_ms:.1f}ms)",
                tag="HTTP",
                exc_info=True,
            )
            raise
        finally:
            TrackLogger.clear_user_email()
            TrackLogger.clear_request_id()


def resolve_cache_control(path: str) -> str | None:
    """Find the best-matching Cache-Control value for a request path."""
    for prefix, value in _CACHE_CONTROL_RULES:
        if path == prefix or path.startswith(prefix):
            return value
    return None
