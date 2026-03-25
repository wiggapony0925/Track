#
# logger.py
# TrackBackend
#
# Production-grade logging for the Track backend.
#
# Features:
#   - Python `logging` module (not print) — proper levels, filtering, handlers
#   - Colored console output for local dev
#   - JSON structured output on Render (machine-parseable for Better Stack)
#   - Rotating file logs in local dev (track.log, 5 MB × 3 backups)
#   - Configurable log level via LOG_LEVEL env var (default: INFO on Render, DEBUG local)
#   - Structured context: request timing, feed performance, cache stats
#   - Full stack traces on error/warning via exc_info support
#   - Dedicated methods for every subsystem: bus, subway, rail, alerts, cache,
#     ML (model load · per-prediction · cache hits), perf
#
# Usage:
#   from app.utils.logger import TrackLogger
#   TrackLogger.info("message")
#   TrackLogger.error("something broke", exc_info=True)
#   TrackLogger.ml("[MODEL] LightGBM loaded — 176 trees")
#   TrackLogger.request("GET", "/nearby", 200, elapsed_ms=42.3)
#

from __future__ import annotations

import contextvars
import json as _json
import logging
import os
import sys
import time
import traceback as _tb
from contextlib import contextmanager
from logging.handlers import RotatingFileHandler
from pathlib import Path

from colorama import Fore, Style, init

# Initialize colorama for cross-platform color support
init(autoreset=True)

# ---------------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------------
_ON_RENDER = bool(os.environ.get("RENDER"))
_LOG_LEVEL_STR = os.environ.get("LOG_LEVEL", "INFO" if _ON_RENDER else "DEBUG").upper()
_LOG_LEVEL = getattr(logging, _LOG_LEVEL_STR, logging.INFO)

# ---------------------------------------------------------------------------
# Log directory — only used in local dev (Render reads stdout)
# ---------------------------------------------------------------------------
_LOG_DIR = Path(__file__).resolve().parent.parent.parent / "logs"
_LOG_FILE = _LOG_DIR / "track.log"

# ---------------------------------------------------------------------------
# Custom formatters
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
_request_id_ctx: contextvars.ContextVar[str] = contextvars.ContextVar(
    "track_request_id", default="-"
)


class _UserEmailFilter(logging.Filter):
    """Inject request-scoped user email and Rndr-Id into every log record."""

    def filter(self, record: logging.LogRecord) -> bool:
        record.user_email = _user_email_ctx.get()
        record.request_id = _request_id_ctx.get()
        return True


class _ColorFormatter(logging.Formatter):
    """Console formatter that adds ANSI colors — used in local dev."""

    def format(self, record: logging.LogRecord) -> str:
        color = _LEVEL_COLORS.get(record.levelname, "")
        reset = Style.RESET_ALL
        tag = getattr(record, "tag", "TRACK")
        user_email = getattr(record, "user_email", "-")
        ts = self.formatTime(record, "%H:%M:%S")
        msg = record.getMessage()
        request_id = getattr(record, "request_id", "-")
        rid = f" {Fore.YELLOW}[{request_id}]{reset}" if request_id != "-" else ""
        line = (
            f"{Fore.CYAN}{ts}{reset} "
            f"{color}[{record.levelname}]{reset} "
            f"{Fore.BLUE}[{tag}]{reset} "
            f"{Fore.MAGENTA}[{user_email}]{reset}"
            f"{rid} "
            f"{msg}"
        )
        # Append traceback if present (exc_info was set)
        if record.exc_info and record.exc_info[1] is not None:
            line += "\n" + self.formatException(record.exc_info)
        return line


class _JSONFormatter(logging.Formatter):
    """Structured JSON formatter for Render / Better Stack / log aggregators.

    Each log line is a single JSON object — easy to filter by tag, level,
    request_id, or user in any log dashboard.
    """

    def format(self, record: logging.LogRecord) -> str:
        tag = getattr(record, "tag", "TRACK")
        user_email = getattr(record, "user_email", "-")
        request_id = getattr(record, "request_id", "-")
        payload: dict = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S")
            + f".{int(record.msecs):03d}Z",
            "level": record.levelname,
            "tag": tag,
            "msg": record.getMessage(),
        }
        if user_email != "-":
            payload["user"] = user_email
        if request_id != "-":
            payload["rndr_id"] = request_id
        # Include stack trace for errors
        if record.exc_info and record.exc_info[1] is not None:
            payload["exc"] = self.formatException(record.exc_info)
        return _json.dumps(payload, default=str)


class _FileFormatter(logging.Formatter):
    """Plain-text formatter for the rotating log file — no ANSI codes."""

    def format(self, record: logging.LogRecord) -> str:
        tag = getattr(record, "tag", "TRACK")
        user_email = getattr(record, "user_email", "-")
        request_id = getattr(record, "request_id", "-")
        ts = self.formatTime(record, "%Y-%m-%d %H:%M:%S")
        ms = f".{int(record.msecs):03d}"
        line = f"{ts}{ms} [{record.levelname}] [{tag}] [{user_email}] [{request_id}] {record.getMessage()}"
        if record.exc_info and record.exc_info[1] is not None:
            line += "\n" + self.formatException(record.exc_info)
        return line


# ---------------------------------------------------------------------------
# Configure the "track" logger once at import time
# ---------------------------------------------------------------------------

_logger = logging.getLogger("track")
_logger.setLevel(logging.DEBUG)  # handlers filter; logger captures everything
_logger.propagate = False

