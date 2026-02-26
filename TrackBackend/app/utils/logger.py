#
# logger.py
# TrackBackend
#
# Production-grade logging for the Track backend.
#
# Features:
#   - Python `logging` module (not print) — proper levels, filtering, handlers
#   - Colored console output with timestamps
#   - Rotating file logs (track.log, max 5 MB × 3 backups)
#   - Structured context: request timing, feed performance, cache stats
#   - Dedicated methods for every subsystem: bus, subway, rail, alerts, cache
#
# Usage:
#   from app.utils.logger import TrackLogger
#   TrackLogger.info("message")
#   TrackLogger.bus("Route B63 resolved", route_id="B63")
#   TrackLogger.request("GET", "/nearby", 200, elapsed_ms=42.3)
#

from __future__ import annotations

import contextvars
import logging
import sys
import time
from contextlib import contextmanager
from logging.handlers import RotatingFileHandler
from pathlib import Path

from colorama import Fore, Style, init

# Initialize colorama for cross-platform color support
init(autoreset=True)

# ---------------------------------------------------------------------------
# Log directory — sits next to the project root
# ---------------------------------------------------------------------------
_LOG_DIR = Path(__file__).resolve().parent.parent.parent / "logs"
_LOG_DIR.mkdir(exist_ok=True)
_LOG_FILE = _LOG_DIR / "track.log"

# ---------------------------------------------------------------------------
# Custom formatter with colors for console
# ---------------------------------------------------------------------------

_LEVEL_COLORS = {
    "DEBUG": Fore.WHITE + Style.DIM,
    "INFO": Fore.GREEN,
    "WARNING": Fore.YELLOW,
    "ERROR": Fore.RED,
    "CRITICAL": Fore.RED + Style.BRIGHT,
}

_user_email_ctx: contextvars.ContextVar[str] = contextvars.ContextVar(
    "track_user_email", default="-"
)


class _UserEmailFilter(logging.Filter):
    """Inject request-scoped user email into every log record."""

    def filter(self, record: logging.LogRecord) -> bool:
        record.user_email = _user_email_ctx.get()
        return True


class _ColorFormatter(logging.Formatter):
    """Console formatter that adds ANSI colors to the level name."""

    def format(self, record: logging.LogRecord) -> str:
        color = _LEVEL_COLORS.get(record.levelname, "")
        reset = Style.RESET_ALL
        # Tag (subsystem) is stored in the `tag` extra field
        tag = getattr(record, "tag", "TRACK")
        user_email = getattr(record, "user_email", "-")
        ts = self.formatTime(record, "%H:%M:%S")
        msg = record.getMessage()
        # Format: 12:34:56 [INFO] [SUBWAY] [user@email] message
        return (
            f"{Fore.CYAN}{ts}{reset} "
            f"{color}[{record.levelname}]{reset} "
            f"{Fore.BLUE}[{tag}]{reset} "
            f"{Fore.MAGENTA}[{user_email}]{reset} "
            f"{msg}"
        )


class _FileFormatter(logging.Formatter):
    """Plain-text formatter for the log file — no ANSI codes."""

    def format(self, record: logging.LogRecord) -> str:
        tag = getattr(record, "tag", "TRACK")
        user_email = getattr(record, "user_email", "-")
        ts = self.formatTime(record, "%Y-%m-%d %H:%M:%S")
        return f"{ts} [{record.levelname}] [{tag}] [{user_email}] {record.getMessage()}"


# ---------------------------------------------------------------------------
# Configure the root "track" logger once at import time
# ---------------------------------------------------------------------------

_logger = logging.getLogger("track")
_logger.setLevel(logging.DEBUG)
_logger.propagate = False  # Don't duplicate to root logger

if not _logger.handlers:
    # Console handler — INFO and above (colorful)
    _console = logging.StreamHandler(sys.stdout)
    _console.setLevel(logging.DEBUG)
    _console.addFilter(_UserEmailFilter())
    _console.setFormatter(_ColorFormatter())
    _logger.addHandler(_console)

    # File handler — DEBUG and above, rotating 5 MB × 3 backups
    try:
        _file = RotatingFileHandler(
            _LOG_FILE, maxBytes=5 * 1024 * 1024, backupCount=3, encoding="utf-8",
        )
        _file.setLevel(logging.DEBUG)
        _file.addFilter(_UserEmailFilter())
        _file.setFormatter(_FileFormatter())
        _logger.addHandler(_file)
    except (OSError, PermissionError):
        # If file logging fails (e.g. Docker read-only FS), keep going
        pass


# ---------------------------------------------------------------------------
# Public API — TrackLogger
# ---------------------------------------------------------------------------


