# TrackBackend

A high-performance Python proxy API for the **Track** iOS app. It ingests raw MTA data (GTFS-Realtime Protobuf and JSON feeds) and serves pristine, standardized JSON to the iOS client.

## Tech Stack

- **Python 3.11+**
- **FastAPI** — Lightning-fast async web framework
- **Pydantic** — Data validation and settings management
- **HTTPX** — Async HTTP client for MTA feeds (connection-pooled, shared `AsyncClient`)
- **aiosqlite** — Async SQLite access for GTFS schedule lookups (connection-pooled)
- **gtfs-realtime-bindings** — Protobuf decoder for GTFS-Realtime feeds

## Quick Start

```bash
cd TrackBackend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

The API will be available at `http://127.0.0.1:8000`. Auto-generated docs are at `/docs`.

## Running Tests

```bash
pip install pytest pytest-asyncio httpx
python -m pytest tests/ -v
```

## Performance Architecture

### SQLite Connection Pool (`ScheduleDBPool`)

The GTFS schedule database (`transit_schedule.db`) is queried on nearly every request — nearby routes, bus schedule fallback, stop search, and service window checks. Previously, every query opened a fresh `aiosqlite.connect()` and closed it after use. Under load (especially `/nearby/grouped` which fires 50+ concurrent queries via `asyncio.gather`), this caused:

- Thread creation overhead (~2–5ms per connection)
- File handle churn (open/close on every call)
- Contention when dozens of coroutines hit the storage layer simultaneously

**Solution:** A shared connection pool (`app/services/transit/db_pool.py`) keeps **8 pre-opened SQLite connections** on an `asyncio.Queue`. Query methods borrow a connection, use it, and return it — no open/close overhead per request.

```
┌─────────────────────────────────────────────────┐
│  ScheduleDBPool  (asyncio.Queue, size=8)        │
│                                                 │
│  open()   → Pre-opens 8 connections at startup  │
│             WAL mode + read_uncommitted=1       │
│  acquire() → Borrows a connection (async ctx)   │
│             Returns it when done                │
│             Self-heals broken connections        │
│  close()  → Drains all connections at shutdown  │
└─────────────────────────────────────────────────┘
```

**Lifecycle integration:**
- `startup` event in `lifecycle.py` → `await schedule_pool.open()`
- `shutdown` event in `lifecycle.py` → `await schedule_pool.close()`

**Files using the pool:**

| File | Methods |
|------|---------|
| `schedule_service.py` | `get_scheduled_arrivals_async`, `get_line_schedule_async`, `get_headsigns_for_route_async` |
| `nearby.py` | `_discover_routes_in_area` |
| `service.py` (ScheduleRepository) | `search_stops`, `service_window_for_mode`, `has_nearby_stop_for_mode`, `nearby_route_ids_for_mode`, `route_has_service_on_date` |

**Test safety:** When the pool hasn't been opened (e.g. during unit tests), `acquire()` falls back to a standalone `aiosqlite.connect()` so tests run without any pool setup.

### HTTP Connection Pool (httpx)

Upstream HTTP calls (MTA GTFS-RT, SIRI, OBA, TrackEngine) use a shared `httpx.AsyncClient` with connection pooling:
- `max_connections=20`, `max_keepalive_connections=10`
- Lazy-initialized, closed at shutdown
- Retry logic via `tenacity` for TrackEngine calls

## 🏪 Track API Marketplace

Welcome to the **Track API Marketplace**, a high-performance Python proxy API powering the Track NYC Transit iOS app.

The API merges highly disparate MTA feeds (GTFS-Realtime Protobuf, GTFS Static JSON/CSV, SIRI, OBA) into unified, pristine JSON schemas ready for mobile clients.

### 🔐 Global Authentication
Currently, no API key is required. However, for future enterprise usage, include:
```http
Authorization: Bearer <YOUR_API_KEY>
```

---

### 🚄 1. Subway Endpoints

#### `GET /subway/shapes/all`
Returns polylines and colors for ALL subway lines. Used to render the full NYC system map.
- **Response `200 OK`**: `{"lines": [{"mode": "subway", "route_id": "L", "name": "L", "color_hex": "A7A9AC", "polylines": ["..."]}]}`

#### `GET /subway/stations/all`
Returns all stations with their coordinates and routes served.
- **Response `200 OK`**: `{"count": 472, "stations": [{"id": "L01", "name": "8 Av", "lat": 40.74, "lon": -74.0, "routes": ["L"]}]}`

