# Track Transit Map Bible

This document turns the Transit technical follow-up into a build spec for Track.

Reference inspiration:
- [Transit.pdf](/Users/jeffreyfernandez/Downloads/A%20Technical%20Follow-Up:%20How%20We%20Built%20the%20World's%20Prettiest%20Auto-Generated%20Transit%20Maps%20%7C%20Transit.pdf)

Track goal:

Build a subway map engine that is geographically faithful at street level, diagrammatically readable at city level, visually stable while panning and zooming, and strong enough to make Track feel like a dedicated transit product rather than a thin wrapper over a general map.

This means we are not only drawing lines.
We are building:
- a transit geometry engine,
- a corridor topology engine,
- a lane-ordering engine,
- a station-placement engine,
- a zoom-aware renderer,
- and a QA system that catches ugly failures before users do.

## 1. Non-Negotiable Product Rules

These are the rules the map must obey at all times.

1. A line must never look detached from the stop it serves.
2. Shared service corridors must never visually collapse into one line when they are meant to be shown as separate services.
3. Lines should stay parallel through a shared corridor until the actual geographic divergence, not merely until the last shared stop.
4. Lane order must be stable. If a line is "left of" another line in one part of a corridor, it should not randomly flip unless there is a real topological reason.
5. Bends must preserve spacing. Corners cannot bunch, kink, or self-intersect when multiple lines travel together.
6. Transfer stations must sit at the visual intersection or shared center of the lines they connect.
7. The same physical network must render consistently across zoom levels. Zoom may change emphasis, not truth.
8. Live route selection and vehicle overlays must sit on top of the same geometry system, not fight it.
9. If the high-quality processed geometry is unavailable, the fallback must still be correct and readable, just less polished.
10. Every important visual decision must be measurable or testable.

## 2. What "Better Than the Transit Article" Means for Track

Transit's article is the baseline, not the finish line.

Track should go further in these areas:

- Better street-level fidelity for NYC at close zoom.
- Better live route integration, because Track is not only a system map.
- Better stop attachment under interaction, selection, and filtering.
- Better diagnostics and regression protection.
- Better offline and degraded behavior.
- Better zoom choreography between geographic and diagrammatic presentation.

Transit mostly described an auto-generated transit map engine.
Track needs that plus:
- live vehicles,
- route overlays,
- nearest-stop logic,
- walking directions,
- route filtering,
- structure-aware elevated vs subway rendering,
- and user-facing polish on a mobile GPU renderer.

## 3. Architecture for Track

Track should think about the map as a pipeline with clear ownership:

### Backend: geometry truth

Backend owns:
- route shape ingestion,
- shape repair,
- trunk grouping,
- corridor detection,
- lane ordering,
- branch pruning,
- arc rounding / bend normalization,
- processed station placement,
- and export contracts.

Current Track touchpoints:
- [corridor_pipeline.py](/Users/jeffreyfernandez/code/Track/TrackBackend/app/services/mapping/corridor_pipeline.py)
- [subway.py](/Users/jeffreyfernandez/code/Track/TrackBackend/app/routers/subway.py)
- [models.py](/Users/jeffreyfernandez/code/Track/TrackBackend/app/models.py)

### Client: rendering truth

iOS owns:
- zoom-based styling,
- layer ordering,
- lighting / casing / shadows,
- route emphasis,
- station visibility choreography,
- vehicle overlays,
- camera-aware display offsets when necessary,
- and graceful fallbacks.

Current Track touchpoints:
- [MapSystemViewModel.swift](/Users/jeffreyfernandez/code/Track/Track/ViewModels/MapSystemViewModel.swift)
- [MapLibreMapView.swift](/Users/jeffreyfernandez/code/Track/Track/Views/Map/MapLibre/MapLibreMapView.swift)
- [MapLibreStyleConfig.swift](/Users/jeffreyfernandez/code/Track/Track/Views/Map/MapLibre/MapLibreStyleConfig.swift)
- [MapLibreTrackMapView.swift](/Users/jeffreyfernandez/code/Track/Track/Views/Map/MapLibre/MapLibreTrackMapView.swift)
- [VehicleInterpolator.swift](/Users/jeffreyfernandez/code/Track/Track/Utilities/VehicleInterpolator.swift)

## 4. The Required Pipeline

This is the full Track map pipeline.

### Phase A: Input geometry and repair

Inputs:
- GTFS shapes
- GTFS stops
- route metadata
- optional OSM rail geometry fallback / repair source

Rules:
- Prefer agency shapes when clean.
- Replace or repair shapes when they drift badly from track reality.
- Detect bad agency geometry automatically.
- Maintain per-route provenance for debugging.

Minimum diagnostics:
- shape length sanity
- stop-to-shape distance distribution
- self-intersection detection
- branch continuity checks

Track status:
- strong diagnostics already exist in `TrackBackend/scripts`
- OSM fallback/matching should become a first-class path, not just a nice-to-have

### Phase B: Trunk grouping

Goal:
- merge services by trunk color / corridor family before rendering

Examples:
- `A/C/E`
- `B/D/F/M`
- `N/Q/R/W`
- `4/5/6`

Rules:
- same-color routes that share a physical corridor should unify into trunk geometry plus branch stubs
- route labels and stop attribution must still know which actual services serve each branch

Track status:
- already present via `trunk_polylines`

### Phase C: Corridor detection

Goal:
- identify where different trunk groups truly share physical space

Rules:
- shared corridor detection must be geographic, not only stop-based
- detection should survive missing/express/local stop pattern differences
- corridor membership should be smooth across runs, not flicker point-by-point

Track status:
- already implemented in `corridor_pipeline.py`
- should remain backend-owned

### Phase D: Stable lane ordering

Goal:
- decide who goes left/right within shared corridors to minimize ugly crossings

This is one of the biggest remaining quality multipliers.

Rules:
- lane order should optimize globally, not greedily per point
- crossings should only happen when unavoidable
- if one optimization reduces clutter in one junction but explodes clutter elsewhere, it is not good enough

Ideal solution:
- graph-based optimization
- ILP or near-ILP quality target
- per-corridor and per-junction penalty scoring

Penalty terms:
- line crossings
- lane flips
- abrupt order changes
- visually inconsistent branch exits
- crossings close to station markers

Track status:
- partial corridor spacing exists
- full robust ordering is the clearest "Transit-level" gap still worth investing in

### Phase E: Offset geometry and branch transitions

Goal:
- convert corridor membership + lane order into clean offset geometry

Rules:
- transitions into and out of corridors must be blended
- no spikes
- no loops
- no sudden pinches
- no double-offsetting on client and server

Track status:
- good progress already
- keep server as geometric owner
- client should not recompute corridor topology

### Phase F: Arc-based rounding

Goal:
- make turns elegant while preserving spacing

This is the second biggest visual upgrade after lane ordering.

Rules:
- prefer circular-arc style turns over generic bezier smoothing
- preserve parallel spacing on bends
- enforce minimum turn radius based on total corridor width
- simplify geometry if required to keep curves valid

Why:
- bezier-only smoothing can look soft but transit-incorrect
- arc-like turns feel much closer to diagrammatic transit maps
- parallel arcs stay parallel naturally

Track status:
- current rendering relies heavily on round joins and backend offset smoothing
- true arc-rounding should move deeper into backend geometry generation

### Phase G: Station placement

Goal:
- stops must reflect rendered network truth

Rules:
- single-line stations sit on the correct rendered lane
- transfer stations sit at the visual crossing or corridor center
- multi-platform complexes may need multiple markers if structure differs
- station position should be derived from rendered trunk geometry where available

Track status:
- already strong
- processed stations endpoint exists
- consolidated station placement has improved
- keep refining lane-aware station placement alongside lane ordering work

### Phase H: Labels and route bullets

Goal:
- users should instantly know which services run on each section

Rules:
- labels should use local route attribution, not entire trunk group everywhere
- labels should appear at rhythmically spaced intervals
- labels should avoid branch misinformation

Track status:
- trunk route labels exist
- local branch attribution is already partially handled

### Phase I: Zoom model

Goal:
- Track should smoothly transition between geographic truth and readability

Rules by zoom:
- far zoom: emphasize network legibility and separation
- mid zoom: preserve corridor readability and branch clarity
- close zoom: maintain stop attachment and street-level plausibility

Important rule:
- zoom should change styling and emphasis more than geometry identity

Track status:
- good dynamic MapLibre styling foundation exists
- continue using zoom-aware lane offset ramps instead of hard on/off switches

### Phase J: Live overlays

Goal:
- vehicles, selected routes, and walking directions must inherit the same geometry truth

Rules:
- selected route stop markers snap to the displayed route geometry
- live vehicles interpolate on route polylines, not between arbitrary GPS jumps
- active overlays should never reveal a mismatch the base map tried to hide

Track status:
- already strong and improving

## 5. What Track Already Has

Track is not starting from zero.

Already in place:
- backend corridor pipeline
- trunk-level export contract
- processed station endpoint
- stable MapLibre system map layers
- selected-route stop snapping
- dynamic low-zoom lane offsets
- transfer station consolidation
- many geometry diagnostics in `TrackBackend/scripts`

This is a serious map engine already.
The right next step is not to start over.
The right next step is to harden and upgrade the highest-leverage missing phases.

## 6. What Track Still Needs to Reach the Target

These are the top missing pieces, ordered by visual impact.

### P0: Full lane-order optimization

Needed because:
- this is what turns "parallel lines exist" into "the map looks intentionally designed"

Deliverables:
- corridor graph extraction
- ordering solver
- penalty scoring
- deterministic output
- diagnostics for crossings before/after

### P0: Stronger junction and arc rounding

Needed because:
- this is what makes shared trunks feel premium instead of technically correct-but-rough

Deliverables:
- arc segment generation
- min radius enforcement
- junction handoff continuity
- multi-line bend spacing validation

### P1: OSM-backed repair / matching path

Needed because:
- bad agency shapes are unavoidable
- NYC is high-stakes at street level

Deliverables:
- shape quality scoring
- fallback to OSM-derived path when GTFS shape quality fails
- route-by-route override support

### P1: Visual regression suite

Needed because:
- map quality regresses silently

Deliverables:
- golden screenshots for known hard scenes
- corridor crossing metrics
- stop attachment metrics
- branch drift metrics
- "ugly scene" list for NYC

### P1: Better offline fallback

Needed because:
- Track must still feel premium on cold start, poor network, or backend delay

Deliverables:
- cached trunk geometry
- cached processed stations
- quality tier flags
- fallback style behavior

### P2: Rider-personalized filtering with re-centering

Needed because:
- Track can outdo static transit maps by being contextual

Deliverables:
- mode toggles
- agency toggles
- neighborhood focus
- optional route family filtering
- corridor re-centering rules when certain lines are hidden

## 7. Track-Specific Additions Beyond the Transit Article

These are the parts that should make Track better, not just similar.

### A. Active route mode

When a route is selected:
- the selected route becomes primary truth
- inactive system map should dim aggressively
- route stops should snap exactly to the selected route display path
- vehicles should appear to belong to that route, not float over a separate base network

### B. Structure-aware rendering

NYC needs:
- subway
- elevated
- viaduct
- commuter rail

Rules:
- elevated lines can sit above subway lines visually
- reroutes can temporarily demote normal structure assumptions
- station grouping must respect structure differences

### C. Walking + transit continuity

Track is origin-to-destination, not just a network viewer.

Rules:
- walking route join points should land on the same station anchor system the transit map uses
- stop pills and route stop markers should agree with navigation points

### D. Diagnostic culture

Track should be better because it is more inspectable.

Required culture:
- every ugly map bug gets a dedicated diagnostic script or test
- every hard corridor gets a named fixture
- every "this looks off near X" complaint becomes a repeatable case

## 8. Acceptance Criteria

Track should not ship map changes without meeting these.

### Geometry

- p95 stop-to-rendered-line distance at close zoom should remain visually negligible
- no branch self-intersections caused by offsets
- no corridor lane collapse in known shared sections
- no unstable lane flips under normal camera movement

### Visual

- shared corridors remain legible from city to neighborhood zoom
- lines preserve separation through corners
- transfer pills sit where users expect them
- no obvious "line behind line" failure in core Manhattan, Queens Blvd, Broadway, Lex, 8th Ave, 6th Ave

### Product

- selected route mode remains cleaner than full system mode
- vehicles and stops remain aligned during live refreshes
- performance stays smooth on supported iPhones

## 9. NYC Gold-Test Scenes

These scenes should always be checked.

- Lexington Ave `4/5/6`
- Queens Blvd `E/F/M/R` and `7` nearby structure interactions
- 8th Ave `A/C/E`
- 6th Ave `B/D/F/M`
- Broadway `N/Q/R/W`
- DeKalb merges
- Canal St complexity
- Times Sq / 42 St
- Atlantic Ave / Barclays
- Jay St / Hoyt-Schermerhorn / Downtown Brooklyn junctions
- Roosevelt Ave / Jackson Heights multi-structure complex
- Lefferts / Rockaway branches
- Sutphin / Archer branch attribution
- Fulton St complex

Every one of these should eventually have:
- an expected screenshot
- a diagnostic fixture
- and a note about what failure modes it is protecting against

## 10. Engineering Rules for This Repo

Use these rules when modifying the Track map stack.

1. Prefer backend geometry fixes over client-only visual hacks.
2. Use the client for zoom choreography, layer ordering, and final presentation.
3. Never double-apply corridor offsets.
4. Keep route attribution separate from corridor geometry.
5. Consolidate stations from rendered geometry, not disconnected raw centroids.
6. Add diagnostics before or alongside risky geometry changes.
7. If a fix improves one corridor but creates random flips elsewhere, it is not done.
8. Do not accept "good enough at far zoom" if close zoom looks wrong.
9. Do not accept "touches stops" if shared trunk readability is lost.
10. Do not accept "parallel" if the ordering is unstable and spaghetti-like.

## 11. Concrete Roadmap

### Phase 1: Finish corridor presentation

- Keep current trunk export model
- Keep processed station workflow
- tune lane ramps only as a presentation detail
- stabilize lane-aware station placement

### Phase 2: Add lane-order solver

- build corridor graph
- define crossing penalty function
- add deterministic ordering output per shared section
- export ordering metadata if needed

### Phase 3: Add arc-rounding backend phase

- bend simplification
- arc construction
- min-radius enforcement
- branch continuity validation

### Phase 4: Add shape-repair / OSM fallback

- route quality score
- repair mode
- override tables

### Phase 5: Build visual regression system

- simulator screenshot runner
- backend geometry fixtures
- hard-scene goldens

## 12. Definition of Done

Track beats the article when:

- the map is as readable as a diagrammatic transit map,
- as grounded as a geographic street map,
- as stable as a handcrafted system map,
- and fully integrated with live route selection and transit tracking.

That is the standard.

Not:
- "the polylines mostly look okay"
- "the stops are close enough"
- "the lines separate at some zooms"

The standard is:

Track should feel like the subway map Apple and Transit would have built if they were obsessed with NYC block-level correctness, live navigation, and commuter focus.
