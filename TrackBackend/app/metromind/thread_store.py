"""Persistence for MetroMind chat threads + messages.

Backend selection (decided at process start, can be flipped per call by
``SUPABASE_*`` env vars):

* If ``SUPABASE_URL`` and a service key (``SUPABASE_SERVICE_KEY`` or
  ``SUPABASE_SERVICE_ROLE_KEY``) are configured, all reads/writes go to
  the ``metromind_threads`` / ``metromind_messages`` tables in Supabase
  via PostgREST. This is the prod path and survives Render redeploys
  + multi-instance scale.
* Otherwise we fall back to a local SQLite file at
  ``settings.threads_db_path`` so dev still works without service
  credentials.

Performance:

* Per-thread in-memory LRU cache holds the full message list for hot
  threads (cap: 256 threads, ~configurable via env). The chat
  orchestrator calls ``load_messages`` once per turn — when the same
  client keeps the same ``thread_id``, every subsequent turn after the
  first is a single dict lookup with **zero** network or disk I/O.
* ``append_message`` updates both the cache and the durable store, so
  the cache stays consistent without a re-fetch.
* All public functions are sync; FastAPI wraps them in
  ``asyncio.to_thread`` so the event loop stays free.

Public API (unchanged from the previous SQLite-only implementation):

* :func:`create_thread`
* :func:`thread_exists`
* :func:`append_message`
* :func:`load_messages`
* :func:`delete_thread`
* :func:`init_db`
"""

from __future__ import annotations

import os
import sqlite3
import threading
import time
import uuid
from collections import OrderedDict
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Iterator

import httpx

from app.metromind.config import get_metromind_settings
from app.metromind.logger import get_logger
from app.metromind.schemas import ChatMessage

logger = get_logger("thread_store")


# ── Supabase client ─────────────────────────────────────────────────

_THREADS_TABLE = "metromind_threads"
_MESSAGES_TABLE = "metromind_messages"


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
_client_lock = threading.Lock()


def _supabase_http() -> httpx.Client:
    global _supabase_client
    if _supabase_client is not None:
        return _supabase_client
    with _client_lock:
        if _supabase_client is None:
            creds = _supabase_creds()
            assert creds is not None
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
        "Content-Type": "application/json",
        "Content-Profile": "public",
        "Accept-Profile": "public",
    }
    if prefer:
        h["Prefer"] = prefer
    return h


def _iso(ts_unix: int) -> str:
    return (
        datetime.fromtimestamp(ts_unix, tz=UTC)
        .isoformat()
        .replace("+00:00", "Z")
    )


# ── In-memory LRU cache ─────────────────────────────────────────────
#
# Maps thread_id → list[ChatMessage], ordered oldest → newest. Capped at
# _CACHE_MAX threads via OrderedDict eviction. Protected by a lock so
# concurrent uvicorn workers don't tear the list mid-append.

_CACHE_MAX = int(os.environ.get("METROMIND_THREAD_CACHE_MAX", "256"))
_cache: "OrderedDict[str, list[ChatMessage]]" = OrderedDict()
_cache_lock = threading.Lock()


def _cache_get(thread_id: str) -> list[ChatMessage] | None:
    with _cache_lock:
        msgs = _cache.get(thread_id)
        if msgs is None:
            return None
        _cache.move_to_end(thread_id)
        return list(msgs)


def _cache_put(thread_id: str, msgs: list[ChatMessage]) -> None:
    with _cache_lock:
        _cache[thread_id] = list(msgs)
        _cache.move_to_end(thread_id)
        while len(_cache) > _CACHE_MAX:
            _cache.popitem(last=False)


def _cache_append(thread_id: str, msg: ChatMessage) -> None:
    with _cache_lock:
        existing = _cache.get(thread_id)
        if existing is None:
            return  # nothing cached yet — next load_messages will fetch
        existing.append(msg)
        _cache.move_to_end(thread_id)


def _cache_drop(thread_id: str) -> None:
    with _cache_lock:
        _cache.pop(thread_id, None)


# ── Supabase ops ────────────────────────────────────────────────────

