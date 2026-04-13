## NYC Transit API for the Track iOS App

This backend is the operational data layer for the Track app. It powers the home screen,
route detail sheets, transit maps, trip planning, live Go navigation, delay prediction,
accessibility banners, and developer diagnostics.

### What this portal should help you answer
- Which endpoint powers a given app surface?
- Which upstream dependency does that endpoint rely on?
- What cache or warmup behavior should I expect locally and in production?
- If the endpoint fails, what should the frontend still be able to do gracefully?

### What a new developer should know first
- **`/nearby/grouped` is the main home-screen endpoint.** It merges subway, bus, LIRR, and Metro-North into one ranked response.
- **Static map and schedule data come from GTFS static bundles.** Those feeds build stops, routes, shapes, and the local schedule database.
- **Realtime arrivals come from MTA GTFS-Realtime and SIRI/OBA.** If those feeds degrade, most endpoints return stale/cached data or graceful empty arrays instead of hard failures.
- **Trip planning depends on the internal TrackEngine service.** The planning endpoints remain documented here, but runtime health depends on both backend prep and the engine container.

### Data sources at a glance
| Source | Coverage | Update Frequency | Main UI Surfaces |
|--------|----------|------------------|------------------|
| **MTA GTFS-RT** | Subway, LIRR, Metro-North arrivals | Every 15–30 s | Home cards, line sheets, planner live state |
| **MTA SIRI** | Bus arrivals & live vehicles | Every 15–30 s | Nearby buses, bus route details, vehicle maps |
| **OBA** | Bus routes, stops, stop-to-route relationships | Cached minutes to hours | Bus route browser, route metadata, nearby stop discovery |
| **MTA Alerts** | Subway, bus, LIRR, MNR alerts | Every 30–60 s | Inline alert pills, status screens, planner penalties |
| **MTA Elevator/Escalator** | Accessibility outages | Every 5 min | Accessibility screen, station outage context |
| **Open-Meteo** | Current weather | Every 5 min | Delay modeling fallback, diagnostics |
| **MTA GTFS Static** | Schedules, stops, shapes | Daily / bundle refresh | Shapes, stations, schedule DB, inactive routes |
| **TrackEngine internal API** | Trip planning and Go session logic | Per request | Planner, saved trips, destination recommendations |

### Product-surface map

{{TAG_MATRIX_TABLE}}

### Upstream dependency map

The section below is the operational heart of the backend. It is generated directly from `TrackBackend/settings.json`, so the OpenAPI dashboard always reflects the exact configured upstream URLs and path fragments the service depends on in production.

{{UPSTREAM_URLS_TABLE}}

### How failures are handled
- **Warmup-sensitive endpoints** such as `/nearby/grouped` and `/subway/shapes/all` can return `503` with `Retry-After` during cold start.
- **Realtime endpoints** prefer graceful degradation: stale cache, schedule backfill, or empty arrays instead of crashing the app.
- **Planning endpoints** return `503` when the TrackEngine service is unavailable.
- **Localhost-only admin endpoints** return `403` when called remotely.

### Authentication
No public API key flow is required for local development. Production traffic is routed through the Track iOS app and private deployment infrastructure.

### Caching strategy
Responses include `Cache-Control` headers tuned per endpoint:
| Endpoint Type | `max-age` | `stale-while-revalidate` |
|---------------|-----------|-------------------------|
| Static geometry (shapes, stations) | 3600 s | 86400 s |
| Real-time data (arrivals, vehicles) | 5–20 s | 30–90 s |
| Alerts & accessibility | 30–60 s | 300 s |
| Nearby (grouped) | 5–12 s | 30–120 s |

### Connection pooling
The backend uses two connection pools to eliminate per-request overhead:
- **SQLite pool** — 8 pre-opened `aiosqlite` connections for GTFS schedule queries (WAL mode, self-healing). See `app/services/transit/db_pool.py`.
- **HTTP pool** — shared `httpx.AsyncClient` with 20 max connections for all upstream MTA/SIRI/OBA/TrackEngine calls.

### Rate limits
No explicit per-user rate limit is documented for trusted Track clients. Endpoints intended for operational control remain restricted to `localhost` only.
