"""FastAPI dependencies for Supabase JWT verification.

How it works
------------
1. The iOS app stores the Supabase access token in the Keychain after login.
2. Every backend request includes ``Authorization: Bearer <access_token>``.
3. The backend verifies the token signature using the ``SUPABASE_JWT_SECRET``
   (HS256, found in Supabase Dashboard → Settings → API → JWT Secret).
4. PyJWT validates the signature AND the expiry (``exp`` claim) automatically.
5. The verified ``sub`` claim becomes the user's ``user_id``.

No database lookup is required — the JWT is self-contained proof of identity.

Dependency variants
-------------------
* ``require_user`` — raises HTTP 401 if the token is missing or invalid.
  Use on routes that must know who the caller is.
* ``optional_user`` — returns ``None`` instead of raising.
  Use on public routes where identity is used for personalization if present
  but the route still works anonymously.
"""

from __future__ import annotations

import uuid

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.auth.user import AuthUser
from app.config import get_supabase_jwt_secret
from app.utils.logger import TrackLogger

_bearer_scheme = HTTPBearer(auto_error=False)

# JWT algorithm Supabase uses for all project tokens.
_ALGORITHM = "HS256"


def _verify_token(token: str) -> AuthUser:
    """Decode and verify a Supabase JWT, returning an ``AuthUser``.

    Raises
    ------
    HTTPException (401)
        If the token is expired, has an invalid signature, or is missing
        required claims (``sub``).
    HTTPException (503)
        If ``SUPABASE_JWT_SECRET`` is not configured on the backend.
    """
    secret = get_supabase_jwt_secret()
    if not secret:
        TrackLogger.warning("SUPABASE_JWT_SECRET is not configured — auth is disabled", tag="AUTH")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Authentication is not configured on this server.",
        )

    try:
        payload = jwt.decode(
            token,
            secret,
            algorithms=[_ALGORITHM],
            # Supabase JWTs are issued with aud="authenticated".
            # Verifying this prevents tokens from other projects being accepted.
            audience="authenticated",
            options={"verify_exp": True},
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token has expired. Please sign in again.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    except jwt.InvalidTokenError as exc:
        TrackLogger.warning(f"JWT validation failed: {exc}", tag="AUTH")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid authentication token.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    sub = payload.get("sub")
    if not sub:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token is missing required 'sub' claim.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        user_id = uuid.UUID(sub)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token 'sub' claim is not a valid UUID.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return AuthUser(
        user_id=user_id,
        email=payload.get("email"),
        role=payload.get("role", "authenticated"),
    )


async def require_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer_scheme),
) -> AuthUser:
    """FastAPI dependency that requires a valid Supabase Bearer token.

    Returns the verified ``AuthUser`` or raises HTTP 401.

    Example::

        @router.get("/favorites")
        async def get_favorites(user: AuthUser = Depends(require_user)):
            return {"user_id": str(user.user_id)}
    """
    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return _verify_token(credentials.credentials)


async def optional_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer_scheme),
) -> AuthUser | None:
    """FastAPI dependency that returns ``None`` if no valid token is present.

    Use on public routes where a verified identity enables personalization
    but is not required for the route to function.  An invalid or expired
    token on a public route is treated as anonymous (does not raise).

    Example::

        @router.get("/nearby/grouped")
        async def nearby(user: AuthUser | None = Depends(optional_user), ...):
            if user:
                # could bias results toward user's saved routes
                ...
    """
    if credentials is None:
        return None
    try:
        return _verify_token(credentials.credentials)
    except HTTPException:
        # Invalid / expired token on an optional route → treat as anonymous
        return None
