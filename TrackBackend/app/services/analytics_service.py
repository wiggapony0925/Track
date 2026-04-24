"""Server-side analytics ingest service.

Backend is the *only* writer to the analytics tables — iOS POSTs batched
events to ``/analytics/batch`` (with a Supabase Bearer token), this service
validates + enriches + inserts via the service-role key.

Design
------
* One async ``httpx.AsyncClient`` shared via lru_cache.
* Per-table dispatch: each event in the batch carries a ``type`` discriminator
  and is routed to the matching Supabase table.
* Inserts use ``Prefer: return=minimal`` for throughput — we don't need the
  generated ids back to the client.
* Failures are logged but never raised: telemetry must never break a user
  session.  The router returns a per-event accept/reject count.
* Session lifecycle helpers (``start_session`` / ``end_session`` /
  ``touch_session``) are split out so the iOS client can manage them
  explicitly without sending them through the generic event stream.
"""

from __future__ import annotations

import asyncio
import os
import uuid
from functools import lru_cache
from typing import Any

import httpx

from app.utils.logger import TrackLogger

_TAG = "ANALYTICS"

# ── Connection ───────────────────────────────────────────────────────────────


def _supabase_url() -> str:
    return os.environ.get("SUPABASE_URL", "").rstrip("/")


def _service_key() -> str:
    return (
        os.environ.get("SUPABASE_SERVICE_KEY")
        or os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        or ""
    )


@lru_cache(maxsize=1)
def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=_supabase_url(),
        headers={
            "apikey": _service_key(),
            "Authorization": f"Bearer {_service_key()}",
            "Content-Type": "application/json",
            "Content-Profile": "public",
            "Prefer": "return=minimal",
        },
        timeout=8.0,
    )


def _enabled() -> bool:
    return bool(_supabase_url() and _service_key())


# ── Per-table column whitelists ──────────────────────────────────────────────
# Reject anything not in the schema so a malformed iOS build can't crash inserts.

_EVENT_COLUMNS = {
    "user_sessions": {
        "id", "user_id", "started_at", "ended_at", "last_active_at",
        "app_version", "build", "os_version", "device_model", "locale",
        "timezone", "network_type", "foreground_seconds", "screens_viewed",
        "events_count", "entry_screen", "entry_source",
        "push_notification_id", "initial_lat", "initial_lon",
    },
    "analytics_events": {
        "user_id", "session_id", "event_name", "properties", "screen",
        "occurred_at", "app_version", "os_version", "device_model",
        "network_type", "lat", "lon",
    },
    "screen_views": {
        "user_id", "session_id", "screen", "previous_screen", "entered_at",
        "exited_at", "duration_ms", "scroll_depth_pct", "interactions_count",
        "reached_via", "app_version",
    },
    "search_queries": {
        "user_id", "session_id", "source", "query", "results_count",
        "picked_index", "picked_id", "picked_kind", "latency_ms",
        "abandoned", "origin_lat", "origin_lon", "occurred_at",
    },
    "route_engagements": {
        "user_id", "session_id", "action", "route_id", "route_display_name",
        "mode", "origin_label", "origin_lat", "origin_lon",
        "destination_label", "destination_lat", "destination_lon",
        "eta_seconds", "transfers_count", "walk_meters",
        "predicted_arrival", "actual_arrival", "alternatives_offered",
        "position_in_list", "source_screen", "metadata", "occurred_at",
    },
    "map_interactions": {
        "user_id", "session_id", "kind", "zoom_level", "center_lat",
        "center_lon", "target_id", "target_kind", "occurred_at",
    },
    "error_events": {
        "user_id", "session_id", "kind", "severity", "message", "stack",
        "screen", "endpoint", "http_status", "app_version", "os_version",
        "metadata", "occurred_at",
    },
    "performance_metrics": {
        "user_id", "session_id", "kind", "name", "duration_ms",
        "http_status", "payload_bytes", "cache_hit", "network_type",
        "occurred_at",
    },
    "notification_events": {
        "user_id", "session_id", "kind", "notification_id", "category",
        "action_id", "payload", "occurred_at",
    },
    "feature_flag_exposures": {
        "user_id", "session_id", "flag_key", "variant", "context",
        "occurred_at",
    },
}

# Map iOS event "type" → Supabase table.
_TYPE_TO_TABLE = {
    "event": "analytics_events",
    "screen_view": "screen_views",
    "search": "search_queries",
    "route": "route_engagements",
    "map": "map_interactions",
    "error": "error_events",
    "perf": "performance_metrics",
    "notification": "notification_events",
    "exposure": "feature_flag_exposures",
}


def _filter_payload(table: str, payload: dict[str, Any]) -> dict[str, Any]:
    cols = _EVENT_COLUMNS.get(table, set())
    return {k: v for k, v in payload.items() if k in cols and v is not None}


