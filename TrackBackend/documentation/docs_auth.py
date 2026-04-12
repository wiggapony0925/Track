"""Private documentation routes and auth helpers for Scalar/OpenAPI."""

from __future__ import annotations

import hashlib
import hmac
import os
import secrets
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse

from app.config import get_settings

_DOCS_TOKEN = os.environ.get("DOCS_ACCESS_TOKEN", "").strip()
_COOKIE_NAME = "track_docs_session"
_COOKIE_MAX_AGE = 60 * 60 * 24 * get_settings().app_settings.docs_session_days


def register_docs_routes(app: FastAPI, *, static_dir: Path) -> None:
    """Register private Scalar docs routes on the app."""
    docs_html_path = static_dir / "docs" / "index.html"
    original_openapi = app.openapi

    @app.get("/api-docs", include_in_schema=False)
    async def scalar_docs(request: Request):
        """Scalar-powered API documentation."""
        if not _verify_docs_access(request):
            return _denied_response()

        response = HTMLResponse(docs_html_path.read_text())
        query_token = request.query_params.get("token", "")
        if _DOCS_TOKEN and query_token and secrets.compare_digest(query_token, _DOCS_TOKEN):
            _set_session_cookie(response, _DOCS_TOKEN, request)

        return response

    @app.get("/docs", include_in_schema=False)
    async def docs_redirect(request: Request):
        """Redirect `/docs` to `/api-docs`."""
        token = request.query_params.get("token", "")
        url = "/api-docs" + (f"?token={token}" if token else "")
        return RedirectResponse(url=url)

    @app.get("/redoc", include_in_schema=False)
    async def redoc_redirect(request: Request):
        """Redirect `/redoc` to `/api-docs`."""
        token = request.query_params.get("token", "")
        url = "/api-docs" + (f"?token={token}" if token else "")
        return RedirectResponse(url=url)

    @app.get("/openapi.json", include_in_schema=False)
    async def protected_openapi(request: Request):
        """Serve the OpenAPI spec behind the same docs auth."""
        if not _verify_docs_access(request):
            return JSONResponse({"detail": "Access token required"}, status_code=403)
        return JSONResponse(original_openapi())


def _sign_cookie(token: str) -> str:
    return hmac.new(token.encode(), b"track-docs-session", hashlib.sha256).hexdigest()


def _verify_docs_access(request: Request) -> bool:
    if not _DOCS_TOKEN:
        return True

    query_token = request.query_params.get("token", "")
    if query_token and secrets.compare_digest(query_token, _DOCS_TOKEN):
        return True

    cookie_value = request.cookies.get(_COOKIE_NAME, "")
    expected = _sign_cookie(_DOCS_TOKEN)
    return bool(cookie_value and secrets.compare_digest(cookie_value, expected))


def _denied_response() -> HTMLResponse:
    return HTMLResponse(
        content="""<!DOCTYPE html>
<html><head><title>Track API — Access Required</title>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<style>
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       background:#1a1a2e;font-family:system-ui,-apple-system,sans-serif;color:#e0e0e0}
  .card{background:#16213e;border:1px solid #0f3460;border-radius:12px;padding:3rem;
        max-width:420px;text-align:center;box-shadow:0 4px 24px rgba(0,0,0,.4)}
  h1{margin:0 0 .5rem;font-size:1.5rem;color:#a78bfa}
  p{margin:.5rem 0;line-height:1.6;color:#94a3b8}
  code{background:#0f3460;padding:2px 8px;border-radius:4px;font-size:.85rem;color:#c084fc}
</style></head>
<body><div class="card">
  <h1>Access Required</h1>
  <p>This documentation is private.</p>
  <p>Use the link you were given — it contains the access token:</p>
  <p><code>/api-docs?token=&lt;your-token&gt;</code></p>
</div></body></html>""",
        status_code=403,
    )


def _set_session_cookie(
    response: HTMLResponse, token: str, request: Request
) -> HTMLResponse:
    is_https = (
        request.url.scheme == "https"
        or request.headers.get("x-forwarded-proto") == "https"
    )
    response.set_cookie(
        key=_COOKIE_NAME,
        value=_sign_cookie(token),
        max_age=_COOKIE_MAX_AGE,
        httponly=True,
        secure=is_https,
        samesite="lax",
        path="/",
    )
    return response
