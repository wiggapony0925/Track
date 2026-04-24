"""Tool: ``get_subway_status`` — at-a-glance line-by-line subway status.

Wraps :func:`app.services.gtfs.realtime_parser.get_alerts` and groups
the live MTA alert feed into a per-line summary the LLM can read in
one shot. Lets the model answer "how's the system tonight?" without
chaining 26 separate `get_service_alerts` calls.
"""

from __future__ import annotations

import json
from typing import Any

from app.metromind.logger import get_logger
from app.metromind.schemas import UserContext
from app.services.gtfs.realtime_parser import get_alerts

from .base import ToolResult

logger = get_logger("tools.subway_status")


# All numbered/lettered subway lines + SIR. Order matches the MTA's own
# status board so the LLM can render an ordered grid without reshuffling.
SUBWAY_LINES: tuple[str, ...] = (
    "1", "2", "3", "4", "5", "6", "7",
    "A", "B", "C", "D", "E", "F", "G",
    "J", "L", "M", "N", "Q", "R", "W", "Z",
    "SIR",
)


SCHEMA: dict[str, Any] = {
    "name": "get_subway_status",
    "description": (
        "Get a system-wide subway status snapshot — every numbered/lettered "
        "line plus SIR, each tagged 'good service', 'delays', 'planned work', "
        "or 'suspended'. Use this for broad questions like 'how's the subway "
        "tonight?', 'any lines down?', 'what's running normally right now?'. "
        "Prefer get_service_alerts when the user names a specific route."
    ),
    "parameters": {
        "type": "object",
        "properties": {},
        "additionalProperties": False,
    },
}


def _classify(severity: str | None, alert_type: str | None) -> str:
    sev = (severity or "").lower()
    kind = (alert_type or "").lower()
    if any(k in kind for k in ("suspend", "no service")):
        return "suspended"
    if "reroute" in kind or sev in {"severe", "warning"}:
        return "delays"
    if any(k in kind for k in ("planned", "weekend", "service change")):
        return "planned_work"
    return "info"


_PRIORITY = {"suspended": 3, "delays": 2, "planned_work": 1, "info": 0, "good_service": 0}


async def run(arguments: dict[str, Any], context: UserContext | None) -> ToolResult:
    del arguments, context  # System-wide; no inputs.

    alerts = await get_alerts(mode="subway")
    by_line: dict[str, dict[str, Any]] = {
        line: {"line": line, "status": "good_service", "headline": None, "count": 0}
        for line in SUBWAY_LINES
    }

    for alert in alerts:
        affected: list[str] = []
        if alert.route_id:
            affected.append(alert.route_id)
        for r in (alert.affected_routes or []):
            if r and r not in affected:
                affected.append(r)

        status = _classify(alert.severity, alert.alert_type)
        for route in affected:
            slot = by_line.get(route.upper())
            if slot is None:
                continue
            slot["count"] += 1
            if _PRIORITY[status] >= _PRIORITY[slot["status"]]:
                slot["status"] = status
                slot["headline"] = (alert.title or "")[:120]

    lines_out = [by_line[line] for line in SUBWAY_LINES]
    summary = {
        "good": sum(1 for l in lines_out if l["status"] == "good_service"),
        "planned_work": sum(1 for l in lines_out if l["status"] == "planned_work"),
        "delays": sum(1 for l in lines_out if l["status"] == "delays"),
        "suspended": sum(1 for l in lines_out if l["status"] == "suspended"),
    }
    summary["total_lines"] = len(SUBWAY_LINES)

    payload = {
        "summary": summary,
        "lines": lines_out,
    }
    return ToolResult(
        name="get_subway_status",
        content=json.dumps(payload),
        ok=True,
        ui_label="Checking system-wide subway status",
    )
