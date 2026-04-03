# Transit Architecture Comparison — Agent Instructions

## Your Mission

You are analyzing two reference repositories alongside my production transit app ("Track") to find concrete, actionable improvements. The goal is to identify code, patterns, data structures, and algorithms from the reference repos that can **directly improve** Track's backend and iOS app.

**You have full permission to copy, adapt, and reuse any code or files from these repos.**

---

## Repos & Locations

| Repo | Path | Language | License |
|------|------|----------|---------|
| **transitland-lib** | `TRANSITAPP_COMPARISON/transitland-lib/` | Go | GPLv3 (owner has commercial license — reuse OK) |
| **transitland-atlas** | `TRANSITAPP_COMPARISON/transitland-atlas/` | JSON (DMFR) | CC-BY (reuse OK) |
| **Track iOS App** | `Track/` | Swift / SwiftUI | My app |
| **Track Backend** | `TrackBackend/app/` | Python (FastAPI) | My backend |

---

## Track App Architecture (What We Have)

### Backend (Python FastAPI — `TrackBackend/app/`)

- **GTFS-RT parsing**: `app/services/gtfs/realtime_parser.py` — protobuf → Pydantic models, thread-pool based, 120s parsed-result cache
- **GTFS static loading**: `app/services/gtfs/gtfs_loader.py`, `gtfs_parser.py` — loads shapes.txt, stops.txt, trips.txt
- **Corridor pipeline**: `app/services/mapping/corridor_pipeline.py` (3390 LOC) — 5-phase trunk merge → corridor detect → perpendicular offset → export → stop snap. Produces offset polylines so parallel subway lines render side-by-side
- **Subway shapes**: `app/services/mapping/subway_shapes.py` — GTFS shapes → encoded polylines with lane offsets
- **ML delay prediction**: `app/ml/delay_model.py` (LightGBM) + `recency_model.py` (exponential-decay Redis)
- **API**: `app/routers/nearby.py` (3325 LOC) — `/nearby/grouped` merges all modes into ranked feed
- **Caching**: 3-tier (in-memory TTL → Redis → HTTP Cache-Control headers)

### iOS App (Swift — `Track/`)

- **Map rendering**: MapLibre GL Native via `Track/Views/Map/MapLibre/MapLibreMapView.swift` (1881 LOC)
- **Baked GeoJSON tiles**: `Track/Services/TransitTileBaker.swift` — writes 5 GeoJSON FeatureCollections (subway fill/casing, elevated fill/casing, commuter) loaded by MapLibre as `MLNShapeSource`
- **Map system**: `Track/ViewModels/MapSystemViewModel.swift` (2699 LOC) — flattens polylines, assigns trunk index + lane offset, consolidates stations by MTA complex ID
- **Style config**: `Track/Views/Map/MapLibre/MapLibreStyleConfig.swift` — zoom-interpolated widths, blur, lane offset expressions
- **Offline caching**: `Track/Services/OfflineCacheManager.swift` — App Group UserDefaults, versioned cache
- **ETA engine**: `Track/Services/ArrivalETAEngine.swift` — blends vehicle GPS + feed ETA + ML correction
- **API client**: `Track/Network/TrackAPI.swift` — actor-based dedup, URLSession caching

---

## What to Compare — 7 Focus Areas

### 1. GTFS Data Parsing & Validation

**Our code**: `TrackBackend/app/services/gtfs/` — basic CSV loading, no formal validation
**Their code**: `transitland-lib/gtfs/` + `transitland-lib/validator/` + `transitland-lib/rules/`

**Questions to answer:**
- What validation rules do they enforce that we skip? Look at `rules/` directory
- How do they handle malformed/missing fields in shapes.txt, stops.txt, trips.txt?
- Do they compute any derived data we're missing? Check `ext/builders/route_geometry_builder.go` and `route_headway_builder.go`
- How does their route headway computation compare to our schedule-based approach?

### 2. Spatial Operations & Geometry

**Our code**: `TrackBackend/app/services/mapping/corridor_pipeline.py` — custom corridor detection + offset
**Their code**: `transitland-lib/tlxy/` (polyline encoding, line cutting, bbox, point-in-polygon)

**Questions to answer:**
- Compare their polyline encoding/decoding (`tlxy/polyline.go`) with our Python implementation — any precision or performance differences?
- How does their line-cutting algorithm (`tlxy/cut.go`) work? Could it improve our corridor segmentation?
- Look at `tlxy/bbox.go` — do they have spatial indexing approaches we could adopt for our grid-based corridor detection?
- Check `ext/builders/convex_hull_builder.go` — useful for service area visualization?

### 3. Vector Tiles / Map Data Generation

**Our code**: `Track/Services/TransitTileBaker.swift` — bakes GeoJSON FeatureCollections per category
**Their code**: `transitland-lib/server/rest/map.go` — serves MVT (Mapbox Vector Tiles)

**Questions to answer:**
- How do they generate PBF vector tiles? Read `server/rest/map.go` carefully
- What attributes do they include per feature (route color, type, frequency)?
- Do they pre-compute any per-tile simplification or clustering we should adopt?
- Could we adopt their tile-slicing approach (geographic tiles vs our category-based GeoJSON)?
- Is their approach better for our use case, or is our GeoJSON baking sufficient?

### 4. GTFS-RT Real-Time Data Handling

