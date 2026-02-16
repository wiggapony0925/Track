# TrackBackend

A high-performance Python proxy API for the **Track** iOS app. It ingests raw MTA data (GTFS-Realtime Protobuf and JSON feeds) and serves pristine, standardized JSON to the iOS client.

## Tech Stack

- **Python 3.11+**
- **FastAPI** — Lightning-fast async web framework
- **Pydantic** — Data validation and settings management
- **HTTPX** — Async HTTP client for MTA feeds
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

## Endpoints

| Method | Path                                | Description                                    |
|--------|-------------------------------------|------------------------------------------------|
| GET    | `/config`                           | Returns app settings from settings.json        |
| GET    | `/nearby?lat=&lon=`                 | **Unified nearby transit** — buses + trains sorted by arrival time |
| GET    | `/subway/{line_id}`                 | Real-time arrivals for a subway line           |
| GET    | `/lirr`                             | Real-time LIRR arrivals                        |
| GET    | `/bus/routes`                       | All MTA bus routes                             |
| GET    | `/bus/stops/{route_id}`             | Stops for a bus route                          |
| GET    | `/bus/nearby?lat=&lon=`             | Nearby bus stops by GPS coordinate             |
| GET    | `/bus/live/{stop_id}`               | Live bus arrivals at a stop via SIRI           |
| GET    | `/bus/vehicles/{route_id}`          | **Live bus vehicle positions** with GPS/bearing |
| GET    | `/bus/route-shape/{route_id}`       | **Route polylines + stops** for map drawing    |
| GET    | `/alerts`                           | Critical subway service alerts                 |
| GET    | `/accessibility`                    | Currently broken elevators/escalators          |

### Endpoint Details

#### `GET /nearby?lat=&lon=`

Returns the nearest buses and trains with live countdown timers, sorted by `minutes_away`. No routing or trip planning — just a flat list of what's arriving soon nearby. Combines subway arrivals from GTFS-RT feeds and bus arrivals from SIRI.

**Query Parameters:**
- `lat` (required) — User latitude
- `lon` (required) — User longitude
- `radius` (optional, default: 500) — Search radius in meters

**Response:** `NearbyTransitArrival[]`
```json
[
  {
    "route_id": "L",
    "stop_name": "1st Avenue",
    "direction": "Manhattan",
    "minutes_away": 3,
    "status": "On Time",
    "mode": "subway"
  },
  {
    "route_id": "MTA NYCT_B63",
    "stop_name": "5 Av / Union St",
    "direction": "Approaching",
    "minutes_away": 5,
    "status": "Approaching",
    "mode": "bus"
  }
]
```

#### `GET /bus/vehicles/{route_id}`

Returns live GPS positions for all active buses on a route. Used by the iOS app to show bus icons on the map with real-time movement and bearing.

**Response:** `BusVehicle[]`
```json
[
  {
    "vehicle_id": "MTA NYCT_7582",
    "route_id": "MTA NYCT_B63",
    "lat": 40.6728,
    "lon": -73.9894,
    "bearing": 180.0,
    "next_stop": "5 Av / Union St",
    "status_text": "Approaching"
  }
]
```

#### `GET /bus/route-shape/{route_id}`

Returns Google-encoded polylines for drawing the route path on a map, along with all stops on the route.

**Response:** `RouteShape`
```json
{
  "route_id": "MTA NYCT_B63",
  "polylines": ["encoded_polyline_string_1", "encoded_polyline_string_2"],
  "stops": [
    {"id": "MTA_308214", "name": "5 Av / Union St", "lat": 40.6728, "lon": -73.9894, "direction": "0"}
  ]
}
```

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

Set these environment variables (or use defaults for development):

```bash
export SUPABASE_URL=https://octpebjxadbufiplgjqg.supabase.co
export SUPABASE_KEY=sb_publishable_lAEZ_x8O4vjdGaw-I-QUMg_oS5iWKIn
```

### Database Tables

| Table | Purpose | Used By |
|-------|---------|---------|
| `profiles` | User accounts from Apple Sign-In | iOS SupabaseManager |
| `route_interactions` | Analytics - what routes are popular | iOS HomeViewModel, Backend analytics router |
| `schedules` | Widget activation schedules | iOS WidgetSchedules, SyncManager |
| `commute_patterns` | Smart suggestions based on habits | iOS SmartSuggester |

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
