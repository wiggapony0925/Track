## Data Lifecycle and Freshness

To ensure a fast and resilient experience, the Track API utilizes a multi-tiered data strategy. This section documents how different types of transit data are updated and synchronized.

### 1. Lively Data (Real-time)
These datasets are fetched directly from live feeds on every request and are never persisted. They provide the "Now" experience.
- **Arrivals & Vehicle Positions**: Fetched directly from GTFS-RT (Subway/Rail) and SIRI (Bus).
- **Service Alerts**: Pulled from MTA Alerts JSON feeds with a 30-second freshness window.
- **Weather & Delays**: Real-time conditions used for ETA adjustments and delay modeling.

### 2. Offline & Sync Data (Managed)
This data is heavy and is synchronized periodically to support offline search, map rendering, and fast cold-starts.
- **GTFS Static Schedules**: Updated via a background "Bundle Sync" whenever the MTA releases new schedule bundles (roughly monthly). The mobile app automatically downloads the fresh bundle (~5 MB) on launch.
- **Stop Metadata**: Names, accessibility status, and transfer associations are indexed from MTA Open Data and OneBusAway with a **24-hour TTL**.
- **Route Geometry**: Clean street-level map polylines are refreshed from Socrata every **6 hours**.
- **Map Tiles**: Vector tiles are pre-baked from the latest `/tile-data` and updated via the same Bundle Sync mechanism used for GTFS.

### 3. Fully Static Data (App-Code)
These elements are baked into the application logic and only change with an app-store update.
- **Design System**: Official brand colors (e.g., #EE352E for the 1/2/3), typography tokens, and mode-specific iconography.
- **Mode Logic**: Rules for distinguishing transit modes (Subway, LIRR, MNR, Bus) and service types (SBS, Express, Local).
- **Service Boundaries**: The geographic bounding box for the NYC Metropolitan service area used for map clamping and location-gating.
