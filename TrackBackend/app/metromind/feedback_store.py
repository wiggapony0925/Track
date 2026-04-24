"""Storage for MetroMind chat feedback (thumbs up / down).

Backend selection (decided at process start):

* If ``SUPABASE_URL`` and a service key (``SUPABASE_SERVICE_KEY`` or
  ``SUPABASE_SERVICE_ROLE_KEY``) are set, rows go to the
  ``public.metromind_feedback`` table via PostgREST. This is the prod
  path on Render.
* Otherwise we fall back to a local SQLite file at
  ``app/data/metromind_feedback.db`` so dev still works without service
  credentials.

Public API (sync — wrap in ``asyncio.to_thread`` from FastAPI):

* :func:`record_feedback` — insert one row.
* :func:`feedback_summary` — aggregate counts + recent rows.
"""

from __future__ import annotations

import os
import sqlite3
import time
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Iterator

import httpx

from app.metromind.config import get_metromind_settings
from app.metromind.logger import get_logger

logger = get_logger("feedback_store")


_MAX_TEXT = 4000  # Cap per-row text payload size.
_TABLE = "metromind_feedback"


# ── Supabase backend ────────────────────────────────────────────────

def _supabase_creds() -> tuple[str, str] | None:
    url = (os.environ.get("SUPABASE_URL") or "").strip().rstrip("/")
    key = (
        os.environ.get("SUPABASE_SERVICE_KEY")
        or os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        or ""
    ).strip()
    if not url or not key:
        return None
    return url, key


_supabase_client: httpx.Client | None = None


def _supabase_http() -> httpx.Client:
    global _supabase_client
    if _supabase_client is None:
        creds = _supabase_creds()
        assert creds is not None  # caller checks
        url, _ = creds
        _supabase_client = httpx.Client(
            base_url=f"{url}/rest/v1",
            timeout=10.0,
        )
    return _supabase_client


def _supabase_headers(prefer: str | None = None) -> dict[str, str]:
    creds = _supabase_creds()
    assert creds is not None
    _, key = creds
    h = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Accept": "application/json",
        "Content-Profile": "public",
        "Accept-Profile": "public",
    }
    if prefer:
        h["Prefer"] = prefer
    return h


def _record_supabase(row: dict[str, Any]) -> int:
    payload = dict(row)
    if "created_at" in payload and isinstance(payload["created_at"], int):
        payload["created_at"] = (
            datetime.fromtimestamp(payload["created_at"], tz=UTC)
            .isoformat()
            .replace("+00:00", "Z")
        )
    response = _supabase_http().request(
        "POST",
        f"/{_TABLE}",
        params={"select": "id"},
        json=payload,
        headers=_supabase_headers(prefer="return=representation"),
    )
    response.raise_for_status()
    body = response.json() or []
    if isinstance(body, list) and body and isinstance(body[0], dict):
        return int(body[0].get("id") or 0)
    return 0


def _summary_supabase(limit: int) -> dict:
    client = _supabase_http()
    headers = _supabase_headers()

    def _count(rating: int) -> int:
        h = dict(headers)
        h["Prefer"] = "count=exact"
        # Range: 0-0 keeps the response body tiny — we only want the count header.
        h["Range-Unit"] = "items"
        h["Range"] = "0-0"
        r = client.request(
            "GET",
            f"/{_TABLE}",
            params={"rating": f"eq.{rating}", "select": "id"},
            headers=h,
        )
        r.raise_for_status()
        cr = r.headers.get("Content-Range") or r.headers.get("content-range") or ""
        if "/" in cr:
            tail = cr.split("/", 1)[1]
            if tail.isdigit():
                return int(tail)
        return 0

    cols = (
        "id,created_at,rating,thread_id,client_msg_id,"
        "user_prompt,assistant_text,reason,app_version,model_used"
    )
    r = client.request(
        "GET",
        f"/{_TABLE}",
        params={
            "select": cols,
            "order": "created_at.desc",
            "limit": str(max(1, min(limit, 1000))),
        },
        headers=headers,
    )
    r.raise_for_status()
    return {
        "thumbs_up": _count(1),
        "thumbs_down": _count(-1),
        "recent": r.json() or [],
    }


# ── SQLite fallback ─────────────────────────────────────────────────

