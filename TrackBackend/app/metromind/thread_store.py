"""SQLite-backed thread store for MetroMind (Batch 2 — J).

Lightweight persistence so the iOS client can keep a single thread
across app restarts without re-uploading the entire history each turn.

Schema::

    threads(id TEXT PK, created_at INT, updated_at INT, title TEXT NULL)
    messages(id INT PK, thread_id TEXT FK, role TEXT, content TEXT,
             created_at INT, image_data_url TEXT NULL)

The DB lives at ``settings.threads_db_path`` (default
``app/data/metromind_threads.db`` — that path is on the Render
persistent disk in production).

All operations are synchronous; SQLite is fast enough at this scale and
keeps the dependency surface minimal. The orchestrator wraps writes in
``asyncio.to_thread`` so the event loop stays free.
"""

from __future__ import annotations

import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

from app.metromind.config import get_metromind_settings
from app.metromind.logger import get_logger
from app.metromind.schemas import ChatMessage

logger = get_logger("thread_store")


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


def init_db() -> None:
    """Create tables if they don't exist (idempotent)."""
    with _conn() as conn:
        conn.executescript(_SCHEMA)


def create_thread(title: str | None = None) -> str:
    """Mint a new thread id and persist a row."""
    init_db()
    tid = uuid.uuid4().hex
    now = int(time.time())
    with _conn() as conn:
        conn.execute(
            "INSERT INTO threads (id, created_at, updated_at, title) VALUES (?, ?, ?, ?)",
            (tid, now, now, title),
        )
    return tid


def thread_exists(thread_id: str) -> bool:
    init_db()
    with _conn() as conn:
        row = conn.execute(
            "SELECT 1 FROM threads WHERE id = ? LIMIT 1", (thread_id,)
        ).fetchone()
    return row is not None


def append_message(
    thread_id: str,
    role: str,
    content: str,
    *,
    image_data_url: str | None = None,
) -> None:
    """Append a single message; auto-creates the thread row if missing."""
    init_db()
    now = int(time.time())
    with _conn() as conn:
        # Upsert thread row to allow client-supplied thread_ids.
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


def load_messages(thread_id: str, limit: int = 24) -> list[ChatMessage]:
    """Return the last ``limit`` messages, oldest → newest."""
    init_db()
    with _conn() as conn:
        rows = conn.execute(
            "SELECT role, content, image_data_url FROM messages "
            "WHERE thread_id = ? ORDER BY id DESC LIMIT ?",
            (thread_id, max(1, int(limit))),
        ).fetchall()
    rows.reverse()
    out: list[ChatMessage] = []
    for role, content, image in rows:
        out.append(ChatMessage(role=role, content=content, image_data_url=image))
    return out


def delete_thread(thread_id: str) -> bool:
    init_db()
    with _conn() as conn:
        cur = conn.execute("DELETE FROM threads WHERE id = ?", (thread_id,))
    return cur.rowcount > 0


__all__ = [
    "append_message",
    "create_thread",
    "delete_thread",
    "init_db",
    "load_messages",
    "thread_exists",
]
