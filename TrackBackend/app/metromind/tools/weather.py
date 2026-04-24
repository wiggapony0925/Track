"""Tool: ``get_weather`` — current NYC weather for transit decisions.

Uses the free, no-API-key `Open-Meteo <https://open-meteo.com>`_ forecast
endpoint. The model uses this to make smarter recommendations:

* "should I bike to work?" → check wind + precip
* "is it bad outside?" → temp + condition
* "is it gonna rain on me waiting for the bus?" → next-hour precip

Falls back to NYC City Hall coords if the user has no location.
"""

from __future__ import annotations

import json
from typing import Any

import httpx

from app.metromind.logger import get_logger
from app.metromind.schemas import UserContext

from .base import ToolError, ToolResult

logger = get_logger("tools.weather")


_API = "https://api.open-meteo.com/v1/forecast"
_DEFAULT_LAT = 40.7128
_DEFAULT_LON = -74.0060
_TIMEOUT = httpx.Timeout(connect=4.0, read=6.0, write=4.0, pool=4.0)


# Open-Meteo WMO weather code → human label.
_WMO: dict[int, str] = {
    0: "clear",
    1: "mostly clear", 2: "partly cloudy", 3: "overcast",
    45: "fog", 48: "freezing fog",
    51: "light drizzle", 53: "drizzle", 55: "heavy drizzle",
    56: "light freezing drizzle", 57: "freezing drizzle",
    61: "light rain", 63: "rain", 65: "heavy rain",
    66: "light freezing rain", 67: "freezing rain",
    71: "light snow", 73: "snow", 75: "heavy snow",
    77: "snow grains",
    80: "light rain showers", 81: "rain showers", 82: "violent rain showers",
    85: "snow showers", 86: "heavy snow showers",
    95: "thunderstorm", 96: "thunderstorm with hail", 99: "severe thunderstorm",
}


SCHEMA: dict[str, Any] = {
    "name": "get_weather",
    "description": (
        "Get current NYC weather + next-hour outlook (temperature, "
        "conditions, precipitation, wind). Use this whenever weather "
        "would change a transit recommendation: should I bike, is it "
        "raining at the bus stop, will it be bad on the platform, etc. "
        "Defaults to the user's bias point or GPS location."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "lat": {"type": "number", "description": "Override latitude."},
            "lon": {"type": "number", "description": "Override longitude."},
        },
        "additionalProperties": False,
    },
}


def _resolve_coords(
    arguments: dict[str, Any], context: UserContext | None
) -> tuple[float, float]:
    lat = arguments.get("lat")
    lon = arguments.get("lon")
    if lat is not None and lon is not None:
        return float(lat), float(lon)
    if context is not None:
        if context.bias_lat is not None and context.bias_lon is not None:
            return context.bias_lat, context.bias_lon
        if context.lat is not None and context.lon is not None:
            return context.lat, context.lon
    return _DEFAULT_LAT, _DEFAULT_LON


async def run(arguments: dict[str, Any], context: UserContext | None) -> ToolResult:
    lat, lon = _resolve_coords(arguments, context)

    params = {
        "latitude": f"{lat:.4f}",
        "longitude": f"{lon:.4f}",
        "current": (
            "temperature_2m,apparent_temperature,precipitation,weather_code,"
            "wind_speed_10m,relative_humidity_2m"
        ),
        "hourly": "precipitation_probability,precipitation,temperature_2m",
        "forecast_hours": 3,
        "temperature_unit": "fahrenheit",
        "wind_speed_unit": "mph",
        "precipitation_unit": "inch",
        "timezone": "America/New_York",
    }

    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            r = await client.get(_API, params=params)
            r.raise_for_status()
            data = r.json()
    except httpx.HTTPError as exc:
        logger.warning("Weather lookup failed: %s", exc)
        raise ToolError(
            "Couldn't reach the weather service right now. "
            "Tell the user the weather lookup is temporarily unavailable."
        ) from exc

    cur = data.get("current") or {}
    hourly = data.get("hourly") or {}
    code = cur.get("weather_code")
    condition = _WMO.get(int(code), "unknown") if isinstance(code, (int, float)) else "unknown"

    next_hour_pop: int | None = None
    next_hour_precip_in: float | None = None
    pops = hourly.get("precipitation_probability") or []
    precs = hourly.get("precipitation") or []
    if pops:
        try:
            next_hour_pop = int(pops[0])
        except (TypeError, ValueError):
            pass
    if precs:
        try:
            next_hour_precip_in = float(precs[0])
        except (TypeError, ValueError):
            pass

    payload = {
        "location": {"lat": lat, "lon": lon},
        "current": {
            "temperature_f": cur.get("temperature_2m"),
            "feels_like_f": cur.get("apparent_temperature"),
            "humidity_pct": cur.get("relative_humidity_2m"),
            "wind_mph": cur.get("wind_speed_10m"),
            "precipitation_in": cur.get("precipitation"),
            "condition": condition,
            "weather_code": code,
        },
        "next_hour": {
            "precip_probability_pct": next_hour_pop,
            "precip_inches": next_hour_precip_in,
        },
        "source": "open-meteo",
    }
    return ToolResult(
        name="get_weather",
        content=json.dumps(payload),
        ok=True,
        ui_label="Checking the weather",
    )