#### `GET /subway/stations/nearby`
Returns stations strictly within a GPS radius.
- **Parameters**: `lat` (required), `lon` (required), `radius` (optional)
- **Response `200 OK`**: `{"count": 2, "stations": [...]}`

#### `GET /subway/shape/{route_id}`
Returns the full geometry (polylines) and ordered list of stops for a single subway line.
- **Response `200 OK`**: `{"route_id": "L", "polylines": [...], "stops": [...], "directions": [...]}`

#### `GET /subway/{line_id}`
Live countdown arrivals for a single subway line.
- **Response `200 OK`**: `[{"route_id": "L", "station": "L01", "station_name": "8 Av", "direction": "N", "destination": "8 Av", "minutes_away": 3, "arrival_ts": 1700000000, "status": "On Time"}]`

---

### 🚆 2. Commuter Rail (LIRR & Metro-North)

#### `GET /lirr` | `GET /mnr`
Live countdown arrivals for the Long Island Rail Road or Metro-North.
- **Response `200 OK`**: Array of `TrackArrival` objects matching the subway schema.

#### `GET /lirr/shapes/all` | `GET /mnr/shapes/all`
Polylines and brand colors for all branched routes.
- **Response `200 OK`**: `{"lines": [...]}`

#### `GET /lirr/shape/{route_id}` | `GET /mnr/shape/{route_id}`
Polyline geometry for a specific branch (e.g. `LIRR_9` for Port Washington).

---

### 🚌 3. Bus Endpoints (OBA + SIRI)

#### `GET /bus/routes`
Returns all MTA bus routes with per-route brand colors from OBA.
- **Response `200 OK`**: `[{"id": "MTA NYCT_B63", "short_name": "B63", "long_name": "Atlantic Av", "color": "0039A6"}]`

#### `GET /bus/stops/{route_id}`
Returns all ordered stops for a bus route.
- **Response `200 OK`**: `[{"id": "MTA_308214", "name": "5 Av / Union St", "lat": 40.67, "lon": -73.98, "direction": "0"}]`

#### `GET /bus/live/{stop_id}`
Real-time SIRI bus arrivals at a targeted stop.
- **Response `200 OK`**: `[{"route_id": "...", "vehicle_id": "...", "status_text": "Approaching", "expected_arrival": "2026-...", "distance_meters": 150}]`

#### `GET /bus/vehicles/{route_id}`
Live GPS tracking positions, bearing, and distance for all active buses on a route.
- **Response `200 OK`**: `[{"vehicle_id": "...", "lat": 40.6, "lon": -73.9, "bearing": 180.0, "next_stop": "...", "status_text": "at stop"}]`

#### `GET /bus/route-shape/{route_id}`
Returns encoded polylines to draw the bus path on Apple/Google Maps.

---

### 🌍 4. Nearby Transit (Unified)

#### `GET /nearby/grouped`
The flagship endpoint. Combines **Subway, Bus, LIRR, and MNR** into a single grouped response, sorted by the absolute fastest arriving trains or buses near the user. Returns cleanly formatted JSON designed for multi-tab UI cards.

Bus routes include a `bus_service_type` field (`"Local"`, `"Limited"`, `"Local / Limited"`, `"Select Bus Service"`, `"Express"`, `"School"`, or `null` for non-bus) and a `color_hex` that matches the official MTA Bus Routes map palette:

| Service Type | Color | Hex |
|---|---|---|
| Local | Blue | `#0078C6` |
| Limited | Purple | `#6E3FA3` |
| Local / Limited | Purple | `#6E3FA3` |
| Select Bus Service (SBS) | Cyan | `#00B2E3` |
| Express | Green | `#3D9B35` |
| School | Orange | `#F7931E` |

> **Dynamic detection:** Limited and Local / Limited types are detected automatically from GTFS `trips.txt` headsign prefixes ("RUSH" / "LIMITED"). The sets refresh whenever GTFS feeds are re-downloaded.

