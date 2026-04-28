"""Supabase REST-backed persistence for backend-owned engine state."""

from __future__ import annotations

import json
import time
from contextlib import suppress
from datetime import UTC, datetime
from typing import Any
from urllib.parse import urlparse

import httpx

from .domain import (
    CalendarEvent,
    Itinerary,
    RecentDestination,
    RecentTrip,
    SavedPlace,
    SavedTrip,
)
from .store import recent_route_tokens


_SAVED_PLACE_COLUMNS = (
    "id,user_id,label,kind,lat,lon,address,icon,visible_on_map,"
    "created_at,updated_at,last_used_at"
)
_SAVED_PLACE_LEGACY_COLUMNS = (
    "id,user_id,label,kind,lat,lon,address,icon,created_at,updated_at,last_used_at"
)


def _unix_to_iso(timestamp_s: int | None) -> str | None:
    if timestamp_s is None:
        return None
    return (
        datetime.fromtimestamp(timestamp_s, tz=UTC)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _iso_to_unix(value: str | int | float | None) -> int | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return int(value)
    return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())


def _string_list(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, str):
        try:
            decoded = json.loads(value)
        except json.JSONDecodeError:
            return (value,)
        if isinstance(decoded, list):
            return tuple(str(item) for item in decoded)
        return (str(decoded),)
    if isinstance(value, list):
        return tuple(str(item) for item in value)
    return tuple(str(item) for item in value)