class TrackLogger:
    """Centralized logger for the Track backend.

    Every method accepts an optional ``tag`` kwarg to identify the subsystem.
    Convenience methods (``bus``, ``subway``, ``rail``, ``cache``, etc.)
    set the tag automatically.
    """

    # ------------------------------------------------------------------
    # Request-scoped user context
    # ------------------------------------------------------------------
    @staticmethod
    def set_user_email(email: str | None) -> None:
        value = (email or "-").strip() or "-"
        _user_email_ctx.set(value)

    @staticmethod
    def clear_user_email() -> None:
        _user_email_ctx.set("-")

    @staticmethod
    @contextmanager
    def user_context(email: str | None):
        """Temporarily bind a user email to logs in this context."""
        token = _user_email_ctx.set((email or "-").strip() or "-")
        try:
            yield
        finally:
            _user_email_ctx.reset(token)

    # ------------------------------------------------------------------
    # ASCII startup banner (called once from main.py)
    # ------------------------------------------------------------------
    @staticmethod
    def startup() -> None:
        try:
            import pyfiglet
            banner = pyfiglet.figlet_format("TRACK", font="slant")
            # Print banner directly for visual effect (not through logging)
            print(Fore.CYAN + Style.BRIGHT + banner + Style.RESET_ALL)
        except ImportError:
            print(Fore.CYAN + Style.BRIGHT + "=== TRACK ===" + Style.RESET_ALL)
        _logger.info("Track backend starting up", extra={"tag": "STARTUP"})
        _logger.info(f"Log file: {_LOG_FILE}", extra={"tag": "STARTUP"})

    # ------------------------------------------------------------------
    # Core levels
    # ------------------------------------------------------------------
    @staticmethod
    def debug(msg: str, *, tag: str = "TRACK") -> None:
        _logger.debug(msg, extra={"tag": tag})

    @staticmethod
    def info(msg: str, *, tag: str = "TRACK") -> None:
        _logger.info(msg, extra={"tag": tag})

    @staticmethod
    def warning(msg: str, *, tag: str = "TRACK") -> None:
        _logger.warning(msg, extra={"tag": tag})

    @staticmethod
    def error(msg: str, *, tag: str = "TRACK") -> None:
        _logger.error(msg, extra={"tag": tag})

    @staticmethod
    def critical(msg: str, *, tag: str = "TRACK") -> None:
        _logger.critical(msg, extra={"tag": tag})

    # ------------------------------------------------------------------
    # HTTP request logging (used by middleware in main.py)
    # ------------------------------------------------------------------
    @staticmethod
    def request(
        method: str,
        path: str,
        status: int,
        *,
        elapsed_ms: float | None = None,
    ) -> None:
        timing = f" ({elapsed_ms:.1f}ms)" if elapsed_ms is not None else ""
        level = logging.INFO if status < 400 else logging.WARNING if status < 500 else logging.ERROR
        _logger.log(
            level,
            f"{method} {path} → {status}{timing}",
            extra={"tag": "HTTP"},
        )

    # ------------------------------------------------------------------
    # Location logging (lat/lon for nearby endpoints)
    # ------------------------------------------------------------------
    @staticmethod
    def location(lat: float, lon: float, endpoint: str = "") -> None:
        _logger.info(
            f"lat={lat:.5f}, lon={lon:.5f} ({endpoint})",
            extra={"tag": "LOCATION"},
        )

    # ------------------------------------------------------------------
    # Subsystem-specific convenience methods
    # ------------------------------------------------------------------
    @staticmethod
    def subway(msg: str) -> None:
        _logger.info(msg, extra={"tag": "SUBWAY"})

    @staticmethod
    def bus(msg: str) -> None:
        _logger.info(msg, extra={"tag": "BUS"})

    @staticmethod
    def rail(msg: str) -> None:
        _logger.info(msg, extra={"tag": "RAIL"})

    @staticmethod
    def alerts(msg: str) -> None:
        _logger.info(msg, extra={"tag": "ALERTS"})

    @staticmethod
    def cache(msg: str) -> None:
        _logger.debug(msg, extra={"tag": "CACHE"})

    @staticmethod
    def redis(msg: str) -> None:
        """Log Redis / shared-cache activity at INFO level (visible in Render logs)."""
        _logger.info(msg, extra={"tag": "REDIS"})

    @staticmethod
    def feed(msg: str) -> None:
        """Log GTFS / SIRI feed activity."""
        _logger.debug(msg, extra={"tag": "FEED"})

    @staticmethod
    def retry(msg: str) -> None:
        """Log retry attempts for external API calls."""
        _logger.warning(msg, extra={"tag": "RETRY"})

    @staticmethod
    def circuit(msg: str) -> None:
        """Log circuit breaker state changes."""
        _logger.warning(msg, extra={"tag": "CIRCUIT"})

    @staticmethod
    def resolve(msg: str) -> None:
        """Log bus route ID resolution events."""
        _logger.debug(msg, extra={"tag": "RESOLVE"})

    @staticmethod
    def data(msg: str) -> None:
        """Log data loading / parsing events."""
        _logger.info(msg, extra={"tag": "DATA"})

    @staticmethod
    def schedule(msg: str) -> None:
        """Log schedule fallback events."""
        _logger.debug(msg, extra={"tag": "SCHEDULE"})

    @staticmethod
    def analytics(msg: str) -> None:
        """Log analytics / Supabase events."""
        _logger.debug(msg, extra={"tag": "ANALYTICS"})

    # ------------------------------------------------------------------
    # Performance timing helper
    # ------------------------------------------------------------------
    @staticmethod
    def timed(tag: str = "PERF"):
        """Context manager to measure and log elapsed time.

        Usage::

            with TrackLogger.timed("SUBWAY"):
                result = await heavy_operation()
            # Logs: [SUBWAY] Operation completed in 142.3ms
        """
        return _TimedContext(tag)


class _TimedContext:
    """Context manager for ``TrackLogger.timed()``."""

    def __init__(self, tag: str):
        self.tag = tag
        self.start = 0.0

    def __enter__(self) -> _TimedContext:
        self.start = time.perf_counter()
        return self

    def __exit__(self, *exc) -> None:  # noqa: ANN002
        elapsed = (time.perf_counter() - self.start) * 1000
        _logger.debug(f"Completed in {elapsed:.1f}ms", extra={"tag": self.tag})
