"""Router for Long Island Rail Road arrivals and route shapes."""

from __future__ import annotations

from fastapi import APIRouter, Path, Response

from app.models import (
    RESP_404,
    RESP_502,
    AllCommuterRailLinesResponse,
    RouteShape,
    TrackArrival,
)
from app.routers._commuter_rail import (
    build_all_lines,
    build_single_line,
    fetch_arrivals,
)
from app.services.mapping.rail.shapes import (
    get_all_lirr_lines,
    get_single_lirr_line,
)

router = APIRouter(tags=["lirr"])


def _normalise_lirr_name(name: str) -> str:
    return name.lower().replace(" branch", "").strip()


# NOTE: Static path endpoints MUST be declared before the wildcard endpoints.


@router.get(
    "/lirr/shapes/all",
    response_model=AllCommuterRailLinesResponse,
    summary="Get all LIRR branch shapes",
    description=(
        "Returns encoded polylines for every LIRR branch \u2014 used to draw the "
        "full LIRR system map. Each branch includes station markers with "
        "coordinates."
    ),
)
async def lirr_shapes_all() -> AllCommuterRailLinesResponse:
    """Return polylines for ALL LIRR branches."""
    return build_all_lines(get_all_lirr_lines, mode="lirr")


@router.get(
    "/lirr/shape/{route_id}",
    response_model=RouteShape,
    summary="Get single LIRR branch shape",
    description=(
        "Returns polyline geometry, ordered stops, and per-direction shapes "
        "for a single LIRR branch. Accepts numeric GTFS route ID, prefixed "
        "form (e.g. `LIRR_9`), or branch name (e.g. `Babylon`)."
    ),
    responses={**RESP_404},
)
async def lirr_shape(
    route_id: str = Path(
        ...,
        description="LIRR branch GTFS route ID, prefixed form, or branch name.",
        examples=["9", "LIRR_9", "Babylon"],
    )
) -> RouteShape:
    """Return the polyline for a single LIRR branch."""
    return build_single_line(
        route_id,
        prefix="LIRR",
        get_all_fn=get_all_lirr_lines,
        get_single_fn=get_single_lirr_line,
        name_normaliser=_normalise_lirr_name,
    )


@router.get(
    "/lirr",
    response_model=list[TrackArrival],
    summary="Get real-time LIRR arrivals",
    description=(
        "Returns upcoming real-time LIRR arrivals from the GTFS-Realtime "
        "feed. Each arrival includes station, direction, destination, "
        "minutes away, and cancellation status. Returns an empty array if "
        "the MTA feed is temporarily unavailable."
    ),
    responses={**RESP_502},
)
async def lirr_arrivals(response: Response) -> list[TrackArrival]:
    """Return upcoming LIRR arrivals."""
    return await fetch_arrivals("lirr", tag="LIRR", response=response)