- **Parameters**: `lat` (required), `lon` (required), `radius` (optional, default 500m), `mode` (optional filter)
- **Response `200 OK`**:
```json
[
  {
    "route_id": "L",
    "display_name": "L",
    "color_hex": "#A7A9AC",
    "mode": "subway",
    "bus_service_type": null,
    "directions": [
      {
        "direction": "0",
        "direction_label": "Westbound",
        "arrivals": [
          { "minutes_away": 2, "destination": "8 Av", "status": "On Time", "is_real_time": true }
        ]
      }
    ]
  },
  {
    "route_id": "MTA NYCT_M34+",
    "display_name": "M34-SBS",
    "color_hex": "#00B2E3",
    "mode": "bus",
    "bus_service_type": "Select Bus Service",
    "directions": [
      {
        "direction": "0",
        "direction_label": "Eastbound",
        "arrivals": [
          { "minutes_away": 5, "destination": "Waterside", "status": "On Time", "is_real_time": true }
        ]
      }
    ]
  },
  {
    "route_id": "MTABC_SIM1C",
    "display_name": "SIM1C",
    "color_hex": "#3D9B35",
    "mode": "bus",
    "bus_service_type": "Express",
    "directions": [
      {
        "direction": "0",
        "direction_label": "Northbound",
        "arrivals": [
          { "minutes_away": 12, "destination": "Bay Ridge", "status": "On Time", "is_real_time": true }
        ]
      }
    ]
  }
]
```

#### `GET /nearby`
A flattened version of the above, returning purely the nearest raw arrivals.

---

### ⚠️ 5. Status & Alerts

#### `GET /alerts`
Real-time service alerts (delays, planned work) matching the MTA Service Status tracker.
- **Parameters**: `mode` (optional)
- **Response `200 OK`**: `[{"route_id": "L", "title": "Planned Work", "description": "...", "severity": "MODERATE"}]`

#### `GET /accessibility`
Live list of broken elevators and escalators across the system.

---

### 📊 6. Analytics & Intelligence

#### `POST /analytics/log`
Logs an interaction metric when a user tracks a route.
- **Parameters**: `route_id`, `mode`, `interaction_type`

#### `GET /analytics/popular`
Returns the most interacted routes across the entire platform.

---

### 📦 7. Static Data Bundle

#### `GET /static/bundle`
A heavy, highly-cached endpoint hit once by the iOS app to download route shapes, branding, stops, and colors into local CoreData to avoid massive repeated network fetches.

---


## Configuration

All behavior is controlled by `settings.json` in the project root. The iOS app fetches `/config` on launch to receive dynamic settings.

> **Important:** Replace the `mta_api_key` value `"YOUR_KEY_HERE"` in `settings.json` with your actual MTA API key before deploying. Never commit real API keys to source control.

## Directory Structure

```
TrackBackend/
├── app/
│   ├── main.py              # Application entry point
│   ├── config.py            # Settings loader (Pydantic settings)
│   ├── models.py            # Data models (Pydantic schemas)
│   ├── services/
│   │   ├── mta_client.py    # Handles raw MTA calls (Protobuf/XML)
│   │   ├── bus_client.py    # OBA + SIRI bus API client (stops, arrivals, vehicles, shapes)
│   │   └── data_cleaner.py  # Converts raw data to clean JSON
│   └── routers/
│       ├── subway.py        # Endpoints for subway lines
│       ├── bus.py           # Endpoints for bus (routes, stops, live, vehicles, shapes)
│       ├── nearby.py        # Unified nearby transit endpoint
│       ├── lirr.py          # Endpoints for Long Island Rail Road
│       └── status.py        # Endpoints for Alerts/Elevators
├── tests/
│   ├── test_nearby.py       # Tests for /nearby endpoint
│   └── __init__.py
├── settings.json            # THE MASTER CONFIG FILE
├── requirements.txt         # Dependencies
├── Dockerfile               # Container for cloud deployment
└── README.md
```

## GTFS Static Data for Map Lines

The iOS app displays subway, LIRR, and Metro-North route lines on the map. This data comes from the `/static/bundle` endpoint which parses GTFS static files.

### Subway Data
Subway GTFS data is included in the repo at `app/data/subway/` (shapes, stops, etc.).

### LIRR and Metro-North Data
To enable LIRR and Metro-North route lines on the map, download GTFS static data from MTA and place it in these directories:

```
app/data/lirr/gtfslirr/
├── shapes.txt     # Route polyline coordinates
├── trips.txt      # Trip definitions (links routes to shapes)
├── stops.txt      # Station locations
└── routes.txt     # Route definitions

app/data/metro_north/gtfsmnr/
├── shapes.txt
├── trips.txt
├── stops.txt
└── routes.txt
```

**Download GTFS feeds from:** https://new.mta.info/developers

Once the data is in place:
1. Restart the backend server
2. The `/static/bundle` endpoint will include LIRR routes (prefixed `LIRR_*`) and MNR routes (prefixed `MNR_*`)
3. The iOS app will display these routes as dashed lines on the system map

