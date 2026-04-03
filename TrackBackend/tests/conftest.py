"""Shared pytest fixtures for test isolation.
Clears module-level caches between tests so stale data from one test
cannot leak into another."""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _clear_caches():
    """Clear all module-level caches before and after every test.

    Without this, the response-level cache in nearby.py and the
    routes cache in bus_client.py retain results across tests,
    causing mocked tests to unexpectedly receive stale data from
    a prior test that used the same GPS coordinates or cache key.
    """
    _do_clear()
    yield
    _do_clear()


@pytest.fixture(autouse=True)
def _pretend_warmed_up():
    """Mark the backend as warmed-up for tests.

    The /nearby/grouped endpoint returns 503 when _app_state.warmup_complete
    is False. In tests, feeds aren't loaded; setting this flag lets
    endpoint tests run against mocked data without hitting the gate.
    """
    import app.main as _main

    orig = _main._app_state.warmup_complete
    _main._app_state.warmup_complete = True
    yield
    _main._app_state.warmup_complete = orig


def _do_clear():
    """Best-effort cache clearing — import failures are silenced so
    the fixture never breaks a test for unrelated import reasons."""
    try:
        from app.routers.nearby import clear_nearby_cache

        clear_nearby_cache()
    except Exception:
        pass

    try:
        from app.clients.bus_client import clear_bus_cache

        clear_bus_cache()
    except Exception:
        pass

    # Reset the corridor pipeline result cache so tests that call
    # apply_topological_offsets() with small synthetic overlays get a
    # fresh result instead of the cached full-subway-system output.
    try:
        import app.services.mapping.corridor_pipeline as _cp

        _cp._pipeline_result_cache = None
    except Exception:
        pass

    # Reset the subway shapes/all in-memory cache so a test that injects
    # mock data (e.g. TestSubwayShapesAll.test_shapes_all_returns_overlays)
    # does not pollute subsequent tests that expect real pipeline data.
    try:
        import app.routers.subway as _subway

        _subway._shapes_all_cache = None
        _subway._shapes_all_json_bytes = None
        _subway._shapes_all_building = False
    except Exception:
        pass
