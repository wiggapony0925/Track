"""Build follow-up action chips for the iOS chat UI (Batch 2 — D).

Pure heuristics, no LLM call. Runs after the orchestrator finishes and
inspects (a) which tools fired, (b) the last tool payload, and
(c) user context to propose 2–3 chips of the form::

    SuggestedAction(label="Save this trip", kind="save_trip", payload={...})

The client decides what to do with each ``kind``:

* ``send_prompt`` → put ``payload["text"]`` in the composer and send.
* ``save_trip``   → add the itinerary to the user's saved trips.
* ``start_tracking`` → kick off a Live Activity for the itinerary.
* ``open_alerts`` → open the Alerts tab filtered to ``payload["route_id"]``.
* ``open_place``  → open Plan tab focused on ``payload["place_label"]``.
* ``generate_alternatives`` → re-prompt the LLM for different itineraries.

Keep payloads small; the iOS layer can hydrate further from local state.
"""

from __future__ import annotations

import json
from typing import Any

from app.metromind.schemas import SuggestedAction, UserContext


_MAX_CHIPS = 3


def build_suggestions(
    *,
    used_tools: list[str],
    tool_payloads: dict[str, dict[str, Any] | None],
    context: UserContext | None,
) -> list[SuggestedAction]:
    """Return up to 3 chips ranked by usefulness.

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

    # ── Post plan_route ──
    if "plan_route" in used_tools:
        payload = tool_payloads.get("plan_route") or {}
        itineraries = payload.get("itineraries") or []
        first = itineraries[0] if itineraries else {}
        legs = first.get("legs") or []
        primary_route = next(
            (
                leg.get("route_id") or leg.get("route_label")
                for leg in legs
                if (leg.get("mode") or "").lower() != "walk"
            ),
            None,
        )
        _add(SuggestedAction(
            label="Save this trip",
            kind="save_trip",
            payload={
                "origin": payload.get("origin"),
                "destination": payload.get("destination"),
                "summary": first.get("summary"),
            },
        ))
        # Always offer a way to ask for different itineraries — keeps the
        # conversation moving when the first option isn't ideal.
        _add(SuggestedAction(
            label="Show me other options",
            kind="generate_alternatives",
            payload={
                "text": "Show me alternative routes — different transfers or modes please.",
            },
        ))
        if primary_route:
            _add(SuggestedAction(
                label=f"Track the {primary_route}",
                kind="start_tracking",
                payload={"route_id": primary_route},
            ))
            _add(SuggestedAction(
                label=f"Alerts on the {primary_route}",
                kind="open_alerts",
                payload={"route_id": primary_route},
            ))

    # ── Post get_service_alerts ──
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

    # ── Post search_stations ──
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

    # ── Post get_user_places ──
    if "get_user_places" in used_tools and context is not None:
        for place in context.saved_places[:2]:
            label = place.label
            _add(SuggestedAction(
                label=f"Plan trip to {label}",
                kind="send_prompt",
                payload={"text": f"How do I get to {label}?"},
            ))

    # ── Default fallbacks (only if we still have room) ──
    if not chips:
        if context is not None and any(
            (p.kind or "").lower() == "home" for p in context.saved_places
        ):
            _add(SuggestedAction(
                label="How do I get home?",
                kind="send_prompt",
                payload={"text": "How do I get home?"},
            ))
        _add(SuggestedAction(
            label="Any L delays?",
            kind="send_prompt",
            payload={"text": "Any delays on the L?"},
        ))
        _add(SuggestedAction(
            label="Show me R211 trains",
            kind="send_prompt",
            payload={"text": "Tell me about the new R211 trains."},
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