**Our code**: `TrackBackend/app/services/gtfs/realtime_parser.py` + `app/clients/mta_client.py`
**Their code**: `transitland-lib/rt/` + `transitland-lib/fetch/rt_fetch.go` + `server/finders/rtfinder/`

**Questions to answer:**
- How do they cache and serve GTFS-RT data? Look at `server/finders/rtfinder/`
- Do they have RT validation rules (`rt/rules.go`, `rt/validator.go`) that would catch bad data we're currently accepting?
- How does their RT → GeoJSON conversion (`rt/geojson.go`) compare to our vehicle position handling?
- Do they compute RT statistics (`rt/stats.go`) we could use for monitoring feed health?

### 5. Feed Management & Updates

**Our code**: `TrackBackend/app/services/gtfs/gtfs_refresh.py` — daily MTA feed check
**Their code**: `transitland-lib/fetch/` + `transitland-lib/dmfr/` + `transitland-atlas/feeds/`

**Questions to answer:**
- Look at `transitland-atlas/feeds/` for the MTA feed URLs — are we using the same ones? Search for files containing "mta" or "nyc"
- How does their feed fetcher handle versioning (`fetch/static_fetch.go`)? Do they diff feeds?
- Look at `transitland-lib/diff/` — could we use feed diffing to detect MTA schedule changes instead of just checking file timestamps?
- What metadata does their DMFR format capture about feeds that we're missing?

### 6. Database Schema & Query Patterns

**Our code**: `TrackBackend/app/data/transit_schedule.db` (SQLite) — basic schedule lookup
**Their code**: `transitland-lib/schema/postgres/migrations/` + `transitland-lib/tldb/`

**Questions to answer:**
- What tables/indices do they create? Read the migration files in `schema/postgres/migrations/`
- How do they handle spatial queries (PostGIS)? Check `tldb/` for spatial query patterns
- Do they have any query optimizations for stop-time lookups that we could adopt for our SQLite schedule DB?
- Look at their `finders/dbfinder/` — what query patterns do they use for nearest-stop and route-shape lookups?

### 7. Server Architecture

**Our code**: `TrackBackend/app/main.py` + `app/routers/` — FastAPI with in-memory + Redis caching
**Their code**: `transitland-lib/server/` — Go HTTP server with GraphQL + REST + caching + jobs

**Questions to answer:**
- How do they handle caching? Check `server/caches/`
- What job/task execution patterns do they use? Check `server/jobs/` and `server/jobserver/`
- How does their auth middleware work? Check `server/auth/`
- Do they have any request batching or connection pooling patterns we could adopt?

---

## Deliverable Format

For each of the 7 focus areas, provide:

```
### [Area Name]

**What they do better:**
- [Specific technique/algorithm with file path and line numbers]

**What we already do well:**  
- [Things our implementation handles that theirs doesn't]

**Concrete improvements to implement:**
1. [Specific change] — [which Track file to modify] — [expected benefit]
2. ...

**Code to reuse/adapt:**
- [Source file] → [Target file] — [what to extract]
```

---

## Important Notes

1. **transitland-lib is written in Go** — when suggesting code reuse, translate concepts to Python (backend) or Swift (iOS), not literal Go code
2. **Focus on ideas that directly improve the user experience** — faster ETAs, smoother map rendering, better offline support, more accurate data
3. **Our corridor pipeline is custom** — transitland-lib does NOT have corridor offset logic. Don't suggest replacing it
4. **Our baked GeoJSON approach is intentional** — it works well for NYC-only. Only suggest PBF tiles if there's a genuine benefit for our scale
5. **Prioritize quick wins** — changes that can be implemented in 1-2 files over multi-day refactors
6. **transitland-atlas is mostly feed URLs** — the main value is checking if we're missing any MTA feed sources or metadata

---

## Key Files to Read First

Start your analysis with these high-priority files:

### transitland-lib (most relevant to Track)
1. `transitland-lib/server/rest/map.go` — vector tile generation
2. `transitland-lib/tlxy/polyline.go` — polyline encoding
3. `transitland-lib/tlxy/cut.go` — line cutting algorithm
4. `transitland-lib/rt/rt.go` — GTFS-RT parsing
5. `transitland-lib/rt/rules.go` — RT validation rules
6. `transitland-lib/ext/builders/route_geometry_builder.go` — route geometry derivation
7. `transitland-lib/ext/builders/route_headway_builder.go` — headway computation
8. `transitland-lib/server/finders/rtfinder/` — RT data serving
9. `transitland-lib/gtfs/shape.go` — shape entity handling
10. `transitland-lib/validator/validator.go` — validation orchestrator

### transitland-atlas (quick scan)
1. Search `feeds/` for files containing "mta" or "nyc" — check feed URLs
2. Search `operators/` for MTA operator metadata

### Track (files that might benefit from improvements)
1. `TrackBackend/app/services/gtfs/realtime_parser.py`
2. `TrackBackend/app/services/gtfs/gtfs_loader.py`
3. `TrackBackend/app/services/mapping/corridor_pipeline.py`
4. `TrackBackend/app/services/mapping/subway_shapes.py`
5. `Track/Services/TransitTileBaker.swift`
6. `Track/ViewModels/MapSystemViewModel.swift`
7. `Track/Views/Map/MapLibre/MapLibreStyleConfig.swift`
