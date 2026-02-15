"""
Static Data Router

Exposes static GTFS data for offline use in the iOS app.
"""

from fastapi import APIRouter
from fastapi.responses import JSONResponse
from typing import Dict, List, Any

from ..services.gtfs_parser import (
    parse_stops,
    get_routes_with_shapes,
    get_route_colors,
    generate_bundle
)

router = APIRouter(prefix="/static", tags=["static"])


@router.get("/routes")
async def get_routes() -> Dict[str, Any]:
    """
    Get all subway route polylines.
    
    Returns GeoJSON-like structure with route coordinates.
    """
    routes = get_routes_with_shapes()
    return {
        "count": len(routes),
        "routes": routes
    }


@router.get("/stops")
async def get_stops() -> Dict[str, Any]:
    """
    Get all subway stations with coordinates.
    """
    stops = parse_stops()
    return {
        "count": len(stops),
        "stops": stops
    }


@router.get("/colors")
async def get_colors() -> Dict[str, str]:
    """
    Get official MTA route colors.
    """
    return get_route_colors()


@router.get("/bundle")
async def get_bundle() -> Dict[str, Any]:
    """
    Get complete static data bundle for iOS app.
    
    This is the main endpoint for downloading all static data
    needed for offline operation.
    """
    bundle = generate_bundle()
    return bundle


@router.get("/health")
async def health_check() -> Dict[str, str]:
    """
    Health check for static data service.
    """
    return {"status": "ok", "service": "static_data"}
