# Track — NYC Transit AI

Track is an intelligent transit companion for iOS that learns your commute habits and predicts *real* arrival times using local on-device data, a custom backend proxy, and the MTA's live feeds.

## 🏗 Architecture

```
┌──────────────────────────────────────┐
│            iOS App (Track)           │
│  ┌────────┐  ┌────────┐  ┌────────┐ │
│  │HomeView│  │Widgets │  │ Live   │ │
│  │  Map   │  │SmartSug│  │Activity│ │
│  └───┬────┘  └───┬────┘  └───┬────┘ │
│      └───────────┼───────────┘      │
│           ┌──────┴──────┐           │
│           │  TrackAPI   │           │
│           │ (Network)   │           │
│           └──────┬──────┘           │
│    ┌─────────────┼─────────────┐    │
│    │ SwiftData (App Groups)    │    │
│    │ CommutePattern · TripLog  │    │
│    └───────────────────────────┘    │
└──────────────┬───────────────────────┘
               │ HTTPS / JSON
┌──────────────┴───────────────────────┐
│       TrackBackend (FastAPI)         │
│  ┌─────────┐  ┌──────────────────┐  │
│  │ Routers │  │    Services      │  │
│  │ /subway │  │  mta_client.py   │  │
│  │ /bus    │  │  bus_client.py   │  │
│  │ /alerts │  │  data_cleaner.py │  │
│  └────┬────┘  └────────┬─────────┘  │
│       └────────────────┘            │
└──────────────┬───────────────────────┘
               │ Protobuf / SIRI / JSON
┌──────────────┴───────────────────────┐
│          MTA Data Feeds              │
│  GTFS-RT (Subway/LIRR) · SIRI (Bus) │
│  Alerts JSON · Elevator JSON         │
└──────────────────────────────────────┘
```

**iOS App** — SwiftUI + SwiftData + ActivityKit + WidgetKit. Talks only to the backend.

**TrackBackend** — Python FastAPI proxy that ingests raw MTA Protobuf/SIRI/JSON and outputs clean, normalized JSON.

**MTA Feeds** — Real-time GTFS-Realtime for subway/LIRR, SIRI for bus, JSON for alerts and elevators.

## 🚀 Setup

### iOS App

1. **Clone** the repo and open `Track.xcodeproj` in Xcode 16+.
2. **Capabilities:** Enable *App Groups* (`group.com.yourname.track`) on both the `Track` and `TrackWidgets` targets.
3. **Capabilities:** Enable *Live Activities* (`NSSupportsLiveActivities = YES`) in the main app's Info.plist.
4. **Environment:** In `TrackAPI.swift`, set `useLocalServer = true` for Simulator or `false` for a physical device pointing to the cloud.
5. **Build:** Run on iPhone 15 Pro Simulator or later (iOS 18+).

### Backend (Local)

```bash
cd TrackBackend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

The API will be available at `http://127.0.0.1:8000`. Auto-generated docs at `/docs`.

### Backend (Docker)

```bash
cd TrackBackend
docker build -t track-api .
docker run -p 8000:8000 track-api
```

### Backend (Cloud — Render)

1. Push the repo to GitHub.
2. Create a new **Web Service** on [Render](https://render.com).
3. Set the **Root Directory** to `TrackBackend`.
4. Set the **Build Command** to `pip install -r requirements.txt`.
5. Set the **Start Command** to `uvicorn app.main:app --host 0.0.0.0 --port $PORT`.
6. Update `prodURL` in `TrackAPI.swift` with the deployed URL.

## ✨ Features

| Feature | Description |
|---------|-------------|
| **Smart Predictions** | On-device ML learns your commute patterns and predicts the route you need before you ask |
| **Live Activities** | Track a train/bus on your Dynamic Island and Lock Screen with live countdown |
| **Bus + Subway** | Dual-mode UI with a floating transport toggle; SIRI API for buses, GTFS-RT for subway |
| **Reliability Scores** | Historical trip data flags routes that are frequently delayed |
| **Offline Learning** | All habit data stored locally via SwiftData — no cloud account needed |
| **Lock Screen Widget** | Shows your predicted next train/bus automatically based on time of day |
| **Haptic Feedback** | Tactile feedback on mode switching and trip tracking for a premium feel |

## 📂 Project Structure

```
Track/
├── Track/                          # iOS App
│   ├── Models/                     # SwiftData models (Station, Route, TripLog, etc.)
│   ├── Network/                    # TrackAPI client
│   ├── Services/                   # LiveActivityManager, SmartSuggester, etc.
│   ├── ViewModels/                 # HomeViewModel
│   ├── Views/                      # SwiftUI views
│   ├── Theme/                      # AppTheme (colors, typography, layout)
│   ├── Data/                       # DataController (shared App Group container)
│   └── Utilities/                  # HapticManager
├── TrackWidgets/                   # Widget Extension (Lock Screen + Live Activity)
├── TrackBackend/                   # Python FastAPI backend
│   ├── app/
│   │   ├── main.py                 # App entry point with /config endpoint
│   │   ├── config.py               # Pydantic settings loader
│   │   ├── models.py               # Pydantic response schemas
│   │   ├── services/               # MTA client, bus client, data cleaner
│   │   └── routers/                # subway, bus, lirr, status endpoints
│   ├── settings.json               # Master configuration
│   ├── requirements.txt            # Python dependencies
│   └── Dockerfile                  # Container for cloud deployment
└── README.md
```

## 🔌 API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/config` | App settings from settings.json |
| GET | `/subway/{line_id}` | Real-time arrivals for a subway line |
| GET | `/lirr` | Real-time LIRR arrivals |
| GET | `/bus/routes` | All MTA bus routes |
| GET | `/bus/stops/{route_id}` | Stops for a bus route |
| GET | `/bus/nearby?lat=&lon=` | Nearby bus stops |
| GET | `/bus/live/{stop_id}` | Live bus arrivals at a stop |
| GET | `/alerts` | Critical subway service alerts |
| GET | `/accessibility` | Currently broken elevators/escalators |

## 🔒 Privacy

- Location data is used only to find nearby stations and predict commute patterns.
- All user habit data is stored locally on-device via SwiftData.
- No user data is transmitted to third-party services.
- The backend proxies MTA public data only.

## ♿ Accessibility

All UI components include accessibility labels and hints for VoiceOver support.

## 📱 App Icon

The App Icon folder structure is set up at `Assets.xcassets/AppIcon.appiconset`. To set your icon:

1. Create a **1024×1024 PNG** image.
2. Drag it into `Assets.xcassets → AppIcon` in Xcode.
3. Xcode will use this single image at all required sizes.
