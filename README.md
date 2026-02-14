# Track — NYC Transit Companion

Track is an iOS transit app for New York City that shows real-time subway, bus, and LIRR arrivals based on your location. It uses a custom FastAPI backend that proxies live MTA feeds (GTFS-Realtime, SIRI, JSON) and outputs clean, normalized JSON for the iOS client.

---

## Table of Contents

- [Architecture](#architecture)
- [Features](#features)
- [Setup](#setup)
  - [iOS App](#ios-app)
  - [Backend (Local)](#backend-local)
  - [Backend (Docker)](#backend-docker)
  - [Backend (Render)](#backend-render)
  - [Running Tests](#running-tests)
- [API Reference](#api-reference)
  - [Config](#config)
  - [Nearby Transit](#nearby-transit)
  - [Subway](#subway)
  - [Bus](#bus)
  - [LIRR](#lirr)
  - [Service Status](#service-status)
- [Project Structure](#project-structure)
  - [iOS App](#ios-app-structure)
  - [Backend](#backend-structure)
- [Map and UI](#map-and-ui)
- [Privacy](#privacy)
- [Accessibility](#accessibility)

---

## Architecture

```text
                         iOS App (Track)
    +---------------------------------------------------------+
    |                                                         |
    |   HomeView       Widgets                    |
    |   (Map + Feed)   (Lock Screen)              |
    |       |              |                       |
    |       +--------------+                       |
    |                      |                                  |
    |              HomeViewModel                              |
    |                      |                                  |
    |                  TrackAPI                                |
    |              (Network Client)                           |
    |                      |                                  |
    |       SwiftData (App Groups)                            |
    |       CommutePattern / TripLog                          |
    +-----------+---------------------------------------------+
                |
                | HTTPS / JSON
                |
    +-----------+---------------------------------------------+
    |           TrackBackend (FastAPI)                         |
    |                                                         |
    |   Routers:            Services:                         |
    |    /nearby              mta_client.py                   |
    |    /nearby/grouped      bus_client.py                   |
    |    /subway/{line}       data_cleaner.py                 |
    |    /bus/*                                               |
    |    /lirr                                                |
    |    /alerts                                              |
    |    /accessibility                                       |
    +-----------+---------------------------------------------+
                |
                | Protobuf / SIRI / JSON
                |
    +-----------+---------------------------------------------+
    |             MTA Data Feeds                              |
    |   GTFS-RT (Subway, LIRR)  |  SIRI (Bus)                |
    |   Alerts JSON             |  Elevator JSON              |
    +-------------------------------------------------------------+
```

**iOS App** — SwiftUI, SwiftData, MapKit, WidgetKit. Talks only to the backend. All user data stays on-device.

**TrackBackend** — Python FastAPI proxy that ingests raw MTA Protobuf, SIRI XML, and JSON feeds, then returns normalized JSON.

**MTA Feeds** — Real-time GTFS-Realtime for subway and LIRR, SIRI for buses, JSON for service alerts and elevator outages.

---

## Features

| Feature | How It Works |
| :--- | :--- |
| Nearby Transit | Unified feed showing nearest buses and trains sorted by arrival time |
| Route Detail Sheet | Tap a route to see arrivals grouped by direction (swipeable tabs) with a mini route map |
| Live Bus Tracking | Tap a bus route to see active buses on the map with GPS positions and bearing arrows |
| Route Visualization | Full polyline path drawn on the map with stop annotations for any selected bus route |
| GO Mode | Hands-free tracking mode that follows your vehicle, dims passed stops, and shows transit ETA |
| LIRR Support | Long Island Rail Road departures in a dedicated tab |
| Service Alerts | Critical MTA alerts shown in the dashboard alongside nearby arrivals |
| Elevator/Escalator Outages | Real-time accessibility info for stations with broken equipment |
| Nearest Metro | When no transit is within walking distance, recommends the closest stop with distance |
| Draggable Search Pin | Drop a pin anywhere on the map to search for transit at that location |
| Smart Predictions | On-device ML learns commute patterns and suggests routes before you ask |
| Lock Screen Widget | Shows nearest live transit, refreshes every 5 minutes |
| Haptic Feedback | Tactile response on mode switching, tracking, and navigation |
| Quad-Mode UI | Nearby / Subway / Bus / LIRR tabs with a floating transport mode toggle |

---

## Setup

### iOS App

1. Clone the repo and open `Track.xcodeproj` in Xcode 16+.
2. Enable **App Groups** (`group.com.yourname.track`) on both `Track` and `TrackWidgets` targets.
3. In Developer Settings (within the app's Settings view), toggle between localhost and a custom IP for local development.
4. Build and run on an iPhone simulator or device running iOS 18+.

### Backend (Local)

```bash
cd TrackBackend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

The API runs at `http://127.0.0.1:8000`. Interactive docs at `/docs`.

### Backend (Docker)

```bash
cd TrackBackend
docker build -t track-api .
docker run -p 8000:8000 track-api
```

### Backend (Render)

1. Push the repo to GitHub.
2. Create a new **Web Service** on [Render](https://render.com).
3. Set the **Root Directory** to `TrackBackend`.
4. Set the **Build Command** to `pip install -r requirements.txt`.
5. Set the **Start Command** to `uvicorn app.main:app --host 0.0.0.0 --port $PORT`.
6. Update `prodURL` in `TrackAPI.swift` with the deployed URL.

Production is currently deployed at `https://track-api.onrender.com`.

### Running Tests

```bash
cd TrackBackend
pip install pytest pytest-asyncio httpx
python -m pytest tests/ -v
```

---

## API Reference

All endpoints return JSON. The iOS app communicates exclusively through `TrackAPI.swift`.

### Config

| Method | Path | Description |
| :--- | :--- | :--- |
| GET | `/config` | Returns app settings from `settings.json` |

### Nearby Transit

| Method | Path | Query Params | Description |
| :--- | :--- | :--- | :--- |
| GET | `/nearby` | `lat`, `lon`, `radius` (default 500m) | Flat list of nearest buses and trains sorted by arrival time |
| GET | `/nearby/grouped` | `lat`, `lon`, `radius` (default 500m) | Routes grouped by ID with swipeable direction sub-groups |

The grouped endpoint is used for the main dashboard cards. The flat endpoint is the fallback and powers the nearest metro recommendation when no transit is within walking distance.

### Subway

| Method | Path | Description |
| :--- | :--- | :--- |
| GET | `/subway/{line_id}` | Real-time arrivals for a subway line (e.g. `/subway/L`) |

### Bus

| Method | Path | Description |
| :--- | :--- | :--- |
| GET | `/bus/routes` | All MTA bus routes with short name, long name, and color |
| GET | `/bus/stops/{route_id}` | Ordered stops for a specific route |
| GET | `/bus/nearby?lat=&lon=` | Nearby bus stops by coordinates |
| GET | `/bus/live/{stop_id}` | Live arrivals at a specific stop (SIRI feed) |
| GET | `/bus/vehicles/{route_id}` | Live vehicle GPS positions with bearing and next stop |
| GET | `/bus/route-shape/{route_id}` | Encoded polylines and stop list for drawing the route on a map |

Route IDs use the fully qualified MTA format: `MTA NYCT_B63`, `MTA NYCT_Q10`, etc.

### LIRR

| Method | Path | Description |
| :--- | :--- | :--- |
| GET | `/lirr` | Upcoming LIRR departures from the GTFS-Realtime feed |

### Service Status

| Method | Path | Description |
| :--- | :--- | :--- |
| GET | `/alerts` | Critical MTA service alerts with route, title, description, severity |
| GET | `/accessibility` | Currently out-of-service elevators and escalators |

---

## Project Structure

### iOS App Structure

```text
Track/
|-- Models/
|   |-- Station.swift               SwiftData model for subway stations
|   |-- Route.swift                  SwiftData model for transit routes
|   |-- TransportMode.swift          Enum: .nearby, .subway, .bus, .lirr
|   |-- BusModels.swift              BusStop, BusArrival structs
|   |-- ServiceModels.swift          TransitAlert, ElevatorStatus, BusRoute
|   |-- TripLog.swift                SwiftData model for trip history
|   |-- CommutePattern.swift         SwiftData model for learned commute habits
|   |-- WeatherCondition.swift       Weather state enum
|
|-- Network/
|   |-- TrackAPI.swift               API client: all backend calls, response models,
|                                     error types, polyline decoder
|
|-- Repositories/
|   |-- TransitRepository.swift      TrainArrival model, TransitError enum,
|                                     bridges TrackAPI to ViewModels
|
|-- ViewModels/
|                                     search pin, bus route selection, GO mode,
|                                     transit ETA
|
|-- Views/
|   |-- HomeView.swift               Main view: map, bottom sheet, dashboard sections,
|                                     mode switching, settings/route detail sheets
|   |-- LoginView.swift              Authentication screen
|   |-- OnboardingView.swift         First-run setup flow
|   |-- SettingsView.swift           Preferences, developer tools, theme toggle
|   |-- LocationPermissionView.swift Location access gate
|   |-- ContentView.swift            Root router (login -> onboarding -> home)
|   |
|   |-- Components/
|       |-- ArrivalRow.swift           Subway/LIRR arrival row (expandable)
|       |-- BusArrivalRow.swift        Bus arrival row with SIRI status text
|       |-- NearbyTransitRow.swift     Unified bus/train row for nearby feed
|       |-- GroupedRouteRow.swift       Route card with soonest arrival across directions
|       |-- NearbyBusStopRow.swift      Bus stop list item
|       |-- NearbyStationRow.swift      Subway station list item with distance
|       |-- NearestMetroCard.swift      Recommendation card when no transit is nearby
|       |-- RouteDetailSheet.swift      Route detail modal: direction tabs, mini map,
|                                        arrival list, GO button, swipe gestures
|       |-- RouteBadge.swift            Colored circle badge for route names
|       |-- SmartSuggestionCard.swift   ML-based commute suggestion
|       |-- DelayBadgeView.swift        Service delay indicator
|       |-- TransportModeToggle.swift   Floating mode selector (Nearby/Subway/Bus/LIRR)
|       |-- MapAnnotations.swift        SearchPinAnnotation, BusVehicleAnnotation
|       |-- BusStopAnnotation.swift     Bus stop map marker
|       |-- GoModeAnnotations.swift     GO mode user icon, passed-stop dimming
|       |-- NetworkErrorBanner.swift    Error message banner
|
|-- Services/
|   |-- LocationManager.swift        CoreLocation wrapper, permission handling
|   |-- AppLogger.swift              File-based request/response logger
|   |-- SmartSuggester.swift         On-device commute pattern ML
|   |-- TripLogger.swift             SwiftData trip history writer
|   |-- DelayCalculator.swift        Service delay computation
|
|-- Theme/
|   |-- AppTheme.swift               Colors, typography, layout constants,
|                                     subway line colors, map configuration
|
|-- Utilities/
|   |-- FormatUtils.swift            formatArrivalTime(), formatDistance(),
|                                     stripMTAPrefix(), transitStatusColor()
|   |-- DirectionUtils.swift         directionLabel(), shortDirectionLabel()
|   |-- ColorExtensions.swift        Color(hex:) initializer
|   |-- LocationExtensions.swift     CLLocation.bearing(to:), degree/radian conversion
|   |-- HapticManager.swift          UIFeedbackGenerator wrappers
|
|-- Data/
|   |-- DataController.swift         SwiftData container using App Group
|
|-- TrackApp.swift                   @main entry point
```

### Backend Structure

```text
TrackBackend/
|-- app/
|   |-- main.py                     FastAPI entry point, CORS, router registration
|   |-- config.py                   Pydantic settings from settings.json
|   |-- models.py                   Response schemas: TrackArrival, BusRoute, BusStop,
|                                    BusArrival, BusVehicle, NearbyTransitArrival,
|                                    GroupedNearbyTransit, TransitAlert, ElevatorStatus,
|                                    RouteShape
|   |-- routers/
|   |   |-- subway.py               GET /subway/{line_id}
|   |   |-- bus.py                  GET /bus/routes, /bus/stops, /bus/nearby,
|   |   |                            /bus/live, /bus/vehicles, /bus/route-shape
|   |   |-- nearby.py               GET /nearby, /nearby/grouped
|   |   |-- lirr.py                 GET /lirr
|   |   |-- status.py               GET /alerts, /accessibility
|   |
|   |-- services/
|       |-- mta_client.py           Async HTTP client for MTA Protobuf/JSON
|       |-- bus_client.py           OBA + SIRI dual-API for bus data
|       |-- data_cleaner.py         Protobuf parser for arrivals, alerts, elevators
|
|-- tests/
|   |-- test_nearby.py              Unit tests for the nearby endpoint
|
|-- utils/
|   |-- logger.py                   Colored console logging
|
|-- settings.json                   API keys, feed URLs, app configuration
|-- requirements.txt                Python dependencies
|-- Dockerfile                      Container build for deployment
```

---

## Map and UI

The map uses Apple MapKit with bounded camera constraints covering the NYC five boroughs and Long Island.

- **User location dot** that auto-centers on launch via `.userLocation(fallback:)`
- **Recenter button** in the dashboard header to snap back to your position
- **Search pin** for exploring transit at any location by tapping the pin button
- **Bus stop annotations** shown when in Bus mode
- **Live bus vehicles** appear as blue markers with bearing rotation when a route is selected
- **Route polylines** draw the full path on the map when viewing a bus route detail
- **GO mode** replaces the blue dot with a pulsing vehicle icon that follows the route, dims passed stops, and shows transit ETA

The bottom sheet dashboard shows mode-specific content:

| Mode | Content |
| :--- | :--- |
| Nearby | Grouped route cards, nearest metro fallback, service alerts, elevator outages |
| Subway | Nearby station arrivals with expandable detail rows |
| Bus | Selected stop arrivals, nearby bus stop list |
| LIRR | LIRR departure list |

---

## Privacy

- Location data is used only to find nearby stations and learn commute patterns.
- All user habit data is stored locally on-device via SwiftData.
- No user data is transmitted to third-party services.
- The backend proxies MTA public data only.

---

## Accessibility

All UI components include accessibility labels and hints for VoiceOver support. The app reports real-time elevator and escalator outages from the MTA accessibility feed.
