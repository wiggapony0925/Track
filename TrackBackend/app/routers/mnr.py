"""Router for Metro-North Railroad arrivals and route shapes."""

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
    get_all_mnr_lines,
    get_single_mnr_line,
)

router = APIRouter(tags=["mnr"])


# NOTE: Static path endpoints MUST be declared before the wildcard endpoints.


@router.get(
    "/mnr/shapes/all",
    response_model=AllCommuterRailLinesResponse,
    summary="Get all Metro-North line shapes",
    description=(
        "Returns encoded polylines for every Metro-North line \u2014 used to draw "
        "the full MNR system map. Each line includes station markers with "
        "coordinates."
    ),
)
async def mnr_shapes_all() -> AllCommuterRailLinesResponse:
    """Return polylines for ALL Metro-North lines."""
    return build_all_lines(get_all_mnr_lines, mode="mnr")


@router.get(
    "/mnr/shape/{route_id}",
    response_model=RouteShape,
    summary="Get single Metro-North line shape",
    description=(
        "Returns polyline geometry, ordered stops, and per-direction shapes "
        "for a single Metro-North line. Accepts numeric GTFS route ID, "
        "prefixed form (e.g. `MNR_1`), or line name (e.g. `Hudson`)."
    ),
    responses={**RESP_404},
)
async def mnr_shape(
    route_id: str = Path(
        ...,
        description="Metro-North GTFS route ID, prefixed form, or line name.",
        examples=["1", "MNR_1", "Hudson"],
    )
) -> RouteShape:
    """Return the polyline for a single Metro-North line."""
    return build_single_line(
        route_id,
        prefix="MNR",
        get_all_fn=get_all_mnr_lines,
        get_single_fn=get_single_mnr_line,
    )


@router.get(
    "/mnr",
    response_model=list[TrackArrival],
    summary="Get real-time Metro-North arrivals",
    description=(
        "Returns upcoming real-time Metro-North arrivals from the GTFS-Realtime "
        "feed. Each arrival includes station, direction, destination, "
        "minutes away, and cancellation status. Returns an empty array if "
        "the MTA feed is temporarily unavailable."
    ),
    responses={**RESP_502},
)
async def mnr_arrivals(response: Response) -> list[TrackArrival]:
    """Return upcoming Metro-North arrivals."""
    return await fetch_arrivals("metro_north", tag="MNR", response=response)