def _sb_create_thread(thread_id: str, title: str | None) -> None:
    now = int(time.time())
    payload = {
        "id": thread_id,
        "created_at": _iso(now),
        "updated_at": _iso(now),
        "title": title,
    }
    r = _supabase_http().request(
        "POST",
        f"/{_THREADS_TABLE}",
        json=payload,
        headers=_supabase_headers(prefer="return=minimal"),
    )
    r.raise_for_status()


def _sb_upsert_thread(thread_id: str) -> None:
    """Insert-or-bump-updated_at so client-supplied IDs auto-create."""
    now = int(time.time())
    payload = {
        "id": thread_id,
        "updated_at": _iso(now),
    }
    # PostgREST upsert via Prefer: resolution=merge-duplicates.
    r = _supabase_http().request(
        "POST",
        f"/{_THREADS_TABLE}",
        json=payload,
        headers=_supabase_headers(
            prefer="return=minimal,resolution=merge-duplicates"
        ),
    )
    r.raise_for_status()


def _sb_thread_exists(thread_id: str) -> bool:
    r = _supabase_http().request(
        "GET",
        f"/{_THREADS_TABLE}",
        params={"id": f"eq.{thread_id}", "select": "id", "limit": "1"},
        headers=_supabase_headers(),
    )
    r.raise_for_status()
    body = r.json() or []
    return bool(body)


def _sb_append_message(
    thread_id: str,
    role: str,
    content: str,
    image_data_url: str | None,
) -> None:
    _sb_upsert_thread(thread_id)
    now = int(time.time())
    payload = {
        "thread_id": thread_id,
        "role": role,
        "content": content,
        "created_at": _iso(now),
        "image_data_url": image_data_url,
    }
    r = _supabase_http().request(
        "POST",
        f"/{_MESSAGES_TABLE}",
        json=payload,
        headers=_supabase_headers(prefer="return=minimal"),
    )
    r.raise_for_status()


def _sb_load_messages(thread_id: str, limit: int) -> list[ChatMessage]:
    # Order by id desc + limit, then reverse so the newest `limit` rows
    # come back oldest → newest.
    r = _supabase_http().request(
        "GET",
        f"/{_MESSAGES_TABLE}",
        params={
            "thread_id": f"eq.{thread_id}",
            "select": "role,content,image_data_url,id",
            "order": "id.desc",
            "limit": str(max(1, int(limit))),
        },
        headers=_supabase_headers(),
    )
    r.raise_for_status()
    rows = r.json() or []
    rows.reverse()
    return [
        ChatMessage(
            role=row["role"],
            content=row["content"],
            image_data_url=row.get("image_data_url"),
        )
        for row in rows
    ]


def _sb_delete_thread(thread_id: str) -> bool:
    # Cascade handles messages.
    r = _supabase_http().request(
        "DELETE",
        f"/{_THREADS_TABLE}",
        params={"id": f"eq.{thread_id}"},
        headers=_supabase_headers(prefer="return=representation"),
    )
    r.raise_for_status()
    body = r.json() or []
    return bool(body)


# ── SQLite fallback ─────────────────────────────────────────────────

_SCHEMA = """
CREATE TABLE IF NOT EXISTS threads (
    id          TEXT PRIMARY KEY,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    title       TEXT
);

CREATE TABLE IF NOT EXISTS messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id       TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
    role            TEXT NOT NULL,
    content         TEXT NOT NULL,
    created_at      INTEGER NOT NULL,
    image_data_url  TEXT
);

CREATE INDEX IF NOT EXISTS idx_messages_thread_created
    ON messages (thread_id, created_at);
"""


