"""Build follow-up action chips for the iOS chat UI.

Pure heuristics, no LLM call. Runs after the orchestrator finishes and
inspects (a) which tools fired, (b) the last tool payload, and
(c) user context to propose up to ``_MAX_CHIPS`` follow-up chips.

Design goals
------------
* **Personalised first.** When ``context.top_routes`` is populated the
  default fallback chip surfaces the user's most-used line — never a
  hardcoded "L". When no personal data is available, we rotate through
  the busiest NYC subway lines based on the current hour so two
  consecutive empty replies don't show identical chips.
* **Actionable before exploratory.** Chips are emitted in priority
  order (Save → Track → Open Plan → Alternatives → "ask again") and the
  caller's ``_MAX_CHIPS`` cap drops the lowest-priority entries first.
* **Always have an exit.** Empty itineraries (NJ Transit / out of MTA
  area), error tools, and off-topic turns all still produce at least one
  chip that nudges the user back into the planner or toward their
  saved data.

Chip ``kind`` taxonomy (the iOS layer dispatches on this):

* ``send_prompt``        → put ``payload["text"]`` in the composer and send.
* ``save_trip``          → add the itinerary to the user's saved trips.
* ``start_tracking``     → kick off a Live Activity for the itinerary/route.
* ``open_alerts``        → open the Alerts tab filtered to ``payload["route_id"]``.
* ``open_place``         → open Plan tab focused on ``payload["place_label"]``.
* ``open_plan``          → open the Plan tab seeded with origin/destination.
* ``generate_alternatives`` → re-prompt the LLM for different itineraries.
"""

from __future__ import annotations

import json
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

from app.metromind.schemas import SuggestedAction, UserContext


_MAX_CHIPS = 3

# Rotated when the user has no personal route history. Ordered roughly
# by 2024 weekday ridership so the rotation always lands on a line the
# user has at least heard of, regardless of which slot we pick.
_POPULAR_ROUTES: tuple[str, ...] = ("6", "F", "L", "7", "A", "N", "E", "G")

# Drop these label prefixes so "MTA NYCT_B63" → "B63".
_ROUTE_PREFIXES: tuple[str, ...] = ("MTA NYCT_", "MTA BUS_", "MTABC_")


def _short_route(route: str | None) -> str | None:
    """Strip GTFS agency prefixes so the chip text reads naturally."""
    if not route:
        return None
    out = route.strip()
    for prefix in _ROUTE_PREFIXES:
        if out.upper().startswith(prefix):
            out = out[len(prefix) :]
            break
    return out or None


def _default_route_for_hour(now: datetime | None = None) -> str:
    """Pick a popular route deterministically from the current hour.

    Used only when the user has no ``top_routes`` history, so the empty
    chat state doesn't always advertise the same line.
    """
    if now is None:
        now = datetime.now(ZoneInfo("America/New_York"))
    return _POPULAR_ROUTES[now.hour % len(_POPULAR_ROUTES)]


def _pick_personal_route(context: UserContext | None) -> str | None:
    """Return the user's #1 most-used route, short form, if known."""
    if context is None or not context.top_routes:
        return None
    return _short_route(context.top_routes[0])


