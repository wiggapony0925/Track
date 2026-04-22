"""User-specific endpoints for the Track backend.

All routes in this module require a valid Supabase JWT via ``require_user``.
The ``user_id`` in the verified token is the caller's UUID in ``auth.users``
and is used for any future server-side personalisation or data access.

Current endpoints
-----------------
* ``GET /user/me``      — return the verified JWT identity (no DB hit)
* ``GET /user/profile`` — return full profile + settings + trip config from Supabase
"""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app.auth import AuthUser, require_user
from app.models.user import UserContext
from app.services.user_service import load_user_context

router = APIRouter(prefix="/user", tags=["user"])


@router.get(
    "/me",
    summary="Return verified user identity",
    description=(
        "Returns the identity extracted from the caller's Supabase JWT. "
        "Useful for the iOS client to confirm that a token is valid and "
        "has not expired, without touching the database."
    ),
    response_model=dict,
)
async def get_me(user: AuthUser = Depends(require_user)) -> dict:
    """Return the verified ``user_id`` and optional email from the JWT."""
    return {
        "user_id": str(user.user_id),
        "email": user.email,
        "role": user.role,
    }


@router.get(
    "/profile",
    summary="Return full user profile and preferences",
    description=(
        "Fetches the user's profile, app settings, and trip-planning "
        "preferences from Supabase in parallel. Useful for the iOS client "
        "to hydrate all personalisation state in a single round-trip. "
        "Missing rows degrade to null — callers should fall back to defaults."
    ),
    response_model=UserContext,
)
async def get_profile(user: AuthUser = Depends(require_user)) -> UserContext:
    """Return the full :class:`~app.models.user.UserContext` for the caller."""
    return await load_user_context(user)
