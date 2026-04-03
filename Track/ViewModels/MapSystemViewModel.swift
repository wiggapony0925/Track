// ViewModel for loading and caching the full transit system map,
// including subway, LIRR, and Metro-North polylines and stations.
// Extracted from HomeViewModel for separation of concerns.

import CoreLocation
import Foundation
import SwiftUI

@Observable
@MainActor
final class MapSystemViewModel {

    // MARK: - Shared Snapshot Cache

    private struct SharedSnapshot {
        let systemMap: [CachedTransitLine]
        let offsetSubwayLines: [OffsetSubwayLine]
        let trunkPolylines: [TrunkGroupPolylines]?
        let flattenedSubway: [FlattenedMapPolyline]
        let flattenedCommuter: [FlattenedMapPolyline]
        let stations: [CachedSubwayStation]
        let consolidatedStations: [ConsolidatedStation]
        let routeLabels: [TrunkRouteLabel]
    }

    private static var sharedSnapshot: SharedSnapshot?

    // MARK: - Nested Types

    // Full transit system map (pre-decoded for performance)
    // Includes Subway, LIRR, and Metro-North lines
    struct CachedTransitLine: Identifiable {
        let id: String
        let color: Color
        let coordinates: [[CLLocationCoordinate2D]]
        let mode: TransitLineMode

        enum TransitLineMode {
            case subway
            case lirr
            case mnr
        }
    }

    /// Pre-computed subway lines with perpendicular offsets applied to shared corridors.
    /// Computed once when cachedSystemMap is set, so the View never recalculates it.
    struct OffsetSubwayLine: Identifiable {
        let id: String
        let color: Color
        let coordinates: [[CLLocationCoordinate2D]]
    }

    // MARK: - Flattened Map Polylines (Performance Optimized)

    /// A single polyline segment ready for rendering with a stable ID.
    /// This flattens nested structures to avoid nested ForEach loops in SwiftUI Map,
    /// which dramatically improves rendering performance.
    struct FlattenedMapPolyline: Identifiable {
        let id: String  // Stable unique ID: "routeId_branchIndex"
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let lineWidth: CGFloat
        /// Route IDs in this polyline's trunk group (e.g. ["7"] or ["N","W"]).
        /// Used for alert-driven structure overrides at render time.
        let routeIds: [String]
        /// Whether the geographic midpoint of this branch falls in an
        /// elevated segment (inferred from route + geography).  Used
        /// for z-ordering: elevated polylines render above subway ones.
        let isElevated: Bool
        /// Index into `trunkGroups` (0-10).  Passed through as a feature
        /// attribute so MapLibre layers can filter or offset per trunk.
        let trunkIndex: Int
        /// Signed perpendicular offset for pixel-space separation of
        /// parallel trunk groups at low zoom levels.  At zoom 14+ the
        /// geographic corridor offset is sufficient; below zoom 14 this
        /// value is multiplied by a zoom factor and fed to MapLibre's
        /// ``lineOffset`` paint property.
        let laneOffset: CGFloat
    }

    // Full subway station list with served lines
    struct CachedSubwayStation: Identifiable, Equatable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let routes: [String]

