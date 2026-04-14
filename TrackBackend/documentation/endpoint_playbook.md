## Endpoint playbook by product surface

Use this section as the mental map for how the app talks to the backend.

### Tag-to-surface matrix

{{TAG_MATRIX_TABLE}}

### Typical client flows

#### 1. Home screen load
1. Call `/nearby/grouped`
2. Optionally call `/nearby/inactive`
3. Use `status` endpoints to explain disruptions when cards look inconsistent

#### 2. Subway map and route detail
1. Load `/subway/shapes/all` and `/subway/stations/all` for full-map experiences
2. Use `/subway/shape/{route_id}` for a specific line sheet
3. Use `/subway/{line_id}` for live countdowns

#### 3. Bus route exploration
1. Load `/bus/routes` for route list and official display metadata
2. Load route-shape and stop endpoints for map and stop ordering
3. Load live vehicle and arrival endpoints for active route monitoring

#### 4. Planner and Go mode
1. Use `engine` search and saved-place endpoints for origin/destination setup
2. Use `/engine/plan` for itinerary search
3. Use `/engine/go` only when the frontend needs active, step-by-step trip guidance

iOS App → POST /engine/plan → Backend (Python)
                                   │
                          ┌────────┴────────┐
                          │  1. Engine Call  │ ← C++ graph router
                          │  (schedule GTFS) │   returns itineraries
                          └────────┬────────┘
                                   │
                          ┌────────┴────────────────┐
                          │ 2. _enrich_itineraries  │
                          │    _realtime()           │
                          │                          │
                          │  asyncio.gather(         │
                          │    _load_subway_arrivals │ ← MTA Subway GTFS-RT
                          │    _load_rail_arrivals   │ ← LIRR/MNR GTFS-RT
                          │    _load_bus_arrivals    │ ← MTA Bus SIRI
                          │    _load_alert_index     │ ← Service Alerts
                          │  )  ← all 4 in parallel │
                          └────────┬────────────────┘
                                   │
                          ┌────────┴────────────────┐
                          │ 3. _enrich_legs_realtime│
                          │    for each transit leg: │
                          │    • match scheduled     │
                          │      departure to RT feed│
                          │    • set live_status:     │
                          │      status, delay_s,    │
                          │      source, is_realtime │
                          │    • attach alerts       │
                          └────────┬────────────────┘
                                   │
                          ┌────────┴────────┐
                          │  JSON Response   │
                          │  with live_status│
                          │  on every leg    │
                          └────────┬────────┘
                                   │
                              iOS App
                          (renders live badges,
                           delayed/on-time labels)

### Implementation notes for contributors
- If an endpoint powers a rider-facing screen, document **what happens when upstream data is missing**.
- If an endpoint is intended for cached geometry or static metadata, say so explicitly.
- If the frontend should call one endpoint before another, document that sequence in the route description or schema examples.
