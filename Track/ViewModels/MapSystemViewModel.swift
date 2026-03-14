//
//  MapSystemViewModel.swift
//  Track
//
//  ViewModel for loading and caching the full transit system map,
//  including subway, LIRR, and Metro-North polylines and stations.
//  Extracted from HomeViewModel for separation of concerns.
//

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

    /// Pre-computed flattened subway polylines for the system map view.
    /// Uses stable IDs and avoids nested ForEach for optimal MapLibre rendering.
    /// A single fine-detail geometry set is used at ALL zoom levels.
    /// Zoom adaptation is handled purely by rendering properties (line width,
    /// opacity) — matching Apple Maps, which never swaps geometry and
    /// relies on the small corridor offset becoming sub-pixel at far zoom.
    var flattenedSubwayPolylines: [FlattenedMapPolyline] = []

    /// Pre-computed flattened commuter rail (LIRR/MNR) polylines for the system map view.
    var flattenedCommuterRailPolylines: [FlattenedMapPolyline] = []

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
            // Load system map and stations fully in parallel — neither
            // blocks the other. Map lines render the instant they arrive;
            // station dots appear independently as soon as the processed
            // station endpoint resolves.
            async let mapTask: Void = loadSystemMap()
            async let stationsTask: Void = loadStations()
            _ = await (mapTask, stationsTask)

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

        // ── Phase 1: Instant render from disk cache ──
        // Try to hydrate from the persistent disk cache first.
        // This avoids the network round-trip and lets the map draw
        // immediately — matching Transit app's instant-map behavior.
        let diskCacheMgr = OfflineCacheManager.shared
        let hasDiskCache = await loadFromDiskCache()

        // ── Phase 2: Network refresh (background) ──
        // If we already rendered from cache, refresh in the background
        // so the user sees the map instantly but gets fresh data.
        // If no cache existed, this is the primary load path.
        if !diskCacheMgr.isOnline && !hasDiskCache {
            // Truly offline with no cache — use the bundled fallback
            await loadOfflineSystemMap()
            return
        }

        if diskCacheMgr.isOnline {
            await fetchAndRenderFromNetwork(isBackgroundRefresh: hasDiskCache)
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
            message: "Disk cache → \(subwayCount) subway + \(commuterCount) commuter rail lines (instant render)")

        self.cachedSystemMap = decoded
        self.cachedTrunkPolylines = subwayResponse.trunkPolylines
        self.computeSubwayOffsets()
        return true
    }

    /// Fetches shapes from the network and updates the map.
    /// When `isBackgroundRefresh` is true, the map already has content from
    /// the disk cache — this just silently replaces it with fresh data.
    private func fetchAndRenderFromNetwork(isBackgroundRefresh: Bool) async {
        do {
            // Fire all three transit fetches in parallel.
            // Subway is required; LIRR and MNR are optional (fail silently).
            async let subwayTask = TrackAPI.fetchAllSubwayShapes()
            async let lirrTask = try? TrackAPI.fetchAllLIRRShapes()
            async let mnrTask = try? TrackAPI.fetchAllMNRShapes()

            let response = try await subwayTask

            // Persist to disk for next launch (fire-and-forget)
            OfflineCacheManager.shared.cacheSubwayShapes(response)

            // Pre-decode subway coordinates for the system-map overview.
            var decoded: [CachedTransitLine] = response.lines.map { line in
                CachedTransitLine(
                    id: line.routeId,
                    color: Color(hex: line.colorHex),
                    coordinates: line.decodedPolylines,
                    mode: .subway
                )
            }

            // Show subway lines immediately before commuter rail arrives
            self.cachedSystemMap = decoded
            self.cachedTrunkPolylines = response.trunkPolylines
            self.computeSubwayOffsets()

            // Now fold in LIRR and MNR results (already fetched in parallel)
            // Also extract commuter-rail stops so they appear as station dots.
            var commuterStops: [CachedSubwayStation] = []

            if let lirrResponse = await lirrTask {
                let lirrLines: [CachedTransitLine] = lirrResponse.lines.map { line in
                    CachedTransitLine(
                        id: line.routeId,
                        color: Color(hex: line.colorHex),
                        coordinates: line.decodedPolylines,
                        mode: .lirr
                    )
                }
                decoded.append(contentsOf: lirrLines)
                OfflineCacheManager.shared.cacheLIRRShapes(lirrResponse)

                // Collect LIRR stops
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

            if let mnrResponse = await mnrTask {
                let mnrLines: [CachedTransitLine] = mnrResponse.lines.map { line in
                    CachedTransitLine(
                        id: line.routeId,
                        color: Color(hex: line.colorHex),
                        coordinates: line.decodedPolylines,
                        mode: .mnr
                    )
                }
                decoded.append(contentsOf: mnrLines)
                OfflineCacheManager.shared.cacheMNRShapes(mnrResponse)

                // Collect MNR stops
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

            // Merge commuter-rail stops into the station list so they
            // appear as dots on the system map alongside subway stations.
            if !commuterStops.isEmpty {
                // Deduplicate by stop ID — a stop shared by multiple
                // branches keeps all its route IDs.
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
                AppLogger.shared.log(
                    "STATIONS",
                    message: "Added \(dedupedStops.count) commuter-rail stops (\(commuterStops.count) raw)")
            }

            // Log details about what we loaded
            let subwayCount = decoded.filter { $0.mode == .subway }.count
            let lirrCount = decoded.filter { $0.mode == .lirr }.count
            let mnrCount = decoded.filter { $0.mode == .mnr }.count
            let totalBranches = decoded.reduce(0) { $0 + $1.coordinates.count }
            let totalPoints = decoded.reduce(0) { $0 + $1.coordinates.reduce(0) { $0 + $1.count } }

            // Update with commuter rail additions (subway already rendered above)
            if decoded.count > subwayCount {
                self.cachedSystemMap = decoded
                // Flatten commuter rail polylines now that LIRR/MNR data is
                // in cachedSystemMap. This MUST happen here because
                // computeSubwayOffsets() fired earlier (for subway) and its
                // async flattening task reads cachedSystemMap before LIRR/MNR
                // are folded in — resulting in empty commuter polylines.
                flattenCommuterRailPolylines()
            }

            let refreshTag = isBackgroundRefresh ? "(background refresh)" : ""
            AppLogger.shared.log(
                "SYSTEM_MAP",
                message:
                    "Loaded \(decoded.count) transit lines (\(subwayCount) subway, \(lirrCount) LIRR, \(mnrCount) MNR) — \(totalBranches) branches, \(totalPoints) total points \(refreshTag)"
            )
        } catch {
            AppLogger.shared.logError("loadSystemMap", error: error)
            // Fall back to offline data on error only if we don't already
            // have content (disk cache already rendered)
            if cachedSystemMap.isEmpty {
                await loadOfflineSystemMap()
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
                "Loaded \(offlineLines.count) offline transit routes (\(subwayCount) subway, \(lirrCount) LIRR, \(mnrCount) MNR, \(totalBranches) total branches)"
        )
    }

    // MARK: - Subway Offsets & Flattened Polylines

    /// Populates `cachedOffsetSubwayLines` from the system map.
    ///
    /// Corridor offsets (fanning out co-located lines like 4/5/6 on Lex Ave)
    /// are now computed server-side by `/subway/shapes/all`, so the client
    /// simply converts `CachedTransitLine` → `OffsetSubwayLine` 1:1.
    private func computeSubwayOffsets() {
        let subwayLines = cachedSystemMap.filter { $0.mode == .subway }
        cachedOffsetSubwayLines = subwayLines.map {
            OffsetSubwayLine(id: $0.id, color: $0.color, coordinates: $0.coordinates)
        }
        AppLogger.shared.log(
            "SYSTEM_MAP",
            message: "Mapped \(subwayLines.count) subway lines (offsets applied server-side)")

        // Pre-compute flattened polylines for efficient rendering.
        // Heavy CPU work (unify + RDP + Catmull-Rom) runs off main actor
        // so the map and UI remain responsive during computation.
        Task {
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
                message: "Flattened \(commuterFlat.count) commuter rail polylines (\(points) points)")
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
            let laneOffset: CGFloat
        }

        var colorGroupResults: [ColorGroupResult] = []
        var originalSubwayPoints: Int = 0

        // When the server provides pre-merged trunk polylines, use them
        // directly — they are the Phase 1+3 output of the corridor pipeline
        // and are the SAME geometry that station dots were snapped to.
        // This eliminates overlapping same-colour lines and ensures polylines
        // pass through station positions.
        let useTrunkPolylines: Bool = cachedTrunkPolylines != nil && !(cachedTrunkPolylines!.isEmpty)

        if useTrunkPolylines, let trunkGroups = cachedTrunkPolylines {
            for trunk in trunkGroups {
                let decoded: [[CLLocationCoordinate2D]] = trunk.decodedPolylines.filter { $0.count >= 2 }
                guard !decoded.isEmpty else { continue }
                let decodedCount: Int = decoded.reduce(0) { $0 + $1.count }
                originalSubwayPoints += decodedCount

                let groupColor: Color = SubwayRoutesData.color(for: trunk.routeIds.first ?? "")

                AppLogger.shared.log(
                    "POLYLINE_TRUNK",
                    message: "[\(trunk.routeIds.joined(separator: "/"))]: \(decoded.count) trunk polylines (server-merged)")

                colorGroupResults.append(ColorGroupResult(
                    groupIndex: trunk.trunkIndex,
                    routeIds: trunk.routeIds,
                    color: groupColor,
                    polylines: decoded,
                    laneOffset: trunk.laneOffset
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
                    message: "[\(activeRoutes.joined(separator: "/"))]: \(pooledSegments.count) segments → \(unified.count) polylines (trunk + branch stubs)")

                colorGroupResults.append(ColorGroupResult(
                    groupIndex: groupIndex,
                    routeIds: activeRoutes,
                    color: groupColor,
                    polylines: unified,
                    laneOffset: 0  // No server corridor data in offline fallback
                ))
            }
        }

        // Yield to let the map render whatever data is already available
        await Task.yield()

        // ---- Phase 2+3: Simplification + smoothing + flatten ----
        //
        // CORRIDOR OFFSETS ARE APPLIED SERVER-SIDE by corridor_pipeline.py.
        // The server's 5-phase topological pipeline (skeleton → lane ordering
        // → perpendicular vertex offsets → junction blending → export) produces
        // correctly-offset polylines in WGS84.  Applying applyCorridorOffsets()
        // here AGAIN was the root cause of:
        //   - EKG zigzag spikes (double miter amplification)
        //   - Cross-avenue contamination (already-offset lines detected as peers)
        //   - Columbus Circle bubbles (double arc radii)
        //
        // The client applies only RDP simplification — NO Catmull-Rom.
        //
        // MapLibre's `line-join: round` and `line-cap: round` already
        // produce GPU-accelerated smooth rendering.  Client-side
        // Catmull-Rom was over-processing:
        //   - 3× more vertices (GPU + memory cost)
        //   - Shifted polylines off station coordinates (visible at z14+)
        //   - Created "roller coaster" loops at station-snap kinks
        //
        // Parameters:
        //   RDP tolerance 0.00008° (~9 m)  — preserves fine detail

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

        // Server polylines pass through station coordinates — only simplify.
        // No Catmull-Rom: MapLibre renders smooth round joins natively.
        var finalOffsetPolylines: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = []
        for item in grouped {
            let rdp = simplifyPolyline(item.coordinates, tolerance: 0.00008)
            guard rdp.count >= 2 else { continue }
            finalOffsetPolylines.append((groupIndex: item.groupIndex, coordinates: rdp))
        }

        var flat: [FlattenedMapPolyline] = []
        for (i, offset) in finalOffsetPolylines.enumerated() {
            let origin = mapping[i]
            let groupResult = colorGroupResults[origin.resultIndex]
            let groupKey: String = groupResult.routeIds.joined(separator: "-")
            guard offset.coordinates.count >= 2 else { continue }

            // Determine z-level: use the geographic midpoint of this
            // specific branch + its route IDs to infer whether this
            // segment runs on elevated infrastructure.
            let midIdx: Int = offset.coordinates.count / 2
            let midCoord: CLLocationCoordinate2D = offset.coordinates[midIdx]
            let branchStructure: StationStructure = StationComplexLookup.inferStructure(
                routes: groupResult.routeIds,
                lat: midCoord.latitude,
                lon: midCoord.longitude
            )
            let isElevated: Bool = branchStructure == .elevated || branchStructure == .viaduct
            let polylineId: String = "trunk_\(groupKey)_\(origin.branchIndex)"

            flat.append(FlattenedMapPolyline(
                id: polylineId,
                coordinates: offset.coordinates,
                color: groupResult.color,
                lineWidth: 3,
                routeIds: groupResult.routeIds,
                isElevated: isElevated,
                trunkIndex: groupResult.groupIndex,
                laneOffset: groupResult.laneOffset
            ))
        }

        flattenedSubwayPolylines = flat

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
                guard let line = linesByRouteId[routeId.uppercased()] ?? linesByRouteId[routeId] else { continue }
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
            ? Int(Double(originalSubwayPoints - simplifiedPoints) / Double(originalSubwayPoints) * 100)
            : 0
        AppLogger.shared.log(
            "SYSTEM_MAP",
            message:
                "Flattened \(totalPolylines) polylines (\(subwayNearCount) subway, \(commuterCount) commuter rail) — \(simplifiedPoints) points (simplified \(reductionPercent)%)"
        )
    }

    // MARK: - Station Loading

    /// Fetches all subway stations and their served lines.
    ///
    /// Prefers `/subway/stations/processed` (pipeline-snapped positions) so
    /// station pills sit exactly on the offset polylines.  Falls back to the
    /// raw GTFS positions from `/subway/stations/all` if the processed
    /// endpoint is unavailable (e.g. shapes haven't loaded yet).
    func loadStations() async {
        if Self.hasStartedStationLoad { return }
        Self.hasStartedStationLoad = true

        if let snapshot = Self.sharedSnapshot, !snapshot.stations.isEmpty {
            cachedStations = snapshot.stations
            consolidatedStations = snapshot.consolidatedStations
            AppLogger.shared.log("SYSTEM_MAP", message: "Reused shared station snapshot")
            return
        }

        // If offline, use bundled static data
        if !OfflineCacheManager.shared.isOnline {
            loadOfflineStations()
            return
        }

        // ── Fast-path: show previous-session stations instantly while
        // the API request is in flight.  On second+ launch this means
        // station pills appear in <100ms instead of waiting 5-15s for
        // the server (especially on Render cold-start).
        if let cached = OfflineCacheManager.shared.getCachedStations(), !cached.isEmpty {
            let restored = cached.map { s in
                CachedSubwayStation(
                    id: s.id,
                    name: s.name,
                    coordinate: CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude),
                    routes: s.routes
                )
            }
            self.cachedStations = restored
            self.consolidateStations()
            AppLogger.shared.log("STATIONS", message: "Restored \(restored.count) stations from disk cache (instant)")
        }

        do {
            // ── Try processed (snapped) stations first ──
            // The pipeline snaps each station onto the offset polylines so
            // that pills sit directly on their coloured lines instead of
            // floating at the raw GTFS GPS point.
            let processed = try await TrackAPI.fetchProcessedStations()
            let stations: [CachedSubwayStation] = processed.stations.compactMap { ps in
                let positions = ps.positions
                guard !positions.isEmpty else { return nil }

                // Average all per-route snapped coordinates → centroid for
                // the consolidated pill.  This places transfer pills at
                // the visual centre of the corridor they serve.
                let avgLat = positions.map(\.lat).reduce(0, +) / Double(positions.count)
                let avgLon = positions.map(\.lon).reduce(0, +) / Double(positions.count)
                let routes = Array(Set(positions.map(\.routeId))).sorted()

                return CachedSubwayStation(
                    id: ps.stationId,
                    name: ps.name,
                    coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                    routes: routes
                )
            }

            guard !stations.isEmpty else {
                throw URLError(.cannotParseResponse)
            }

            await MainActor.run {
                self.cachedStations = stations
                self.consolidateStations()
            }

            // Cache snapped positions for offline use
            let cached = stations.map { s in
                CachedStation(
                    id: s.id,
                    name: s.name,
                    latitude: s.coordinate.latitude,
                    longitude: s.coordinate.longitude,
                    routes: s.routes
                )
            }
            OfflineCacheManager.shared.cacheStations(cached)

            AppLogger.shared.log("STATIONS", message: "Loaded \(stations.count) processed (snapped) stations")

        } catch {
            // ── Fallback: raw GTFS stations ──
            AppLogger.shared.log("STATIONS", message: "Processed stations unavailable (\(error.localizedDescription)), falling back to raw GTFS")
            await loadRawStations()
        }
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
                self.cachedStations = stations
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
        self.cachedStations = offlineStations
        self.consolidateStations()
        AppLogger.shared.log("OFFLINE", message: "Loaded \(offlineStations.count) offline stations")
    }

    // MARK: - Station Consolidation

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
        //   (a) share a curated complexID + structure, OR
        //   (b) are within 20 m AND have the same structure type
        for i in 0..<stations.count {
            for j in (i + 1)..<stations.count {
                let ki = keyForStation[i], kj = keyForStation[j]

                // Same curated complex + same structure → always merge
                if ki.complexID == kj.complexID && ki.structure == kj.structure {
                    union(i, j)
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

        for line in cachedOffsetSubwayLines {
            for branch in line.coordinates {
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

            let avgLat: Double = latSum / Double(memberIndices.count)
            let avgLon: Double = lonSum / Double(memberIndices.count)
            let routes: [String] = allRoutes.sorted()

            // Color group count
            var colorGroups: Set<Int> = []
            for r in routes { colorGroups.insert(Self.trunkGroupIndex(for: r)) }
            let groupCount: Int = max(colorGroups.count, 1)

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
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                routes: routes,
                colorGroupCount: groupCount,
                trackBearing: bearing,
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
