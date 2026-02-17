#
# supabase_client.py
# TrackBackend
#
# Supabase integration for backend analytics and user data.
# Provides access to route interactions, popular routes, etc.
#
# Environment Variables:
#   SUPABASE_URL - Your Supabase project URL
#   SUPABASE_SERVICE_KEY - Service role key (for server-side access)
#

import os
from datetime import datetime, timezone
from typing import Any

import httpx

from app.utils.logger import TrackLogger

# Supabase configuration from environment
# In production, set these as environment variables
# For development, defaults are provided

# Default Supabase credentials for Track app
_DEFAULT_SUPABASE_URL = "https://octpebjxadbufiplgjqg.supabase.co"
_DEFAULT_SUPABASE_KEY = "sb_publishable_lAEZ_x8O4vjdGaw-I-QUMg_oS5iWKIn"

SUPABASE_URL = os.environ.get("SUPABASE_URL", _DEFAULT_SUPABASE_URL)
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", os.environ.get("SUPABASE_KEY", _DEFAULT_SUPABASE_KEY))


class SupabaseClient:
    """
    Lightweight Supabase client for backend analytics.
    Uses httpx for async HTTP requests to the Supabase REST API.
    """
    
    def __init__(self, url: str | None = None, key: str | None = None):
        self.url = (url or SUPABASE_URL).rstrip("/")
        self.key = key or SUPABASE_SERVICE_KEY
        self.headers = {
            "apikey": self.key,
            "Authorization": f"Bearer {self.key}",
            "Content-Type": "application/json",
            "Prefer": "return=representation"
        }
    
    @property
    def is_configured(self) -> bool:
        """Check if Supabase is properly configured."""
        return bool(self.url and self.key)
    
    async def _request(
        self,
        method: str,
        table: str,
        params: dict[str, Any] | None = None,
        json_data: dict[str, Any] | list[dict[str, Any]] | None = None
    ) -> list[dict[str, Any]]:
        """Make an async request to the Supabase REST API."""
        if not self.is_configured:
            return []
        
        url = f"{self.url}/rest/v1/{table}"
        
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.request(
                method,
                url,
                headers=self.headers,
                params=params,
                json=json_data
            )
            
            if response.status_code >= 400:
                TrackLogger.warning(f"Supabase error {response.status_code}: {response.text}", tag="ANALYTICS")
                return []
            
            if response.status_code == 204:
                return []
            
            return response.json()
    
    # =========================================================================
    # Route Interactions (Analytics)
    # =========================================================================
    
    async def log_route_interaction(
        self,
        route_id: str,
        mode: str,
        interaction_type: str = "click"
    ) -> bool:
        """
        Log a route interaction for analytics.
        
        Args:
            route_id: The route ID (e.g., "L", "B63")
            mode: The transport mode ("subway", "bus", "lirr")
            interaction_type: Type of interaction ("click" or "track")
        
        Returns:
            True if successful, False otherwise
        """
        data = {
            "route_id": route_id,
            "mode": mode,
            "interaction_type": interaction_type,
            "created_at": datetime.now(timezone.utc).isoformat()
        }
        
        result = await self._request("POST", "route_interactions", json_data=data)
        return len(result) > 0
    
    async def get_popular_routes(
        self,
        mode: str | None = None,
        limit: int = 10
    ) -> list[dict[str, Any]]:
        """
        Get the most popular routes based on interaction count.
        
        Args:
            mode: Filter by transport mode (optional)
            limit: Maximum number of results
        
        Returns:
            List of routes with their interaction counts
        """
        # Use Supabase's RPC function for aggregation
        # This requires creating a database function, so we'll use a simpler approach
        # by fetching recent interactions and counting client-side
        
        params = {
            "select": "route_id,mode,interaction_type",
            "order": "created_at.desc",
            "limit": str(limit * 20)  # Fetch more to aggregate
        }
        
        if mode:
            params["mode"] = f"eq.{mode}"
        
        interactions = await self._request("GET", "route_interactions", params=params)
        
        # Aggregate by route_id
        counts: dict[str, dict[str, Any]] = {}
        for interaction in interactions:
            route_id = interaction.get("route_id", "")
            if route_id not in counts:
                counts[route_id] = {
                    "route_id": route_id,
                    "mode": interaction.get("mode", ""),
                    "clicks": 0,
                    "tracks": 0,
                    "total": 0
                }
            
            if interaction.get("interaction_type") == "track":
                counts[route_id]["tracks"] += 1
            else:
                counts[route_id]["clicks"] += 1
            counts[route_id]["total"] += 1
        
        # Sort by total interactions
        sorted_routes = sorted(counts.values(), key=lambda x: x["total"], reverse=True)
        return sorted_routes[:limit]
    
    # =========================================================================
    # Schedules
    # =========================================================================
    
    async def get_user_schedules(self, user_id: str) -> list[dict[str, Any]]:
        """Get all schedules for a user."""
        params = {
            "select": "*",
            "user_id": f"eq.{user_id}",
            "order": "created_at.desc"
        }
        return await self._request("GET", "schedules", params=params)
    
    async def create_schedule(
        self,
        user_id: str,
        route_id: str,
        direction: str,
        days_of_week: list[int],
        start_time: str,
        is_enabled: bool = True
    ) -> dict[str, Any] | None:
        """Create a new schedule for a user."""
        data = {
            "user_id": user_id,
            "route_id": route_id,
            "direction": direction,
            "days_of_week": days_of_week,
            "start_time": start_time,
            "is_enabled": is_enabled
        }
        
        result = await self._request("POST", "schedules", json_data=data)
        return result[0] if result else None
    
    async def delete_schedule(self, schedule_id: str) -> bool:
        """Delete a schedule by ID."""
        params = {"id": f"eq.{schedule_id}"}
        await self._request("DELETE", "schedules", params=params)
        return True
    
    # =========================================================================
    # User Profiles
    # =========================================================================
    
    async def get_profile(self, user_id: str) -> dict[str, Any] | None:
        """Get a user profile by ID."""
        params = {
            "select": "*",
            "id": f"eq.{user_id}"
        }
        result = await self._request("GET", "profiles", params=params)
        return result[0] if result else None
    
    async def upsert_profile(self, profile: dict[str, Any]) -> dict[str, Any] | None:
        """Create or update a user profile using upsert."""
        # Use Supabase upsert by adding on_conflict handling in the request
        # The Prefer header for upsert is already set in self.headers
        result = await self._request("POST", "profiles", json_data=profile)
        return result[0] if result else None


# Singleton instance
supabase = SupabaseClient()
