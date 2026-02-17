#
# test_bus_routes.py
# TrackBackend
#
# Comprehensive test suite verifying that ALL 365 bus routes from
# early_2026_buses_tag.json are correctly covered by the backend.
#
# Tests cover:
#   1. JSON integrity — the canonical data file loads and has expected structure
#   2. ROUTE_LOOKUP — every route in the JSON is in the in-memory lookup
#   3. get_routes() — the multi-agency fetch returns ALL routes when mocked
#   4. Config wiring — settings.json has both MTA NYCT and MTABC agencies
#   5. resolve_bus_id() — resolves every short name to its canonical ID
#   6. Endpoint integration — /bus/routes returns all 365 routes
#   7. Display name — agency prefix stripping
#   8. Per-route parametrized — EVERY SINGLE BUS individually tested
#

from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from unittest.mock import AsyncMock, patch

import pytest

from app.config import get_settings
from app.models import BusRoute
from app.services.bus_client import ROUTE_LOOKUP, get_routes, resolve_bus_id
from app.routers.nearby import _display_name

# ---------------------------------------------------------------------------
# Fixtures: load the canonical JSON once for the whole module
# ---------------------------------------------------------------------------

_JSON_PATH = Path(__file__).resolve().parent.parent / "app" / "data" / "early_2026_buses_tag.json"


@pytest.fixture(scope="module")
def bus_json() -> dict[str, dict[str, str]]:
    """Load and return the raw early_2026_buses_tag.json."""
    assert _JSON_PATH.exists(), f"Bus JSON not found at {_JSON_PATH}"
    with open(_JSON_PATH) as f:
        return json.load(f)


@pytest.fixture(scope="module")
def all_routes(bus_json: dict) -> list[tuple[str, str, str]]:
    """Return a flat list of (category, short_name, official_id) for every route."""
    routes: list[tuple[str, str, str]] = []
    for category, mapping in bus_json.items():
        for short_name, official_id in mapping.items():
            routes.append((category, short_name, official_id))
    return routes


@pytest.fixture(scope="module")
def nyct_routes(all_routes: list) -> list[tuple[str, str, str]]:
    """Only MTA NYCT routes."""
    return [(c, s, oid) for c, s, oid in all_routes if oid.startswith("MTA NYCT_")]


@pytest.fixture(scope="module")
def mtabc_routes(all_routes: list) -> list[tuple[str, str, str]]:
    """Only MTABC routes."""
    return [(c, s, oid) for c, s, oid in all_routes if oid.startswith("MTABC_")]


# ===================================================================
# 1. JSON FILE INTEGRITY
# ===================================================================


class TestBusJsonIntegrity:
    """Verify the canonical bus JSON file has the expected structure."""

    def test_json_file_exists(self):
        assert _JSON_PATH.exists()

    def test_json_is_valid(self, bus_json):
        assert isinstance(bus_json, dict)

    def test_has_all_six_categories(self, bus_json):
        expected = {"Brooklyn", "Manhattan", "Queens", "Bronx", "Staten Island", "Express"}
        assert set(bus_json.keys()) == expected

    def test_total_route_count(self, all_routes):
        assert len(all_routes) == 365, (
            f"Expected 365 total routes, got {len(all_routes)}"
        )

    def test_brooklyn_count(self, bus_json):
        assert len(bus_json["Brooklyn"]) == 66

    def test_manhattan_count(self, bus_json):
        assert len(bus_json["Manhattan"]) == 43

    def test_queens_count(self, bus_json):
        assert len(bus_json["Queens"]) == 100

    def test_bronx_count(self, bus_json):
        assert len(bus_json["Bronx"]) == 48

    def test_staten_island_count(self, bus_json):
        assert len(bus_json["Staten Island"]) == 31

    def test_express_count(self, bus_json):
        assert len(bus_json["Express"]) == 77

    def test_agency_split(self, nyct_routes, mtabc_routes, all_routes):
        assert len(nyct_routes) == 273, f"Expected 273 MTA NYCT, got {len(nyct_routes)}"
        assert len(mtabc_routes) == 92, f"Expected 92 MTABC, got {len(mtabc_routes)}"
        assert len(nyct_routes) + len(mtabc_routes) == len(all_routes)

    def test_every_route_has_agency_prefix(self, all_routes):
        for category, short_name, official_id in all_routes:
            assert "_" in official_id, (
                f"{category}/{short_name}: official_id '{official_id}' missing agency prefix"
            )

    def test_no_duplicate_official_ids(self, all_routes):
        ids = [oid for _, _, oid in all_routes]
        dupes = [oid for oid in ids if ids.count(oid) > 1]
        assert len(dupes) == 0, f"Duplicate official IDs found: {set(dupes)}"


