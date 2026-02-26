#
# cache_stats.py
# TrackBackend
#
# Shared, transport-agnostic cache operation counters.
#
# Any service layer (bus Redis, mta in-process TTL, etc.) imports this module
# and calls the three public helpers:
#
#   bucket(kind)  → returns the KindStats slot for that cache "kind"
#   tick()        → increments the pending-ops counter; auto-flushes at INTERVAL
#   flush()       → emits the stats snapshot immediately (also called on shutdown)
#
# "kind" is a short string identifying the cache layer, e.g.:
#   "bus.stop_arrivals", "bus.route_stops", "mta.feed"
#
# Stats are printed at INFO level via TrackLogger.redis() so they appear in
# Render logs alongside other operational output without per-request noise.
#

from __future__ import annotations

# ---------------------------------------------------------------------------
# Interval
# ---------------------------------------------------------------------------

STATS_INTERVAL: int = 100  # flush a summary every N total ops across all kinds


# ---------------------------------------------------------------------------
# Per-kind counter bucket
# ---------------------------------------------------------------------------

class KindStats:
    """Lightweight counter for one cache "kind"."""

    __slots__ = ("fresh", "stale", "miss", "sets", "errors", "_first_set_logged")

    def __init__(self) -> None:
        self.fresh: int = 0   # GET → found, within TTL (cache hit)
        self.stale: int = 0   # GET → found but expired / served-stale
        self.miss: int = 0    # GET → not found at all
        self.sets: int = 0    # SET (write / populate)
        self.errors: int = 0  # I/O or serialisation error
        self._first_set_logged: bool = False  # one-time first-write log per kind

    @property
    def total_gets(self) -> int:
        return self.fresh + self.stale + self.miss

    @property
    def hit_pct(self) -> float:
        tg = self.total_gets
        return (self.fresh + self.stale) / tg * 100 if tg else 0.0


# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------

_stats: dict[str, KindStats] = {}
_pending: int = 0   # ops since last summary flush


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def bucket(kind: str) -> KindStats:
    """Return (lazily creating) the stats bucket for *kind*."""
    if kind not in _stats:
        _stats[kind] = KindStats()
    return _stats[kind]


def tick() -> None:
    """Increment pending counter; auto-flush stats when STATS_INTERVAL is hit."""
    global _pending
    _pending += 1
    if _pending >= STATS_INTERVAL:
        flush()


def flush() -> None:
    """Emit a one-line-per-kind summary at INFO level via TrackLogger.redis().

    Resets the pending counter.  Safe to call with no data — exits silently.
    """
    global _pending
    _pending = 0
    if not _stats:
        return

    # Import here to avoid a circular import at module load time.
    from app.utils.logger import TrackLogger  # noqa: PLC0415

    lines = ["[CACHE STATS] ── activity snapshot ──────────────────────"]
    for kind, s in sorted(_stats.items()):
        err_suffix = f"  errors={s.errors}" if s.errors else ""
        lines.append(
            f"  {kind:<26}  gets={s.total_gets:5d}  "
            f"fresh={s.fresh:5d}  stale={s.stale:5d}  "
            f"miss={s.miss:5d}  sets={s.sets:5d}  "
            f"hit%={s.hit_pct:5.1f}%{err_suffix}"
        )
    lines.append("─" * 64)
    TrackLogger.redis("\n".join(lines))