# ── Session lifecycle ────────────────────────────────────────────────────────


async def start_session(
    user_id: uuid.UUID,
    *,
    app_version: str | None = None,
    build: str | None = None,
    os_version: str | None = None,
    device_model: str | None = None,
    locale: str | None = None,
    timezone: str | None = None,
    network_type: str | None = None,
    entry_screen: str | None = None,
    entry_source: str | None = None,
    push_notification_id: str | None = None,
    initial_lat: float | None = None,
    initial_lon: float | None = None,
) -> str | None:
    """Create a new session row and return its id, or None on failure."""
    if not _enabled():
        return None
    session_id = str(uuid.uuid4())
    payload = _filter_payload("user_sessions", {
        "id": session_id,
        "user_id": str(user_id),
        "app_version": app_version,
        "build": build,
        "os_version": os_version,
        "device_model": device_model,
        "locale": locale,
        "timezone": timezone,
        "network_type": network_type,
        "entry_screen": entry_screen,
        "entry_source": entry_source,
        "push_notification_id": push_notification_id,
        "initial_lat": initial_lat,
        "initial_lon": initial_lon,
    })
    try:
        r = await _client().post("/rest/v1/user_sessions", json=payload)
        if r.status_code >= 300:
            TrackLogger.warning(
                f"start_session failed: {r.status_code} {r.text[:200]}", tag=_TAG
            )
            return None
        return session_id
    except Exception as exc:  # noqa: BLE001
        TrackLogger.warning(f"start_session exception: {exc}", tag=_TAG)
        return None


async def end_session(
    session_id: str,
    user_id: uuid.UUID,
    *,
    foreground_seconds: int | None = None,
    screens_viewed: int | None = None,
    events_count: int | None = None,
) -> bool:
    if not _enabled():
        return False
    patch: dict[str, Any] = {"ended_at": "now()"}
    # Use SQL "now()" via PostgREST: actually PostgREST doesn't evaluate "now()".
    # Just send a fresh ISO timestamp from the server side.
    from datetime import datetime, timezone as _tz
    patch["ended_at"] = datetime.now(_tz.utc).isoformat()
    if foreground_seconds is not None:
        patch["foreground_seconds"] = max(0, int(foreground_seconds))
    if screens_viewed is not None:
        patch["screens_viewed"] = max(0, int(screens_viewed))
    if events_count is not None:
        patch["events_count"] = max(0, int(events_count))
    try:
        r = await _client().patch(
            "/rest/v1/user_sessions",
            params={"id": f"eq.{session_id}", "user_id": f"eq.{user_id}"},
            json=patch,
        )
        return r.status_code < 300
    except Exception as exc:  # noqa: BLE001
        TrackLogger.warning(f"end_session exception: {exc}", tag=_TAG)
        return False


# ── Batch ingest ─────────────────────────────────────────────────────────────


async def ingest_batch(
    user_id: uuid.UUID,
    events: list[dict[str, Any]],
    *,
    default_session_id: str | None = None,
) -> dict[str, int]:
    """Ingest a batch of mixed-type events.

    Each event must carry ``type`` (one of ``_TYPE_TO_TABLE`` keys).
    Returns ``{"accepted": n, "rejected": m, "tables": {table: count}}``.
    """
    if not _enabled() or not events:
        return {"accepted": 0, "rejected": len(events), "tables": {}}

    # Bucket by destination table.
    buckets: dict[str, list[dict[str, Any]]] = {}
    rejected = 0
    uid = str(user_id)
    for ev in events:
        if not isinstance(ev, dict):
            rejected += 1
            continue
        t = ev.get("type")
        table = _TYPE_TO_TABLE.get(str(t) if t is not None else "")
        if table is None:
            rejected += 1
            continue
        row = dict(ev)
        row.pop("type", None)
        row.setdefault("session_id", default_session_id)
        row["user_id"] = uid
        row = _filter_payload(table, row)
        if not row.get("user_id"):
            rejected += 1
            continue
        buckets.setdefault(table, []).append(row)

    table_counts: dict[str, int] = {}

    async def _flush(table: str, rows: list[dict[str, Any]]) -> None:
        if not rows:
            return
        try:
            r = await _client().post(f"/rest/v1/{table}", json=rows)
            if r.status_code >= 300:
                TrackLogger.warning(
                    f"ingest {table} failed: {r.status_code} {r.text[:300]}",
                    tag=_TAG,
                )
                return
            table_counts[table] = len(rows)
        except Exception as exc:  # noqa: BLE001
            TrackLogger.warning(f"ingest {table} exception: {exc}", tag=_TAG)

    await asyncio.gather(*[_flush(t, rows) for t, rows in buckets.items()])

    accepted = sum(table_counts.values())
    return {
        "accepted": accepted,
        "rejected": len(events) - accepted,
        "tables": table_counts,
    }