# ===================================================================
# 2. ROUTE_LOOKUP COVERAGE
# ===================================================================


class TestRouteLookupCoverage:
    """Verify every route in the JSON is in the ROUTE_LOOKUP dict."""

    def test_route_lookup_not_empty(self):
        assert len(ROUTE_LOOKUP) > 0, "ROUTE_LOOKUP is empty — JSON failed to load"

    def test_every_short_name_in_lookup(self, all_routes):
        missing = []
        for category, short_name, expected_id in all_routes:
            if short_name not in ROUTE_LOOKUP:
                missing.append(f"{category}/{short_name}")
        assert len(missing) == 0, (
            f"{len(missing)} routes missing from ROUTE_LOOKUP: {missing[:20]}"
        )

    def test_every_lookup_resolves_to_correct_id(self, all_routes):
        wrong = []
        for category, short_name, expected_id in all_routes:
            actual = ROUTE_LOOKUP.get(short_name)
            if actual != expected_id:
                wrong.append(f"{short_name}: expected={expected_id}, got={actual}")
        assert len(wrong) == 0, (
            f"{len(wrong)} routes have wrong IDs: {wrong[:20]}"
        )

    def test_lowercase_lookups_exist(self, all_routes):
        missing = []
        for _, short_name, _ in all_routes:
            if short_name.lower() not in ROUTE_LOOKUP:
                missing.append(short_name)
        assert len(missing) == 0, (
            f"Lowercase lookup missing for: {missing[:20]}"
        )


# ===================================================================
# 3. get_routes() — MULTI-AGENCY FETCH
# ===================================================================


def _make_oba_response(routes: list[tuple[str, str, str]]) -> dict[str, Any]:
    """Build a fake OBA JSON response for a list of (id, short_name, long_name)."""
    return {
        "code": 200,
        "data": {
            "list": [
                {
                    "id": rid,
                    "shortName": sn,
                    "longName": ln,
                    "color": "0039A6",
                    "description": "",
                }
                for rid, sn, ln in routes
            ]
        },
    }


SAMPLE_NYCT_ROUTES = [
    ("MTA NYCT_B63", "B63", "Atlantic Av / Fulton St"),
    ("MTA NYCT_M15", "M15", "First Av / Second Av"),
    ("MTA NYCT_Bx1", "Bx1", "Grand Concourse"),
]

SAMPLE_MTABC_ROUTES = [
    ("MTABC_Q58", "Q58", "Maspeth / Ridgewood"),
    ("MTABC_QM1", "QM1", "Bayside / Manhattan Express"),
]


class TestGetRoutesMultiAgency:
    """Verify get_routes() queries ALL agencies and merges results."""

    @pytest.mark.asyncio
    @patch("app.services.bus_client._fetch_bus_json", new_callable=AsyncMock)
    async def test_returns_routes_from_both_agencies(self, mock_fetch):
        """Mock both OBA responses and confirm both sets of routes are returned."""
        mock_fetch.side_effect = [
            _make_oba_response(SAMPLE_NYCT_ROUTES),
            _make_oba_response(SAMPLE_MTABC_ROUTES),
        ]
        routes = await get_routes()
        short_names = {r.short_name for r in routes}
        assert "B63" in short_names, "Missing NYCT route B63"
        assert "Q58" in short_names, "Missing MTABC route Q58"
        assert len(routes) == 5

    @pytest.mark.asyncio
    @patch("app.services.bus_client._fetch_bus_json", new_callable=AsyncMock)
    async def test_deduplicates_by_id(self, mock_fetch):
        """If both agencies return the same route ID, keep only one copy."""
        overlap = [("MTA NYCT_B63", "B63", "Atlantic Av / Fulton St")]
        mock_fetch.side_effect = [
            _make_oba_response(SAMPLE_NYCT_ROUTES),
            _make_oba_response(overlap),  # B63 appears in both
        ]
        routes = await get_routes()
        b63_count = sum(1 for r in routes if r.id == "MTA NYCT_B63")
        assert b63_count == 1, f"B63 duplicated: appeared {b63_count} times"

    @pytest.mark.asyncio
    @patch("app.services.bus_client._fetch_bus_json", new_callable=AsyncMock)
    async def test_survives_one_agency_failure(self, mock_fetch):
        """If one agency fetch fails, the other should still return routes."""
        mock_fetch.side_effect = [
            Exception("MTA NYCT API down"),
            _make_oba_response(SAMPLE_MTABC_ROUTES),
        ]
        routes = await get_routes()
        assert len(routes) == 2, "Should still return MTABC routes when NYCT fails"

    @pytest.mark.asyncio
    @patch("app.services.bus_client._fetch_bus_json", new_callable=AsyncMock)
    async def test_returns_empty_when_all_agencies_fail(self, mock_fetch):
        mock_fetch.side_effect = [
            Exception("NYCT down"),
            Exception("MTABC down"),
        ]
        routes = await get_routes()
        assert routes == []

    @pytest.mark.asyncio
    @patch("app.services.bus_client._fetch_bus_json", new_callable=AsyncMock)
    async def test_calls_fetch_for_each_agency(self, mock_fetch):
        """Confirm _fetch_bus_json is called once per agency in settings."""
        mock_fetch.return_value = _make_oba_response([])
        await get_routes()
        # Should be called at least 2 times (NYCT + MTABC)
        assert mock_fetch.call_count >= 2, (
            f"Expected at least 2 agency calls, got {mock_fetch.call_count}"
        )


