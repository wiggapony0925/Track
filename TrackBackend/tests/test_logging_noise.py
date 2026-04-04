"""Regression tests for non-actionable backend logging noise."""

from __future__ import annotations

import pytest

from app.models import TransitAlert
from app.services.gtfs import realtime_parser
from app.services.transit import alert_service


@pytest.fixture
def _pretend_warmed_up():
    """Override the global warmup fixture for isolated unit tests."""
    yield


def test_fast_travel_drop_logs_at_debug_not_warning(monkeypatch: pytest.MonkeyPatch):
    """Fast-travel pruning should not emit warning-level logs."""
    calls: list[tuple[str, str, str]] = []

    def _record_debug(msg: str, *, tag: str = "TRACK") -> None:
        calls.append(("debug", tag, msg))

    def _record_warning(
        msg: str,
        *,
        tag: str = "TRACK",
        exc_info: bool = False,
    ) -> None:
        del exc_info  # Unused by this test.
        calls.append(("warning", tag, msg))

    monkeypatch.setattr(realtime_parser.TrackLogger, "debug", _record_debug)
    monkeypatch.setattr(realtime_parser.TrackLogger, "warning", _record_warning)

    realtime_parser._log_fast_travel_drop("trip-123", ["A→B", "B→C"])

    assert calls == [
        (
            "debug",
            "RT",
            "[RT] Fast-travel on trip trip-123: A→B (+1 more) — dropping",
        )
    ]


@pytest.mark.asyncio
async def test_alert_refresh_log_uses_advisory_wording(
    monkeypatch: pytest.MonkeyPatch,
):
    """Alert refresh summaries should not look like warning-level log lines."""
    messages: list[tuple[str, str]] = []

    async def _fake_get_alerts() -> list[TransitAlert]:
        return [
            TransitAlert(
                route_id="A",
                title="Severe alert",
                description="Service suspended.",
                severity="severe",
                affected_routes=["A"],
            ),
            TransitAlert(
                route_id="C",
                title="Warning alert",
                description="Delays reported.",
                severity="warning",
                affected_routes=["C"],
            ),
        ]

    def _record_info(msg: str, *, tag: str = "TRACK") -> None:
        messages.append((tag, msg))

    monkeypatch.setattr(
        "app.services.gtfs.realtime_parser.get_alerts",
        _fake_get_alerts,
    )
    monkeypatch.setattr(alert_service.TrackLogger, "info", _record_info)

    alert_service._alert_state.boost_by_route = {}
    alert_service._alert_state.last_refresh = 0.0

    await alert_service._do_refresh()

    assert messages == [
        (
            "ML",
            "[ALERTS] Index refreshed — 1 severe, 1 advisory routes affected",
        )
    ]