        static func == (lhs: CachedSubwayStation, rhs: CachedSubwayStation) -> Bool {
            lhs.id == rhs.id && lhs.routes == rhs.routes
        }
    }

    /// A route label placed along a trunk polyline showing which trains
    /// run on that section — the colored circles with route letters
    /// that Apple Maps shows at intervals along transit lines.
    struct TrunkRouteLabel: Identifiable, Equatable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let routeIds: [String]   // e.g. ["A", "C", "E"]
        let color: Color

        static func == (lhs: TrunkRouteLabel, rhs: TrunkRouteLabel) -> Bool {
            lhs.id == rhs.id && lhs.routeIds == rhs.routeIds
        }
    }

    /// A group of nearby stations consolidated into a single map marker.
    ///
    /// Stations are grouped by **complex ID** (from `StationComplexLookup`)
    /// then sub-grouped by **physical structure** (subway vs. elevated).
    /// This means 74 St–Roosevelt Ave produces TWO consolidated stations:
    ///   - 7 train (elevated) → one capsule
    ///   - E/F/M/R (subway)   → one capsule
    /// Both share the same `complexID`, so the renderer can draw a transfer
    /// indicator connecting them.
    struct ConsolidatedStation: Identifiable, Equatable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let routes: [String]           // All route IDs merged from the group
        let colorGroupCount: Int       // Distinct MTA trunk-color groups
        let trackBearing: Double       // Degrees from north (0-180), track direction
        /// Direction-preserving tangent heading from the nearest rendered
        /// trunk segment. Used so station dots can inherit the same visual
        /// lane offset direction as the MapLibre line layer.
        let laneHeading: Double?
        /// Signed pixel-lane offset for single-group stations. This matches
        /// the trunk feature's `lane_offset` attribute so station dots can
        /// move with the shared corridor at low zoom without collapsing the
        /// rendered parallel lines.
        let laneOffset: CGFloat
        let structure: StationStructure // Physical structure (subway, elevated, etc.)
        let complexID: Int             // MTA station complex group
        /// All GTFS stop IDs that were merged into this consolidated marker.
        /// Used to match live arrival `stopId` → station for pulse animation.
        let sourceStopIDs: Set<String>
        /// True when the station spans ≥ 2 MTA trunk-color groups.
        /// Non-transfer stops render as a colored route dot; transfers
        /// render as a white pill with a dark outline.
        let isTransfer: Bool

        static func == (lhs: ConsolidatedStation, rhs: ConsolidatedStation) -> Bool {
            lhs.id == rhs.id && lhs.routes == rhs.routes
        }
    }

    // MARK: - Properties

    var cachedSystemMap: [CachedTransitLine] = []
    var cachedOffsetSubwayLines: [OffsetSubwayLine] = []

    /// Pre-merged trunk-level polylines from the server's corridor pipeline.
    /// When present, `computeFlattenedPolylinesAsync()` renders these directly
    /// instead of re-pooling per-route GTFS shapes — eliminating duplicate
    /// stacked lines and ensuring polylines align with snapped station dots.
    var cachedTrunkPolylines: [TrunkGroupPolylines]?

    /// Crossing points where different trunk groups intersect.
    /// Populated from the server's corridor pipeline.
    var cachedCrossings: [CrossingPoint] = []

    /// Pre-computed flattened subway polylines for the system map view.
    /// Uses stable IDs and avoids nested ForEach for optimal MapLibre rendering.
    /// A single fine-detail geometry set is used at ALL zoom levels.
    /// Zoom adaptation is handled purely by rendering properties (line width,
    /// opacity) — matching Apple Maps, which never swaps geometry and
    /// relies on the small corridor offset becoming sub-pixel at far zoom.
    var flattenedSubwayPolylines: [FlattenedMapPolyline] = []

    /// Pre-computed flattened commuter rail (LIRR/MNR) polylines for the system map view.
    var flattenedCommuterRailPolylines: [FlattenedMapPolyline] = []

    /// Pre-baked GeoJSON tile set for instant MapLibre rendering.
    /// When available, MapLibre loads these files directly via its C++
    /// GeoJSON parser, bypassing all Swift feature-building loops.
    /// Set during cold-start (from disk) and after each network refresh.
    var bakedTileSet: TransitTileBaker.BakedTileSet?

    /// Route IDs whose service is currently rerouted or suspended,
    /// according to live MTA alerts.  When a normally-elevated route
    /// appears in this set, its polylines are demoted to subway-level
    /// rendering (no casing, drawn below other elevated lines).
    ///
    /// Updated by `HomeViewModel.refreshAlerts()` every 30 s.
    /// The set auto-clears when alerts expire (backend filters by
    /// `active_period`).
    var reroutedRouteIDs: Set<String> = []

    /// Station IDs (GTFS stop_id) that have at least one live arrival
    /// within 1 minute.  Drives the "pulse" animation on station capsules.
    ///
    /// Updated by `HomeViewModel` after each nearby-transit refresh.
    /// Map-keyed as `stopId → routeId` so the pulse ring can use the
    /// approaching train's route color.
    var imminentArrivals: [String: String] = [:]  // stopId → routeId

    /// Scans grouped subway arrivals for stops with ≤ 1 minute arrival.
    /// Only live (non-placeholder, non-cancelled) arrivals qualify.
    func updateImminentStations(
        from groups: [GroupedNearbyTransitResponse]
    ) {
        var result: [String: String] = [:]  // stopId → routeId
        for group in groups {
            guard group.mode == "subway" else { continue }
            for direction in group.directions {
                for arrival in direction.arrivals {
                    guard let stopId = arrival.stopId,
                          !arrival.isPlaceholder,
                          !arrival.isCancelled,
                          arrival.minutesAway <= 1
                    else { continue }
                    // First arrival wins (soonest route color)
                    if result[stopId] == nil {
                        result[stopId] = group.routeId
                    }
                }
            }
        }
        imminentArrivals = result
    }

    /// Scans alerts for reroute/suspension indicators and updates
    /// `reroutedRouteIDs`.  Only subway-mode alerts with Mercury
    /// `alert_type` containing "Reroute" or "Suspended" qualify —
    /// normal "Delays" alerts do NOT affect structure rendering.
    func updateReroutedRoutes(from alerts: [TransitAlert]) {
        reroutedRouteIDs = StationComplexLookup.reroutedRouteIDs(from: alerts)
    }

    /// Route labels placed along trunk polylines (Apple Maps–style bullets).
    var trunkRouteLabels: [TrunkRouteLabel] = []

    var cachedStations: [CachedSubwayStation] = []

    /// Stations consolidated by proximity (20 m radius) with merged routes
    /// and track-aligned bearing.  Used by the map view for capsule markers.
    var consolidatedStations: [ConsolidatedStation] = []

    /// Guards against redundant network fetches when the ViewModel is
    /// re-created (e.g. HomeView structural identity changes).
    /// MUST be static — an instance-level flag only guards the single instance
    /// that owns it; if SwiftUI creates multiple instances before the first
    /// finishes loading (observed as 6× SYSTEM_MAP in logs) each gets its own
    /// fresh flag = false and kicks off a duplicate load task.
    private static var hasStartedLoading = false

    /// Guards specifically against double-loading subway stations.
    /// We cannot use `cachedStations.isEmpty` as a guard because
    /// `loadFromDiskCache()` (inside `loadSystemMap()`) appends commuter-rail
    /// stops to `cachedStations` BEFORE `loadStations()` gets a chance to run.
    /// That made `cachedStations.isEmpty` return false, causing
    /// `loadStations()` to return immediately — with zero subway stations.
    private static var hasStartedStationLoad = false

    /// Handle to the currently running flattening task.  Used to cancel
    /// an in-flight disk-cache flatten when a fresher network flatten
    /// arrives — prevents the first task from persisting incomplete data.
    private var activeFlattenTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        if let snapshot = Self.sharedSnapshot {
            cachedSystemMap = snapshot.systemMap
            cachedOffsetSubwayLines = snapshot.offsetSubwayLines
            cachedTrunkPolylines = snapshot.trunkPolylines
            flattenedSubwayPolylines = snapshot.flattenedSubway
            flattenedCommuterRailPolylines = snapshot.flattenedCommuter
            trunkRouteLabels = snapshot.routeLabels
            cachedStations = snapshot.stations
            consolidatedStations = snapshot.consolidatedStations
            return
        }

        guard !Self.hasStartedLoading else { return }
        Self.hasStartedLoading = true
        Task {
            let mapLoadStart = Date()
            // Load system map and stations fully in parallel — neither
            // blocks the other. Map lines render the instant they arrive;
            // station dots appear independently as soon as the processed
            // station endpoint resolves.
            async let mapTask: Void = loadSystemMap()
            async let stationsTask: Void = loadStations()
            _ = await (mapTask, stationsTask)

            let mapLoadElapsed = Date().timeIntervalSince(mapLoadStart)
            let subwayCount = flattenedSubwayPolylines.count
            let commuterCount = flattenedCommuterRailPolylines.count
            let stationCount = cachedStations.count
            let elapsed = AppLogger.formatDuration(mapLoadElapsed)
            let sinceL = AppLogger.shared.timeSinceLaunchFormatted
            AppLogger.shared.log(
                "TIMING",
                message: "MapSystemViewModel loaded in"
                    + " \(elapsed) — \(subwayCount) subway"
                    + " + \(commuterCount) commuter polylines,"
                    + " \(stationCount) stations"
                    + " (T+\(sinceL))")

            // Both tasks ran in parallel so stations may have been
            // consolidated before offset polylines were ready.
            // Re-consolidate once to guarantee transfer-intersection
            // placement has access to cachedOffsetSubwayLines.
            self.consolidateStations()

            Self.sharedSnapshot = SharedSnapshot(
                systemMap: cachedSystemMap,
                offsetSubwayLines: cachedOffsetSubwayLines,
                trunkPolylines: cachedTrunkPolylines,
                flattenedSubway: flattenedSubwayPolylines,
                flattenedCommuter: flattenedCommuterRailPolylines,
                stations: cachedStations,
                consolidatedStations: consolidatedStations,
                routeLabels: trunkRouteLabels
            )
        }
    }

    // MARK: - System Map Loading

    /// Fetches the full transit system map (subway, LIRR, MNR polylines).
    ///
    /// **Fast-path**: On every launch after the first, the system map renders
    /// from a persistent disk cache in < 100 ms — no network needed.
    /// A background refresh keeps the cache fresh (≤ 24 h stale window).
    ///
    /// Falls back to bundled offline data when network is unavailable.
    func loadSystemMap() async {
        if !cachedSystemMap.isEmpty { return }

        if let snapshot = Self.sharedSnapshot, !snapshot.systemMap.isEmpty {
            cachedSystemMap = snapshot.systemMap
            cachedOffsetSubwayLines = snapshot.offsetSubwayLines
            cachedTrunkPolylines = snapshot.trunkPolylines
            flattenedSubwayPolylines = snapshot.flattenedSubway
            flattenedCommuterRailPolylines = snapshot.flattenedCommuter
            trunkRouteLabels = snapshot.routeLabels
            consolidatedStations = snapshot.consolidatedStations
            AppLogger.shared.log("SYSTEM_MAP", message: "Reused shared map snapshot")
            return
        }

        // ── Phase 0: Try pre-computed flattened polyline cache ──
        // If we have a recent flattened cache, render it INSTANTLY (< 50 ms)
        // by skipping the entire decode → unify → simplify → flatten pipeline.
        // This is the fastest possible cold-start path.
        let diskCacheMgr = OfflineCacheManager.shared
        let flattenedRestored = loadFlattenedFromDiskCache()
        if flattenedRestored {
            AppLogger.shared.log(
                "SYSTEM_MAP",
                message: "⚡ Instant render from flattened"
                    + " polyline cache")
        }

        // ── Phase 1: Instant render from disk cache ──
        // Try to hydrate from the persistent disk cache first.
        // This avoids the network round-trip and lets the map draw
        // immediately — matching Transit app's instant-map behavior.
        let hasDiskCache = await loadFromDiskCache()

        // ── Phase 2: Network refresh (background) ──
        // If we already rendered from cache, refresh in the background
        // so the user sees the map instantly but gets fresh data.
        // If no cache existed, this is the primary load path.
        if !diskCacheMgr.isOnline && !hasDiskCache && !flattenedRestored {
            // Truly offline with no cache — use the bundled fallback
            await loadOfflineSystemMap()
            return
        }

        if diskCacheMgr.isOnline {
            if hasDiskCache || flattenedRestored {
                // Map is already rendered from disk cache — delay the network
                // refresh by a few seconds so the backend's limited CPU can
                // prioritize /nearby/grouped (which the user sees first).
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
            }
            await fetchAndRenderFromNetwork(isBackgroundRefresh: hasDiskCache || flattenedRestored)
        }
    }

    /// Attempts to load the system map from the persistent disk cache.
    /// Returns `true` if the cache was populated and rendering was triggered.
    private func loadFromDiskCache() async -> Bool {
        let cache = OfflineCacheManager.shared

        // Load subway shapes from disk
        guard let subwayResponse = cache.getCachedSubwayShapes() else { return false }

        var decoded: [CachedTransitLine] = subwayResponse.lines.map { line in
            CachedTransitLine(
                id: line.routeId,
                color: Color(hex: line.colorHex),
                coordinates: line.decodedPolylines,
                mode: .subway
            )
        }

        // Also load commuter rail from disk cache
        var commuterStops: [CachedSubwayStation] = []

        if let lirrResponse = cache.getCachedLIRRShapes() {
            decoded.append(contentsOf: lirrResponse.lines.map { line in
                CachedTransitLine(
                    id: line.routeId,
                    color: Color(hex: line.colorHex),
                    coordinates: line.decodedPolylines,
                    mode: .lirr
                )
            })
            for line in lirrResponse.lines {
                for stop in line.stops {
                    commuterStops.append(CachedSubwayStation(
                        id: stop.stopId,
                        name: stop.name,
                        coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon),
                        routes: [line.routeId]
                    ))
                }
            }
        }
        if let mnrResponse = cache.getCachedMNRShapes() {
            decoded.append(contentsOf: mnrResponse.lines.map { line in
                CachedTransitLine(
                    id: line.routeId,
                    color: Color(hex: line.colorHex),
                    coordinates: line.decodedPolylines,
                    mode: .mnr
                )
            })
            for line in mnrResponse.lines {
                for stop in line.stops {
                    commuterStops.append(CachedSubwayStation(
                        id: stop.stopId,
                        name: stop.name,
                        coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon),
                        routes: [line.routeId]
                    ))
                }
            }
        }

        // Merge commuter-rail stops into the station list (dedup by ID)
        if !commuterStops.isEmpty {
            var stopMap: [String: CachedSubwayStation] = [:]
            for s in commuterStops {
                if var existing = stopMap[s.id] {
                    let merged = Array(Set(existing.routes + s.routes)).sorted()
                    existing = CachedSubwayStation(
                        id: existing.id, name: existing.name,
                        coordinate: existing.coordinate, routes: merged
                    )
                    stopMap[s.id] = existing
                } else {
                    stopMap[s.id] = s
                }
            }
            cachedStations.append(contentsOf: stopMap.values)
        }

        guard !decoded.isEmpty else { return false }

        let subwayCount = decoded.filter { $0.mode == .subway }.count
        let commuterCount = decoded.count - subwayCount
        AppLogger.shared.log(
            "SYSTEM_MAP",
            message: "Disk cache → \(subwayCount) subway"
                + " + \(commuterCount) commuter rail lines"
                + " (instant render)")

        self.cachedSystemMap = decoded
        self.cachedTrunkPolylines = subwayResponse.trunkPolylines
        self.cachedCrossings = subwayResponse.crossings ?? []
        self.computeSubwayOffsets()
        return true
    }

    /// Fetches shapes from the network and updates the map.
    /// When `isBackgroundRefresh` is true, the map already has content from
    /// the disk cache — this just silently replaces it with fresh data.
    private func fetchAndRenderFromNetwork(isBackgroundRefresh: Bool) async {
        // Wait for the backend health gate before firing shape requests.
        // Without this, all three shape fetches (subway/LIRR/MNR) timeout
        // or 502 during Render cold-start, wasting 60-90s of wall time.
        await TrackAPI.waitForBackendReady()

        let networkStart = Date()
        do {
            // Fire all three transit fetches in parallel.
            // Subway is required; LIRR and MNR are optional (logged on failure).
            async let subwayTask = TrackAPI.fetchAllSubwayShapes()
            async let lirrTask: AllCommuterRailLinesResponse? = {
                do {
                    return try await TrackAPI.fetchAllLIRRShapes()
                } catch {
                    await MainActor.run {
                        AppLogger.shared.logError(
                            "LIRR shapes failed",
                            error: error)
                    }
                    return nil
                }
            }()
            async let mnrTask: AllCommuterRailLinesResponse? = {
                do {
                    return try await TrackAPI.fetchAllMNRShapes()
                } catch {
                    await MainActor.run {
                        AppLogger.shared.logError(
                            "MNR shapes failed",
                            error: error)
                    }
                    return nil
                }
            }()

            // ── Phase A: Commuter rail (fast — usually cache hit) ──
            // Await LIRR/MNR first because they typically resolve in
            // < 1 s (often from URLSession cache) while subway/shapes/all
            // can take 20-60 s during Render cold start.  Processing
            // commuter rail here lets the map show LIRR & MNR lines
            // immediately instead of blocking behind the subway await.
            let lirrResponse = await lirrTask
            let mnrResponse = await mnrTask

            var commuterLines: [CachedTransitLine] = []
            var commuterStops: [CachedSubwayStation] = []

            if let lirrResponse {
                let lirrLines: [CachedTransitLine] = lirrResponse.lines.map { line in
                    CachedTransitLine(
                        id: line.routeId,
                        color: Color(hex: line.colorHex),
                        coordinates: line.decodedPolylines,
                        mode: .lirr
                    )
                }
                commuterLines.append(contentsOf: lirrLines)
                OfflineCacheManager.shared.cacheLIRRShapes(lirrResponse)
                for line in lirrResponse.lines {
                    for stop in line.stops {
                        let coord = CLLocationCoordinate2D(
                            latitude: stop.lat,
                            longitude: stop.lon)
                        commuterStops.append(CachedSubwayStation(
                            id: stop.stopId,
                            name: stop.name,
                            coordinate: coord,
                            routes: [line.routeId]
                        ))
                    }
                }
                AppLogger.shared.log(
                    "SYSTEM_MAP",
                    message: "LIRR: \(lirrLines.count) lines loaded")
            }

            if let mnrResponse {
                let mnrLines: [CachedTransitLine] = mnrResponse.lines.map { line in
                    CachedTransitLine(
                        id: line.routeId,
                        color: Color(hex: line.colorHex),
                        coordinates: line.decodedPolylines,
                        mode: .mnr
                    )
                }
                commuterLines.append(contentsOf: mnrLines)
                OfflineCacheManager.shared.cacheMNRShapes(mnrResponse)
                for line in mnrResponse.lines {
                    for stop in line.stops {
                        let coord = CLLocationCoordinate2D(
                            latitude: stop.lat,
                            longitude: stop.lon)
                        commuterStops.append(CachedSubwayStation(
                            id: stop.stopId,
                            name: stop.name,
                            coordinate: coord,
                            routes: [line.routeId]
                        ))
                    }
                }
                AppLogger.shared.log(
                    "SYSTEM_MAP",
                    message: "MNR: \(mnrLines.count) lines loaded")
            }

            // Render commuter rail NOW — don't wait for subway.
            // Appends to the subway polylines already visible from the
            // flattened-cache or disk-cache loaded earlier.
            if !commuterLines.isEmpty {
                self.cachedSystemMap.removeAll(where: { $0.mode == .lirr || $0.mode == .mnr })
                self.cachedSystemMap.append(contentsOf: commuterLines)
                flattenCommuterRailPolylines()

                // Merge commuter-rail stops into the station list
                if !commuterStops.isEmpty {
                    var stopMap: [String: CachedSubwayStation] = [:]
                    for s in commuterStops {
                        if var existing = stopMap[s.id] {
                            let merged = Array(Set(existing.routes + s.routes)).sorted()
                            existing = CachedSubwayStation(
                                id: existing.id,
                                name: existing.name,
                                coordinate: existing.coordinate,
                                routes: merged
                            )
                            stopMap[s.id] = existing
                        } else {
                            stopMap[s.id] = s
                        }
                    }
                    let dedupedStops = Array(stopMap.values)
                    self.cachedStations.append(contentsOf: dedupedStops)
                    self.consolidateStations()
                    let rawCount = commuterStops.count
                    AppLogger.shared.log(
                        "STATIONS",
                        message: "Added"
                            + " \(dedupedStops.count)"
                            + " commuter-rail stops"
                            + " (\(rawCount) raw)")
                }
                AppLogger.shared.log(
                    "SYSTEM_MAP",
                    message: "Commuter rail rendered"
                        + " (\(commuterLines.count) lines)"
                        + " — awaiting subway…")
            }

            // ── Phase B: Subway (may be slow during cold start) ─────
            let response = try await subwayTask
            let subwayElapsed = Date().timeIntervalSince(networkStart)
            let elapsed = AppLogger.formatDuration(subwayElapsed)
            AppLogger.shared.log(
                "TIMING",
                message: "  subway/shapes/all →"
                    + " \(response.lines.count) lines"
                    + " in \(elapsed)")

            OfflineCacheManager.shared.cacheSubwayShapes(response)

            var decoded: [CachedTransitLine] = response.lines.map { line in
                CachedTransitLine(
                    id: line.routeId,
                    color: Color(hex: line.colorHex),
                    coordinates: line.decodedPolylines,
                    mode: .subway
                )
            }
            // Merge commuter rail (already processed in Phase A)
            decoded.append(contentsOf: commuterLines)

            self.cachedSystemMap = decoded
            self.cachedTrunkPolylines = response.trunkPolylines
            self.cachedCrossings = response.crossings ?? []
            self.computeSubwayOffsets(forceReflatten: true)

            // Re-flatten commuter rail after cachedSystemMap was replaced
            if !commuterLines.isEmpty {
                flattenCommuterRailPolylines()
            }

            let subwayCount = decoded.filter { $0.mode == .subway }.count
            let lirrCount = decoded.filter { $0.mode == .lirr }.count
            let mnrCount = decoded.filter { $0.mode == .mnr }.count
            let totalBranches = decoded.reduce(0) { $0 + $1.coordinates.count }
            let totalPoints = decoded.reduce(0) { $0 + $1.coordinates.reduce(0) { $0 + $1.count } }

            let refreshTag = isBackgroundRefresh ? "(background refresh)" : ""
            AppLogger.shared.log(
                "SYSTEM_MAP",
                message: "Loaded \(decoded.count) transit lines"
                    + " (\(subwayCount) subway,"
                    + " \(lirrCount) LIRR,"
                    + " \(mnrCount) MNR) —"
                    + " \(totalBranches) branches,"
                    + " \(totalPoints) total points"
                    + " \(refreshTag)")

            // ── Commuter-rail retry ──
            // If LIRR/MNR both failed in Phase A, schedule retries.
            if lirrCount == 0 || mnrCount == 0 {
                let missingModes = [
                    lirrCount == 0 ? "LIRR" : nil,
                    mnrCount == 0 ? "MNR" : nil,
                ].compactMap { $0 }.joined(separator: "+")
                AppLogger.shared.log(
                    "SYSTEM_MAP",
                    message: "⚠️ Missing \(missingModes)"
                        + " — scheduling commuter-rail retry")
                let commuterRetryDelays: [UInt64] = [8, 25, 50]
                for (attempt, delay) in commuterRetryDelays.enumerated() {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    AppLogger.shared.log(
                        "SYSTEM_MAP",
                        message: "🔄 Commuter-rail retry"
                            + " \(attempt + 1)"
                            + "/\(commuterRetryDelays.count)…")

                    var addedLines: [CachedTransitLine] = []
                    var addedStops: [CachedSubwayStation] = []

                    if !cachedSystemMap.contains(where: { $0.mode == .lirr }) {
                        if let lirrResp = try? await TrackAPI.fetchAllLIRRShapes() {
                            let lines = lirrResp.lines.map { line in
                                CachedTransitLine(
                                    id: line.routeId,
                                    color: Color(hex: line.colorHex),
                                    coordinates: line.decodedPolylines,
                                    mode: .lirr)
                            }
                            addedLines.append(contentsOf: lines)
                            OfflineCacheManager.shared.cacheLIRRShapes(lirrResp)
                            for line in lirrResp.lines {
                                for stop in line.stops {
                                    let coord = CLLocationCoordinate2D(
                                        latitude: stop.lat,
                                        longitude: stop.lon)
                                    addedStops.append(CachedSubwayStation(
                                        id: stop.stopId,
                                        name: stop.name,
                                        coordinate: coord,
                                        routes: [line.routeId]))
                                }
                            }
                        }
                    }

                    if !cachedSystemMap.contains(where: { $0.mode == .mnr }) {
                        if let mnrResp = try? await TrackAPI.fetchAllMNRShapes() {
                            let lines = mnrResp.lines.map { line in
                                CachedTransitLine(
                                    id: line.routeId,
                                    color: Color(hex: line.colorHex),
                                    coordinates: line.decodedPolylines,
                                    mode: .mnr)
                            }
                            addedLines.append(contentsOf: lines)
                            OfflineCacheManager.shared.cacheMNRShapes(mnrResp)
                            for line in mnrResp.lines {
                                for stop in line.stops {
                                    let coord = CLLocationCoordinate2D(
                                        latitude: stop.lat,
                                        longitude: stop.lon)
                                    addedStops.append(CachedSubwayStation(
                                        id: stop.stopId,
                                        name: stop.name,
                                        coordinate: coord,
                                        routes: [line.routeId]))
                                }
                            }
                        }
                    }

                    if !addedLines.isEmpty {
                        self.cachedSystemMap.append(contentsOf: addedLines)
                        if !addedStops.isEmpty {
                            self.cachedStations.append(contentsOf: addedStops)
                            self.consolidateStations()
                        }
                        flattenCommuterRailPolylines()
                        let hasLIRR = cachedSystemMap.contains(where: { $0.mode == .lirr })
                        let hasMNR = cachedSystemMap.contains(where: { $0.mode == .mnr })
                        AppLogger.shared.log(
                            "SYSTEM_MAP",
                            message: "✅ Commuter-rail retry"
                                + " \(attempt + 1) added"
                                + " \(addedLines.count) lines"
                                + " (LIRR: \(hasLIRR),"
                                + " MNR: \(hasMNR))")
                        if hasLIRR && hasMNR { return }
                    } else {
                        AppLogger.shared.log(
                            "SYSTEM_MAP",
                            message: "⚠️ Commuter-rail retry"
                                + " \(attempt + 1) — still no data")
                    }
                }
            }
        } catch {
            AppLogger.shared.logError("loadSystemMap", error: error)
            // Fall back to offline data on error only if we don't already
            // have content (disk cache already rendered)
            if cachedSystemMap.isEmpty {
                await loadOfflineSystemMap()
            }

            // ── Retry with backoff ──
            // The initial fetch often fails during Render cold start
            // (502/timeout while corridor pipeline builds).  Schedule
            // a background retry so the map eventually gets fresh
            // polylines — even if the first attempt hit stale
            // offline data.
            let retryDelays: [UInt64] = [10, 30, 60]  // seconds
            for (attempt, delay) in retryDelays.enumerated() {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard !Task.isCancelled else { return }
                AppLogger.shared.log(
                    "SYSTEM_MAP",
                    message: "🔄 Retry \(attempt + 1)"
                        + "/\(retryDelays.count)"
                        + " fetching shapes…")
                let countBefore = (
                    flattenedSubwayPolylines.count
                    + flattenedCommuterRailPolylines.count)
                await fetchAndRenderFromNetwork(
                    isBackgroundRefresh: true)
                let countAfter = (
                    flattenedSubwayPolylines.count
                    + flattenedCommuterRailPolylines.count)
                let hasCommuter = cachedSystemMap.contains {
                    $0.mode == .lirr || $0.mode == .mnr
                }
                if countAfter > countBefore || hasCommuter {
                    AppLogger.shared.log(
                        "SYSTEM_MAP",
                        message: "✅ Shapes retry"
                            + " \(attempt + 1) succeeded —"
                            + " \(cachedSystemMap.count)"
                            + " lines loaded")
                    return
                }
                AppLogger.shared.log(
                    "SYSTEM_MAP",
                    message: "⚠️ Shapes retry"
                        + " \(attempt + 1)"
                        + " — no new data yet")
            }
        }
    }

    /// Determines the transit mode for a route ID based on prefix
    private func transitMode(for routeId: String) -> CachedTransitLine.TransitLineMode? {
        let upper = routeId.uppercased()
        if upper.hasPrefix("LIRR") { return .lirr }
        if upper.hasPrefix("MNR") { return .mnr }
        return nil
    }

    /// Checks if a route ID is a commuter rail route (LIRR or MNR)
    private func isCommuterRailRoute(_ routeId: String) -> Bool {
        transitMode(for: routeId) != nil
    }

    // MARK: - Commuter Rail Bundle Loading

    /// Loads LIRR and MNR routes from the static bundle
    private func loadCommuterRailFromBundle(_ bundle: StaticBundle) -> [CachedTransitLine] {
        var lines: [CachedTransitLine] = []

        // Log all route IDs in the bundle for debugging
        let allRouteIds = bundle.routes.routeIds

        // Count LIRR and MNR routes (uppercase once for efficiency)
        var lirrCount = 0
        var mnrCount = 0
        for routeId in allRouteIds {
            let upper = routeId.uppercased()
            if upper.hasPrefix("LIRR") {
                lirrCount += 1
            } else if upper.hasPrefix("MNR") {
                mnrCount += 1
            }
        }

        AppLogger.shared.log(
            "BUNDLE",
            message: "Bundle has \(allRouteIds.count) routes: \(lirrCount) LIRR, \(mnrCount) MNR")

        for routeId in allRouteIds {
            // Only process LIRR and MNR routes
            guard let mode = transitMode(for: routeId) else { continue }

            let branches = bundle.routes.branches(for: routeId)
            guard !branches.isEmpty else { continue }

            // Convert BundleCoordinate to CLLocationCoordinate2D
            let coordinates: [[CLLocationCoordinate2D]] = branches.map { branch in
                branch.map { coord in
                    CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lon)
                }
            }

            let color = SubwayRoutesData.color(for: routeId)

            lines.append(
                CachedTransitLine(
                    id: routeId,
                    color: color,
                    coordinates: coordinates,
                    mode: mode
                ))
        }

        return lines
    }

    /// Loads all transit routes from bundled offline data.
    private func loadOfflineSystemMap() async {
        // Load subway routes from bundled offline data
        var offlineLines: [CachedTransitLine] = SubwayRoutesData.allRouteIds.compactMap {
            routeId -> CachedTransitLine? in
            let rawBranches = SubwayRoutesData.routeBranches(for: routeId)
            guard !rawBranches.isEmpty else { return nil }
            return CachedTransitLine(
                id: routeId,
                color: SubwayRoutesData.color(for: routeId),
                coordinates: rawBranches,
                mode: .subway
            )
        }

        // Load LIRR shapes from disk cache (saved when last online)
        if let lirrResponse = OfflineCacheManager.shared.getCachedLIRRShapes() {
            let lirrLines: [CachedTransitLine] = lirrResponse.lines.map { line in
                CachedTransitLine(
                    id: line.routeId,
                    color: Color(hex: line.colorHex),
                    coordinates: line.decodedPolylines,
                    mode: .lirr
                )
            }
            offlineLines.append(contentsOf: lirrLines)
        }

        // Load MNR shapes from disk cache (saved when last online)
        if let mnrResponse = OfflineCacheManager.shared.getCachedMNRShapes() {
            let mnrLines: [CachedTransitLine] = mnrResponse.lines.map { line in
                CachedTransitLine(
                    id: line.routeId,
                    color: Color(hex: line.colorHex),
                    coordinates: line.decodedPolylines,
                    mode: .mnr
                )
            }
            offlineLines.append(contentsOf: mnrLines)
        }

        self.cachedSystemMap = offlineLines
        self.computeSubwayOffsets()

        // Count per mode for logging
        let subwayCount = offlineLines.filter { $0.mode == .subway }.count
        let lirrCount = offlineLines.filter { $0.mode == .lirr }.count
        let mnrCount = offlineLines.filter { $0.mode == .mnr }.count
        let totalBranches = offlineLines.reduce(0) { $0 + $1.coordinates.count }
        AppLogger.shared.log(
            "OFFLINE",
            message:
                "Loaded \(offlineLines.count) offline transit"
                + " routes (\(subwayCount) subway,"
                + " \(lirrCount) LIRR, \(mnrCount) MNR,"
                + " \(totalBranches) total branches)"
        )
    }

    // MARK: - Subway Offsets & Flattened Polylines

    /// Populates `cachedOffsetSubwayLines` from the system map.
    ///
    /// Corridor offsets (fanning out co-located lines like 4/5/6 on Lex Ave)
    /// are now computed server-side by `/subway/shapes/all`, so the client
    /// simply converts `CachedTransitLine` → `OffsetSubwayLine` 1:1.
    /// - Parameter forceReflatten: When `true` (network refresh), always
    ///   recompute flattened polylines even if they're already populated.
    ///   When `false` (disk cache loading), keep existing flattened data
    ///   so good polylines from the flattened disk cache aren't overwritten
    ///   by a raw cache that may lack trunk polyline offsets.
    private func computeSubwayOffsets(forceReflatten: Bool = false) {
        let subwayLines = cachedSystemMap.filter { $0.mode == .subway }
        cachedOffsetSubwayLines = subwayLines.map {
            OffsetSubwayLine(id: $0.id, color: $0.color, coordinates: $0.coordinates)
        }
        AppLogger.shared.log(
            "SYSTEM_MAP",
            message: "Mapped \(subwayLines.count) subway lines (offsets applied server-side)")

        // Skip re-flattening if good polylines already exist (e.g. from
        // the flattened disk cache) — prevents overwriting correct lane
        // offsets with zero-offset data from a raw cache that's missing
        // trunk polylines.  Network refresh always force-re-flattens.
        // Validate that the cached count is plausible (≥ 30 polylines for
        // 11 trunk groups) — if the cache was persisted from an incomplete
        // flatten, force a re-compute instead of preserving gaps.
        if !forceReflatten && !flattenedSubwayPolylines.isEmpty {
            let hasOffsets = flattenedSubwayPolylines.contains { abs($0.laneOffset) > 0.01 }
            let hasEnoughPolylines = flattenedSubwayPolylines.count >= 30
            if hasOffsets && hasEnoughPolylines {
                AppLogger.shared.log(
                    "SYSTEM_MAP",
                    message: "Keeping"
                        + " \(flattenedSubwayPolylines.count)"
                        + " existing flattened polylines"
                        + " with valid offsets"
                        + " (skip re-flatten)")
                return
            }
        }

        // Pre-compute flattened polylines for efficient rendering.
        // Heavy CPU work (unify + RDP + Catmull-Rom) runs off main actor
        // so the map and UI remain responsive during computation.
        // Cancel any in-flight flatten task first — prevents a stale
        // disk-cache flatten from persisting incomplete data when a
        // fresher network refresh arrives moments later.
        activeFlattenTask?.cancel()
        activeFlattenTask = Task {
            await computeFlattenedPolylinesAsync()
        }
    }

    /// Flattens commuter rail (LIRR / MNR) polylines from `cachedSystemMap`
    /// into `flattenedCommuterRailPolylines`.  Extracted as a standalone
    /// method so it can be called **after** LIRR/MNR data is confirmed in
    /// `cachedSystemMap` — fixing the race where the main flattening task
    /// runs before commuter data has arrived from the network.
    private func flattenCommuterRailPolylines() {
        let tolerance = AppSettings.shared.polylineSimplificationTolerance
        var commuterFlat: [FlattenedMapPolyline] = []
        for line in cachedSystemMap where line.mode != .subway {
            let validCoords = line.coordinates.filter { $0.count >= 2 }
            guard !validCoords.isEmpty else { continue }
            let unified = unifyTrainPolylines(validCoords)
            for (branchIndex, coords) in unified.enumerated() {
                let simplified = simplifyPolyline(coords, tolerance: tolerance)
                commuterFlat.append(
                    FlattenedMapPolyline(
                        id: "\(line.id)_\(branchIndex)",
                        coordinates: simplified,
                        color: line.color,
                        lineWidth: 2,
                        routeIds: [line.id],
                        isElevated: false,
                        trunkIndex: -1,
                        laneOffset: 0
                    ))
            }
        }
        flattenedCommuterRailPolylines = commuterFlat

        if !commuterFlat.isEmpty {
            let points = commuterFlat.reduce(0) { $0 + $1.coordinates.count }
            AppLogger.shared.log(
                "SYSTEM_MAP",
                message: "Flattened"
                    + " \(commuterFlat.count) commuter rail"
                    + " polylines (\(points) points)")
        }
    }

    // MARK: - MTA Trunk Color Groups
    //
    // Apple Maps draws ONE polyline per trunk color — not per route.
    // Routes that share a physical corridor and color are merged into a
    // single set of polylines (trunk + branch stubs).  This dramatically
    // reduces the number of MapPolyline overlays and eliminates the
    // "5 stacked yellow lines" problem.

    /// Each group is a set of route IDs that share one color on the MTA map.
    /// The first route ID in each group is used as the "representative" for
    /// color lookup via `SubwayRoutesData.color(for:)`.
    private static let trunkGroups: [[String]] = [
        ["1", "2", "3"],               // Red — 7th Ave / Broadway
        ["4", "5", "6", "6X"],         // Green — Lexington Ave
        ["7", "7X"],                   // Purple — Flushing
        ["A", "C", "E"],              // Blue — 8th Ave
        ["B", "D", "F", "FX", "M"],   // Orange — 6th Ave
        ["G"],                          // Lime Green — Crosstown
        ["J", "Z"],                    // Brown — Nassau St
        ["L"],                          // Gray — 14th St / Canarsie
        ["N", "Q", "R", "W"],         // Yellow — Broadway BMT
        ["S"],                          // Shuttle Gray
        ["SI"],                        // Staten Island Railway
    ]

    /// Pre-computes flattened polyline arrays with stable IDs for efficient MapLibre rendering.
    ///
    /// **Strategy — Apple Maps style**:
    /// 1. Routes grouped by MTA trunk color (e.g. N/Q/R/W → yellow).
    /// 2. All polyline segments for a color group unified into ONE trunk + branches.
    /// 3. Cross-color corridor offsets applied so parallel lines (e.g. blue + green
    ///    on Lex Ave) render side-by-side, not stacked.
    /// 4. Route labels generated at intervals along each trunk.
    ///
    /// Runs as an async method so it yields to the run loop between phases,
    /// keeping the UI responsive while heavy CPU work executes.
    private func computeFlattenedPolylinesAsync() async {
        _ = AppSettings.shared.polylineSimplificationTolerance

        // Build a lookup: route ID → index into cachedOffsetSubwayLines
        // (used for route-label spatial attribution regardless of trunk path)
        var linesByRouteId: [String: OffsetSubwayLine] = [:]
        for line in cachedOffsetSubwayLines {
            linesByRouteId[line.id.uppercased()] = line
        }

        // ---- Phase 1: Per-color unification + simplification ----
        // Each entry: (groupIndex, groupRouteIds, color, polylines, laneOffset)
        struct ColorGroupResult {
            let groupIndex: Int
            let routeIds: [String]
            let color: Color
            var polylines: [[CLLocationCoordinate2D]]
            /// Signed perpendicular offset from the server corridor pipeline.
            var laneOffset: CGFloat
            /// Per-branch local line offsets from the server corridor pipeline.
            let polylineLaneOffsets: [CGFloat]
        }

        var colorGroupResults: [ColorGroupResult] = []
        var originalSubwayPoints: Int = 0

        // When the server provides pre-merged trunk polylines, use them
        // directly — they are the Phase 1+3 output of the corridor pipeline
        // and are the SAME geometry that station dots were snapped to.
        // This eliminates overlapping same-colour lines and ensures polylines
        // pass through station positions.
        let useTrunkPolylines: Bool = !(cachedTrunkPolylines?.isEmpty ?? true)

        if useTrunkPolylines, let trunkGroups = cachedTrunkPolylines {
            for trunk in trunkGroups {
                let decoded: [[CLLocationCoordinate2D]] = (
                    trunk.decodedPolylines.filter { $0.count >= 2 })
                guard !decoded.isEmpty else { continue }
                let decodedCount: Int = decoded.reduce(0) { $0 + $1.count }
                originalSubwayPoints += decodedCount

                let groupColor: Color = SubwayRoutesData.color(for: trunk.routeIds.first ?? "")

                #if DEBUG
                let localOffsets = trunk.polylineLaneOffsets
                    .map { String(format: "%.2f", $0) }
                    .joined(separator: ", ")
                AppLogger.shared.log(
                    "POLYLINE_TRUNK",
                    message: "[\(trunk.routeIds.joined(separator: "/"))]"
                        + ": \(decoded.count) trunk polylines,"
                        + " laneOffset=\(String(format: "%.3f", Double(trunk.laneOffset))),"
                        + " localOffsets=[\(localOffsets)]"
                        + " (server-merged)")
                #endif

                colorGroupResults.append(ColorGroupResult(
                    groupIndex: trunk.trunkIndex,
                    routeIds: trunk.routeIds,
                    color: groupColor,
                    polylines: decoded,
                    laneOffset: trunk.laneOffset,
                    polylineLaneOffsets: trunk.polylineLaneOffsets
                ))
            }
        } else {
            // Fallback: pool per-route GTFS shapes and unify client-side
            for (groupIndex, group) in Self.trunkGroups.enumerated() {
                var pooledSegments: [[CLLocationCoordinate2D]] = []
                for routeId in group {
                    if let line = linesByRouteId[routeId.uppercased()] ?? linesByRouteId[routeId] {
                        let valid = line.coordinates.filter { $0.count >= 2 }
                        pooledSegments.append(contentsOf: valid)
                    }
                }

                guard !pooledSegments.isEmpty else { continue }
                let pooledCount: Int = pooledSegments.reduce(0) { $0 + $1.count }
                originalSubwayPoints += pooledCount

                let groupColor: Color = SubwayRoutesData.color(for: group[0])

                let unified = unifyTrainPolylines(pooledSegments)
                    .filter { $0.count >= 2 }

                let activeRoutes = group.filter { routeId in
                    linesByRouteId[routeId.uppercased()] != nil || linesByRouteId[routeId] != nil
                }

                AppLogger.shared.log(
                    "POLYLINE_UNIFY",
                    message: "[\(activeRoutes.joined(separator: "/"))]:"
                        + " \(pooledSegments.count) segments"
                        + " → \(unified.count) polylines"
                        + " (trunk + branch stubs)")

                colorGroupResults.append(ColorGroupResult(
                    groupIndex: groupIndex,
                    routeIds: activeRoutes,
                    color: groupColor,
                    polylines: unified,
                    laneOffset: 0,
                    polylineLaneOffsets: []
                ))
            }

        }

        // ── Client-side corridor detection ──
        //
        // When ALL lane offsets are zero (server corridor pipeline didn't
        // compute them or server timed out), detect overlapping trunk
        // groups using a spatial hash grid and assign lane offsets so
        // parallel lines render side-by-side instead of stacking
        // invisibly on top of each other.
        let allOffsetsZero = colorGroupResults.allSatisfy { abs($0.laneOffset) < 0.01 }
        if allOffsetsZero && colorGroupResults.count >= 2 {
            AppLogger.shared.log(
                "CORRIDOR_FALLBACK",
                message: "All \(colorGroupResults.count)"
                    + " trunk offsets are zero"
                    + " — running client corridor detection")
            let polylinesByGroup = Dictionary(
                uniqueKeysWithValues: colorGroupResults.map { ($0.groupIndex, $0.polylines) }
            )
            let clientOffsets = Self._assignClientCorridorOffsets(
                groupCount: colorGroupResults.count,
                groupIndices: colorGroupResults.map(\.groupIndex),
                polylinesByGroup: polylinesByGroup
            )
            for i in colorGroupResults.indices {
                if let offset = clientOffsets[colorGroupResults[i].groupIndex] {
                    colorGroupResults[i].laneOffset = offset
                }
            }
        }

        #if DEBUG
        // ── Diagnostic: Lane offset summary for ALL trunk groups ──
        let offsetSummary = colorGroupResults
            .sorted { $0.groupIndex < $1.groupIndex }
            .map { grp in
                let label = grp.routeIds.joined(separator: "/")
                return "\(label)=\(String(format: "%+.2f", Double(grp.laneOffset)))"
            }
            .joined(separator: ", ")
        AppLogger.shared.log(
            "LANE_OFFSET",
            message: "Global trunk offsets: [\(offsetSummary)]")
        #endif

        // Yield to let the map render whatever data is already available
        await Task.yield()

        // ---- Phase 2+3: Simplification + smoothing + flatten ----
        //
        // CORRIDOR OFFSETS ARE APPLIED SERVER-SIDE by corridor_pipeline.py.
        // The server's 5-phase topological pipeline (skeleton → lane ordering
        // → perpendicular vertex offsets → junction blending → export) produces
        // correctly-offset polylines in WGS84.
        //
        // Client pipeline (order matters):
        //   1. RDP simplification — reduce raw GTFS noise while preserving detail
        //   2. Backtrack + spike removal — fix artifacts
        //   3. Near-duplicate removal — clean micro-clusters
        //   4. High-density circular-arc fillet — smooth ALL bends ≥ 6°
        //      with 20-point arcs and large radius for glass-smooth curves
        //
        // v9 — Backend now produces float64 + precision-6 encoded polylines
        // with 25 m densification (was float32 + precision-5 + 100 m gaps).
        // Source data is 10× more precise, so client-side smoothing can be
        // lighter-touch.
        //
        // Parameters:
        //   RDP tolerance 0.00004° (~4.4 m) — preserves curve detail
        //   Fillet angle 10° — catches visible subway bends
        //   Arc points 16 — smooth at all zoom levels

        struct PolylineOrigin { let resultIndex: Int; let branchIndex: Int }

        var grouped: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = []
        var mapping: [PolylineOrigin] = []

        for (resultIndex, groupResult) in colorGroupResults.enumerated() {
            for (branchIndex, coords) in groupResult.polylines.enumerated() {
                guard coords.count >= 2 else { continue }
                grouped.append((groupIndex: groupResult.groupIndex, coordinates: coords))
                mapping.append(PolylineOrigin(resultIndex: resultIndex, branchIndex: branchIndex))
            }
        }

        // Server polylines pass through station coordinates.
        // After simplification, high-density arc fillets smooth all bends.
        /// Returns the lane offset for a specific branch within a trunk group.
        ///
        /// **Always returns the trunk-level global offset** so every segment
        /// of the same colour trunk renders at one consistent pixel position.
        /// Per-segment offsets (`polylineLaneOffsets`) cause MapLibre's
        /// `lineOffset` to shift segments differently, creating visible
        /// "branching" artefacts at corridor transitions — e.g. a yellow
        /// trunk appearing as two parallel lines, or a red trunk showing
        /// two segments connecting at an unnatural junction.  Using the
        /// trunk average eliminates these artefacts while still keeping
        /// different-colour trunks properly separated in shared corridors.
        func localLaneOffset(
            for groupResult: ColorGroupResult,
            branchIndex: Int
        ) -> CGFloat {
            return groupResult.laneOffset
        }

        func isTransitionRampOffset(_ value: CGFloat) -> Bool {
            let magnitude = Double(abs(value))
            guard magnitude > 0.01 else { return false }
            let quadrupled = magnitude * 4.0
            let isQuarterMultiple = abs(quadrupled.rounded() - quadrupled) < 0.01
            let isWholeLaneMultiple = abs(magnitude.rounded() - magnitude) < 0.01
            return isQuarterMultiple && !isWholeLaneMultiple
        }

        struct PreparedPolyline {
            let origin: PolylineOrigin
            let groupIndex: Int
            let coordinates: [CLLocationCoordinate2D]
            let localLaneOffset: CGFloat
        }

        var finalOffsetPolylines: [PreparedPolyline] = []
        for index in grouped.indices {
            let item = grouped[index]
            let origin = mapping[index]
            let groupResult = colorGroupResults[origin.resultIndex]
            let localLaneOffset = localLaneOffset(
                for: groupResult,
                branchIndex: origin.branchIndex
            )

            // ── v10: Server trunk polylines are pre-processed ──
            //
            // When using server trunks, the backend already ran the full
            // geometry pipeline: merge → station snap → dedup → fillet.
            // Applying client-side RDP/backtrack/spike would DEGRADE the
            // server's precision-6 output (client RDP tolerance is 4.4m
            // vs server's 1.5m).  Just pass coordinates through directly.
            //
            // The legacy client fallback (when server trunks are unavailable)
            // still runs the full processing chain.
            let finalCoordinates: [CLLocationCoordinate2D]

            if useTrunkPolylines {
                // Server trunk path: zero processing — decode → render
                guard item.coordinates.count >= 2 else {
                    AppLogger.shared.log(
                        "POLYLINE_DROP",
                        message: "Dropped branch"
                            + " \(origin.branchIndex)"
                            + " of group \(item.groupIndex)"
                            + " — too few points"
                            + " (\(item.coordinates.count))")
                    continue
                }
                finalCoordinates = item.coordinates
            } else {
                // Legacy client fallback: full processing chain
                let simplified: [CLLocationCoordinate2D]
                if abs(localLaneOffset) > 0.01 {
                    let preserveFanOutShape = isTransitionRampOffset(localLaneOffset)
                    if preserveFanOutShape && item.coordinates.count <= 96 {
                        simplified = item.coordinates
                    } else if item.coordinates.count <= 24 {
                        simplified = item.coordinates
                    } else {
                        simplified = simplifyPolyline(
                            item.coordinates,
                            tolerance: preserveFanOutShape ? 0.00001 : 0.000015
                        )
                    }
                } else {
                    simplified = simplifyPolyline(item.coordinates, tolerance: 0.00004)
                }

                guard simplified.count >= 2 else {
                    AppLogger.shared.log(
                        "POLYLINE_DROP",
                        message: "Dropped branch"
                            + " \(origin.branchIndex)"
                            + " of group \(item.groupIndex)"
                            + " after simplification"
                            + " (\(item.coordinates.count)"
                            + " → \(simplified.count) points)")
                    continue
                }

                let cleaned = removeSpikes(removePolylineBacktracks(simplified))
                guard cleaned.count >= 2 else {
                    AppLogger.shared.log(
                        "POLYLINE_DROP",
                        message: "Dropped branch"
                            + " \(origin.branchIndex)"
                            + " of group \(item.groupIndex)"
                            + " after backtrack/spike removal"
                            + " (\(simplified.count)"
                            + " → \(cleaned.count) points)")
                    continue
                }

                let deduplicated = removeNearDuplicates(cleaned, minSpacing: 0.00004)
                guard deduplicated.count >= 2 else {
                    AppLogger.shared.log(
                        "POLYLINE_DROP",
                        message: "Dropped branch"
                            + " \(origin.branchIndex)"
                            + " of group \(item.groupIndex)"
                            + " after dedup"
                            + " (\(cleaned.count)"
                            + " → \(deduplicated.count) points)")
                    continue
                }

                finalCoordinates = junctionAwareFillet(
                    deduplicated,
                    laneOffset: Double(localLaneOffset),
                    angleThreshold: 10.0,
                    baseRadiusDeg: 0.00045,
                    scaleFactor: 0.00030,
                    arcPoints: 16
                )
            }

            finalOffsetPolylines.append(PreparedPolyline(
                origin: origin,
                groupIndex: item.groupIndex,
                coordinates: finalCoordinates,
                localLaneOffset: localLaneOffset
            ))
        }

        var flat: [FlattenedMapPolyline] = []
        for prepared in finalOffsetPolylines {
            let origin = prepared.origin
            let groupResult = colorGroupResults[origin.resultIndex]
            let groupKey: String = groupResult.routeIds.joined(separator: "-")
            guard prepared.coordinates.count >= 2 else {
                AppLogger.shared.log(
                    "POLYLINE_DROP",
                    message: "Dropped polyline"
                        + " trunk_\(groupKey)_\(origin.branchIndex)"
                        + " after fillet"
                        + " (\(prepared.coordinates.count) points)")
                continue
            }
            let localLaneOffset = prepared.localLaneOffset

            // Determine z-level: use the geographic midpoint of this
            // specific branch + its route IDs to infer whether this
            // segment runs on elevated infrastructure.
            let midIdx: Int = prepared.coordinates.count / 2
            let midCoord: CLLocationCoordinate2D = prepared.coordinates[midIdx]
            let branchStructure: StationStructure = StationComplexLookup.inferStructure(
                routes: groupResult.routeIds,
                lat: midCoord.latitude,
                lon: midCoord.longitude
            )
            let isElevated: Bool = branchStructure == .elevated || branchStructure == .viaduct
            let polylineId: String = "trunk_\(groupKey)_\(origin.branchIndex)"

            flat.append(FlattenedMapPolyline(
                id: polylineId,
                coordinates: prepared.coordinates,
                color: groupResult.color,
                lineWidth: 3,
                routeIds: groupResult.routeIds,
                isElevated: isElevated,
                trunkIndex: prepared.groupIndex,
                laneOffset: localLaneOffset
            ))
        }

        flattenedSubwayPolylines = flat

        #if DEBUG
        // ── Diagnostic: summarize non-zero lane offsets across final polylines ──
        var offsetsByTrunk: [String: Set<String>] = [:]
        for poly in flat where abs(poly.laneOffset) > 0.01 {
            let key = poly.routeIds.joined(separator: "/")
            offsetsByTrunk[key, default: []].insert(String(format: "%.2f", Double(poly.laneOffset)))
        }
        if !offsetsByTrunk.isEmpty {
            let summary = offsetsByTrunk
                .sorted { $0.key < $1.key }
                .map { "\($0.key): [\($0.value.sorted().joined(separator: ", "))]" }
                .joined(separator: " | ")
            AppLogger.shared.log(
                "LANE_OFFSET",
                message: "Flattened polylines with non-zero offsets: \(summary)")
        } else {
            AppLogger.shared.log(
                "LANE_OFFSET",
                message: "⚠️ NO polylines have"
                    + " non-zero lane offsets"
                    + " — all lines will overlap!")
        }
        #endif

        // Yield after subway polylines are set so the map can start rendering them
        await Task.yield()

        // Route labels — use base (non-offset) coordinates so they sit
        // centered on the actual track regardless of offset tier.
        //
        // Per-label route attribution: instead of stamping the full trunk
        // group (e.g. "A C E") on every label, build a spatial grid per
        // individual route and only include routes whose polylines actually
        // pass near each label coordinate.  This prevents labels like
        // "A C E" appearing on the E-only Jamaica/Archer Av branch.
        //
        // IMPORTANT: The corridor pipeline applies perpendicular offsets up
        // to ~350 m, which can push route polylines into grid cells 2 away
        // from the original track centre.  Use ±2 cell search to compensate.
        let routeGridCell = 0.002  // ~220 m at NYC latitude
        func routeGridKey(lat: Double, lon: Double) -> Int64 {
            let latCell = Int64(floor(lat / routeGridCell))
            let lonCell = Int64(floor(lon / routeGridCell))
            return latCell &* 10_000_000 &+ lonCell
        }

        var routeLabels: [TrunkRouteLabel] = []
        for groupResult in colorGroupResults {
            let groupKey = groupResult.routeIds.joined(separator: "-")

            // Build per-route spatial grid for this color group
            var perRouteGrid: [String: Set<Int64>] = [:]
            for routeId in groupResult.routeIds {
                let key = routeId.uppercased()
                guard let line = linesByRouteId[key]
                    ?? linesByRouteId[routeId]
                else { continue }
                var grid = Set<Int64>()
                for branch in line.coordinates {
                    for pt in branch {
                        grid.insert(routeGridKey(lat: pt.latitude, lon: pt.longitude))
                    }
                }
                perRouteGrid[routeId] = grid
            }

            /// Returns the subset of `groupResult.routeIds` whose offset
            /// polylines pass within ±2 grid cells (~440 m) of `coord`.
            /// The wider radius accounts for corridor pipeline perpendicular
            /// offsets (up to ~350 m at dense trunk corridors).
            /// Returns `nil` when NO route can be attributed — caller skips
            /// the label entirely instead of showing the wrong trunk group.
            func routesNear(_ coord: CLLocationCoordinate2D) -> [String]? {
                let latCell = Int64(floor(coord.latitude / routeGridCell))
                let lonCell = Int64(floor(coord.longitude / routeGridCell))
                let nearby = groupResult.routeIds.filter { routeId in
                    guard let grid = perRouteGrid[routeId] else { return false }
                    // ±2 cells ≈ 440 m — covers corridor offsets up to ~350 m
                    for dl: Int64 in -2...2 {
                        for dn: Int64 in -2...2 {
                            if grid.contains((latCell + dl) &* 10_000_000 &+ (lonCell + dn)) {
                                return true
                            }
                        }
                    }
                    return false
                }
                // No fallback — if attribution finds nothing, skip the label.
                // The old fallback (`nearby.isEmpty ? groupResult.routeIds : nearby`)
                // caused "A C E" labels on E-only branches when the corridor
                // pipeline offset pushed E's polyline outside the ±1 grid range.
                return nearby.isEmpty ? nil : nearby
            }

            for (branchIdx, coords) in groupResult.polylines.enumerated() {
                guard coords.count >= 2 else { continue }
                let labelInterval = 60
                var labelIdx = 0
                var ptIdx = labelInterval / 2
                while ptIdx < coords.count {
                    let labelCoord = coords[ptIdx]
                    if let labelRoutes = routesNear(labelCoord) {
                        routeLabels.append(TrunkRouteLabel(
                            id: "label_\(groupKey)_\(branchIdx)_\(labelIdx)",
                            coordinate: labelCoord,
                            routeIds: labelRoutes,
                            color: groupResult.color
                        ))
                    }
                    labelIdx += 1
                    ptIdx += labelInterval
                }
                if let lastCoord = coords.last,
                   let endRoutes = routesNear(lastCoord) {
                    routeLabels.append(TrunkRouteLabel(
                        id: "label_\(groupKey)_\(branchIdx)_end",
                        coordinate: lastCoord,
                        routeIds: endRoutes,
                        color: groupResult.color
                    ))
                }
            }
        }
        trunkRouteLabels = routeLabels

        // ---- Commuter rail (LIRR / MNR) ----
        // Delegate to the dedicated method which is also called directly
        // by fetchAndRenderFromNetwork() after LIRR/MNR data arrives.
        // This ensures commuter rail is flattened here for the disk-cache
        // path (where cachedSystemMap already contains LIRR/MNR).
        flattenCommuterRailPolylines()

        let subwayNearCount = flattenedSubwayPolylines.count
        let commuterCount = flattenedCommuterRailPolylines.count
        let totalPolylines = subwayNearCount + commuterCount
        let simplifiedPoints =
            flattenedSubwayPolylines.reduce(0) { $0 + $1.coordinates.count }
            + flattenedCommuterRailPolylines.reduce(0) { $0 + $1.coordinates.count }
        let reductionPercent = originalSubwayPoints > 0
            ? Int(
                Double(originalSubwayPoints - simplifiedPoints)
                / Double(originalSubwayPoints) * 100
            )
            : 0
        AppLogger.shared.log(
            "SYSTEM_MAP",
            message:
                "Flattened \(totalPolylines) polylines"
                + " (\(subwayNearCount) subway,"
                + " \(commuterCount) commuter rail)"
                + " — \(simplifiedPoints) points"
                + " (simplified \(reductionPercent)%)"
        )

        // Persist pre-computed flattened polylines to disk so the next
        // cold start can skip the entire decode → unify → simplify pipeline.
        // Skip persistence if this task was cancelled (a newer flatten is
        // running with fresher data — don't overwrite with stale results).
        guard !Task.isCancelled else {
            AppLogger.shared.log(
                "SYSTEM_MAP",
                message: "Flatten task cancelled"
                    + " — skipping disk persist")
            return
        }
        persistFlattenedToDisk()
    }

    // MARK: - Client-Side Corridor Detection (Offline Fallback)

    /// Detects trunk groups that share geographic corridors using a spatial
    /// hash grid, then assigns lane offsets so parallel lines render
    /// side-by-side instead of stacking on top of each other.
    ///
    /// This is a lightweight client-side fallback for when the server's
    /// corridor pipeline data isn't available (offline mode or server error).
    ///
    /// Algorithm:
    /// 1. Build a grid-cell occupancy set per trunk group (~220 m cells)
    /// 2. Two trunk groups are "corridor neighbors" if they share ≥ 3 cells
    /// 3. Greedy offset assignment: each trunk gets an offset ≥ 1.0 apart
    ///    from its corridor neighbors
    /// 4. Re-centre around 0 and clamp to ±2.5
    /// Assigns client-computed corridor offsets to `ColorGroupResult` values
    /// so that trunk groups sharing geographic corridors render as parallel
    /// lines instead of overlapping.
    ///
    /// This method mutates `laneOffset` on each element of `groups`.
    private static func _assignClientCorridorOffsets(
        groupCount: Int,
        groupIndices: [Int],
        polylinesByGroup: [Int: [[CLLocationCoordinate2D]]]
    ) -> [Int: CGFloat] {
        guard groupCount >= 2 else { return [:] }

        // ── Step 1: Spatial hash — build grid-cell occupancy per trunk ──
        // ~110 m cells at NYC latitude — fine enough to detect shared
        // corridors but coarse enough to tolerate minor alignment
        // differences between GTFS shape variants.
        let cellSize: Double = 0.001
        func cellKey(_ lat: Double, _ lon: Double) -> Int64 {
            let gx = Int64(floor(lat / cellSize))
            let gy = Int64(floor(lon / cellSize))
            return gx &* 100_000_000 &+ gy
        }

        var cellsByTrunk: [Int: Set<Int64>] = [:]
        for (trunkIdx, polylines) in polylinesByGroup {
            var cells = Set<Int64>()
            for polyline in polylines {
                // Sample every vertex AND intermediate points along long segments
                // so sparse polylines still register in shared corridor cells.
                for i in 0..<polyline.count {
                    let c = polyline[i]
                    cells.insert(cellKey(c.latitude, c.longitude))

                    // Interpolate along segment if gap > cellSize
                    if i + 1 < polyline.count {
                        let next = polyline[i + 1]
                        let dLat = next.latitude - c.latitude
                        let dLon = next.longitude - c.longitude
                        let dist = max(abs(dLat), abs(dLon))
                        let steps = Int(dist / cellSize)
                        if steps > 1 {
                            for s in 1..<steps {
                                let frac = Double(s) / Double(steps)
                                cells.insert(cellKey(
                                    c.latitude + dLat * frac,
                                    c.longitude + dLon * frac
                                ))
                            }
                        }
                    }
                }
            }
            cellsByTrunk[trunkIdx] = cells
        }

        // ── Step 2: Detect corridor neighbors (≥ 5 shared cells) ──
        //
        // Two trunk groups sharing ≥ 5 grid cells (~550 m of overlapping
        // track) are considered corridor neighbors and need distinct offsets.
        var neighbors: [Int: Set<Int>] = [:]
        let sorted = groupIndices.sorted()
        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let ti = sorted[i], tj = sorted[j]
                guard let ci = cellsByTrunk[ti], let cj = cellsByTrunk[tj] else { continue }
                let shared = ci.intersection(cj).count
                if shared >= 5 {
                    neighbors[ti, default: []].insert(tj)
                    neighbors[tj, default: []].insert(ti)
                }
            }
        }

        // If no corridors detected, all offsets stay at 0
        guard !neighbors.isEmpty else { return [:] }

        // ── Step 3: Greedy offset assignment with min separation ──
        // Only corridor members get offsets; isolated groups stay at 0.
        let minDelta: CGFloat = 1.0
        var placed: [Int: CGFloat] = [:]

        for ti in sorted {
            let tiNeighbors = neighbors[ti] ?? []
            guard !tiNeighbors.isEmpty else { continue }  // Skip non-corridor groups

            var offset: CGFloat = 0

            // Find the highest placed offset among corridor neighbors
            var maxNeighborOffset: CGFloat?
            for (prevT, prevVal) in placed {
                if tiNeighbors.contains(prevT) {
                    if maxNeighborOffset == nil || prevVal > maxNeighborOffset! {
                        maxNeighborOffset = prevVal
                    }
                }
            }

            if let maxNbr = maxNeighborOffset {
                let minRequired = maxNbr + minDelta
                if offset < minRequired {
                    offset = minRequired
                }
            }

            placed[ti] = offset
        }

        // ── Step 4: Re-centre around 0 ──
        if !placed.isEmpty {
            let vals = Array(placed.values)
            let centre = ((vals.min() ?? 0) + (vals.max() ?? 0)) / 2.0
            for key in placed.keys {
                placed[key]! -= centre
            }
        }

        // ── Step 5: Clamp to ±2.5 ──
        if let maxAbs = placed.values.map({ abs($0) }).max(), maxAbs > 2.5 {
            let scale: CGFloat = 2.5 / maxAbs
            for key in placed.keys {
                placed[key]! *= scale
            }
        }

        // Log the detected corridors
        let corridorSummary = neighbors.keys.sorted().map { ti -> String in
            let nbrs = neighbors[ti, default: []].sorted().map { ni -> String in
                let label = polylinesByGroup[ni] != nil ? "\(ni)" : "?"
                return label
            }
            return "\(ti)↔{\(nbrs.joined(separator: ","))}"
        }.joined(separator: ", ")
        let offsetSummary = placed.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(String(format: "%+.2f", Double($0.value)))" }
            .joined(separator: ", ")
        AppLogger.shared.log(
            "CORRIDOR_FALLBACK",
            message: "Client corridors: [\(corridorSummary)] → offsets: [\(offsetSummary)]")

        return placed
    }

    // MARK: - Flattened Polyline Disk Cache

    /// Restores pre-computed flattened polylines from disk, providing an
    /// instant cold-start render (< 50 ms) by skipping the entire
    /// decode → unify → simplify → refine pipeline.
    ///
    /// Returns `true` if the cache was valid and polylines were restored.
    private func loadFlattenedFromDiskCache() -> Bool {
        let cache = OfflineCacheManager.shared
        // No TTL check — polylines are physical track geometry that
        // changes maybe 1-2× per year.  Always show whatever we have
        // cached; the background network refresh keeps it current.
        guard let bundle = cache.getCachedFlattenedPolylines()
        else { return false }

        let subway = bundle.subway.compactMap { cached -> FlattenedMapPolyline? in
            let coords = cached.coordinates.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count == 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            }
            guard coords.count >= 2 else { return nil }
            return FlattenedMapPolyline(
                id: cached.id,
                coordinates: coords,
                color: Color(hex: cached.colorHex),
                lineWidth: CGFloat(cached.lineWidth),
                routeIds: cached.routeIds,
                isElevated: cached.isElevated,
                trunkIndex: cached.trunkIndex,
                laneOffset: CGFloat(cached.laneOffset)
            )
        }

        let commuter = bundle.commuter.compactMap { cached -> FlattenedMapPolyline? in
            let coords = cached.coordinates.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count == 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            }
            guard coords.count >= 2 else { return nil }
            return FlattenedMapPolyline(
                id: cached.id,
                coordinates: coords,
                color: Color(hex: cached.colorHex),
                lineWidth: CGFloat(cached.lineWidth),
                routeIds: cached.routeIds,
                isElevated: cached.isElevated,
                trunkIndex: cached.trunkIndex,
                laneOffset: CGFloat(cached.laneOffset)
            )
        }

        guard !subway.isEmpty else { return false }

        flattenedSubwayPolylines = subway
        flattenedCommuterRailPolylines = commuter

        // Try to load baked GeoJSON tiles from disk (even faster path —
        // MapLibre loads the file directly via C++ parser, zero Swift
        // feature-building overhead).
        bakedTileSet = OfflineCacheManager.shared.getCachedBakedTiles()
        if bakedTileSet != nil {
            AppLogger.shared.log(
                "BAKE",
                message: "Loaded baked GeoJSON tiles from disk")
        }

        let totalPoints = subway.reduce(0) { $0 + $1.coordinates.count }
            + commuter.reduce(0) { $0 + $1.coordinates.count }
        AppLogger.shared.log(
            "SYSTEM_MAP",
            message: "Restored"
                + " \(subway.count + commuter.count)"
                + " flattened polylines from disk"
                + " cache (\(totalPoints) points)")
        return true
    }

    /// Persists the current flattened polylines to disk so subsequent
    /// cold starts render instantly without re-running the pipeline.
    private func persistFlattenedToDisk() {
        let subway = flattenedSubwayPolylines.map { poly in
            OfflineCacheManager.CachedFlattenedPolyline(
                id: poly.id,
                coordinates: poly.coordinates.map { [$0.latitude, $0.longitude] },
                colorHex: poly.color.toHex(),
                lineWidth: Double(poly.lineWidth),
                routeIds: poly.routeIds,
                isElevated: poly.isElevated,
                trunkIndex: poly.trunkIndex,
                laneOffset: Double(poly.laneOffset)
            )
        }
        let commuter = flattenedCommuterRailPolylines.map { poly in
            OfflineCacheManager.CachedFlattenedPolyline(
                id: poly.id,
                coordinates: poly.coordinates.map { [$0.latitude, $0.longitude] },
                colorHex: poly.color.toHex(),
                lineWidth: Double(poly.lineWidth),
                routeIds: poly.routeIds,
                isElevated: poly.isElevated,
                trunkIndex: poly.trunkIndex,
                laneOffset: Double(poly.laneOffset)
            )
        }
        let bundle = OfflineCacheManager.CachedFlattenedBundle(subway: subway, commuter: commuter)

        // ── Prepare bake input on @MainActor ──
        // Color.toHex() touches UIColor which is @MainActor-isolated,
        // so we do all the conversion here before handing off to a
        // detached task.  Everything below is pure Sendable value types.
        let nonElevated = flattenedSubwayPolylines.filter { !$0.isElevated }
        let elevated = flattenedSubwayPolylines.filter { $0.isElevated }

        func toPolylineData(
            _ polys: [FlattenedMapPolyline]
        ) -> [TransitTileBaker.PolylineData] {
            polys.map {
                TransitTileBaker.PolylineData(
                    coordinates: $0.coordinates,
                    colorHex: $0.color.toHex(),
                    trunkIndex: $0.trunkIndex,
                    laneOffset: Double($0.laneOffset),
                    routeIds: $0.routeIds,
                    isElevated: $0.isElevated
                )
            }
        }

        let subwayFillData = toPolylineData(nonElevated)
        let elevatedFillData = toPolylineData(elevated)
        let commuterData = toPolylineData(flattenedCommuterRailPolylines)

        let crossingData = cachedCrossings.map {
            TransitTileBaker.CrossingData(
                lat: $0.lat, lng: $0.lng,
                trunkIndices: $0.trunkIndices
            )
        }

        // Pre-compute crossing gaps for casing layers
        let subwayCasingData = TransitTileBaker.buildCasingPolylines(
            from: subwayFillData, crossings: crossingData
        )
        let elevatedCasingData = TransitTileBaker.buildCasingPolylines(
            from: elevatedFillData, crossings: crossingData
        )

        let bakeInput = TransitTileBaker.BakeInput(
            subwayFill: subwayFillData,
            subwayCasing: subwayCasingData,
            elevatedFill: elevatedFillData,
            elevatedCasing: elevatedCasingData,
            commuter: commuterData
        )

        Task.detached(priority: .utility) { [weak self] in
            await OfflineCacheManager.shared.cacheFlattenedPolylines(bundle)
            await MainActor.run {
                AppLogger.shared.log(
                    "SYSTEM_MAP",
                    message: "Persisted flattened"
                        + " polylines to disk cache")
            }
            // Bake GeoJSON tile files (pure I/O, no @MainActor dependencies)
            let tiles = await Self.bakeGeoJSONTiles(input: bakeInput)
            if let tiles {
                await MainActor.run { [weak self] in
                    self?.bakedTileSet = tiles
                }
            }
        }
    }

    /// Bakes pre-built input into GeoJSON files for MapLibre.
    /// Runs off the main actor — pure CPU + I/O, no UIKit or SwiftUI calls.
    nonisolated private static func bakeGeoJSONTiles(
        input: TransitTileBaker.BakeInput
    ) async -> TransitTileBaker.BakedTileSet? {
        guard let dir = await OfflineCacheManager.shared.bakedTilesDirectory()
        else { return nil }

        let start = CFAbsoluteTimeGetCurrent()
        guard let tileSet = TransitTileBaker.bake(input, to: dir) else {
            await MainActor.run {
                AppLogger.shared.log(
                    "BAKE",
                    message: "Failed to bake GeoJSON tiles")
            }
            return nil
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let totalFeatures = input.subwayFill.count
            + input.subwayCasing.count
            + input.elevatedFill.count
            + input.elevatedCasing.count
            + input.commuter.count
        await MainActor.run {
            AppLogger.shared.log(
                "BAKE",
                message: "Baked \(totalFeatures) features"
                    + " into 5 GeoJSON files"
                    + " in \(String(format: "%.0f", elapsed * 1000))ms")
        }
        return tileSet
    }

    // MARK: - Station Loading

    /// Fetches all subway stations and their served lines.
    ///
    /// Raw MTA stop coordinates are the source of truth. The system-map
    /// polylines move locally in shared corridors; the station coordinates
    /// themselves should stay at the exact spots the MTA published.
    func loadStations() async {
        if Self.hasStartedStationLoad { return }
        Self.hasStartedStationLoad = true

        if let snapshot = Self.sharedSnapshot, !snapshot.stations.isEmpty {
            cachedStations = snapshot.stations
            consolidatedStations = snapshot.consolidatedStations
            AppLogger.shared.log("SYSTEM_MAP", message: "Reused shared station snapshot")
            return
        }

        // ── Fast path: restore from disk cache ──
        // Station positions rarely change (MTA updates a few times per
        // year).  Show cached stations instantly — like Transit app does —
        // and refresh from the network in the background.
        let cachedOnDisk = OfflineCacheManager.shared.getCachedStations()
        if let cachedOnDisk, !cachedOnDisk.isEmpty {
            let restored = cachedOnDisk.map { s in
                CachedSubwayStation(
                    id: s.id,
                    name: s.name,
                    coordinate: CLLocationCoordinate2D(
                        latitude: s.latitude,
                        longitude: s.longitude
                    ),
                    routes: s.routes
                )
            }
            // Merge with any commuter-rail stops already loaded by loadSystemMap()
            let commuterStops = self.cachedStations.filter { s in
                s.routes.contains(where: { $0.hasPrefix("LIRR") || $0.hasPrefix("MNR") })
            }
            self.cachedStations = restored + commuterStops
            self.consolidateStations()
            AppLogger.shared.log(
                "STATIONS",
                message: "Restored \(restored.count)"
                    + " stations from disk cache"
                    + " (instant)")
        }

        // If offline, use bundled static data (only if disk cache was empty)
        if !OfflineCacheManager.shared.isOnline {
            let allCommuter = cachedStations.allSatisfy { station in
                station.routes.contains { route in
                    route.hasPrefix("LIRR")
                    || route.hasPrefix("MNR")
                }
            }
            if cachedStations.isEmpty || allCommuter {
                loadOfflineStations()
            }
            return
        }

        // Network refresh: always fetch fresh station positions when
        // online, but the user already sees disk-cached stations above.
        await loadRawStations()
    }

    /// Fetch raw GTFS station positions (fallback when processed endpoint
    /// is unavailable or returns empty).
    private func loadRawStations() async {
        do {
            let response = try await TrackAPI.fetchAllSubwayStations()
            let stations = response.stations.map { s in
                CachedSubwayStation(
                    id: s.id,
                    name: s.name,
                    coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon),
                    routes: s.routes
                )
            }
            await MainActor.run {
                // Merge subway stations with any commuter-rail stops already
                // loaded by loadSystemMap() — never overwrite the full array.
                let commuterStops = self.cachedStations.filter { s in
                    s.routes.contains(where: { $0.hasPrefix("LIRR") || $0.hasPrefix("MNR") })
                }
                self.cachedStations = stations + commuterStops
                self.consolidateStations()
            }

            // Cache stations for offline use
            let cachedStations = response.stations.map { s in
                CachedStation(
                    id: s.id,
                    name: s.name,
                    latitude: s.lat,
                    longitude: s.lon,
                    routes: s.routes
                )
            }
            OfflineCacheManager.shared.cacheStations(cachedStations)

        } catch {
            AppLogger.shared.logError("loadStations", error: error)
            // Fall back to offline data on error
            loadOfflineStations()
        }
    }

    /// Loads stations from bundled offline data.
    private func loadOfflineStations() {
        let offlineStations = SubwayRoutesData.majorStations.map { station in
            CachedSubwayStation(
                id: station.id,
                name: station.name,
                coordinate: station.coordinate,
                routes: station.routes
            )
        }
        // Keep any commuter-rail stops already added by loadSystemMap()
        let commuterStops = self.cachedStations.filter { s in
            s.routes.contains(where: { $0.hasPrefix("LIRR") || $0.hasPrefix("MNR") })
        }
        self.cachedStations = offlineStations + commuterStops
        self.consolidateStations()
        AppLogger.shared.log("OFFLINE", message: "Loaded \(offlineStations.count) offline stations")
    }

    // MARK: - Station Consolidation

    // ── Transfer stop placement helpers ──────────────────
    //
    // Transfer stations (≥ 2 trunk color groups) are placed at the
    // geometric intersection of serving polylines, rather than at the
    // simple average of GTFS stop coordinates.  This positions the white
    // capsule marker exactly where trunk polylines cross on the map,
    // producing a cleaner visual — especially at major junctions like
    // Times Square, Atlantic Ave, or Fulton St.

    /// Project a point onto a line segment, returning the foot of the
    /// perpendicular and the squared distance in degree-space (lon scaled
    /// by cos(40.7°) for NYC).
    private static func projectOntoSegment(
        lat: Double, lon: Double,
        aLat: Double, aLon: Double,
        bLat: Double, bLon: Double
    ) -> (projLat: Double, projLon: Double, distSq: Double) {
        let cosNYC: Double = 0.76  // cos(40.7°)
        let dx: Double = (bLon - aLon) * cosNYC
        let dy: Double = bLat - aLat
        let px: Double = (lon - aLon) * cosNYC
        let py: Double = lat - aLat
        let lenSq: Double = dx * dx + dy * dy

        if lenSq < 1e-20 {
            return (aLat, aLon, px * px + py * py)
        }

        let t: Double = max(0, min(1, (px * dx + py * dy) / lenSq))
        let projLat: Double = aLat + t * (bLat - aLat)
        let projLon: Double = aLon + t * (bLon - aLon)
        let eLat: Double = lat - projLat
        let eLon: Double = (lon - projLon) * cosNYC
        return (projLat, projLon, eLat * eLat + eLon * eLon)
    }

    /// Find the intersection point of two line segments (if any).
    /// Returns nil if segments don't intersect or are nearly parallel.
    private static func segmentIntersection(
        a1Lat: Double, a1Lon: Double, a2Lat: Double, a2Lon: Double,
        b1Lat: Double, b1Lon: Double, b2Lat: Double, b2Lon: Double
    ) -> (lat: Double, lon: Double)? {
        let d1Lat: Double = a2Lat - a1Lat
        let d1Lon: Double = a2Lon - a1Lon
        let d2Lat: Double = b2Lat - b1Lat
        let d2Lon: Double = b2Lon - b1Lon

        let denom: Double = d1Lon * d2Lat - d1Lat * d2Lon
        if abs(denom) < 1e-15 { return nil }  // parallel / degenerate

        let diffLat: Double = b1Lat - a1Lat
        let diffLon: Double = b1Lon - a1Lon
        let t: Double = (diffLon * d2Lat - diffLat * d2Lon) / denom
        let u: Double = (diffLon * d1Lat - diffLat * d1Lon) / denom

        // Allow slight overshoot (0.05) to catch near-intersections
        guard t >= -0.05 && t <= 1.05 && u >= -0.05 && u <= 1.05 else { return nil }

        return (a1Lat + t * d1Lat, a1Lon + t * d1Lon)
    }

    /// Compute a better placement for a transfer station by finding where
    /// polylines from its serving trunk groups cross or are closest.
    ///
    /// **Strategy:**
    /// 1. Try segment-segment intersection between nearby segments of
    ///    different trunk groups → exact crossing point.
    /// 2. Fallback: project centroid onto nearest segment of each trunk
    ///    group and average the projection points.
    private func transferPolylinePosition(
        centroid: CLLocationCoordinate2D,
        trunkGroups: Set<Int>,
        referencePolylinesByGroup: [Int: [[CLLocationCoordinate2D]]]
    ) -> CLLocationCoordinate2D? {
        guard trunkGroups.count >= 2, !referencePolylinesByGroup.isEmpty else { return nil }

        // Degree-space search radius (~500 m)
        let searchRadius: Double = 0.005

        // ── Collect nearby segments per trunk group ──
        struct Seg {
            let aLat: Double; let aLon: Double
            let bLat: Double; let bLon: Double
        }
        var trunkSegs: [Int: [Seg]] = [:]

        for (tidx, branches) in referencePolylinesByGroup {
            guard trunkGroups.contains(tidx) else { continue }

            for branch in branches {
                for i in 0..<(branch.count - 1) {
                    let a = branch[i], b = branch[i + 1]
                    // Bounding box filter
                    let minLat: Double = min(a.latitude, b.latitude) - searchRadius
                    let maxLat: Double = max(a.latitude, b.latitude) + searchRadius
                    let minLon: Double = min(a.longitude, b.longitude) - searchRadius
                    let maxLon: Double = max(a.longitude, b.longitude) + searchRadius
                    guard centroid.latitude >= minLat && centroid.latitude <= maxLat &&
                          centroid.longitude >= minLon,
                          centroid.longitude <= maxLon
                    else { continue }

                    trunkSegs[tidx, default: []].append(
                        Seg(aLat: a.latitude, aLon: a.longitude,
                            bLat: b.latitude, bLon: b.longitude))
                }
            }
        }

        let servingTrunks: [Int] = Array(trunkSegs.keys)
        guard servingTrunks.count >= 2 else { return nil }

        // ── Strategy 1: Find segment-segment intersection ──
        var bestIntersection: (lat: Double, lon: Double)? = nil
        var bestIntDist: Double = .infinity

        for i in 0..<servingTrunks.count {
            for j in (i + 1)..<servingTrunks.count {
                let segsA: [Seg] = trunkSegs[servingTrunks[i]] ?? []
                let segsB: [Seg] = trunkSegs[servingTrunks[j]] ?? []
                for sa in segsA {
                    for sb in segsB {
                        if let inter = Self.segmentIntersection(
                            a1Lat: sa.aLat, a1Lon: sa.aLon,
                            a2Lat: sa.bLat, a2Lon: sa.bLon,
                            b1Lat: sb.aLat, b1Lon: sb.aLon,
                            b2Lat: sb.bLat, b2Lon: sb.bLon
                        ) {
                            let cosNYC: Double = 0.76
                            let dLat: Double = inter.lat - centroid.latitude
                            let dLon: Double = (inter.lon - centroid.longitude) * cosNYC
                            let d: Double = dLat * dLat + dLon * dLon
                            if d < bestIntDist {
                                bestIntDist = d
                                bestIntersection = inter
                            }
                        }
                    }
                }
            }
        }

        // Use intersection if within ~300m of centroid.
        // The 0.003° threshold in degree-space ≈ 300m at NYC latitude.
        // Beyond that, the intersection is likely from a distant crossing
        // of the same trunk groups (e.g. two lines that cross in both
        // midtown and downtown — we only want the nearest crossing).
        if let inter = bestIntersection, bestIntDist < 0.003 * 0.003 {
            return CLLocationCoordinate2D(latitude: inter.lat, longitude: inter.lon)
        }

        // ── Strategy 2: Average nearest projections per trunk group ──
        // Only include projections that are within ~300m of the centroid.
        // If a trunk group has no nearby polyline segments (e.g. the branch
        // was pruned or the polyline doesn't reach this area), skip it
        // rather than projecting onto a distant path in a different area.
        let maxProjDistSq: Double = 0.003 * 0.003  // ~300m in degree-space
        var projLats: [Double] = []
        var projLons: [Double] = []

        for tidx in servingTrunks {
            var bestDistSq: Double = .infinity
            var bestLat: Double = centroid.latitude
            var bestLon: Double = centroid.longitude

            for seg in (trunkSegs[tidx] ?? []) {
                let (pLat, pLon, dSq) = Self.projectOntoSegment(
                    lat: centroid.latitude, lon: centroid.longitude,
                    aLat: seg.aLat, aLon: seg.aLon,
                    bLat: seg.bLat, bLon: seg.bLon)
                if dSq < bestDistSq {
                    bestDistSq = dSq
                    bestLat = pLat
                    bestLon = pLon
                }
            }

            // Only include this trunk's projection if it's close enough.
            // A distant projection means the polyline doesn't serve this
            // area — using it would pull the marker off-station.
            if bestDistSq < maxProjDistSq {
                projLats.append(bestLat)
                projLons.append(bestLon)
            }
        }

        // Need at least 2 valid projections to improve on the centroid.
        // With only 1 projection, the centroid is a better default since
        // it already incorporates all member stations' coordinates.
        guard projLats.count >= 2 else { return nil }

        let avgLat2: Double = projLats.reduce(0, +) / Double(projLats.count)
        let avgLon2: Double = projLons.reduce(0, +) / Double(projLons.count)

        // Final sanity check: the averaged projection should be closer to
        // the centroid than ~500m.  If it's farther, something went wrong
        // (e.g., projections landed on the wrong side of an intersection).
        let finalDLat: Double = avgLat2 - centroid.latitude
        let finalDLon: Double = (avgLon2 - centroid.longitude) * 0.76
        let finalDistSq: Double = finalDLat * finalDLat + finalDLon * finalDLon
        guard finalDistSq < 0.005 * 0.005 else { return nil }  // ~500m

        return CLLocationCoordinate2D(latitude: avgLat2, longitude: avgLon2)
    }

    /// Returns the rendered trunk geometry keyed by trunk group index.
    ///
    /// When server-provided trunk polylines are available, these are the
    /// exact branches MapLibre draws. Otherwise, we fall back to the
    /// per-route offset lines grouped by trunk colour.
    private func stationReferencePolylinesByGroup() -> [Int: [[CLLocationCoordinate2D]]] {
        if let trunkPolylines = cachedTrunkPolylines, !trunkPolylines.isEmpty {
            var result: [Int: [[CLLocationCoordinate2D]]] = [:]
            for trunk in trunkPolylines {
                let decoded = trunk.decodedPolylines.filter { $0.count >= 2 }
                guard !decoded.isEmpty else { continue }
                result[trunk.trunkIndex, default: []].append(contentsOf: decoded)
            }
            if !result.isEmpty {
                return result
            }
        }

        var result: [Int: [[CLLocationCoordinate2D]]] = [:]
        for line in cachedOffsetSubwayLines {
            let trunkIndex = Self.trunkGroupIndex(for: line.id)
            let valid = line.coordinates.filter { $0.count >= 2 }
            guard !valid.isEmpty else { continue }
            result[trunkIndex, default: []].append(contentsOf: valid)
        }
        return result
    }

    /// Returns low-zoom corridor lane offsets keyed by trunk group index.
    private func stationReferenceLaneOffsetsByGroup() -> [Int: CGFloat] {
        guard let trunkPolylines = cachedTrunkPolylines, !trunkPolylines.isEmpty else {
            return [:]
        }

        var result: [Int: CGFloat] = [:]
        for trunk in trunkPolylines {
            result[trunk.trunkIndex] = trunk.laneOffset
        }
        return result
    }

    /// Finds the direction-preserving heading of the nearest segment in the
    /// rendered trunk geometry. The heading preserves the encoded segment
    /// direction, which is important because positive/negative `lineOffset`
    /// values are applied relative to that direction.
    private static func nearestSegmentHeading(
        near coordinate: CLLocationCoordinate2D,
        branches: [[CLLocationCoordinate2D]]
    ) -> Double? {
        var bestHeading: Double?
        var bestDistSq: Double = .infinity

        for branch in branches {
            guard branch.count >= 2 else { continue }
            for i in 0..<(branch.count - 1) {
                let a = branch[i]
                let b = branch[i + 1]
                let (_, _, distSq) = projectOntoSegment(
                    lat: coordinate.latitude,
                    lon: coordinate.longitude,
                    aLat: a.latitude,
                    aLon: a.longitude,
                    bLat: b.latitude,
                    bLon: b.longitude
                )
                guard distSq < bestDistSq else { continue }

                let cosNYC: Double = 0.76
                let dx: Double = (b.longitude - a.longitude) * cosNYC
                let dy: Double = b.latitude - a.latitude
                guard dx * dx + dy * dy > 1e-12 else { continue }

                var heading: Double = atan2(dx, dy) * 180.0 / .pi
                if heading < 0 { heading += 360.0 }
                bestDistSq = distSq
                bestHeading = heading
            }
        }

        return bestHeading
    }

    /// Maps a route ID to its MTA trunk-color group index.
    private static func trunkGroupIndex(for routeId: String) -> Int {
        let r = routeId.uppercased()
        switch r {
        case "1", "2", "3":                return 0
        case "4", "5", "6", "6X":          return 1
        case "7", "7X":                    return 2
        case "A", "C", "E":               return 3
        case "B", "D", "F", "FX", "M":    return 4
        case "G":                          return 5
        case "J", "Z":                    return 6
        case "L":                          return 7
        case "N", "Q", "R", "W":          return 8
        case "S":                          return 9
        case "SI":                         return 10
        default:
            // Commuter rail: each agency gets its own group so that
            // commuter-rail stations never merge with subway stations.
            if r.hasPrefix("LIRR") { return 11 }
            if r.hasPrefix("MNR")  { return 12 }
            return 99
        }
    }

    /// Groups stations by **complex ID + structure type** (hierarchical
    /// clustering), then falls back to proximity-based merge (20 m) for
    /// stations not in the lookup table.
    ///
    /// This produces separate capsule annotations for platforms on different
    /// physical levels (e.g., elevated 7 vs underground E/F/M/R at 74 St),
    /// while still merging co-located same-level stops into single capsules.
    ///
    /// Stations that share a `complexID` but have different `structure`
    /// values produce linked markers — the renderer can draw a transfer
    /// indicator between them.
    private func consolidateStations() {
        let stations = cachedStations
        guard !stations.isEmpty else { return }
        let referencePolylinesByGroup = stationReferencePolylinesByGroup()
        let referenceLaneOffsetsByGroup = stationReferenceLaneOffsetsByGroup()

        // ── Phase 1: Assign each station a (complexID, structure) key ──
        //
        // Stations in StationComplexLookup get their curated complex/structure.
        // Others get a hash-derived unique complex ID + default .subway.
        struct GroupKey: Hashable {
            let complexID: Int
            let structure: StationStructure
        }

        var keyForStation: [GroupKey] = []
        for station in stations {
            let entry = StationComplexLookup.entry(
                for: station.id,
                routes: station.routes,
                lat: station.coordinate.latitude,
                lon: station.coordinate.longitude
            )
            keyForStation.append(GroupKey(complexID: entry.complexID, structure: entry.structure))
        }

        // ── Phase 2: Proximity merge within same-structure stations ──
        //
        // For stations NOT in the curated lookup (hash-derived complex IDs),
        // merge co-located same-structure stops within 20 m — same as before.
        // This catches duplicate stops from the API that aren't in the table.
        let mergeRadiusDeg: Double = 0.00024  // ~20 m at NYC longitude
        let mergeRadiusSq: Double = mergeRadiusDeg * mergeRadiusDeg

        var parent = Array(0..<stations.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // Merge stations that either:
        //   (a) share a curated complexID + structure AND are within 500 m, OR
        //   (b) are within 20 m AND have the same structure type
        //
        // The 500 m cap on (a) is a safety net: if two distant stations
        // ever share a complex ID due to hash collision or JSON error,
        // we refuse to merge them rather than averaging their coordinates
        // into the East River.  No real NYC complex spans more than ~350 m.
        let complexMergeRadiusDeg: Double = 0.006   // ~500 m at NYC latitude
        let complexMergeRadiusSq: Double = complexMergeRadiusDeg * complexMergeRadiusDeg

        for i in 0..<stations.count {
            for j in (i + 1)..<stations.count {
                let ki = keyForStation[i], kj = keyForStation[j]

                // Same complex + same structure → merge only if close enough
                if ki.complexID == kj.complexID && ki.structure == kj.structure {
                    let dx: Double =
                        stations[i].coordinate.longitude
                        - stations[j].coordinate.longitude
                    let dy: Double =
                        stations[i].coordinate.latitude
                        - stations[j].coordinate.latitude
                    if dx * dx + dy * dy <= complexMergeRadiusSq {
                        union(i, j)
                    }
                    continue
                }

                // Only proximity-merge if same structure type
                guard ki.structure == kj.structure else { continue }

                let dx: Double = stations[i].coordinate.longitude - stations[j].coordinate.longitude
                let dy: Double = stations[i].coordinate.latitude - stations[j].coordinate.latitude
                if dx * dx + dy * dy <= mergeRadiusSq {
                    union(i, j)
                }
            }
        }

        // Collect groups
        var groups: [Int: [Int]] = [:]
        for i in 0..<stations.count {
            groups[find(i), default: []].append(i)
        }

        // ── Phase 3: Build spatial index of polyline tangents for bearing ──
        let cellSize: Double = 0.001
        var cellTangents: [Int64: [(Double, Double)]] = [:]

        func tangentCellKey(_ lat: Double, _ lon: Double) -> Int64 {
            let gx: Int32 = Int32(lat / cellSize)
            let gy: Int32 = Int32(lon / cellSize)
            let hi: Int64 = Int64(gx) << 32
            let lo: Int64 = Int64(gy & 0x7FFF_FFFF)
            return hi | lo
        }

        for branches in referencePolylinesByGroup.values {
            for branch in branches {
                for i in 0..<(branch.count - 1) {
                    let a = branch[i], b = branch[i + 1]
                    let dx: Double = b.longitude - a.longitude
                    let dy: Double = b.latitude - a.latitude
                    let len: Double = sqrt(dx * dx + dy * dy)
                    guard len > 1e-10 else { continue }
                    let ux: Double = dx / len
                    let uy: Double = dy / len
                    let keyA: Int64 = tangentCellKey(a.latitude, a.longitude)
                    let keyB: Int64 = tangentCellKey(b.latitude, b.longitude)
                    cellTangents[keyA, default: []].append((ux, uy))
                    if keyB != keyA {
                        cellTangents[keyB, default: []].append((ux, uy))
                    }
                }
            }
        }

        // ── Phase 4: Build consolidated stations ──
        var result: [ConsolidatedStation] = []

        for (_, memberIndices) in groups {
            var latSum: Double = 0.0
            var lonSum: Double = 0.0
            var allRoutes: Set<String> = []
            var primaryName: String = ""
            var maxRouteCount: Int = 0

            for idx in memberIndices {
                let s = stations[idx]
                latSum += s.coordinate.latitude
                lonSum += s.coordinate.longitude
                for r in s.routes { allRoutes.insert(r) }
                if s.routes.count > maxRouteCount {
                    maxRouteCount = s.routes.count
                    primaryName = s.name
                }
            }

            var avgLat: Double = latSum / Double(memberIndices.count)
            var avgLon: Double = lonSum / Double(memberIndices.count)
            let routes: [String] = allRoutes.sorted()

            // Color group count
            var colorGroups: Set<Int> = []
            for r in routes { colorGroups.insert(Self.trunkGroupIndex(for: r)) }
            let groupCount: Int = max(colorGroups.count, 1)
            let sortedColorGroups = colorGroups.sorted()
            let stationLaneOffset: CGFloat = {
                guard groupCount == 1, let trunkGroup = sortedColorGroups.first else { return 0 }
                return referenceLaneOffsetsByGroup[trunkGroup] ?? 0
            }()

            // ── Transfer stop: snap to polyline intersection/projection ──
            // For stops served by ≥ 2 trunk color groups, position the
            // marker at the geometric intersection of their polylines
            // (or the average of nearest projections if no intersection).
            if groupCount >= 2 {
                if let betterPos = transferPolylinePosition(
                    centroid: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                    trunkGroups: colorGroups,
                    referencePolylinesByGroup: referencePolylinesByGroup
                ) {
                    avgLat = betterPos.latitude
                    avgLon = betterPos.longitude
                }
            }

            let stationCoordinate = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            let laneHeading: Double? = {
                guard groupCount == 1, let trunkGroup = sortedColorGroups.first else { return nil }
                guard let branches = referencePolylinesByGroup[trunkGroup] else { return nil }
                return Self.nearestSegmentHeading(near: stationCoordinate, branches: branches)
            }()

            // Track bearing from polyline tangents in 3×3 neighborhood
            let gx: Int32 = Int32(avgLat / cellSize)
            let gy: Int32 = Int32(avgLon / cellSize)
            var sumUx: Double = 0.0
            var sumUy: Double = 0.0
            var tangentCount: Int = 0
            for dx: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    let hi: Int64 = Int64(gx &+ dx) << 32
                    let lo: Int64 = Int64((gy &+ dy) & 0x7FFF_FFFF)
                    let key: Int64 = hi | lo
                    if let tangents = cellTangents[key] {
                        for (ux, uy) in tangents {
                            if uy < 0 || (uy == 0 && ux < 0) {
                                sumUx -= ux; sumUy -= uy
                            } else {
                                sumUx += ux; sumUy += uy
                            }
                            tangentCount += 1
                        }
                    }
                }
            }

            let bearing: Double
            if tangentCount > 0 {
                let rad: Double = atan2(sumUx, sumUy)
                var deg: Double = rad * 180.0 / .pi
                if deg < 0 { deg += 360 }
                if deg >= 180 { deg -= 180 }
                bearing = deg
            } else {
                bearing = 0
            }

            // Use structure and complexID from the first member
            let firstKey: GroupKey = keyForStation[memberIndices[0]]
            let allStopIDs: Set<String> = Set(memberIndices.map { stations[$0].id })
            let primaryId: String = allStopIDs.sorted().first ?? ""

            result.append(ConsolidatedStation(
                id: primaryId,
                name: primaryName,
                coordinate: stationCoordinate,
                routes: routes,
                colorGroupCount: groupCount,
                trackBearing: bearing,
                laneHeading: laneHeading,
                laneOffset: stationLaneOffset,
                structure: firstKey.structure,
                complexID: firstKey.complexID,
                sourceStopIDs: allStopIDs,
                isTransfer: groupCount >= 2
            ))
        }

        self.consolidatedStations = result
        AppLogger.shared.log(
            "STATIONS",
            message: "Consolidated \(stations.count) stations → \(result.count) groups")
    }
}