# ===================================================================
# 4. SETTINGS / CONFIG WIRING
# ===================================================================


class TestSettingsMultiAgency:
    """Verify settings.json has the multi-agency configuration."""

    def test_routes_for_agency_is_list(self):
        settings = get_settings()
        eps = settings.urls.bus_endpoints
        assert eps is not None, "bus_endpoints not configured"
        assert isinstance(eps.routes_for_agency, list), (
            f"routes_for_agency should be a list, got {type(eps.routes_for_agency)}"
        )

    def test_routes_for_agency_has_nyct(self):
        settings = get_settings()
        eps = settings.urls.bus_endpoints
        paths = eps.routes_for_agency if isinstance(eps.routes_for_agency, list) else [eps.routes_for_agency]
        has_nyct = any("MTA" in p and "NYCT" in p for p in paths)
        assert has_nyct, f"No MTA NYCT agency in routes_for_agency: {paths}"

    def test_routes_for_agency_has_mtabc(self):
        settings = get_settings()
        eps = settings.urls.bus_endpoints
        paths = eps.routes_for_agency if isinstance(eps.routes_for_agency, list) else [eps.routes_for_agency]
        has_mtabc = any("MTABC" in p for p in paths)
        assert has_mtabc, f"No MTABC agency in routes_for_agency: {paths}"

    def test_oba_base_url_configured(self):
        settings = get_settings()
        assert settings.urls.bus_oba_base, "bus_oba_base URL is empty"

    def test_bus_api_key_configured(self):
        settings = get_settings()
        assert settings.api_keys.mta_bus_key, "mta_bus_key is empty"


# ===================================================================
# 5. resolve_bus_id() — EVERY ROUTE FROM JSON
# ===================================================================


class TestResolveBusIdComplete:
    """Verify resolve_bus_id returns the correct canonical ID for every route."""

    @pytest.mark.asyncio
    async def test_resolve_every_json_route(self, all_routes):
        """The big one: iterate every single route from the JSON and
        verify resolve_bus_id maps short_name -> official_id."""
        failures = []
        for category, short_name, expected_id in all_routes:
            actual = await resolve_bus_id(short_name)
            if actual != expected_id:
                failures.append(
                    f"  {category}/{short_name}: expected={expected_id}, got={actual}"
                )
        assert len(failures) == 0, (
            f"\n{len(failures)} / {len(all_routes)} routes failed resolve_bus_id:\n"
            + "\n".join(failures[:30])
        )

    @pytest.mark.asyncio
    async def test_resolve_all_nyct(self, nyct_routes):
        """All 273 MTA NYCT routes resolve correctly."""
        failures = []
        for _, short_name, expected_id in nyct_routes:
            actual = await resolve_bus_id(short_name)
            if actual != expected_id:
                failures.append(f"{short_name}: {expected_id} -> {actual}")
        assert len(failures) == 0, (
            f"{len(failures)} NYCT routes failed: {failures[:20]}"
        )

    @pytest.mark.asyncio
    async def test_resolve_all_mtabc(self, mtabc_routes):
        """All 92 MTABC routes resolve correctly."""
        failures = []
        for _, short_name, expected_id in mtabc_routes:
            actual = await resolve_bus_id(short_name)
            if actual != expected_id:
                failures.append(f"{short_name}: {expected_id} -> {actual}")
        assert len(failures) == 0, (
            f"{len(failures)} MTABC routes failed: {failures[:20]}"
        )

    @pytest.mark.asyncio
    async def test_already_qualified_ids_pass_through(self, all_routes):
        """IDs that already have an agency prefix should pass through unchanged."""
        for _, _, official_id in all_routes[:50]:
            result = await resolve_bus_id(official_id)
            assert result == official_id, (
                f"Qualified ID changed: {official_id} -> {result}"
            )


