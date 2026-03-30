#
# weather.py
# TrackBackend
#
# Lightweight endpoint that exposes the cached Open-Meteo weather for the
# iOS app to use as a fallback when WeatherKit is unavailable (e.g. in the
# Simulator where Apple's JWT authenticator fails).
#
# Returns temperature, WMO code, SF Symbol name, condition description, and
# the delay-model category ("clear" / "rain" / "snow").
#

from __future__ import annotations

from fastapi import APIRouter, Query

from app.clients.weather_client import get_current_weather, get_cached_weather_details

router = APIRouter(tags=["weather"])


# ── WMO code → SF Symbol mapping ─────────────────────────────────────────
# Maps Open-Meteo WMO weather interpretation codes to Apple SF Symbol names.
# These are the same multicolor symbols WeatherKit returns on real devices.
# Full WMO table: https://open-meteo.com/en/docs
#
# Each entry: (day_symbol, night_symbol, description)
# Night variants use moon-based symbols for clear/partly cloudy conditions;
# precipitation and overcast symbols are the same day and night.
_WMO_TO_SYMBOL: dict[int, tuple[str, str, str]] = {
    # (SF Symbol day, SF Symbol night, human-readable description)
    0:  ("sun.max.fill",         "moon.stars.fill",       "Clear sky"),
    1:  ("sun.min.fill",         "moon.fill",             "Mainly clear"),
    2:  ("cloud.sun.fill",       "cloud.moon.fill",       "Partly cloudy"),
    3:  ("cloud.fill",           "cloud.fill",            "Overcast"),
    45: ("cloud.fog.fill",       "cloud.fog.fill",        "Fog"),
    48: ("cloud.fog.fill",       "cloud.fog.fill",        "Depositing rime fog"),
    51: ("cloud.drizzle.fill",   "cloud.drizzle.fill",    "Light drizzle"),
    53: ("cloud.drizzle.fill",   "cloud.drizzle.fill",    "Moderate drizzle"),
    55: ("cloud.drizzle.fill",   "cloud.drizzle.fill",    "Dense drizzle"),
    56: ("cloud.sleet.fill",     "cloud.sleet.fill",      "Light freezing drizzle"),
    57: ("cloud.sleet.fill",     "cloud.sleet.fill",      "Dense freezing drizzle"),
    61: ("cloud.rain.fill",      "cloud.rain.fill",       "Slight rain"),
    63: ("cloud.rain.fill",      "cloud.rain.fill",       "Moderate rain"),
    65: ("cloud.heavyrain.fill", "cloud.heavyrain.fill",  "Heavy rain"),
    66: ("cloud.sleet.fill",     "cloud.sleet.fill",      "Light freezing rain"),
    67: ("cloud.sleet.fill",     "cloud.sleet.fill",      "Heavy freezing rain"),
    71: ("cloud.snow.fill",      "cloud.snow.fill",       "Slight snow fall"),
    73: ("cloud.snow.fill",      "cloud.snow.fill",       "Moderate snow fall"),
    75: ("cloud.snow.fill",      "cloud.snow.fill",       "Heavy snow fall"),
    77: ("cloud.snow.fill",      "cloud.snow.fill",       "Snow grains"),
    80: ("cloud.rain.fill",      "cloud.rain.fill",       "Slight rain showers"),
    81: ("cloud.rain.fill",      "cloud.rain.fill",       "Moderate rain showers"),
    82: ("cloud.heavyrain.fill", "cloud.heavyrain.fill",  "Violent rain showers"),
    85: ("cloud.snow.fill",      "cloud.snow.fill",       "Slight snow showers"),
    86: ("cloud.snow.fill",      "cloud.snow.fill",       "Heavy snow showers"),
    95: ("cloud.bolt.rain.fill", "cloud.bolt.rain.fill",  "Thunderstorm"),
    96: ("cloud.bolt.rain.fill", "cloud.bolt.rain.fill",  "Thunderstorm with slight hail"),
    99: ("cloud.bolt.rain.fill", "cloud.bolt.rain.fill",  "Thunderstorm with heavy hail"),
}

_DEFAULT_SYMBOL = ("cloud.fill", "cloud.fill", "Unknown")


@router.get(
    "/weather",
    summary="Get current weather",
    description="Returns current weather conditions from Open-Meteo, including temperature, SF Symbol name, and WMO code.",
)
async def get_weather(
    lat: float = Query(40.7128, description="Latitude. Defaults to NYC.", examples=[40.7128]),
    lon: float = Query(-74.006, description="Longitude. Defaults to NYC.", examples=[-74.006]),
) -> dict:
    """Return current weather conditions.

    Response includes:
    - `temperature_c` / `temperature_f` — current temperature
    - `wmo_code` — WMO weather interpretation code
    - `symbol` — Apple SF Symbol name (day/night aware)
    - `description` — human-readable condition (e.g. "Partly cloudy")
    - `category` — simplified category (`clear`, `rain`, `snow`)
    - `windspeed_kmh` — current wind speed
    - `is_day` — whether it's currently daytime

    Uses a 5-minute cache internally. Serves as a fallback for Apple WeatherKit.
    """
    # Trigger a fetch (uses 5-min cache / 1-min negative cache internally)
    category = await get_current_weather(lat=lat, lon=lon)
    details = get_cached_weather_details()

    # Build response from cached details (may be error-fallback data)
    wmo_code = details.get("wmo_code", 0) if details else 0
    temp_c = details.get("temperature_c") if details else None
    temp_f = round(temp_c * 9 / 5 + 32) if temp_c is not None else None
    windspeed = details.get("windspeed_kmh") if details else None
    is_day = details.get("is_day", True) if details else True

    day_symbol, night_symbol, description = _WMO_TO_SYMBOL.get(wmo_code, _DEFAULT_SYMBOL)
    symbol = day_symbol if is_day else night_symbol

    return {
        "temperature_c": temp_c,
        "temperature_f": temp_f,
        "wmo_code": wmo_code,
        "symbol": symbol,
        "description": description,
        "category": category,
        "windspeed_kmh": windspeed,
        "is_day": is_day,
    }