class SupabaseEngineStore:
    """Persist engine state in Supabase PostgREST using the service role key."""

    backend_name = "supabase"

    def __init__(
        self,
        *,
        supabase_url: str,
        service_key: str,
        schema: str = "public",
        timeout_s: float = 10.0,
        client: httpx.Client | None = None,
    ) -> None:
        base_url = supabase_url.rstrip("/")
        parsed = urlparse(base_url)
        project_ref = (parsed.hostname or "supabase").split(".")[0]

        self.supabase_url = base_url
        self.schema = schema
        self.description = f"supabase://{project_ref}/{schema}"
        self._service_key = service_key
        self._owns_client = client is None
        self._client = client or httpx.Client(
            base_url=f"{base_url}/rest/v1",
            timeout=timeout_s,
        )
        self._saved_places_has_visible_on_map = True

    def _headers(self, *, prefer: str | None = None) -> dict[str, str]:
        headers = {
            "apikey": self._service_key,
            "Authorization": f"Bearer {self._service_key}",
            "Accept": "application/json",
            "Accept-Profile": self.schema,
            "Content-Profile": self.schema,
        }
        if prefer:
            headers["Prefer"] = prefer
        return headers

    def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, str] | list[tuple[str, str]] | None = None,
        json_body: Any = None,
        prefer: str | None = None,
    ) -> Any:
        response = self._client.request(
            method,
            f"/{path.lstrip('/')}",
            params=params,
            json=json_body,
            headers=self._headers(prefer=prefer),
        )
        response.raise_for_status()
        if not response.content:
            return None
        return response.json()

    def _select_one(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, str] | list[tuple[str, str]] | None = None,
        json_body: Any = None,
        prefer: str | None = None,
    ) -> dict[str, Any]:
        payload = self._request(
            method,
            path,
            params=params,
            json_body=json_body,
            prefer=prefer,
        )
        if isinstance(payload, list):
            if not payload:
                raise LookupError(f"No rows returned for {path}")
            return payload[0]
        if isinstance(payload, dict):
            return payload
        raise LookupError(f"Unexpected response payload for {path}")

    def _rpc(self, function_name: str, payload: dict[str, Any]) -> Any:
        return self._request("POST", f"rpc/{function_name}", json_body=payload)

    @staticmethod
    def _is_missing_visible_on_map_error(error: httpx.HTTPStatusError) -> bool:
        if error.response.status_code != 400:
            return False
        body = error.response.text.lower()
        url = str(error.request.url).lower()
        return "visible_on_map" in body or "visible_on_map" in url

    def _saved_place_select_columns(self) -> str:
        return (
            _SAVED_PLACE_COLUMNS
            if self._saved_places_has_visible_on_map
            else _SAVED_PLACE_LEGACY_COLUMNS
        )

    def _saved_place_payload(
        self,
        *,
        user_id: str,
        label: str,
        kind: str,
        lat: float,
        lon: float,
        address: str | None,
        icon: str | None,
        visible_on_map: bool,
    ) -> dict[str, Any]:
        payload = {
            "user_id": user_id,
            "label": label,
            "kind": kind,
            "lat": lat,
            "lon": lon,
            "address": address,
            "icon": icon,
        }
        if self._saved_places_has_visible_on_map:
            payload["visible_on_map"] = visible_on_map
        return payload

    def _saved_place_from_row(self, row: dict[str, Any]) -> SavedPlace:
        return SavedPlace(
            place_id=int(row["id"]),
            user_id=str(row["user_id"]),
            label=str(row["label"]),
            kind=str(row["kind"]),
            lat=float(row["lat"]),
            lon=float(row["lon"]),
            address=row.get("address"),
            icon=row.get("icon"),
            visible_on_map=bool(row.get("visible_on_map", True)),
            created_at=int(_iso_to_unix(row["created_at"]) or 0),
            updated_at=int(_iso_to_unix(row["updated_at"]) or 0),
            last_used_at=_iso_to_unix(row.get("last_used_at")),
        )

    def _saved_trip_from_row(self, row: dict[str, Any]) -> SavedTrip:
        return SavedTrip(
            trip_id=int(row["id"]),
            user_id=str(row["user_id"]),
            name=str(row["name"]),
            origin_label=str(row["origin_label"]),
            origin_lat=float(row["origin_lat"]),
            origin_lon=float(row["origin_lon"]),
            destination_label=str(row["destination_label"]),
            destination_lat=float(row["destination_lat"]),
            destination_lon=float(row["destination_lon"]),
            preferred_departure_hour=(
                int(row["preferred_departure_hour"])
                if row.get("preferred_departure_hour") is not None
                else None
            ),
            preferred_arrival_hour=(
                int(row["preferred_arrival_hour"])
                if row.get("preferred_arrival_hour") is not None
                else None
            ),
            preferred_modes=_string_list(row.get("preferred_modes")),
            created_at=int(_iso_to_unix(row["created_at"]) or 0),
            updated_at=int(_iso_to_unix(row["updated_at"]) or 0),
            last_used_at=_iso_to_unix(row.get("last_used_at")),
        )

    def _recent_trip_from_row(self, row: dict[str, Any]) -> RecentTrip:
        return RecentTrip(
            recent_trip_id=int(row["id"]),
            user_id=str(row["user_id"]),
            origin_label=str(row["origin_label"]),
            origin_lat=float(row["origin_lat"]),
            origin_lon=float(row["origin_lon"]),
            destination_label=str(row["destination_label"]),
            destination_lat=float(row["destination_lat"]),
            destination_lon=float(row["destination_lon"]),
            requested_at=int(_iso_to_unix(row["requested_at"]) or 0),
            leave_at_ts=int(row["leave_at_ts"]),
            arrive_at_ts=int(row["arrive_at_ts"]),
            summary=str(row["summary"]),
            route_tokens=_string_list(row.get("route_tokens")),
        )

    def list_saved_places(self, user_id: str) -> list[SavedPlace]:
        params = {
            "select": self._saved_place_select_columns(),
            "user_id": f"eq.{user_id}",
            "order": "kind.asc,updated_at.desc,label.asc",
        }
        try:
            rows = self._request("GET", "engine_saved_places", params=params)
        except httpx.HTTPStatusError as exc:
            if not self._is_missing_visible_on_map_error(exc):
                raise
            self._saved_places_has_visible_on_map = False
            params["select"] = self._saved_place_select_columns()
            rows = self._request("GET", "engine_saved_places", params=params)
        return [self._saved_place_from_row(row) for row in rows or []]

    def upsert_saved_place(
        self,
        *,
        user_id: str,
        label: str,
        kind: str,
        lat: float,
        lon: float,
        address: str | None = None,
        icon: str | None = None,
        visible_on_map: bool = True,
        place_id: int | None = None,
    ) -> SavedPlace:
        payload = self._saved_place_payload(
            user_id=user_id,
            label=label,
            kind=kind,
            lat=lat,
            lon=lon,
            address=address,
            icon=icon,
            visible_on_map=visible_on_map,
        )
        if place_id is None:
            try:
                row = self._select_one(
                    "POST",
                    "engine_saved_places",
                    json_body=payload,
                    prefer="return=representation",
                )
            except httpx.HTTPStatusError as exc:
                if not self._is_missing_visible_on_map_error(exc):
                    raise
                self._saved_places_has_visible_on_map = False
                payload = self._saved_place_payload(
                    user_id=user_id,
                    label=label,
                    kind=kind,
                    lat=lat,
                    lon=lon,
                    address=address,
                    icon=icon,
                    visible_on_map=visible_on_map,
                )
                row = self._select_one(
                    "POST",
                    "engine_saved_places",
                    json_body=payload,
                    prefer="return=representation",
                )
        else:
            params = {
                "select": self._saved_place_select_columns(),
                "id": f"eq.{place_id}",
                "user_id": f"eq.{user_id}",
            }
            try:
                row = self._select_one(
                    "PATCH",
                    "engine_saved_places",
                    params=params,
                    json_body=payload,
                    prefer="return=representation",
                )
            except httpx.HTTPStatusError as exc:
                if not self._is_missing_visible_on_map_error(exc):
                    raise
                self._saved_places_has_visible_on_map = False
                params["select"] = self._saved_place_select_columns()
                payload = self._saved_place_payload(
                    user_id=user_id,
                    label=label,
                    kind=kind,
                    lat=lat,
                    lon=lon,
                    address=address,
                    icon=icon,
                    visible_on_map=visible_on_map,
                )
                row = self._select_one(
                    "PATCH",
                    "engine_saved_places",
                    params=params,
                    json_body=payload,
                    prefer="return=representation",
                )
        if "visible_on_map" not in row:
            row = {**row, "visible_on_map": visible_on_map}
        return self._saved_place_from_row(row)

    def delete_saved_place(self, user_id: str, place_id: int) -> None:
        self._request(
            "DELETE",
            "engine_saved_places",
            params={
                "id": f"eq.{place_id}",
                "user_id": f"eq.{user_id}",
            },
        )

    def touch_saved_place(self, user_id: str, place_id: int) -> None:
        now_iso = _unix_to_iso(int(time.time()))
        self._request(
            "PATCH",
            "engine_saved_places",
            params={
                "id": f"eq.{place_id}",
                "user_id": f"eq.{user_id}",
            },
            json_body={
                "last_used_at": now_iso,
                "updated_at": now_iso,
            },
        )

    def list_saved_trips(self, user_id: str) -> list[SavedTrip]:
        rows = self._request(
            "GET",
            "engine_saved_trips",
            params={
                "select": (
                    "id,user_id,name,origin_label,origin_lat,origin_lon,"
                    "destination_label,destination_lat,destination_lon,"
                    "preferred_departure_hour,preferred_arrival_hour,"
                    "preferred_modes,created_at,updated_at,last_used_at"
                ),
                "user_id": f"eq.{user_id}",
                "order": "updated_at.desc,name.asc",
            },
        )
        return [self._saved_trip_from_row(row) for row in rows or []]

    def upsert_saved_trip(
        self,
        *,
        user_id: str,
        name: str,
        origin_label: str,
        origin_lat: float,
        origin_lon: float,
        destination_label: str,
        destination_lat: float,
        destination_lon: float,
        preferred_departure_hour: int | None,
        preferred_arrival_hour: int | None,
        preferred_modes: tuple[str, ...],
        trip_id: int | None = None,
    ) -> SavedTrip:
        payload = {
            "user_id": user_id,
            "name": name,
            "origin_label": origin_label,
            "origin_lat": origin_lat,
            "origin_lon": origin_lon,
            "destination_label": destination_label,
            "destination_lat": destination_lat,
            "destination_lon": destination_lon,
            "preferred_departure_hour": preferred_departure_hour,
            "preferred_arrival_hour": preferred_arrival_hour,
            "preferred_modes": list(preferred_modes),
        }
        if trip_id is None:
            row = self._select_one(
                "POST",
                "engine_saved_trips",
                json_body=payload,
                prefer="return=representation",
            )
        else:
            row = self._select_one(
                "PATCH",
                "engine_saved_trips",
                params={
                    "select": (
                        "id,user_id,name,origin_label,origin_lat,origin_lon,"
                        "destination_label,destination_lat,destination_lon,"
                        "preferred_departure_hour,preferred_arrival_hour,"
                        "preferred_modes,created_at,updated_at,last_used_at"
                    ),
                    "id": f"eq.{trip_id}",
                    "user_id": f"eq.{user_id}",
                },
                json_body=payload,
                prefer="return=representation",
            )
        return self._saved_trip_from_row(row)

    def delete_saved_trip(self, user_id: str, trip_id: int) -> None:
        self._request(
            "DELETE",
            "engine_saved_trips",
            params={
                "id": f"eq.{trip_id}",
                "user_id": f"eq.{user_id}",
            },
        )

    def touch_saved_trip(self, user_id: str, trip_id: int) -> None:
        now_iso = _unix_to_iso(int(time.time()))
        self._request(
            "PATCH",
            "engine_saved_trips",
            params={
                "id": f"eq.{trip_id}",
                "user_id": f"eq.{user_id}",
            },
            json_body={
                "last_used_at": now_iso,
                "updated_at": now_iso,
            },
        )

    def record_recent_trip(
        self,
        user_id: str,
        *,
        origin_label: str,
        origin_lat: float,
        origin_lon: float,
        destination_label: str,
        destination_lat: float,
        destination_lon: float,
        itinerary: Itinerary,
    ) -> RecentTrip:
        row = self._select_one(
            "POST",
            "engine_recent_trips",
            json_body={
                "user_id": user_id,
                "origin_label": origin_label,
                "origin_lat": origin_lat,
                "origin_lon": origin_lon,
                "destination_label": destination_label,
                "destination_lat": destination_lat,
                "destination_lon": destination_lon,
                "requested_at": _unix_to_iso(int(time.time())),
                "leave_at_ts": itinerary.leave_at_ts,
                "arrive_at_ts": itinerary.arrive_at_ts,
                "summary": itinerary.summary,
                "route_tokens": list(recent_route_tokens(itinerary)),
            },
            prefer="return=representation",
        )
        self._rpc(
            "engine_trim_recent_trips",
            {
                "p_user_id": user_id,
                "p_keep_rows": 100,
            },
        )
        return self._recent_trip_from_row(row)

    def list_recent_trips(self, user_id: str, limit: int = 20) -> list[RecentTrip]:
        rows = self._request(
            "GET",
            "engine_recent_trips",
            params={
                "select": (
                    "id,user_id,origin_label,origin_lat,origin_lon,"
                    "destination_label,destination_lat,destination_lon,"
                    "requested_at,leave_at_ts,arrive_at_ts,summary,route_tokens"
                ),
                "user_id": f"eq.{user_id}",
                "order": "requested_at.desc,id.desc",
                "limit": str(limit),
            },
        )
        return [self._recent_trip_from_row(row) for row in rows or []]

    def list_recent_destinations(
        self,
        user_id: str,
        limit: int = 20,
    ) -> list[RecentDestination]:
        rows = self._rpc(
            "engine_recent_destinations",
            {
                "p_user_id": user_id,
                "p_limit": limit,
            },
        )
        return [
            RecentDestination(
                label=str(row["label"]),
                lat=float(row["lat"]),
                lon=float(row["lon"]),
                trip_count=int(row["trip_count"]),
                last_used_at=int(row["last_used_at"]),
            )
            for row in rows or []
        ]

    def replace_calendar_events(
        self,
        user_id: str,
        events: list[CalendarEvent],
    ) -> list[CalendarEvent]:
        self._request(
            "DELETE",
            "engine_calendar_events",
            params={"user_id": f"eq.{user_id}"},
        )
        if not events:
            return []

        now_iso = _unix_to_iso(int(time.time()))
        payload = [
            {
                "user_id": user_id,
                "external_id": event.external_id,
                "title": event.title,
                "location_label": event.location_label,
                "lat": event.lat,
                "lon": event.lon,
                "starts_at": _unix_to_iso(event.starts_at),
                "ends_at": _unix_to_iso(event.ends_at),
                "notes": event.notes,
                "created_at": now_iso,
                "updated_at": now_iso,
            }
            for event in events
        ]
        self._request(
            "POST",
            "engine_calendar_events",
            json_body=payload,
        )
        return events

    def list_calendar_events(
        self,
        user_id: str,
        *,
        starts_after: int | None = None,
        starts_before: int | None = None,
        limit: int = 25,
    ) -> list[CalendarEvent]:
        params: list[tuple[str, str]] = [
            (
                "select",
                "external_id,title,location_label,lat,lon,starts_at,ends_at,notes",
            ),
            ("user_id", f"eq.{user_id}"),
        ]
        if starts_after is not None:
            params.append(("starts_at", f"gte.{_unix_to_iso(starts_after)}"))
        if starts_before is not None:
            params.append(("starts_at", f"lte.{_unix_to_iso(starts_before)}"))
        params.extend(
            [
                ("order", "starts_at.asc"),
                ("limit", str(limit)),
            ]
        )

        rows = self._request("GET", "engine_calendar_events", params=params)
        return [
            CalendarEvent(
                external_id=str(row["external_id"]),
                title=str(row["title"]),
                location_label=str(row["location_label"]),
                starts_at=int(_iso_to_unix(row["starts_at"]) or 0),
                ends_at=_iso_to_unix(row.get("ends_at")),
                lat=float(row["lat"]) if row.get("lat") is not None else None,
                lon=float(row["lon"]) if row.get("lon") is not None else None,
                notes=row.get("notes"),
            )
            for row in rows or []
        ]

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def __del__(self) -> None:  # pragma: no cover - defensive cleanup only
        with suppress(Exception):
            self.close()