if not _logger.handlers:
    _ctx_filter = _UserEmailFilter()

    # ── Console / stdout handler ──────────────────────────────────────
    _console = logging.StreamHandler(sys.stdout)
    _console.setLevel(_LOG_LEVEL)
    _console.addFilter(_ctx_filter)

    if _ON_RENDER:
        # Structured JSON on Render — one JSON object per line
        _console.setFormatter(_JSONFormatter())
    else:
        # Colorful human-readable locally
        _console.setFormatter(_ColorFormatter())

    _logger.addHandler(_console)

    # ── File handler (local dev only) ─────────────────────────────────
    if not _ON_RENDER:
        try:
            _LOG_DIR.mkdir(exist_ok=True)
            _file = RotatingFileHandler(
                _LOG_FILE,
                maxBytes=5 * 1024 * 1024,
                backupCount=3,
                encoding="utf-8",
            )
            _file.setLevel(logging.DEBUG)
            _file.addFilter(_ctx_filter)
            _file.setFormatter(_FileFormatter())
            _logger.addHandler(_file)
        except (OSError, PermissionError):
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
    # Request-scoped Render request ID (from Rndr-Id header)
    # ------------------------------------------------------------------
    @staticmethod
    def set_request_id(request_id: str | None) -> None:
        """Bind the Render Rndr-Id header value to all logs for this request."""
        _request_id_ctx.set((request_id or "-").strip() or "-")

    @staticmethod
    def clear_request_id() -> None:
        _request_id_ctx.set("-")

    # ------------------------------------------------------------------
    # ASCII startup banner (called once from main.py)
    # ------------------------------------------------------------------
    @staticmethod
    def startup() -> None:
        import os
        try:
            import pyfiglet
            banner = pyfiglet.figlet_format("TRACK", font="slant")
            # Print banner directly for visual effect (not through logging)
            print(Fore.CYAN + Style.BRIGHT + banner + Style.RESET_ALL)
        except ImportError:
            print(Fore.CYAN + Style.BRIGHT + "=== TRACK ===" + Style.RESET_ALL)
        _logger.info("Track backend starting up", extra={"tag": "STARTUP"})
        _logger.info(f"Log file: {_LOG_FILE}", extra={"tag": "STARTUP"})

        # ── Key feature flags ────────────────────────────────────────────
        ml_raw = os.environ.get("ARRIVING_PREDICTION_MODEL", "true")
        ml_on = ml_raw.strip().lower() not in ("false", "0", "off", "no", "disabled")
        ml_label = f"{'ENABLED' if ml_on else '*** DISABLED ***'} (ARRIVING_PREDICTION_MODEL={ml_raw})"
        _logger.info(f"[STARTUP] ML prediction model: {ml_label}", extra={"tag": "STARTUP"})

        env_name = os.environ.get("RENDER_SERVICE_NAME", os.environ.get("ENV", "local"))
        _logger.info(f"[STARTUP] Environment: {env_name}", extra={"tag": "STARTUP"})

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
    def warning(msg: str, *, tag: str = "TRACK", exc_info: bool = False) -> None:
        _logger.warning(msg, extra={"tag": tag}, exc_info=exc_info)

    @staticmethod
    def error(msg: str, *, tag: str = "TRACK", exc_info: bool = False) -> None:
        _logger.error(msg, extra={"tag": tag}, exc_info=exc_info)

    @staticmethod
    def critical(msg: str, *, tag: str = "TRACK", exc_info: bool = False) -> None:
        _logger.critical(msg, extra={"tag": tag}, exc_info=exc_info)

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

        # Render health-check probes hit "/" which returns 404 — expected noise.
        # /health returns 503 during warmup — also expected; don't log as ERROR.
        _path = path.split("?")[0]
        if _path == "/" and status == 404:
            return  # suppress Render probe noise entirely
        if _path == "/health" and status == 503:
            level = logging.INFO  # warmup 503 is expected
        else:
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
        _logger.info(msg, extra={"tag": "RETRY"})

    @staticmethod
    def circuit(msg: str) -> None:
        """Log circuit breaker state changes."""
        _logger.info(msg, extra={"tag": "CIRCUIT"})

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

    @staticmethod
    def ml(msg: str) -> None:
        """Log ML model events (load, reload, feature encoding, predictions) at INFO."""
        _logger.info(msg, extra={"tag": "ML"})

    @staticmethod
    def prediction(
        *,
        route_id: str,
        minutes_away: int,
        adjusted: int,
        factor: float,
        source: str,
        recency_s: float = 0.0,
        stop_id: str | None = None,
        mode: str = "subway",
    ) -> None:
        """Structured per-prediction log — emits at DEBUG to avoid log spam.

        Use ``TrackLogger.ml()`` for INFO-level model lifecycle events, and
        this for per-request prediction detail visible at DEBUG level:

            TrackLogger.prediction(
                route_id="7", minutes_away=5, adjusted=6,
                factor=1.10, source="model", recency_s=45.0, stop_id="127N",
            )
        """
        _logger.debug(
            f"[PREDICT] {route_id}/{mode} {minutes_away}min"
            f" → {adjusted}min | factor={factor:.3f}"
            f" recency={recency_s:+.0f}s src={source}"
            + (f" stop={stop_id}" if stop_id else ""),
            extra={"tag": "ML"},
        )

    @staticmethod
    def model_event(msg: str, *, level: str = "info") -> None:
        """Log significant model lifecycle events (load, reload, fallback, flag).

        Always visible in Render logs regardless of log level filter.
        Use ``level='warning'`` when falling back to heuristic.
        """
        fn = getattr(_logger, level, _logger.info)
        fn(f"[MODEL] {msg}", extra={"tag": "ML"})

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