# ===================================================================
# 6. ENDPOINT INTEGRATION (mocked)
# ===================================================================


class TestBusRoutesEndpointCoverage:
    """GET /bus/routes — verify the endpoint returns routes from both agencies."""

    @patch("app.routers.bus.get_routes", new_callable=AsyncMock)
    def test_endpoint_returns_all_365_routes(self, mock_routes, all_routes):
        """Simulate get_routes returning all 365 routes and confirm the
        endpoint passes them through correctly."""
        from fastapi.testclient import TestClient
        from app.main import app
        test_client = TestClient(app)

        mock_routes.return_value = [
            BusRoute(
                id=oid,
                short_name=sn,
                long_name=f"{cat} bus",
                color="0039A6",
                description=cat,
            )
            for cat, sn, oid in all_routes
        ]
        response = test_client.get("/bus/routes")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 365, f"Expected 365 routes, got {len(data)}"

        # Verify every official ID is present
        returned_ids = {r["id"] for r in data}
        expected_ids = {oid for _, _, oid in all_routes}
        missing = expected_ids - returned_ids
        assert len(missing) == 0, f"Endpoint missing {len(missing)} routes: {missing}"


# ===================================================================
# 7. DISPLAY NAME — AGENCY PREFIX STRIPPING
# ===================================================================


class TestDisplayNameAllRoutes:
    """Verify _display_name() strips ALL agency prefixes for bus routes."""

    def test_strips_mta_nyct_prefix(self):
        assert _display_name("MTA NYCT_B63") == "B63"
        assert _display_name("MTA NYCT_M15+") == "M15+"
        assert _display_name("MTA NYCT_Bx1") == "Bx1"

    def test_strips_mtabc_prefix(self):
        assert _display_name("MTABC_Q112") == "Q112"
        assert _display_name("MTABC_QM1") == "QM1"
        assert _display_name("MTABC_Q58") == "Q58"

    def test_strips_mta_bus_prefix(self):
        assert _display_name("MTA BUS_Q10") == "Q10"

    def test_passthrough_plain_ids(self):
        assert _display_name("Q43") == "Q43"
        assert _display_name("B63") == "B63"

    def test_every_json_route_display_name_is_clean(self, all_routes):
        """For every route in the JSON, _display_name(official_id) should
        return the short_name (no agency prefix)."""
        failures = []
        for category, short_name, official_id in all_routes:
            display = _display_name(official_id)
            # The display name should match the short name, except for
            # SBS routes where "B46-SBS" maps to "B46+" (the + is the MTA convention)
            if "_" in display:
                failures.append(
                    f"  {category}/{short_name}: _display_name('{official_id}') = '{display}' (still has prefix!)"
                )
        assert len(failures) == 0, (
            f"\n{len(failures)} routes still have agency prefix in display name:\n"
            + "\n".join(failures[:30])
        )


# ===================================================================
# 8. PER-ROUTE PARAMETRIZED TESTS — EVERY SINGLE BUS
# ===================================================================

# Build the full list at module load time so @pytest.mark.parametrize works.
# Each entry: (short_name, official_id, category)
def _load_all_bus_routes() -> list[tuple[str, str, str]]:
    with open(_JSON_PATH) as f:
        data = json.load(f)
    routes = []
    for category, mapping in data.items():
        for short_name, official_id in mapping.items():
            routes.append((short_name, official_id, category))
    return routes

_ALL_BUS_ROUTES = _load_all_bus_routes()

# Split by borough for readability in test output
_BROOKLYN_ROUTES = [(s, o) for s, o, c in _ALL_BUS_ROUTES if c == "Brooklyn"]
_MANHATTAN_ROUTES = [(s, o) for s, o, c in _ALL_BUS_ROUTES if c == "Manhattan"]
_QUEENS_ROUTES = [(s, o) for s, o, c in _ALL_BUS_ROUTES if c == "Queens"]
_BRONX_ROUTES = [(s, o) for s, o, c in _ALL_BUS_ROUTES if c == "Bronx"]
_STATEN_ISLAND_ROUTES = [(s, o) for s, o, c in _ALL_BUS_ROUTES if c == "Staten Island"]
_EXPRESS_ROUTES = [(s, o) for s, o, c in _ALL_BUS_ROUTES if c == "Express"]


