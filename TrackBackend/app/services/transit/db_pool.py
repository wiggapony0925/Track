"""Shared aiosqlite connection pool for transit_schedule.db.

Instead of opening/closing a fresh SQLite connection (and background thread)
for every query, we maintain a pool of pre-opened ``aiosqlite.Connection``
objects.  Callers acquire a connection, use it, and release it back — the
same way httpx connection pooling works for HTTP.

Usage::

    from app.services.transit.db_pool import schedule_pool

    async with schedule_pool.acquire() as conn:
        cursor = await conn.execute("SELECT ...")
        rows = await cursor.fetchall()

The pool is initialized via ``schedule_pool.open()`` at app startup and
closed via ``schedule_pool.close()`` at shutdown.  If the pool hasn't been
opened yet, ``acquire()`` falls back to a one-off connection so that tests
and scripts still work without explicit lifecycle management.
"""

from __future__ import annotations

import asyncio
import contextlib
from pathlib import Path
from typing import AsyncIterator

import aiosqlite

from app.utils.logger import TrackLogger

# Default DB path — same as schedule_service.py
_DEFAULT_DB = Path("app/data/transit_schedule.db")

# Pool sizing: aiosqlite wraps each connection in its own background thread.
# 8 connections ≈ 8 threads — enough to serve 50+ concurrent gather() calls
# without the overhead of opening/closing 50 connections per request.
_DEFAULT_POOL_SIZE = 8


class ScheduleDBPool:
    """Async connection pool for the GTFS schedule SQLite database.

    Internally uses an ``asyncio.Queue`` as a semaphore + object store.
    Connections are pre-opened at ``open()`` time and recycled on release.
    """

    def __init__(
        self,
        db_path: Path = _DEFAULT_DB,
        pool_size: int = _DEFAULT_POOL_SIZE,
    ):
        self._db_path = db_path
        self._pool_size = pool_size
        self._pool: asyncio.Queue[aiosqlite.Connection] | None = None
        self._connections: list[aiosqlite.Connection] = []
        self._opened = False

    @property
    def is_open(self) -> bool:
        return self._opened

    @property
    def size(self) -> int:
        return self._pool_size

    @property
    def available(self) -> int:
        """Number of idle connections currently in the pool."""
        if self._pool is None:
            return 0
        return self._pool.qsize()

    async def open(self) -> None:
        """Pre-open ``pool_size`` aiosqlite connections and place them in the queue."""
        if self._opened:
            return

        if not self._db_path.exists():
            TrackLogger.warning(
                f"[DB_POOL] DB not found at {self._db_path} — pool will not open",
                tag="DB_POOL",
            )
            return

        self._pool = asyncio.Queue(maxsize=self._pool_size)
        self._connections = []

        for i in range(self._pool_size):
            try:
                conn = await aiosqlite.connect(
                    str(self._db_path),
                    timeout=30,
                )
                conn.row_factory = aiosqlite.Row
                # Enable WAL mode for better concurrent read performance
                await conn.execute("PRAGMA journal_mode=WAL")
                await conn.execute("PRAGMA read_uncommitted=1")
                self._connections.append(conn)
                await self._pool.put(conn)
            except Exception as exc:
                TrackLogger.error(
                    f"[DB_POOL] Failed to open connection {i}: {exc}",
                    tag="DB_POOL",
                )
                break

        self._opened = True
        TrackLogger.info(
            f"[DB_POOL] Opened {len(self._connections)} connections "
            f"to {self._db_path.name}",
            tag="DB_POOL",
        )

    async def close(self) -> None:
        """Close all pooled connections."""
        if not self._opened:
            return

        for conn in self._connections:
            with contextlib.suppress(Exception):
                await conn.close()

        self._connections.clear()
        self._pool = None
        self._opened = False
        TrackLogger.info("[DB_POOL] All connections closed", tag="DB_POOL")

    @contextlib.asynccontextmanager
    async def acquire(self) -> AsyncIterator[aiosqlite.Connection]:
        """Borrow a connection from the pool.

        If the pool hasn't been opened yet (e.g. in tests), falls back to a
        one-off connection that is closed when the context manager exits.
        """
        if not self._opened or self._pool is None:
            # Fallback: open a standalone connection (backward-compatible)
            conn = await aiosqlite.connect(str(self._db_path), timeout=30)
            conn.row_factory = aiosqlite.Row
            try:
                yield conn
            finally:
                await conn.close()
            return

        # Borrow from pool (blocks if all connections are in use)
        conn = await self._pool.get()
        try:
            yield conn
        except Exception:
            # If the connection errored, try to validate or replace it
            try:
                await conn.execute("SELECT 1")
            except Exception:
                # Connection is broken — create a replacement
                with contextlib.suppress(Exception):
                    await conn.close()
                try:
                    new_conn = await aiosqlite.connect(
                        str(self._db_path), timeout=30
                    )
                    new_conn.row_factory = aiosqlite.Row
                    await new_conn.execute("PRAGMA journal_mode=WAL")
                    await new_conn.execute("PRAGMA read_uncommitted=1")
                    # Replace in tracking list
                    idx = self._connections.index(conn)
                    self._connections[idx] = new_conn
                    conn = new_conn
                except Exception as replace_exc:
                    TrackLogger.error(
                        f"[DB_POOL] Failed to replace broken connection: {replace_exc}",
                        tag="DB_POOL",
                    )
            raise
        finally:
            await self._pool.put(conn)


# Module-level singleton
schedule_pool = ScheduleDBPool()
