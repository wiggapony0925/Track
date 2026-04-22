"""Authentication helpers for the Track backend.

Supabase signs every user access token with the project's JWT secret (HS256).
The ``require_user`` and ``optional_user`` FastAPI dependencies verify the
``Authorization: Bearer <token>`` header cryptographically — no database
lookup, no trust in client-supplied claims.

Usage
-----
::

    from app.auth import require_user, optional_user, AuthUser

    @router.get("/personalized")
    async def my_route(user: AuthUser = Depends(require_user)):
        return {"user_id": str(user.user_id)}

    @router.get("/public-with-context")
    async def public_route(user: AuthUser | None = Depends(optional_user)):
        if user:
            # personalize response
            ...
"""

from app.auth.dependencies import optional_user, require_user
from app.auth.user import AuthUser

__all__ = ["AuthUser", "optional_user", "require_user"]
