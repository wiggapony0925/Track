"""Tool: ``get_service_alerts`` — fetch live MTA alerts."""

from __future__ import annotations

import json
from typing import Any

from app.metromind.logger import get_logger
from app.metromind.schemas import UserContext
from app.services.gtfs.realtime_parser import get_alerts

from .base import ToolError, ToolResult

logger = get_logger("tools.alerts")


_VALID_MODES = {"subway", "bus", "lirr", "mnr"}


SCHEMA: dict[str, Any] = {
    "name": "get_service_alerts",
    "description": (
        "Fetch current MTA service alerts (delays, suspensions, planned work). "
        "Optionally filter by transit mode or route_id. Use this for any question "
        "about delays, outages, weekend work, or whether a line is running. "
        "Always call this before stating a line is down."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "mode": {
                "type": "string",
                "enum": ["subway", "bus", "lirr", "mnr"],
                "description": "Filter to a single transit mode.",
            },
            "route_id": {
                "type": "string",
                "description": (
                    "Filter to a specific route (e.g. 'A', 'L', '7', 'B44'). "
                    "Case-sensitive."
                ),
            },
            "limit": {
                "type": "integer",
                "minimum": 1,
                "maximum": 30,
                "default": 10,
            },
        },
        "additionalProperties": False,
    },
}


def _serialise_alert(alert: Any) -> dict[str, Any]:
    return {
        "title": alert.title,
        "description": (alert.description or "")[:500],
        "severity": alert.severity,
        "mode": alert.mode,
        "route_id": alert.route_id,
        "affected_routes": alert.affected_routes or [],
        "alert_type": alert.alert_type,
        "effect": alert.effect,
        "cause": alert.cause,
        "active_period": alert.human_readable_active_period,
        "active_period_end": alert.active_period_end,
    }


async def run(arguments: dict[str, Any], context: UserContext | None) -> ToolResult:
    del context  # Unused — alerts are global.

    mode = arguments.get("mode")
    if mode is not None and mode not in _VALID_MODES:
        raise ToolError(
            f"Invalid mode '{mode}'. Must be one of {sorted(_VALID_MODES)}."
        )

    route_filter = (arguments.get("route_id") or "").strip() or None
    limit = int(arguments.get("limit") or 10)
    limit = max(1, min(limit, 30))

    alerts = await get_alerts(mode=mode)

    if route_filter:
        alerts = [
            a
            for a in alerts
            if (a.route_id and a.route_id.upper() == route_filter.upper())
            or any(r.upper() == route_filter.upper() for r in (a.affected_routes or []))
        ]

    # Sort by MTA sort_order (higher = more severe), then severity string.
    alerts_sorted = sorted(
        alerts,
        key=lambda a: (-(a.sort_order or 0), a.severity or "", a.title or ""),
    )

    trimmed = [_serialise_alert(a) for a in alerts_sorted[:limit]]

    payload = {
        "filter": {"mode": mode, "route_id": route_filter},
        "total_matching": len(alerts),
        "alerts": trimmed,
    }

    return ToolResult(
        name="get_service_alerts",
        content=json.dumps(payload),
        ok=True,
        ui_label=(
            f"Checking {mode} alerts"
            if mode
            else "Checking service alerts"
        ),
    )
