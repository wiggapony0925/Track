"""OpenAPI tag metadata and tag-level documentation helpers."""

from __future__ import annotations

OPENAPI_TAGS = [
    {
        "name": "nearby",
        "description": (
            "Primary home-screen data source. Combines subway, bus, LIRR, and Metro-North into a single ranked feed "
            "with route grouping, inline alerts, brand colors, and bus service classifications. "
            "If this tag is unhealthy, the main Track landing experience feels empty or stale."
        ),
    },
    {
        "name": "subway",
        "description": (
            "NYC Subway realtime and geometry. Powers line detail sheets, full-system map rendering, "
            "station discovery, inactive-line logic, and planner leg styling."
        ),
    },
    {
        "name": "bus",
        "description": (
            "MTA Bus realtime, route metadata, shapes, schedules, and stops. Supports nearby buses, "
            "route detail sheets, live vehicles, official bus colors, and bus map layers."
        ),
    },
    {
        "name": "lirr",
        "description": (
            "Long Island Rail Road realtime arrivals, branch shapes, and station geometry for nearby cards, "
            "branch detail sheets, and planner trip legs."
        ),
    },
    {
        "name": "mnr",
        "description": (
            "Metro-North realtime arrivals, line shapes, and station geometry for nearby cards, "
            "line detail sheets, and planner trip legs."
        ),
    },
    {
        "name": "status",
        "description": (
            "Systemwide status surfaces: service alerts, worst-per-route status, and elevator/escalator outages. "
            "These endpoints explain why arrivals or trips may be impacted."
        ),
    },
    {
        "name": "predict",
        "description": (
            "ML delay prediction and operational model controls. Used to turn raw upstream ETAs into smarter, "
            "context-aware countdowns in the UI."
        ),
    },
    {
        "name": "weather",
        "description": (
            "Server-side weather fallback from Open-Meteo. Supports simulator/dev environments where WeatherKit "
            "is unavailable and feeds delay-model context."
        ),
    },
    {
        "name": "engine",
        "description": (
            "Track planning platform: saved places, recent trips, recommendations, calendar context, trip planning, "
            "and live Go-session assembly. This tag underpins the planning tab and commute workflows."
        ),
    },
    {
        "name": "system",
        "description": (
            "Operational diagnostics, configuration, warmup state, GTFS health, and cache administration. "
            "Admin endpoints (`/admin/*`) are restricted to localhost."
        ),
    },
]

_TAG_UI_GUIDE: list[tuple[str, str, str, str]] = [
    (
        "nearby",
        "Home tab, nearby cards, inactive lines",
        "`/nearby/grouped` first, `/nearby/inactive` second",
        "Empty or stale home experience",
    ),
    (
        "subway",
        "Subway maps, line sheets, station discovery",
        "Use `shapes/all` + `stations/all` for full-map flows; single-line endpoints for drill-down",
        "Maps may render without live countdown confidence",
    ),
    (
        "bus",
        "Nearby buses, route browser, route map, vehicle map",
        "Use route metadata endpoints before stop/vehicle drill-down endpoints",
        "Bus discovery and live vehicles degrade first",
    ),
    (
        "lirr",
        "Commuter rail nearby cards and branch detail",
        "Use `shapes/all` for system views, `/lirr` for live arrival lists",
        "Realtime falls back to static schedule context",
    ),
    (
        "mnr",
        "Commuter rail nearby cards and line detail",
        "Use `shapes/all` for system views, `/mnr` for live arrival lists",
        "Realtime falls back to static schedule context",
    ),
    (
        "status",
        "Alerts view, inline disruption pills, accessibility context",
        "Use alerts to explain realtime anomalies, not as the only source of truth for arrivals",
        "Riders lose disruption context before raw countdowns disappear",
    ),
    (
        "predict",
        "Adjusted ETAs and debug/admin model operations",
        "Safe for per-arrival usage; intended as a refinement layer over raw upstream ETAs",
        "Countdowns remain available but become less context-aware",
    ),
    (
        "weather",
        "Simulator/dev fallback weather and diagnostics",
        "Treat as backend fallback, not a full weather product surface",
        "Prediction context loses weather input",
    ),
    (
        "engine",
        "Planner tab, smart recommendations, Go mode",
        "Use saved place/trip endpoints for persistence, `plan` for route search, `go` for active guidance",
        "Planning workflows degrade independently from nearby arrivals",
    ),
    (
        "system",
        "Ops, deploy validation, cache/admin diagnostics",
        "Use for debugging and deployment health, not normal app rendering",
        "Operational visibility is reduced",
    ),
]


def render_tag_matrix() -> str:
    """Return a markdown table mapping tags to product surfaces."""
    lines = [
        "| Tag | Primary app surfaces | Recommended usage | Failure symptom |",
        "|-----|----------------------|-------------------|-----------------|",
    ]
    for tag, surfaces, usage, symptom in _TAG_UI_GUIDE:
        lines.append(f"| `{tag}` | {surfaces} | {usage} | {symptom} |")
    return "\n".join(lines)
