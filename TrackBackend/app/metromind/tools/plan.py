"""Tool: ``plan_route`` — compute a trip using TrackEngine."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

from app.metromind.logger import get_logger
from app.metromind.schemas import UserContext
from app.services.track_engine.integration import (
    LocationInput,
    PlanRequest,
    get_engine_service,
)

from .base import ToolError, ToolResult

logger = get_logger("tools.plan")


def _iso(ts: int | float | None) -> str | None:
    """Convert an epoch ts to ISO 8601 (UTC) for client cards."""
    if ts is None:
        return None
    try:
        return datetime.fromtimestamp(int(ts), tz=timezone.utc).isoformat()
    except (OverflowError, OSError, ValueError):
        return None


SCHEMA: dict[str, Any] = {
    "name": "plan_route",
    "description": (
        "Plan transit trips between two points using the Track routing engine "
        "(subway, bus, LIRR, Metro-North). Returns a ranked list of itineraries "
        "with duration, transfers, and route badges. Use this whenever the user "
        "asks how to get somewhere, the best way to a place, or compares routes."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "origin_label": {
                "type": "string",
                "description": (
                    "Human label for the origin (station name, address, or place). "
                    "If the user said 'from here' use 'Current location'."
                ),
            },
            "origin_lat": {"type": "number"},
            "origin_lon": {"type": "number"},
            "origin_stop_id": {
                "type": "string",
                "description": "GTFS stop_id if known (preferred over lat/lon).",
            },
            "destination_label": {"type": "string"},
            "destination_lat": {"type": "number"},
            "destination_lon": {"type": "number"},
            "destination_stop_id": {"type": "string"},
            "num_itineraries": {
                "type": "integer",
                "minimum": 1,
                "maximum": 5,
                "default": 3,
            },
            "accessibility_priority": {
                "type": "boolean",
                "description": "Prefer ADA-accessible routes.",
                "default": False,
            },
        },
        "required": ["origin_label", "destination_label"],
        "additionalProperties": False,
    },
}


def _build_location(
    *,
    label: str,
    lat: float | None,
    lon: float | None,
    stop_id: str | None,
    fallback_lat: float | None = None,
    fallback_lon: float | None = None,
) -> LocationInput:
    resolved_lat = lat if lat is not None else fallback_lat
    resolved_lon = lon if lon is not None else fallback_lon
    if resolved_lat is None or resolved_lon is None:
        if not stop_id:
            raise ToolError(
                f"Missing coordinates or stop_id for '{label}'. Ask the user to "
                "clarify or call search_stations first."
            )
    return LocationInput(
        label=label,
        lat=resolved_lat,
        lon=resolved_lon,
        stop_id=stop_id,
    )


async def _resolve_label_via_search(
    engine: Any,
    label: str,
) -> tuple[float | None, float | None, str | None]:
    """Best-effort: turn a free-text label into (lat, lon, stop_id).

    Uses the same fuzzy GTFS stop search that powers `search_stations`,
    but tries a few common variants of the label so colloquial names
    like ``"Times Square"`` still resolve to ``"Times Sq-42 St"``.
    Returns ``(None, None, None)`` when no match is found.
    """
    candidates = _label_search_variants(label)
    for variant in candidates:
        try:
            stops = await engine.repository.search_stops(variant, limit=1)
        except Exception:  # noqa: BLE001 — search is best-effort
            logger.exception("search_stops failed while resolving '%s'", variant)
            continue
        if stops:
            stop = stops[0]
            logger.info(
                "Resolved '%s' (via '%s') → %s (%s)",
                label,
                variant,
                stop.stop_name,
                stop.stop_id,
            )
            return stop.lat, stop.lon, stop.stop_id
    return None, None, None


def _label_search_variants(label: str) -> list[str]:
    """Generate progressively looser search terms for a place label."""
    base = label.strip()
    if not base:
        return []

    # Common NYC abbreviations the GTFS stops table actually uses.
    abbrev = (
        base.replace("Square", "Sq")
        .replace("Street", "St")
        .replace("Avenue", "Av")
        .replace("Boulevard", "Blvd")
        .replace("Center", "Ctr")
        .replace("Bridge", "Bridge")  # no-op, kept for clarity
    )

    seen: set[str] = set()
    variants: list[str] = []
    for candidate in (base, abbrev):
        words = candidate.split()
        # Try full string, then drop trailing words one at a time.
        for end in range(len(words), 0, -1):
            v = " ".join(words[:end]).strip()
            key = v.lower()
            if v and key not in seen:
                seen.add(key)
                variants.append(v)
    return variants


def _serialise_itinerary(itin: Any) -> dict[str, Any]:
    """Pare an engine Itinerary down to a compact dict for the LLM."""
    legs = []
    for leg in itin.legs:
        alerts = [
            {
                "title": a.title,
                "severity": a.severity,
                "alert_type": a.alert_type,
                "description": a.description[:240],
            }
            for a in (leg.alerts or [])
        ]
        duration_min = round(leg.duration_s / 60, 1)
        legs.append(
            {
                "mode": leg.mode,
                "route_id": leg.route_id,
                "route_name": leg.route_name,
                # iOS-friendly aliases (RoutePlanPayload.Leg expects these names).
                "route_label": leg.route_name,
                "from_name": leg.board_stop_name,
                "to_name": leg.alight_stop_name,
                "depart_time": _iso(leg.departure_ts),
                "arrive_time": _iso(leg.arrival_ts),
                "duration_minutes": duration_min,
                "num_stops": leg.stop_count,
                "headsign": leg.headsign,
                "board_stop_name": leg.board_stop_name,
                "alight_stop_name": leg.alight_stop_name,
                "departure_ts": leg.departure_ts,
                "arrival_ts": leg.arrival_ts,
                "duration_min": duration_min,
                "stop_count": leg.stop_count,
                "walk_meters": round(leg.walk_meters or 0, 0),
                "live_status": (
                    {
                        "source": leg.live_status.source,
                        "status": leg.live_status.status,
                        "status_text": leg.live_status.status_text,
                        "delay_s": leg.live_status.delay_s,
                    }
                    if leg.live_status
                    else None
                ),
                "alerts": alerts,
            }
        )

    total_min = round(itin.total_duration_s / 60, 1)
    walk_meters = round(itin.walk_meters or 0, 0)
    return {
        "itinerary_id": itin.itinerary_id,
        "summary": itin.summary,
        "total_duration_min": total_min,
        # iOS-friendly aliases (RoutePlanPayload.Itinerary expects these names).
        "total_minutes": total_min,
        "walk_minutes": round(walk_meters / 80.0, 1),  # ~80 m/min walking
        "transfer_count": itin.transfer_count,
        "departure_time": _iso(itin.leave_at_ts),
        "arrival_time": _iso(itin.arrive_at_ts),
        "transfers": itin.transfer_count,
        "walk_meters": walk_meters,
        "leave_at_ts": itin.leave_at_ts,
        "arrive_at_ts": itin.arrive_at_ts,
        "accessible": itin.accessible,
        "legs": legs,
        "fare_total_cents": getattr(itin.fare, "total_cents", None) if itin.fare else None,
    }


def _critique_itinerary(itin_dict: dict[str, Any]) -> list[str]:
    """Quick critique pass — surface any high-risk facts the LLM should mention.

    Pure local logic (no extra LLM call). Looks at each leg's alerts and
    live_status to produce 0–N short risk notes the LLM is told to mention.
    """
    notes: list[str] = []
    for leg in itin_dict.get("legs") or []:
        route = leg.get("route_name") or leg.get("route_id") or "this leg"

        # Severe / suspended alerts.
        for alert in leg.get("alerts") or []:
            sev = (alert.get("severity") or "").lower()
            kind = (alert.get("alert_type") or "").lower()
            if sev in {"severe", "warning"} or any(
                k in kind for k in ("suspend", "no service", "reroute")
            ):
                title = (alert.get("title") or "alert").strip()
                notes.append(f"{route}: {title}")

        # Live delays > 4 minutes.
        live = leg.get("live_status") or {}
        delay_s = live.get("delay_s") or 0
        if isinstance(delay_s, (int, float)) and delay_s >= 240:
            notes.append(
                f"{route} is currently running ~{int(delay_s/60)} min late"
            )
    # Dedupe while preserving order, cap at 3 to keep prompt tight.
    seen: set[str] = set()
    out: list[str] = []
    for n in notes:
        if n not in seen:
            seen.add(n)
            out.append(n)
        if len(out) >= 3:
            break
    return out


async def run(arguments: dict[str, Any], context: UserContext | None) -> ToolResult:
    origin_label = (arguments.get("origin_label") or "").strip()
    destination_label = (arguments.get("destination_label") or "").strip()
    if not origin_label or not destination_label:
        raise ToolError("Both origin_label and destination_label are required.")

    device_lat = context.lat if context else None
    device_lon = context.lon if context else None

    engine = get_engine_service()

    # Resolve free-text origin label via fuzzy stop search when the model
    # didn't supply coordinates or a stop_id.
    origin_lat = arguments.get("origin_lat")
    origin_lon = arguments.get("origin_lon")
    origin_stop_id = arguments.get("origin_stop_id")
    origin_is_current = "current" in origin_label.lower()
    if (
        origin_lat is None
        and origin_lon is None
        and not origin_stop_id
        and not origin_is_current
    ):
        origin_lat, origin_lon, origin_stop_id = await _resolve_label_via_search(
            engine, origin_label
        )

    dest_lat = arguments.get("destination_lat")
    dest_lon = arguments.get("destination_lon")
    dest_stop_id = arguments.get("destination_stop_id")
    if dest_lat is None and dest_lon is None and not dest_stop_id:
        dest_lat, dest_lon, dest_stop_id = await _resolve_label_via_search(
            engine, destination_label
        )

    origin = _build_location(
        label=origin_label,
        lat=origin_lat,
        lon=origin_lon,
        stop_id=origin_stop_id,
        fallback_lat=device_lat if origin_is_current else None,
        fallback_lon=device_lon if origin_is_current else None,
    )
    destination = _build_location(
        label=destination_label,
        lat=dest_lat,
        lon=dest_lon,
        stop_id=dest_stop_id,
    )

    num = int(arguments.get("num_itineraries") or 3)
    num = max(1, min(num, 5))

    request = PlanRequest(
        origin=origin,
        destination=destination,
        num_itineraries=num,
        accessibility_priority=bool(arguments.get("accessibility_priority")),
        record_recent=False,
    )

    try:
        itineraries, schedule_note = await engine.plan(request)
    except RuntimeError as exc:
        # The C++ TrackEngine routing service is offline / unreachable / timing
        # out. Surface a clear, *user-facing* error so the model tells the rider
        # the engine is down instead of deflecting or retry-spamming.
        msg = str(exc)
        if (
            "TRACK_ENGINE_URL" in msg
            or "TrackEngine" in msg
            or "circuit open" in msg
            or "unreachable" in msg
            or "timed out" in msg
        ):
            logger.warning("Routing engine unavailable: %s", msg)
            raise ToolError(
                "ENGINE_DOWN: The Track routing engine is currently down or "
                "unreachable, so trip planning is temporarily unavailable. "
                "You MUST tell the user plainly that the trip-planning engine "
                "is down right now (don't hide it, don't be vague). Then offer "
                "alternatives you CAN do: check service alerts, look up live "
                "arrivals, or look up a specific station."
            ) from exc
        raise

    serialised = [_serialise_itinerary(i) for i in itineraries[:num]]

    # Critique pass: surface high-risk facts the LLM should mention.
    risk_notes: list[str] = []
    for itin in serialised:
        risk_notes.extend(_critique_itinerary(itin))
    # Dedupe across itineraries.
    seen: set[str] = set()
    deduped: list[str] = []
    for n in risk_notes:
        if n not in seen:
            seen.add(n)
            deduped.append(n)
        if len(deduped) >= 3:
            break

    payload = {
        "origin": origin_label,
        "destination": destination_label,
        "schedule_note": schedule_note,
        "itineraries": serialised,
        # Hint to the LLM — if non-empty, mention briefly in the caption.
        "risk_notes": deduped,
    }

    return ToolResult(
        name="plan_route",
        content=json.dumps(payload),
        ok=True,
        ui_label=f"Planning {origin_label} → {destination_label}",
    )
