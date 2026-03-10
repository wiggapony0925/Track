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
import MapKit
import SwiftUI

@Observable
@MainActor
final class MapSystemViewModel {

    // MARK: - Shared Snapshot Cache

    private struct SharedSnapshot {
        let systemMap: [CachedTransitLine]
        let offsetSubwayLines: [OffsetSubwayLine]
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

        static func == (lhs: ConsolidatedStation, rhs: ConsolidatedStation) -> Bool {
            lhs.id == rhs.id && lhs.routes == rhs.routes
        }
    }

    // MARK: - Properties

    var cachedSystemMap: [CachedTransitLine] = []
    var cachedOffsetSubwayLines: [OffsetSubwayLine] = []

    /// Pre-computed flattened subway polylines for the system map view.
    /// Uses stable IDs and avoids nested ForEach for optimal MapKit rendering.
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

    // MARK: - Init

    init() {
        if let snapshot = Self.sharedSnapshot {
            cachedSystemMap = snapshot.systemMap
            cachedOffsetSubwayLines = snapshot.offsetSubwayLines
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
            await loadSystemMap()
            await loadStations()
            Self.sharedSnapshot = SharedSnapshot(
                systemMap: cachedSystemMap,
                offsetSubwayLines: cachedOffsetSubwayLines,
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
    /// Falls back to bundled offline data when network is unavailable.
    func loadSystemMap() async {
        if !cachedSystemMap.isEmpty { return }

        if let snapshot = Self.sharedSnapshot, !snapshot.systemMap.isEmpty {
            cachedSystemMap = snapshot.systemMap
            cachedOffsetSubwayLines = snapshot.offsetSubwayLines
            flattenedSubwayPolylines = snapshot.flattenedSubway
            flattenedCommuterRailPolylines = snapshot.flattenedCommuter
            trunkRouteLabels = snapshot.routeLabels
            consolidatedStations = snapshot.consolidatedStations
            AppLogger.shared.log("SYSTEM_MAP", message: "Reused shared map snapshot")
            return
        }

        // If offline, use bundled static data
        if !OfflineCacheManager.shared.isOnline {
            await loadOfflineSystemMap()
            return
        }

        do {
            // Fetch subway shapes from API
            let response = try await TrackAPI.fetchAllSubwayShapes()

            // Pre-decode subway coordinates for the system-map overview.
            // Deduplication and simplification are handled by the backend.
            var decoded: [CachedTransitLine] = response.lines.map { line in
                let branches = line.decodedPolylines
                return CachedTransitLine(
                    id: line.routeId,
                    color: Color(hex: line.colorHex),
                    coordinates: branches,
                    mode: .subway
                )
            }

            // Fetch LIRR shapes from API
            if let lirrResponse = try? await TrackAPI.fetchAllLIRRShapes() {
                let lirrLines: [CachedTransitLine] = lirrResponse.lines.map { line in
                    CachedTransitLine(
                        id: line.routeId,
                        color: Color(hex: line.colorHex),
                        coordinates: line.decodedPolylines,
                        mode: .lirr
                    )
                }
                decoded.append(contentsOf: lirrLines)
                // Cache for offline use
                await MainActor.run {
                    OfflineCacheManager.shared.cacheLIRRShapes(lirrResponse)
                }
            }

            // Fetch MNR shapes from API
            if let mnrResponse = try? await TrackAPI.fetchAllMNRShapes() {
                let mnrLines: [CachedTransitLine] = mnrResponse.lines.map { line in
                    CachedTransitLine(
                        id: line.routeId,
                        color: Color(hex: line.colorHex),
                        coordinates: line.decodedPolylines,
                        mode: .mnr
                    )
                }
                decoded.append(contentsOf: mnrLines)
                // Cache for offline use
                await MainActor.run {
                    OfflineCacheManager.shared.cacheMNRShapes(mnrResponse)
                }
            }

            // Log details about what we loaded
            let subwayCount = decoded.filter { $0.mode == .subway }.count
            let lirrCount = decoded.filter { $0.mode == .lirr }.count
            let mnrCount = decoded.filter { $0.mode == .mnr }.count
            let totalBranches = decoded.reduce(0) { $0 + $1.coordinates.count }
            let totalPoints = decoded.reduce(0) { $0 + $1.coordinates.reduce(0) { $0 + $1.count } }

            await MainActor.run {
                self.cachedSystemMap = decoded
                self.computeSubwayOffsets()
            }

            AppLogger.shared.log(
                "SYSTEM_MAP",
                message:
                    "Loaded \(decoded.count) transit lines (\(subwayCount) subway, \(lirrCount) LIRR, \(mnrCount) MNR) — \(totalBranches) branches, \(totalPoints) total points"
            )
        } catch {
            AppLogger.shared.logError("loadSystemMap", error: error)
            // Fall back to offline data on error
            await loadOfflineSystemMap()
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

        // Pre-compute flattened polylines for efficient rendering
        computeFlattenedPolylines()
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

    /// Pre-computes flattened polyline arrays with stable IDs for efficient MapKit rendering.
    ///
    /// **Strategy — Apple Maps style**:
    /// 1. Routes grouped by MTA trunk color (e.g. N/Q/R/W → yellow).
    /// 2. All polyline segments for a color group unified into ONE trunk + branches.
    /// 3. Cross-color corridor offsets applied so parallel lines (e.g. blue + green
    ///    on Lex Ave) render side-by-side, not stacked.
    /// 4. Route labels generated at intervals along each trunk.
    private func computeFlattenedPolylines() {
        let tolerance = AppSettings.shared.polylineSimplificationTolerance

        // Build a lookup: route ID → index into cachedOffsetSubwayLines
        var linesByRouteId: [String: OffsetSubwayLine] = [:]
        for line in cachedOffsetSubwayLines {
            linesByRouteId[line.id.uppercased()] = line
        }

        // ---- Phase 1: Per-color unification + simplification ----
        // Each entry: (groupIndex, groupRouteIds, color, polylines)
        struct ColorGroupResult {
            let groupIndex: Int
            let routeIds: [String]
            let color: Color
            var polylines: [[CLLocationCoordinate2D]]
        }

        var colorGroupResults: [ColorGroupResult] = []
        var originalSubwayPoints = 0

        for (groupIndex, group) in Self.trunkGroups.enumerated() {
            var pooledSegments: [[CLLocationCoordinate2D]] = []
            for routeId in group {
                if let line = linesByRouteId[routeId.uppercased()] ?? linesByRouteId[routeId] {
                    let valid = line.coordinates.filter { $0.count >= 2 }
                    pooledSegments.append(contentsOf: valid)
                }
            }

            guard !pooledSegments.isEmpty else { continue }
            originalSubwayPoints += pooledSegments.reduce(0) { $0 + $1.count }

            let groupColor = SubwayRoutesData.color(for: group[0])

            // Unify same-color segments into one trunk + branch stubs.
            // Simplification and smoothing are deferred to Phase 2 so each
            // zoom tier gets its own appropriate level of detail.
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
                polylines: unified
            ))
        }

        // ---- Phase 2+3: Simplification + corridor offsets + flatten ----
        //
        // A SINGLE fine-detail geometry set is used for ALL zoom levels.
        // This matches Apple Maps behaviour: the polylines never change
        // shape when zooming — only their rendered line-width thins out.
        // The small corridor offset (~13 m) becomes sub-pixel at city
        // overview, so parallel lines naturally converge into one.
        //
        // Parameters:
        //   RDP tolerance 0.00006° (~7 m)  — preserves fine detail
        //   Catmull-Rom 3 segments         — smooth curves
        //   Corridor offset 0.00015°       — ~13 m street-level separation
        //   Smooth window 16               — gradual offset transitions

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

        // Apply offsets to the raw, dense unified polylines FIRST.
        // This ensures the spatial grid has enough vertices to properly match parallel lines.
        let offsetGrouped = applyCorridorOffsets(
            grouped,
            laneSpacingDegrees: 0.00015,
            smoothWindow: 16
        )

        // NOW simplify and smooth the offsetted lines
        var finalOffsetPolylines: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = []
        for (i, item) in offsetGrouped.enumerated() {
            let offsetCoords = item.coordinates
            let rdp = simplifyPolyline(offsetCoords, tolerance: 0.00006)
            let smoothed = smoothPolyline(rdp, segmentsPerCurve: 3)
            guard smoothed.count >= 2 else { continue }
            finalOffsetPolylines.append((groupIndex: item.groupIndex, coordinates: smoothed))
        }

        var flat: [FlattenedMapPolyline] = []
        for (i, offset) in finalOffsetPolylines.enumerated() {
            let origin = mapping[i]
            let groupResult = colorGroupResults[origin.resultIndex]
            let groupKey = groupResult.routeIds.joined(separator: "-")
            guard offset.coordinates.count >= 2 else { continue }

            // Determine z-level: use the geographic midpoint of this
            // specific branch + its route IDs to infer whether this
            // segment runs on elevated infrastructure.
            let midIdx = offset.coordinates.count / 2
            let midCoord = offset.coordinates[midIdx]
            let branchStructure = StationComplexLookup.inferStructure(
                routes: groupResult.routeIds,
                lat: midCoord.latitude,
                lon: midCoord.longitude
            )

            flat.append(FlattenedMapPolyline(
                id: "trunk_\(groupKey)_\(origin.branchIndex)",
                coordinates: offset.coordinates,
                color: groupResult.color,
                lineWidth: 3,
                routeIds: groupResult.routeIds,
                isElevated: branchStructure == .elevated || branchStructure == .viaduct
            ))
        }

        flattenedSubwayPolylines = flat

        // Route labels — use base (non-offset) coordinates so they sit
        // centered on the actual track regardless of offset tier.
        var routeLabels: [TrunkRouteLabel] = []
        for groupResult in colorGroupResults {
            let groupKey = groupResult.routeIds.joined(separator: "-")
            for (branchIdx, coords) in groupResult.polylines.enumerated() {
                guard coords.count >= 2 else { continue }
                let labelInterval = 60
                var labelIdx = 0
                var ptIdx = labelInterval / 2
                while ptIdx < coords.count {
                    routeLabels.append(TrunkRouteLabel(
                        id: "label_\(groupKey)_\(branchIdx)_\(labelIdx)",
                        coordinate: coords[ptIdx],
                        routeIds: groupResult.routeIds,
                        color: groupResult.color
                    ))
                    labelIdx += 1
                    ptIdx += labelInterval
                }
                if let lastCoord = coords.last {
                    routeLabels.append(TrunkRouteLabel(
                        id: "label_\(groupKey)_\(branchIdx)_end",
                        coordinate: lastCoord,
                        routeIds: groupResult.routeIds,
                        color: groupResult.color
                    ))
                }
            }
        }
        trunkRouteLabels = routeLabels

        // ---- Commuter rail (LIRR / MNR — same unify + simplify, NO smooth) ----
        var commuterFlat: [FlattenedMapPolyline] = []
        var originalCommuterPoints = 0
        for line in cachedSystemMap where line.mode != .subway {
            let validCoords = line.coordinates.filter { $0.count >= 2 }
            guard !validCoords.isEmpty else { continue }
            originalCommuterPoints += validCoords.reduce(0) { $0 + $1.count }
            let unified = unifyTrainPolylines(validCoords)
            for (branchIndex, coords) in unified.enumerated() {
                let simplified = simplifyPolyline(coords, tolerance: tolerance)
                commuterFlat.append(
                    FlattenedMapPolyline(
                        id: "\(line.id)_\(branchIndex)",
                        coordinates: simplified,
                        color: line.color,
                        lineWidth: 2,                        routeIds: [line.id],                        isElevated: false
                    ))
            }
        }
        flattenedCommuterRailPolylines = commuterFlat

        let subwayNearCount = flattenedSubwayPolylines.count
        let totalPolylines = subwayNearCount + commuterFlat.count
        let simplifiedPoints =
            flattenedSubwayPolylines.reduce(0) { $0 + $1.coordinates.count }
            + commuterFlat.reduce(0) { $0 + $1.coordinates.count }
        let originalPoints = originalSubwayPoints + originalCommuterPoints
        let reductionPercent = originalPoints > 0
            ? Int(Double(originalPoints - simplifiedPoints) / Double(originalPoints) * 100)
            : 0
        AppLogger.shared.log(
            "SYSTEM_MAP",
            message:
                "Flattened \(totalPolylines) polylines (\(subwayNearCount) subway, \(commuterFlat.count) commuter rail) — \(originalPoints) → \(simplifiedPoints) points (simplified \(reductionPercent)%)"
        )
    }

    // MARK: - Station Loading

    /// Fetches all subway stations and their served lines.
    /// Falls back to bundled offline data when network is unavailable.
    func loadStations() async {
        if !cachedStations.isEmpty { return }

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
        default:                           return 99
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
        let mergeRadiusDeg = 0.00024  // ~20 m at NYC longitude
        let mergeRadiusSq = mergeRadiusDeg * mergeRadiusDeg

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

                let dx = stations[i].coordinate.longitude - stations[j].coordinate.longitude
                let dy = stations[i].coordinate.latitude - stations[j].coordinate.latitude
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
        let cellSize = 0.001
        var cellTangents: [Int64: [(Double, Double)]] = [:]

        func tangentCellKey(_ lat: Double, _ lon: Double) -> Int64 {
            let gx = Int32(lat / cellSize)
            let gy = Int32(lon / cellSize)
            return (Int64(gx) << 32) | Int64(gy & 0x7FFF_FFFF)
        }

        for line in cachedOffsetSubwayLines {
            for branch in line.coordinates {
                for i in 0..<(branch.count - 1) {
                    let a = branch[i], b = branch[i + 1]
                    let dx = b.longitude - a.longitude
                    let dy = b.latitude - a.latitude
                    let len = sqrt(dx * dx + dy * dy)
                    guard len > 1e-10 else { continue }
                    let ux = dx / len, uy = dy / len
                    let keyA = tangentCellKey(a.latitude, a.longitude)
                    let keyB = tangentCellKey(b.latitude, b.longitude)
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
            var latSum = 0.0, lonSum = 0.0
            var allRoutes = Set<String>()
            var primaryName = ""
            var maxRouteCount = 0

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

            let avgLat = latSum / Double(memberIndices.count)
            let avgLon = lonSum / Double(memberIndices.count)
            let routes = allRoutes.sorted()

            // Color group count
            var colorGroups = Set<Int>()
            for r in routes { colorGroups.insert(Self.trunkGroupIndex(for: r)) }
            let groupCount = max(colorGroups.count, 1)

            // Track bearing from polyline tangents in 3×3 neighborhood
            let gx = Int32(avgLat / cellSize)
            let gy = Int32(avgLon / cellSize)
            var sumUx = 0.0, sumUy = 0.0, tangentCount = 0
            for dx: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    let key = (Int64(gx &+ dx) << 32) | Int64((gy &+ dy) & 0x7FFF_FFFF)
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
                let rad = atan2(sumUx, sumUy)
                var deg = rad * 180.0 / .pi
                if deg < 0 { deg += 360 }
                if deg >= 180 { deg -= 180 }
                bearing = deg
            } else {
                bearing = 0
            }

            // Use structure and complexID from the first member
            let firstKey = keyForStation[memberIndices[0]]
            let allStopIDs = Set(memberIndices.map { stations[$0].id })
            let primaryId = allStopIDs.sorted().first ?? ""

            result.append(ConsolidatedStation(
                id: primaryId,
                name: primaryName,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                routes: routes,
                colorGroupCount: groupCount,
                trackBearing: bearing,
                structure: firstKey.structure,
                complexID: firstKey.complexID,
                sourceStopIDs: allStopIDs
            ))
        }

        self.consolidatedStations = result
        AppLogger.shared.log(
            "STATIONS",
            message: "Consolidated \(stations.count) stations → \(result.count) groups")
    }
}