def _db_path() -> Path:
    settings = get_metromind_settings()
    p = Path(settings.threads_db_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


@contextmanager
def _conn() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(_db_path(), isolation_level=None, timeout=5.0)
    try:
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA foreign_keys=ON;")
        yield conn
    finally:
        conn.close()


def _sqlite_init() -> None:
    with _conn() as conn:
        conn.executescript(_SCHEMA)


def _sqlite_create_thread(thread_id: str, title: str | None) -> None:
    _sqlite_init()
    now = int(time.time())
    with _conn() as conn:
        conn.execute(
            "INSERT INTO threads (id, created_at, updated_at, title) VALUES (?, ?, ?, ?)",
            (thread_id, now, now, title),
        )


def _sqlite_thread_exists(thread_id: str) -> bool:
    _sqlite_init()
    with _conn() as conn:
        row = conn.execute(
            "SELECT 1 FROM threads WHERE id = ? LIMIT 1", (thread_id,)
        ).fetchone()
    return row is not None


def _sqlite_append_message(
    thread_id: str, role: str, content: str, image_data_url: str | None
) -> None:
    _sqlite_init()
    now = int(time.time())
    with _conn() as conn:
        conn.execute(
            "INSERT INTO threads (id, created_at, updated_at) VALUES (?, ?, ?) "
            "ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at",
            (thread_id, now, now),
        )
        conn.execute(
            "INSERT INTO messages (thread_id, role, content, created_at, image_data_url) "
            "VALUES (?, ?, ?, ?, ?)",
            (thread_id, role, content, now, image_data_url),
        )


def _sqlite_load_messages(thread_id: str, limit: int) -> list[ChatMessage]:
    _sqlite_init()
    with _conn() as conn:
        rows = conn.execute(
            "SELECT role, content, image_data_url FROM messages "
            "WHERE thread_id = ? ORDER BY id DESC LIMIT ?",
            (thread_id, max(1, int(limit))),
        ).fetchall()
    rows.reverse()
    return [
        ChatMessage(role=role, content=content, image_data_url=image)
        for role, content, image in rows
    ]


def _sqlite_delete_thread(thread_id: str) -> bool:
    _sqlite_init()
    with _conn() as conn:
        cur = conn.execute("DELETE FROM threads WHERE id = ?", (thread_id,))
    return cur.rowcount > 0


# ── Public API ──────────────────────────────────────────────────────

def backend_name() -> str:
    return "supabase" if _supabase_creds() else "sqlite"


def init_db() -> None:
    """Idempotent — only meaningful for the SQLite fallback path."""
    if _supabase_creds():
        return
    _sqlite_init()


def create_thread(title: str | None = None) -> str:
    """Mint a new thread id and persist a row."""
    tid = uuid.uuid4().hex
    if _supabase_creds():
        try:
            _sb_create_thread(tid, title)
            return tid
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "supabase create_thread failed, falling back to sqlite: %s", exc
            )
    _sqlite_create_thread(tid, title)
    return tid


def thread_exists(thread_id: str) -> bool:
    # Cache hit short-circuits the network round-trip.
    if _cache_get(thread_id) is not None:
        return True
    if _supabase_creds():
        try:
            return _sb_thread_exists(thread_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "supabase thread_exists failed, falling back to sqlite: %s", exc
            )
    return _sqlite_thread_exists(thread_id)


def append_message(
    thread_id: str,
    role: str,
    content: str,
    *,
    image_data_url: str | None = None,
) -> None:
    """Append a single message; auto-creates the thread row if missing."""
    msg = ChatMessage(role=role, content=content, image_data_url=image_data_url)

    if _supabase_creds():
        try:
            _sb_append_message(thread_id, role, content, image_data_url)
            _cache_append(thread_id, msg)
            return
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "supabase append_message failed, falling back to sqlite: %s", exc
            )
            _cache_drop(thread_id)  # cache may now be stale
    _sqlite_append_message(thread_id, role, content, image_data_url)
    _cache_append(thread_id, msg)


def load_messages(thread_id: str, limit: int = 24) -> list[ChatMessage]:
    """Return the last ``limit`` messages, oldest → newest."""
    cached = _cache_get(thread_id)
    if cached is not None:
        # Cache stores the full known history for the thread; slice tail.
        return cached[-max(1, int(limit)) :]

    if _supabase_creds():
        try:
            msgs = _sb_load_messages(thread_id, limit)
            _cache_put(thread_id, msgs)
            return msgs
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "supabase load_messages failed, falling back to sqlite: %s", exc
            )
    msgs = _sqlite_load_messages(thread_id, limit)
    _cache_put(thread_id, msgs)
    return msgs


def delete_thread(thread_id: str) -> bool:
    _cache_drop(thread_id)
    if _supabase_creds():
        try:
            return _sb_delete_thread(thread_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "supabase delete_thread failed, falling back to sqlite: %s", exc
            )
    return _sqlite_delete_thread(thread_id)


__all__ = [
    "append_message",
    "backend_name",
    "create_thread",
    "delete_thread",
    "init_db",
    "load_messages",
    "thread_exists",
]
