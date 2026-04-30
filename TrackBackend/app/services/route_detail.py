"""Helpers for Transit-style route detail responses."""

from __future__ import annotations

import re

from app.models import RouteDetail, RoutePattern, RouteShape


def _pattern_token(value: str) -> str:
    token = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return token or "pattern"


def build_route_detail(*, route_id: str, mode: str, shape: RouteShape) -> RouteDetail:
    """Build a backend-authored route detail response from a route shape."""
    patterns: list[RoutePattern] = []
    for index, direction in enumerate(shape.directions):
        headsign_token = _pattern_token(direction.headsign)
        patterns.append(
            RoutePattern(
                pattern_id=(
                    f"{mode}:{shape.route_id}:{direction.direction_id}:"
                    f"{headsign_token}:{index}"
                ),
                direction_id=direction.direction_id,
                headsign=direction.headsign,
                polylines=direction.polylines,
                stops=direction.stops,
                service_type=direction.service_type or shape.service_type,
                local_only_stop_ids=direction.local_only_stop_ids,
            )
        )

    return RouteDetail(
        route_id=route_id,
        mode=mode,
        route_shape=shape,
        patterns=patterns,
    )