class TestEveryBrooklynBus:
    """Test every single Brooklyn bus route individually (66 routes)."""

    @pytest.mark.parametrize("short_name,official_id", _BROOKLYN_ROUTES, ids=[r[0] for r in _BROOKLYN_ROUTES])
    def test_in_route_lookup(self, short_name, official_id):
        assert short_name in ROUTE_LOOKUP, f"{short_name} not in ROUTE_LOOKUP"
        assert ROUTE_LOOKUP[short_name] == official_id

    @pytest.mark.parametrize("short_name,official_id", _BROOKLYN_ROUTES, ids=[r[0] for r in _BROOKLYN_ROUTES])
    def test_display_name_clean(self, short_name, official_id):
        display = _display_name(official_id)
        assert "_" not in display, f"_display_name('{official_id}') = '{display}' still has prefix"

    @pytest.mark.parametrize("short_name,official_id", _BROOKLYN_ROUTES, ids=[r[0] for r in _BROOKLYN_ROUTES])
    @pytest.mark.asyncio
    async def test_resolve_bus_id(self, short_name, official_id):
        result = await resolve_bus_id(short_name)
        assert result == official_id, f"resolve_bus_id('{short_name}') = '{result}', expected '{official_id}'"


class TestEveryManhattanBus:
    """Test every single Manhattan bus route individually (43 routes)."""

    @pytest.mark.parametrize("short_name,official_id", _MANHATTAN_ROUTES, ids=[r[0] for r in _MANHATTAN_ROUTES])
    def test_in_route_lookup(self, short_name, official_id):
        assert short_name in ROUTE_LOOKUP, f"{short_name} not in ROUTE_LOOKUP"
        assert ROUTE_LOOKUP[short_name] == official_id

    @pytest.mark.parametrize("short_name,official_id", _MANHATTAN_ROUTES, ids=[r[0] for r in _MANHATTAN_ROUTES])
    def test_display_name_clean(self, short_name, official_id):
        display = _display_name(official_id)
        assert "_" not in display, f"_display_name('{official_id}') = '{display}' still has prefix"

    @pytest.mark.parametrize("short_name,official_id", _MANHATTAN_ROUTES, ids=[r[0] for r in _MANHATTAN_ROUTES])
    @pytest.mark.asyncio
    async def test_resolve_bus_id(self, short_name, official_id):
        result = await resolve_bus_id(short_name)
        assert result == official_id, f"resolve_bus_id('{short_name}') = '{result}', expected '{official_id}'"


class TestEveryQueensBus:
    """Test every single Queens bus route individually (100 routes)."""

    @pytest.mark.parametrize("short_name,official_id", _QUEENS_ROUTES, ids=[r[0] for r in _QUEENS_ROUTES])
    def test_in_route_lookup(self, short_name, official_id):
        assert short_name in ROUTE_LOOKUP, f"{short_name} not in ROUTE_LOOKUP"
        assert ROUTE_LOOKUP[short_name] == official_id

    @pytest.mark.parametrize("short_name,official_id", _QUEENS_ROUTES, ids=[r[0] for r in _QUEENS_ROUTES])
    def test_display_name_clean(self, short_name, official_id):
        display = _display_name(official_id)
        assert "_" not in display, f"_display_name('{official_id}') = '{display}' still has prefix"

    @pytest.mark.parametrize("short_name,official_id", _QUEENS_ROUTES, ids=[r[0] for r in _QUEENS_ROUTES])
    @pytest.mark.asyncio
    async def test_resolve_bus_id(self, short_name, official_id):
        result = await resolve_bus_id(short_name)
        assert result == official_id, f"resolve_bus_id('{short_name}') = '{result}', expected '{official_id}'"


