"""Upstream URL documentation tables rendered into the OpenAPI overview."""

from __future__ import annotations

from app.config import Settings

_URL_DOCS: dict[str, tuple[str, str, str]] = {
    "subway_ace": (
        "Live A/C/E train trip updates.",
        "Home nearby cards, line detail sheets, planner live status.",
        "A/C/E arrivals go stale or fall back to cache/schedule data.",
    ),
    "subway_g": (
        "Live G train trip updates.",
        "Nearby cards and G route detail.",
        "G realtime countdowns degrade to cached/scheduled data.",
    ),
    "subway_nqrw": (
        "Live N/Q/R/W trip updates.",
        "Nearby cards, route sheets, planner matching.",
        "N/Q/R/W countdown accuracy drops.",
    ),
    "subway_123456": (
        "Live 1/2/3/4/5/6/7 feed family updates.",
        "Highest-traffic subway lines on home and line detail views.",
        "Numbered-line countdown chips become stale or schedule-only.",
    ),
    "subway_bdfm": (
        "Live B/D/F/M trip updates.",
        "Nearby cards and route sheets.",
        "B/D/F/M realtime degrades.",
    ),
    "subway_jz": (
        "Live J/Z trip updates.",
        "Nearby and route detail.",
        "J/Z arrivals degrade.",
    ),
    "subway_l": (
        "Live L trip updates.",
        "Nearby and route detail.",
        "L countdowns degrade.",
    ),
    "subway_si": (
        "Live Staten Island Railway updates.",
        "Nearby and route detail where applicable.",
        "SI realtime degrades.",
    ),
    "lirr": (
        "Live LIRR arrivals and trip status.",
        "Nearby cards, branch detail, planner leg status.",
        "LIRR falls back to cached or static schedule context.",
    ),
    "metro_north": (
        "Live Metro-North arrivals and trip status.",
        "Nearby cards, line detail, planner leg status.",
        "Metro-North falls back to cached or static schedule context.",
    ),
    "alerts_json": (
        "Current subway disruptions and planned work.",
        "Inline home alerts, route badges, status views.",
        "Subway routes lose active alert context.",
    ),
    "bus_alerts_json": (
        "Current bus disruptions.",
        "Nearby bus cards and bus status context.",
        "Bus routes lose alert context.",
    ),
    "lirr_alerts_json": (
        "Current LIRR disruptions.",
        "LIRR cards and status context.",
        "LIRR alert banners disappear.",
    ),
    "mnr_alerts_json": (
        "Current Metro-North disruptions.",
        "Metro-North cards and status context.",
        "MNR alert banners disappear.",
    ),
    "elevators_json": (
        "Elevator and escalator outage list.",
        "Accessibility screen and station outage context.",
        "Accessibility data becomes stale until refresh succeeds.",
    ),
    "bus_siri_base": (
        "Base host for SIRI live bus endpoints.",
        "Nearby buses, live arrivals, vehicle maps.",
        "Live bus monitoring requests cannot be composed.",
    ),
    "bus_oba_base": (
        "Base host for OBA route and stop metadata endpoints.",
        "Bus route browser, stop discovery, route detail metadata.",
        "Bus metadata requests cannot be composed.",
    ),
    "mta_colors_api": (
        "Sync official subway/LIRR/MNR colors into brand config.",
        "Route badges, map lines, timeline chips.",
        "Brand sync stops updating; existing local colors remain.",
    ),
    "open_meteo_api": (
        "Fetch current weather for prediction context and fallback weather endpoint.",
        "Weather fallback and prediction context.",
        "Weather endpoint degrades and predictions lose weather signal.",
    ),
    "track_engine_internal_url": (
        "Reach the internal TrackEngine service.",
        "Planner results, Go mode, destination intelligence.",
        "`/engine/plan` and `/engine/go` can return `503`.",
    ),
    "bus_open_data_routes_api": (
        "Download bus route geometry from open data.",
        "Bus map overlays and route shapes.",
        "Bus map lines and route geometry can become stale.",
    ),
    "bus_open_data_stops_api": (
        "Download the in-effect bus stop index.",
        "Bus stop markers and nearby stop discovery.",
        "Stop index freshness degrades.",
    ),
}

_GTFS_DOCS: dict[str, tuple[str, str, str]] = {
    "subway": (
        "Build subway stops, shapes, schedules, and the local DB.",
        "Subway maps, inactive routes, schedule backfill.",
        "Static subway data cannot refresh.",
    ),
    "lirr": (
        "Build LIRR branches, stations, and schedule DB.",
        "LIRR maps and schedule context.",
        "Static LIRR refresh fails.",
    ),
    "metro_north": (
        "Build Metro-North lines, stations, and schedule DB.",
        "MNR maps and schedule context.",
        "Static MNR refresh fails.",
    ),
    "bus_bronx": (
        "Build Bronx bus schedule data.",
        "Bus route sheets, inactive routes, schedule backfill.",
        "Bronx bus schedules become stale.",
    ),
    "bus_brooklyn": (
        "Build Brooklyn bus schedule data.",
        "Bus route sheets, inactive routes, schedule backfill.",
        "Brooklyn bus schedules become stale.",
    ),
    "bus_manhattan": (
        "Build Manhattan bus schedule data.",
        "Bus route sheets, inactive routes, schedule backfill.",
        "Manhattan bus schedules become stale.",
    ),
    "bus_queens": (
        "Build Queens bus schedule data.",
        "Bus route sheets, inactive routes, schedule backfill.",
        "Queens bus schedules become stale.",
    ),
    "bus_staten_island": (
        "Build Staten Island bus schedule data.",
        "Bus route sheets, inactive routes, schedule backfill.",
        "Staten Island bus schedules become stale.",
    ),
    "bus_mta": (
        "Build MTA Bus Company schedule data.",
        "Bus route sheets, inactive routes, schedule backfill.",
        "MTA Bus Company schedules become stale.",
    ),
}

