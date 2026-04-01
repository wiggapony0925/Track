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

    The /nearby/grouped endpoint now returns 503 when _warmup_complete
    is False. In tests, feeds aren't loaded; setting this flag lets
    endpoint tests run against mocked data without hitting the gate.
    """
    import app.main as _main

    orig = _main._warmup_complete
    _main._warmup_complete = True
    yield
    _main._warmup_complete = orig


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