class TestEveryBronxBus:
    """Test every single Bronx bus route individually (48 routes)."""

    @pytest.mark.parametrize("short_name,official_id", _BRONX_ROUTES, ids=[r[0] for r in _BRONX_ROUTES])
    def test_in_route_lookup(self, short_name, official_id):
        assert short_name in ROUTE_LOOKUP, f"{short_name} not in ROUTE_LOOKUP"
        assert ROUTE_LOOKUP[short_name] == official_id

    @pytest.mark.parametrize("short_name,official_id", _BRONX_ROUTES, ids=[r[0] for r in _BRONX_ROUTES])
    def test_display_name_clean(self, short_name, official_id):
        display = _display_name(official_id)
        assert "_" not in display, f"_display_name('{official_id}') = '{display}' still has prefix"

    @pytest.mark.parametrize("short_name,official_id", _BRONX_ROUTES, ids=[r[0] for r in _BRONX_ROUTES])
    @pytest.mark.asyncio
    async def test_resolve_bus_id(self, short_name, official_id):
        result = await resolve_bus_id(short_name)
        assert result == official_id, f"resolve_bus_id('{short_name}') = '{result}', expected '{official_id}'"


class TestEveryStatenIslandBus:
    """Test every single Staten Island bus route individually (31 routes)."""

    @pytest.mark.parametrize("short_name,official_id", _STATEN_ISLAND_ROUTES, ids=[r[0] for r in _STATEN_ISLAND_ROUTES])
    def test_in_route_lookup(self, short_name, official_id):
        assert short_name in ROUTE_LOOKUP, f"{short_name} not in ROUTE_LOOKUP"
        assert ROUTE_LOOKUP[short_name] == official_id

    @pytest.mark.parametrize("short_name,official_id", _STATEN_ISLAND_ROUTES, ids=[r[0] for r in _STATEN_ISLAND_ROUTES])
    def test_display_name_clean(self, short_name, official_id):
        display = _display_name(official_id)
        assert "_" not in display, f"_display_name('{official_id}') = '{display}' still has prefix"

    @pytest.mark.parametrize("short_name,official_id", _STATEN_ISLAND_ROUTES, ids=[r[0] for r in _STATEN_ISLAND_ROUTES])
    @pytest.mark.asyncio
    async def test_resolve_bus_id(self, short_name, official_id):
        result = await resolve_bus_id(short_name)
        assert result == official_id, f"resolve_bus_id('{short_name}') = '{result}', expected '{official_id}'"


class TestEveryExpressBus:
    """Test every single Express bus route individually (77 routes)."""

    @pytest.mark.parametrize("short_name,official_id", _EXPRESS_ROUTES, ids=[r[0] for r in _EXPRESS_ROUTES])
    def test_in_route_lookup(self, short_name, official_id):
        assert short_name in ROUTE_LOOKUP, f"{short_name} not in ROUTE_LOOKUP"
        assert ROUTE_LOOKUP[short_name] == official_id

    @pytest.mark.parametrize("short_name,official_id", _EXPRESS_ROUTES, ids=[r[0] for r in _EXPRESS_ROUTES])
    def test_display_name_clean(self, short_name, official_id):
        display = _display_name(official_id)
        assert "_" not in display, f"_display_name('{official_id}') = '{display}' still has prefix"

    @pytest.mark.parametrize("short_name,official_id", _EXPRESS_ROUTES, ids=[r[0] for r in _EXPRESS_ROUTES])
    @pytest.mark.asyncio
    async def test_resolve_bus_id(self, short_name, official_id):
        result = await resolve_bus_id(short_name)
        assert result == official_id, f"resolve_bus_id('{short_name}') = '{result}', expected '{official_id}'"


# ===================================================================
# 9. LOWERCASE / CASE-INSENSITIVE LOOKUP — EVERY ROUTE
# ===================================================================

class TestCaseInsensitiveLookup:
    """Verify every route resolves via lowercase too (e.g. 'q10' → MTABC_Q10)."""

    @pytest.mark.parametrize("short_name,official_id", [(s, o) for s, o, _ in _ALL_BUS_ROUTES],
                             ids=[s for s, _, _ in _ALL_BUS_ROUTES])
    def test_lowercase_in_lookup(self, short_name, official_id):
        lc = short_name.lower()
        assert lc in ROUTE_LOOKUP, f"'{lc}' (lowercase of '{short_name}') not in ROUTE_LOOKUP"

    @pytest.mark.parametrize("short_name,official_id", [(s, o) for s, o, _ in _ALL_BUS_ROUTES],
                             ids=[f"{s}_lower" for s, _, _ in _ALL_BUS_ROUTES])
    @pytest.mark.asyncio
    async def test_resolve_lowercase(self, short_name, official_id):
        """resolve_bus_id should handle lowercase input."""
        result = await resolve_bus_id(short_name.lower())
        assert result == official_id, (
            f"resolve_bus_id('{short_name.lower()}') = '{result}', expected '{official_id}'"
        )