def build_suggestions(
    *,
    used_tools: list[str],
    tool_payloads: dict[str, dict[str, Any] | None],
    context: UserContext | None,
) -> list[SuggestedAction]:
    """Return up to ``_MAX_CHIPS`` chips ranked by usefulness.

    ``tool_payloads`` maps tool name → parsed JSON content (last call
    wins if a tool fires twice). Pass ``None`` for tools whose content
    couldn't be parsed.
    """
    chips: list[SuggestedAction] = []
    seen_labels: set[str] = set()

    def _add(chip: SuggestedAction) -> None:
        if chip.label in seen_labels or len(chips) >= _MAX_CHIPS:
            return
        seen_labels.add(chip.label)
        chips.append(chip)

    personal_route = _pick_personal_route(context)
    home_label = next(
        (
            p.label
            for p in (context.saved_places if context is not None else [])
            if (p.kind or "").lower() == "home"
        ),
        None,
    )
    # Location signal — either device GPS or a dropped map pin. The
    # bias_label is what we surface in chip text ("near Union Sq",
    # "near pinned spot") so users see *why* a chip is being offered.
    has_location = (
        context is not None
        and context.bias_lat is not None
        and context.bias_lon is not None
    )
    location_label: str | None = None
    if context is not None and context.bias_label:
        location_label = context.bias_label.strip() or None
    location_is_pin = (
        context is not None and context.bias_source == "map_pin"
    )

    # ── Post plan_route ──────────────────────────────────────────────
    if "plan_route" in used_tools:
        payload = tool_payloads.get("plan_route") or {}
        itineraries = payload.get("itineraries") or []
        origin = payload.get("origin")
        destination = payload.get("destination")

        if itineraries:
            first = itineraries[0] or {}
            legs = first.get("legs") or []
            primary_route = _short_route(
                next(
                    (
                        leg.get("route_id") or leg.get("route_label")
                        for leg in legs
                        if (leg.get("mode") or "").lower() != "walk"
                    ),
                    None,
                )
            )
            # 1) Save — primary action while the trip is on screen.
            _add(SuggestedAction(
                label="Save this trip",
                kind="save_trip",
                payload={
                    "origin": origin,
                    "destination": destination,
                    "summary": first.get("summary"),
                },
            ))
            # 2) Track the line — kick off Live Activity. Only if the
            #    trip actually rides a transit line (skip walk-only).
            if primary_route:
                _add(SuggestedAction(
                    label=f"Track the {primary_route}",
                    kind="start_tracking",
                    payload={"route_id": primary_route},
                ))
            # 3) Alternatives — keep the conversation moving.
            _add(SuggestedAction(
                label="Show other options",
                kind="generate_alternatives",
                payload={
                    "text": (
                        "Show me alternative routes — different transfers "
                        "or modes please."
                    ),
                },
            ))
        else:
            # Empty itineraries — usually means destination is outside
            # the MTA service area (Newark, Hoboken, Jersey City, …).
            # The model has already been prompted to give NJ Transit /
            # PATH guidance in text; chips should let the user keep
            # exploring rather than stranding them.
            _add(SuggestedAction(
                label="Try a different destination",
                kind="send_prompt",
                payload={
                    "text": (
                        "Suggest a few destinations near there I could "
                        "actually reach by subway."
                    ),
                },
            ))
            if destination:
                _add(SuggestedAction(
                    label="Open in Plan tab",
                    kind="open_plan",
                    payload={
                        "origin": origin,
                        "destination": destination,
                    },
                ))

    # ── Post get_service_alerts ──────────────────────────────────────
    if "get_service_alerts" in used_tools:
        _add(SuggestedAction(
            label="Plan around it",
            kind="send_prompt",
            payload={"text": "Plan a route that avoids the affected lines."},
        ))
        _add(SuggestedAction(
            label="What about other lines?",
            kind="send_prompt",
            payload={"text": "Are there alerts on any other lines right now?"},
        ))

    # ── Post get_arrivals ────────────────────────────────────────────
    if "get_arrivals" in used_tools:
        payload = tool_payloads.get("get_arrivals") or {}
        arrivals = payload.get("arrivals") or []
        first_arrival = arrivals[0] if arrivals else {}
        route_id = _short_route(first_arrival.get("route_id"))
        if route_id:
            _add(SuggestedAction(
                label=f"Track the {route_id}",
                kind="start_tracking",
                payload={"route_id": route_id},
            ))
            _add(SuggestedAction(
                label=f"Alerts on the {route_id}",
                kind="open_alerts",
                payload={"route_id": route_id},
            ))

    # ── Post search_stations ─────────────────────────────────────────
    if "search_stations" in used_tools:
        payload = tool_payloads.get("search_stations") or {}
        stops = payload.get("stops") or []
        first_name = (stops[0] or {}).get("stop_name") if stops else None
        if first_name:
            _add(SuggestedAction(
                label=f"Plan a trip from {first_name}",
                kind="send_prompt",
                payload={"text": f"How do I get home from {first_name}?"},
            ))

    # ── Post get_user_places ─────────────────────────────────────────
    if "get_user_places" in used_tools and context is not None:
        for place in context.saved_places[:2]:
            _add(SuggestedAction(
                label=f"Plan trip to {place.label}",
                kind="send_prompt",
                payload={"text": f"How do I get to {place.label}?"},
            ))

    # ── Default fallbacks ────────────────────────────────────────────
    # Only fire if we still have headroom and nothing tool-specific
    # filled the slot. We always personalise on top_routes if available
    # so the chip never advertises a line the user doesn't ride.
    if len(chips) < _MAX_CHIPS:
        # Location-aware "get me home from this pin" — highest-value
        # default chip when the user has both dropped a pin AND saved a
        # home address. The prompt encodes the pin's label so the LLM
        # can route from there even though the chip is pure text.
        if has_location and home_label and location_label and location_is_pin:
            _add(SuggestedAction(
                label=f"Get home from {location_label}",
                kind="send_prompt",
                payload={
                    "text": (
                        f"How do I get from {location_label} to "
                        f"{home_label.lower()}?"
                    ),
                },
            ))
        elif home_label:
            _add(SuggestedAction(
                label=f"How do I get {home_label.lower()}?"
                if home_label.lower() != "home"
                else "How do I get home?",
                kind="send_prompt",
                payload={"text": "How do I get home?"},
            ))

        route_for_chip = personal_route or _default_route_for_hour()
        _add(SuggestedAction(
            label=f"Any {route_for_chip} delays?",
            kind="send_prompt",
            payload={"text": f"Any delays on the {route_for_chip}?"},
        ))

        # Location-aware "what's nearby" — when we have GPS or a pin we
        # can phrase the prompt around it so the LLM scopes its tool
        # call. Without location we still offer the same idea, just
        # generically. Personalised "track my line" wins if the user
        # has a usual route, since that's higher signal than "nearby".
        if personal_route:
            _add(SuggestedAction(
                label=f"Track the {personal_route}",
                kind="start_tracking",
                payload={"route_id": personal_route},
            ))
        elif has_location and location_label:
            _add(SuggestedAction(
                label=f"Stations near {location_label}",
                kind="send_prompt",
                payload={
                    "text": f"What stations are near {location_label}?",
                },
            ))
        elif has_location:
            _add(SuggestedAction(
                label="What's near me?",
                kind="send_prompt",
                payload={"text": "What stations are near me right now?"},
            ))
        else:
            _add(SuggestedAction(
                label="What's nearby?",
                kind="send_prompt",
                payload={"text": "What stations are near me?"},
            ))

    return chips[:_MAX_CHIPS]


def parse_tool_payload(name: str, content: str) -> dict[str, Any] | None:
    """Best-effort JSON parse of a tool's ``content`` string."""
    try:
        parsed = json.loads(content)
    except (json.JSONDecodeError, TypeError):
        return None
    return parsed if isinstance(parsed, dict) else None


__all__ = ["build_suggestions", "parse_tool_payload"]