## Data Sources

| Source | Protocol | Usage |
|--------|----------|-------|
| MTA GTFS-Realtime | Protobuf | Subway & LIRR real-time arrivals |
| MTA GTFS Static | CSV | Route shapes for map display |
| MTA SIRI | JSON | Bus arrivals, vehicle positions |
| MTA OBA | JSON | Bus routes, stops, route shapes |
| MTA Alerts | JSON | Service alerts, elevator status |
| Supabase | REST | User data, analytics, schedules |

## Supabase Integration

The backend connects to Supabase for user analytics and data sync.

### Configuration

All secrets are set in the **Render dashboard → Environment**, never committed to the repo.

| Env var | Where to get it |
|---|---|
| `SUPABASE_URL` | Supabase dashboard → Project Settings → API |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase dashboard → Project Settings → API |
| `MTA_API_KEY` | https://api.mta.info |
| `OBA_API_KEY` | https://bustime.mta.info |
| `REDIS_URL` | Auto-injected by Render from the `track-redis` key-value store |

### Database Tables

| Table | Purpose | Used By |
|-------|---------|---------|
| `profiles` | User accounts from Apple Sign-In | iOS SupabaseManager |
| `route_interactions` | Analytics - what routes are popular | iOS HomeViewModel, Backend analytics router |
| `schedules` | Widget activation schedules | iOS WidgetSchedules, SyncManager |
| `commute_patterns` | Smart suggestions based on habits | iOS SmartSuggester |

---

## Operations & Maintenance Runbook

> **For future developers and AI agents:** This section documents every periodic task that may need to be run. The backend is designed to be left alone. Only touch it when one of the triggers below applies.

---

### ML Model Retraining

The delay prediction model (`app/data/delay_model.pkl`) was trained on MTA open data + bootstrap samples. Once real users are riding with the app, Redis accumulates actual observed delay errors via `recency_model.py`. When you have enough users (~500–1,000+), retrain to incorporate real data.

**How to retrain:**

```bash
cd TrackBackend
source .venv/bin/activate

# Step 1 — Export live Redis observations to CSV
# Requires REDIS_URL pointing at the production Redis instance
export REDIS_URL=<from Render dashboard>
python -m app.ml.export_observations -o observations.csv

# Step 2 — Retrain the model (adds real data on top of MTA open data)
python -m app.ml.train_model --real-data observations.csv

# Step 3 — Upload the new model to Supabase Storage
export SUPABASE_URL=https://octpebjxadbufiplgjqg.supabase.co
export SUPABASE_SERVICE_ROLE_KEY=<from Render dashboard>
python scripts/upload_model.py

# Step 4 — Hot-swap without a deploy (zero downtime)
curl -X POST https://track-api.onrender.com/predict/reload-model
```

**When to retrain:** When the app has been live for several weeks and you want predictions to reflect real NYC patterns rather than historical MTA data only.

---

### GTFS Static Data Refresh

MTA updates GTFS static feeds (stop locations, route shapes, schedules) roughly quarterly. The backend downloads these on cold start from Supabase Storage.

**How to refresh:**

```bash
cd TrackBackend
source .venv/bin/activate

# Re-download the latest MTA training datasets
python scripts/fetch_mta_training_data.py

# Then re-upload the updated tarballs to Supabase Storage
# (do this from scripts/upload_gtfs.py if it exists, or manually via Supabase dashboard)
# Buckets: gtfs-data/ (7 tarballs) and Static_MTA_data/ (raw GTFS text files)
```

**When to refresh:** If arrival times look wrong, trains don't show on certain routes, or MTA announces a major schedule change (usually September and January).

---

### Infrastructure Scaling

| If you see... | Action |
|---|---|
| Render CPU consistently > 80% | Already on Standard ($25/mo). Next step: scale to `standard-plus` or add `numInstances: 2` in `render.yaml` |
| Redis memory > 80 MB | Increase `plan: starter` → `plan: standard` in `render.yaml`, or reduce TTLs in `settings.json` `cache` section |
| Cold starts taking > 60s | The persistent disk may have been wiped — first boot re-downloads GTFS from Supabase (expected) |
| Deploy fails with `libgomp` error | Check `Dockerfile` — `libgomp1` must be in the `apt-get install` line |

Current infrastructure (as of Mar 2026):
- **Web service:** Render Standard (2 GB RAM, 1 CPU, 2 Gunicorn workers)
- **Redis:** Render Starter Key-Value (100 MB, `allkeys-lru`)
- **Persistent disk:** 10 GB mounted at `/app/app/data`

