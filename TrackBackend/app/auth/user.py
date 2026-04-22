"""AuthUser — the verified identity extracted from a Supabase JWT.

Fields map directly to the JWT claims that Supabase populates:

* ``user_id``  — ``sub`` claim — the user's UUID in ``auth.users``
* ``email``    — ``email`` claim — may be absent for private-relay Apple addresses
* ``role``     — ``role`` claim — always ``"authenticated"`` for signed-in users
* ``exp``      — expiry timestamp — checked automatically by PyJWT during decode
"""

from __future__ import annotations

import uuid

from pydantic import BaseModel, Field


class AuthUser(BaseModel):
    """Verified identity from a Supabase JWT.

    Constructed by ``require_user`` / ``optional_user`` dependencies after
    PyJWT has validated the token signature and expiry.  All fields come
    directly from the JWT claims — no database round-trip is needed.
    """

    user_id: uuid.UUID = Field(..., description="User UUID (JWT 'sub' claim).")
    email: str | None = Field(
        None,
        description=(
            "User email from JWT claims. May be None for Apple private relay "
            "addresses that the user chose not to share."
        ),
    )
    role: str = Field(
        "authenticated",
        description="Supabase role — always 'authenticated' for signed-in users.",
    )
