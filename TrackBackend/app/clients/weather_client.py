#
# weather_client.py
# TrackBackend
#
# Fetches current weather conditions from the Open-Meteo API (free, no key).
# Returns a weather category ("clear" | "rain" | "snow") compatible with
# delay_model.py's WEATHER_ENCODING.
#
# Open-Meteo:
#   • Free for non-commercial use, no API key required
#   • WMO weather interpretation codes returned on the /v1/forecast endpoint
#   • Rate limit: ~10,000 requests/day (more than enough at 5-min caching)
#
# Caching: in-memory TTL cache (5 minutes).  Weather doesn't change on a
# per-request basis — one fetch per 5 min is plenty.  Falls back to "clear"
# on any error so callers are never blocked.
#

from __future__ import annotations

import time
from typing import Any

import httpx

from app.utils.logger import TrackLogger
from app.utils.metrics import WEATHER_CATEGORY, WEATHER_FETCH_TOTAL

# ── NYC coordinates (default) ────────────────────────────────────────────
_DEFAULT_LAT = 40.7128
_DEFAULT_LON = -74.0060

# ── Open-Meteo endpoint ──────────────────────────────────────────────────
_OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast"

# ── Cache ─────────────────────────────────────────────────────────────────
_CACHE_TTL = 300          # 5 minutes for successful fetches
_NEGATIVE_CACHE_TTL = 60  # 1 minute cooldown after errors (prevents 429 storms)
_cached_weather: str | None = None
_cached_details: dict[str, Any] | None = None
_cached_at: float = 0.0
_is_negative_cache: bool = False  # True when cache holds error-fallback data


# ── WMO weather code → category mapping ──────────────────────────────────
# Full table: https://open-meteo.com/en/docs
# We collapse WMO codes into the three buckets delay_model.py understands.
def _wmo_to_category(code: int) -> str:
    """Map WMO weather interpretation code to delay_model category."""
    if code in (
        71, 73, 75, 77,    # Snow fall: slight, moderate, heavy, snow grains
        85, 86,             # Snow showers: slight, heavy
    ):
        return "snow"
    if code in (
        51, 53, 55,         # Drizzle: light, moderate, dense
        56, 57,             # Freezing drizzle: light, dense
        61, 63, 65,         # Rain: slight, moderate, heavy
        66, 67,             # Freezing rain: light, heavy
        80, 81, 82,         # Rain showers: slight, moderate, violent
        95, 96, 99,         # Thunderstorm: slight/moderate, with hail
    ):
        return "rain"
    # 0=clear, 1-3=partly cloudy/overcast, 45/48=fog
    return "clear"


async def get_current_weather(
    lat: float = _DEFAULT_LAT,
    lon: float = _DEFAULT_LON,
) -> str:
    """Return current weather category for the given coordinates.

    Returns one of: "clear", "rain", "snow".
    Never raises — falls back to "clear" on any error.
    """
    global _cached_weather, _cached_details, _cached_at, _is_negative_cache

    now = time.monotonic()
    if _cached_weather is not None and (now - _cached_at) < (
        _NEGATIVE_CACHE_TTL if _is_negative_cache else _CACHE_TTL
    ):
        return _cached_weather

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                _OPEN_METEO_URL,
                params={
                    "latitude": lat,
                    "longitude": lon,
                    "current_weather": "true",
                },
            )
            resp.raise_for_status()
            data = resp.json()

        current = data.get("current_weather", {})
        wmo_code = int(current.get("weathercode", 0))
        temperature = current.get("temperature")
        windspeed = current.get("windspeed")
        is_day = bool(current.get("is_day", 1))  # Open-Meteo: 1=day, 0=night

        category = _wmo_to_category(wmo_code)

        _cached_weather = category
        _cached_details = {
            "wmo_code": wmo_code,
            "temperature_c": temperature,
            "windspeed_kmh": windspeed,
            "category": category,
            "is_day": is_day,
        }
        _cached_at = now
        _is_negative_cache = False

        # Prometheus gauge: 0=clear, 1=rain, 2=snow
        WEATHER_CATEGORY.set({"clear": 0, "rain": 1, "snow": 2}.get(category, 0))
        WEATHER_FETCH_TOTAL.labels(status="ok").inc()

        TrackLogger.info(
            f"[WEATHER] Open-Meteo: code={wmo_code} → {category} "
            f"(temp={temperature}°C, wind={windspeed} km/h)",
            tag="WEATHER",
        )
        return category

    except Exception as exc:
        WEATHER_FETCH_TOTAL.labels(status="error").inc()
        TrackLogger.warning(
            f"[WEATHER] Open-Meteo fetch failed: {exc} — defaulting to 'clear'",
            tag="WEATHER",
        )
        # ── Negative cache: store fallback so we don't hammer the API ─────
        # Use stale data if available, otherwise default to "clear".
        fallback = _cached_weather or "clear"
        _cached_weather = fallback
        if _cached_details is None:
            _cached_details = {
                "wmo_code": 0,
                "temperature_c": None,
                "windspeed_kmh": None,
                "category": fallback,
                "is_day": True,
            }
        _cached_at = now
        _is_negative_cache = True
        return fallback


def get_cached_weather_details() -> dict[str, Any] | None:
    """Return the last-fetched weather details dict, or None if never fetched.

    Useful for the /health or /admin endpoints to expose current weather state.
    """
    return _cached_details