---

### Observability — Logging & Uptime Monitoring

The backend ships structured logs to **Better Stack** for 30-day retention and search, and uses Better Stack Uptime to alert on downtime.

#### What was set up (Feb 2026)

| Component | Detail |
|---|---|
| **Log streaming** | Render → Observability → Log Streams → `s1768496.eu-fsn-3-vec.betterstackdata.com:6514` |
| **Uptime monitor** | Better Stack Uptime → `https://track-vkrr.onrender.com/health` every 3 min |
| **Health endpoint** | `GET /health` → `{"status": "ok"}` — lightweight, no DB/cache calls |
| **Rndr-Id tracing** | Every log line includes the Render request ID for end-to-end request tracing |

#### Log format

Every log line emitted by the backend follows this structure:

```
2026-02-27 14:23:01.042 [INFO] [HTTP] [user@email.com] [58ebfa3c-8929-4485] GET /nearby/grouped → 200 (143.2ms)
```

| Field | Meaning |
|---|---|
| `[HTTP]` / `[ML]` / `[REDIS]` / `[CACHE]` | Subsystem tag — filterable in Better Stack |
| `[user@email.com]` | Authenticated user making the request |
| `[58ebfa3c-...]` | `Rndr-Id` header injected by Render — ties all log lines from one request together |

#### Searching logs in Better Stack

Go to **Telemetry → Live tail** or **Logs** and use queries like:

```
subsystem:[ML]          # all ML prediction logs
level:ERROR             # errors only
request_id:58ebfa3c    # all logs from one specific request
user_email:user@email  # all logs for a specific user
```

#### How Rndr-Id tracing works (code)

Render injects a unique `Rndr-Id` header on every inbound HTTP request. The `log_requests` middleware in `app/main.py` extracts it and binds it to a `contextvars.ContextVar` so every log call made during that request (across any service file) automatically includes it:

```python
# app/main.py — log_requests middleware
request_id = request.headers.get("Rndr-Id") or "-"
TrackLogger.set_request_id(request_id)
# ... handle request ...
finally:
    TrackLogger.clear_request_id()
```

#### Re-configuring log stream

If the Better Stack source is recreated or the endpoint changes:
1. Render Dashboard → workspace name (top left) → **Integrations → Observability**
2. **Log Streams** → edit the default destination
3. Update host:port and token

---

### Environment Variables (Render Dashboard)

These must be set manually in **Render → Track service → Environment**. They are never in the repo.

| Variable | Description |
|---|---|
| `MTA_API_KEY` | From https://api.mta.info — required for all GTFS-RT feeds |
| `OBA_API_KEY` | From https://bustime.mta.info — required for bus arrivals |
| `SUPABASE_URL` | `https://octpebjxadbufiplgjqg.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | From Supabase dashboard → Project Settings → API |
| `REDIS_URL` | Auto-injected by Render from the `track-redis` key-value store |
| `ARRIVING_PREDICTION_MODEL` | Set to `false` to disable ML predictions instantly without a deploy |

---

### Database Schema Changes

The schema source of truth is `db.txt` in the repo root. If you add a new table:

1. Write idempotent SQL in `db.txt`
2. Run it in the Supabase dashboard → SQL Editor
3. Enable RLS on the new table
4. Add a policy (`auth.uid() = user_id` pattern matches all existing tables)
5. Update `app/models.py` with the corresponding Pydantic schema if the backend reads/writes it

The `supabase/migrations/` folder is kept in sync via `supabase db pull` — run it after any schema change to keep the migration file current.

---

### Running Tests

```bash
cd TrackBackend
source .venv/bin/activate
python -m pytest tests/ -q --ignore=tests/integration
# Expected: 2320 passed, 14 known failures (pre-existing, not regressions)
```

The 14 known failures are pre-existing test stubs that test live MTA/SIRI behavior — they require active network and are expected to fail locally.


### Analytics Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/analytics/popular` | Get most popular routes |
| POST | `/analytics/log` | Log a route interaction |

### Example: Get Popular Routes

```bash
curl "http://localhost:8000/analytics/popular?mode=subway&limit=5"
```

Response:
```json
{
  "popular_routes": [
    {"route_id": "L", "mode": "subway", "clicks": 42, "tracks": 15, "total": 57},
    {"route_id": "7", "mode": "subway", "clicks": 38, "tracks": 12, "total": 50}
  ],
  "count": 2
}
```
