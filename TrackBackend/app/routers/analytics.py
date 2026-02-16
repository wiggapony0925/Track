#
# analytics.py
# TrackBackend
#
# Analytics endpoints for popular routes and usage statistics.
# Data is sourced from Supabase route_interactions table.
#

from fastapi import APIRouter, Query

from app.services.supabase_client import supabase

router = APIRouter(prefix="/analytics", tags=["Analytics"])


@router.get("/popular")
async def get_popular_routes(
    mode: str | None = Query(None, description="Filter by mode: subway, bus, lirr"),
    limit: int = Query(10, ge=1, le=50, description="Number of results to return")
):
    """
    Get the most popular routes based on user interactions.
    
    This endpoint returns routes ranked by the number of clicks and tracks
    from all users, helping surface trending transit lines.
    
    Returns:
        List of popular routes with interaction counts
    """
    routes = await supabase.get_popular_routes(mode=mode, limit=limit)
    return {
        "popular_routes": routes,
        "count": len(routes)
    }


@router.post("/log")
async def log_interaction(
    route_id: str = Query(..., description="Route ID (e.g., 'L', 'B63')"),
    mode: str = Query(..., description="Transport mode: subway, bus, lirr"),
    interaction_type: str = Query("click", description="Type: click or track")
):
    """
    Log a route interaction for analytics.
    
    This endpoint is called by the iOS app when a user taps on a route
    or starts tracking. Used to build popularity rankings.
    
    Returns:
        Success status
    """
    success = await supabase.log_route_interaction(
        route_id=route_id,
        mode=mode,
        interaction_type=interaction_type
    )
    return {"success": success}