_SCHEMA = """
CREATE TABLE IF NOT EXISTS feedback (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at      INTEGER NOT NULL,
    rating          INTEGER NOT NULL,
    thread_id       TEXT,
    client_msg_id   TEXT,
    user_prompt     TEXT,
    assistant_text  TEXT,
    reason          TEXT,
    app_version     TEXT,
    model_used      TEXT
);

CREATE INDEX IF NOT EXISTS idx_feedback_created ON feedback (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_feedback_rating  ON feedback (rating);
"""


def _db_path() -> Path:
    settings = get_metromind_settings()
    base = Path(settings.threads_db_path).parent
    base.mkdir(parents=True, exist_ok=True)
    return base / "metromind_feedback.db"


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(_db_path(), isolation_level=None, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn


@contextmanager
def _cursor() -> Iterator[sqlite3.Cursor]:
    conn = _connect()
    try:
        cur = conn.cursor()
        cur.executescript(_SCHEMA)
        yield cur
    finally:
        conn.close()


def _record_sqlite(row: dict[str, Any]) -> int:
    with _cursor() as cur:
        cur.execute(
            """
            INSERT INTO feedback (
                created_at, rating, thread_id, client_msg_id,
                user_prompt, assistant_text, reason, app_version, model_used
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                row["created_at"],
                row["rating"],
                row.get("thread_id"),
                row.get("client_msg_id"),
                row.get("user_prompt"),
                row.get("assistant_text"),
                row.get("reason"),
                row.get("app_version"),
                row.get("model_used"),
            ),
        )
        return cur.lastrowid or 0


def _summary_sqlite(limit: int) -> dict:
    with _cursor() as cur:
        cur.execute(
            "SELECT rating, COUNT(*) AS n FROM feedback GROUP BY rating"
        )
        counts = {int(r["rating"]): int(r["n"]) for r in cur.fetchall()}
        cur.execute(
            """
            SELECT id, created_at, rating, thread_id, client_msg_id,
                   user_prompt, assistant_text, reason, app_version, model_used
            FROM feedback
            ORDER BY created_at DESC
            LIMIT ?
            """,
            (max(1, min(limit, 1000)),),
        )
        rows = [dict(r) for r in cur.fetchall()]
    return {
        "thumbs_up": counts.get(1, 0),
        "thumbs_down": counts.get(-1, 0),
        "recent": rows,
    }


# ── Public API ──────────────────────────────────────────────────────

def backend_name() -> str:
    return "supabase" if _supabase_creds() else "sqlite"


def _truncate(value: str | None) -> str | None:
    if value is None:
        return None
    v = value.strip()
    if not v:
        return None
    return v[:_MAX_TEXT]


def record_feedback(
    *,
    rating: int,
    thread_id: str | None = None,
    client_msg_id: str | None = None,
    user_prompt: str | None = None,
    assistant_text: str | None = None,
    reason: str | None = None,
    app_version: str | None = None,
    model_used: str | None = None,
) -> int:
    """Insert a feedback row. Returns the new row id (0 if unknown)."""
    if rating not in (-1, 1):
        raise ValueError("rating must be 1 or -1")
    row = {
        "created_at": int(time.time()),
        "rating": rating,
        "thread_id": thread_id or None,
        "client_msg_id": client_msg_id or None,
        "user_prompt": _truncate(user_prompt),
        "assistant_text": _truncate(assistant_text),
        "reason": _truncate(reason),
        "app_version": app_version or None,
        "model_used": model_used or None,
    }

    if _supabase_creds():
        try:
            row_id = _record_supabase(row)
            logger.info(
                "feedback recorded backend=supabase id=%s rating=%s thread=%s",
                row_id, rating, thread_id,
            )
            return row_id
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "supabase feedback insert failed, falling back to sqlite: %s", exc
            )

    row_id = _record_sqlite(row)
    logger.info(
        "feedback recorded backend=sqlite id=%s rating=%s thread=%s",
        row_id, rating, thread_id,
    )
    return row_id


def feedback_summary(limit: int = 200) -> dict:
    """Aggregate counts + recent rows. Tries Supabase, falls back to SQLite."""
    if _supabase_creds():
        try:
            data = _summary_supabase(limit)
            data["backend"] = "supabase"
            return data
        except Exception as exc:  # noqa: BLE001
            logger.warning("supabase summary failed, falling back to sqlite: %s", exc)
    data = _summary_sqlite(limit)
    data["backend"] = "sqlite"
    return data
