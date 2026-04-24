"""Analytics ingest endpoints.

All routes require a valid Supabase JWT.  The verified ``user_id`` from the
token is *always* used as the row owner — clients cannot spoof another
user's identity even by tampering with the request body.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Body, Depends, HTTPException, status

from app.auth import AuthUser, require_user
from app.services import analytics_service

router = APIRouter(prefix="/analytics", tags=["analytics"])


@router.post(
    "/session/start",
    summary="Start a user session",
    description=(
        "Creates a new ``user_sessions`` row and returns its id. The iOS "
        "client should call this on cold-start and on foreground after a "
        "≥30 s background gap."
    ),
)
async def start_session(
    body: dict[str, Any] = Body(default_factory=dict),
    user: AuthUser = Depends(require_user),
) -> dict[str, Any]:
    sid = await analytics_service.start_session(
        user.user_id,
        app_version=body.get("app_version"),
        build=body.get("build"),
        os_version=body.get("os_version"),
        device_model=body.get("device_model"),
        locale=body.get("locale"),
        timezone=body.get("timezone"),
        network_type=body.get("network_type"),
        entry_screen=body.get("entry_screen"),
        entry_source=body.get("entry_source"),
        push_notification_id=body.get("push_notification_id"),
        initial_lat=body.get("initial_lat"),
        initial_lon=body.get("initial_lon"),
    )
    if sid is None:
        # Don't 500 — telemetry must never break the app.
        return {"ok": False, "session_id": None}
    return {"ok": True, "session_id": sid}


@router.post(
    "/session/end",
    summary="End a user session",
)
async def end_session(
    body: dict[str, Any] = Body(...),
    user: AuthUser = Depends(require_user),
) -> dict[str, Any]:
    sid = body.get("session_id")
    if not isinstance(sid, str) or not sid:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="session_id is required.",
        )
    ok = await analytics_service.end_session(
        sid,
        user.user_id,
        foreground_seconds=body.get("foreground_seconds"),
        screens_viewed=body.get("screens_viewed"),
        events_count=body.get("events_count"),
    )
    return {"ok": ok}


@router.post(
    "/batch",
    summary="Ingest a batch of analytics events",
    description=(
        "Accepts a list of typed events and dispatches each to its Supabase "
        "table.  The verified user_id from the JWT is forced onto every row "
        "so clients cannot spoof identity. Unknown event types are dropped "
        "silently and counted in ``rejected``."
    ),
)
async def ingest_batch(
    body: dict[str, Any] = Body(...),
    user: AuthUser = Depends(require_user),
) -> dict[str, Any]:
    events = body.get("events")
    if not isinstance(events, list):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="events must be a list.",
        )
    if len(events) > 500:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail="Batch too large (max 500 events).",
        )
    sid = body.get("session_id") if isinstance(body.get("session_id"), str) else None
    result = await analytics_service.ingest_batch(
        user.user_id, events, default_session_id=sid
    )
    return {"ok": True, **result}