_BUS_ENDPOINT_DOCS: dict[str, tuple[str, str, str]] = {
    "vehicle_monitoring": (
        "SIRI vehicle-monitoring path for live bus positions.",
        "Vehicle markers and route tracking map UI.",
        "Live buses disappear or freeze.",
    ),
    "stop_monitoring": (
        "SIRI stop-monitoring path for live bus arrivals.",
        "Nearby buses and bus route stop sheets.",
        "Countdowns degrade to schedule/static views.",
    ),
    "stops_for_route": (
        "OBA path for ordered route stop lists.",
        "Bus route detail screens.",
        "Route stop sequences may be unavailable.",
    ),
    "stops_near_location": (
        "OBA path for nearby bus stop discovery.",
        "Home nearby and bus stop discovery.",
        "Nearby bus results become incomplete.",
    ),
}

_ROUTES_FOR_AGENCY_DOC = (
    "OBA route-list path for a bus agency.",
    "`/bus/routes`, route browser, official colors.",
    "Route catalog or color metadata may go stale.",
)

_ORDERED_URL_KEYS = [
    "subway_ace",
    "subway_g",
    "subway_nqrw",
    "subway_123456",
    "subway_bdfm",
    "subway_jz",
    "subway_l",
    "subway_si",
    "lirr",
    "metro_north",
    "alerts_json",
    "bus_alerts_json",
    "lirr_alerts_json",
    "mnr_alerts_json",
    "elevators_json",
    "bus_siri_base",
    "bus_oba_base",
    "mta_colors_api",
    "open_meteo_api",
    "track_engine_internal_url",
    "bus_open_data_routes_api",
    "bus_open_data_stops_api",
]


def render_upstream_urls(settings: Settings) -> str:
    """Render all configured upstream URLs and their purpose as markdown tables."""
    urls = settings.urls
    bus_endpoints = urls.bus_endpoints

    sections: list[str] = [
        "#### Exact configured URLs from settings.json",
        "",
        "| Config key | Exact configured value | Why we use it | Main UI purpose | Failure impact |",
        "|------------|------------------------|---------------|-----------------|----------------|",
    ]

    for key in _ORDERED_URL_KEYS:
        value = getattr(urls, key)
        why, ui, impact = _URL_DOCS[key]
        sections.append(row(f"urls.{key}", value or "(not configured)", why, ui, impact))

    if bus_endpoints is not None:
        sections.extend(
            [
                "",
                "#### Effective bus endpoint URLs",
                "",
                "| Config key | Exact configured value | Why we use it | Main UI purpose | Failure impact |",
                "|------------|------------------------|---------------|-----------------|----------------|",
            ]
        )
        sections.append(
            row(
                "urls.bus_endpoints.vehicle_monitoring",
                join_url(urls.bus_siri_base, bus_endpoints.vehicle_monitoring),
                *_BUS_ENDPOINT_DOCS["vehicle_monitoring"],
            )
        )
        sections.append(
            row(
                "urls.bus_endpoints.stop_monitoring",
                join_url(urls.bus_siri_base, bus_endpoints.stop_monitoring),
                *_BUS_ENDPOINT_DOCS["stop_monitoring"],
            )
        )
        routes_for_agency = bus_endpoints.routes_for_agency
        if isinstance(routes_for_agency, str):
            routes_for_agency = [routes_for_agency]
        for index, path in enumerate(routes_for_agency):
            sections.append(
                row(
                    f"urls.bus_endpoints.routes_for_agency[{index}]",
                    join_url(urls.bus_oba_base, path),
                    *_ROUTES_FOR_AGENCY_DOC,
                )
            )
        sections.append(
            row(
                "urls.bus_endpoints.stops_for_route",
                join_url(urls.bus_oba_base, bus_endpoints.stops_for_route),
                *_BUS_ENDPOINT_DOCS["stops_for_route"],
            )
        )
        sections.append(
            row(
                "urls.bus_endpoints.stops_near_location",
                join_url(urls.bus_oba_base, bus_endpoints.stops_near_location),
                *_BUS_ENDPOINT_DOCS["stops_near_location"],
            )
        )

    sections.extend(
        [
            "",
            "#### Static GTFS bundle URLs",
            "",
            "| Config key | Exact configured value | Why we use it | Main UI purpose | Failure impact |",
            "|------------|------------------------|---------------|-----------------|----------------|",
        ]
    )
    for key, value in urls.gtfs_static_feeds.items():
        why, ui, impact = _GTFS_DOCS.get(
            key,
            (
                "Refresh static transit data.",
                "Maps, schedules, and offline metadata.",
                "That feed's static data cannot refresh.",
            ),
        )
        sections.append(row(f"urls.gtfs_static_feeds.{key}", value, why, ui, impact))

    return "\n".join(sections)


def join_url(base: str, path: str) -> str:
    """Join a base URL and a relative path for docs display."""
    if not base:
        return path
    return f"{base.rstrip('/')}/{path.lstrip('/')}"


def row(key: str, value: str, why: str, ui: str, impact: str) -> str:
    """Render one markdown row."""
    return f"| `{key}` | `{escape_pipes(value)}` | {why} | {ui} | {impact} |"


def escape_pipes(value: str) -> str:
    """Escape pipe characters inside markdown table cells."""
    return value.replace("|", "\\|")
