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
        let flattenedSubwayMid: [FlattenedMapPolyline]
        let flattenedSubwayFar: [FlattenedMapPolyline]
        let flattenedCommuter: [FlattenedMapPolyline]
        let stations: [CachedSubwayStation]
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

    // MARK: - Properties

    var cachedSystemMap: [CachedTransitLine] = []
    var cachedOffsetSubwayLines: [OffsetSubwayLine] = []

    /// Pre-computed flattened subway polylines for the system map view.
    /// Uses stable IDs and avoids nested ForEach for optimal MapKit rendering.
    /// Three tiers with increasing corridor offsets so parallel lines remain
    /// visually separated at every zoom level — matching Apple Maps.
    var flattenedSubwayPolylines: [FlattenedMapPolyline] = []     // near (veryClose/close)
    var flattenedSubwayMidZoom: [FlattenedMapPolyline] = []       // medium zoom
    var flattenedSubwayFarZoom: [FlattenedMapPolyline] = []       // far/distant zoom

    /// Pre-computed flattened commuter rail (LIRR/MNR) polylines for the system map view.
    var flattenedCommuterRailPolylines: [FlattenedMapPolyline] = []

    /// Route labels placed along trunk polylines (Apple Maps–style bullets).
    var trunkRouteLabels: [TrunkRouteLabel] = []

    var cachedStations: [CachedSubwayStation] = []

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
            flattenedSubwayMidZoom = snapshot.flattenedSubwayMid
            flattenedSubwayFarZoom = snapshot.flattenedSubwayFar
            flattenedCommuterRailPolylines = snapshot.flattenedCommuter
            trunkRouteLabels = snapshot.routeLabels
            cachedStations = snapshot.stations
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
                flattenedSubwayMid: flattenedSubwayMidZoom,
                flattenedSubwayFar: flattenedSubwayFarZoom,
                flattenedCommuter: flattenedCommuterRailPolylines,
                stations: cachedStations,
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
            flattenedSubwayMidZoom = snapshot.flattenedSubwayMid
            flattenedSubwayFarZoom = snapshot.flattenedSubwayFar
            flattenedCommuterRailPolylines = snapshot.flattenedCommuter
            trunkRouteLabels = snapshot.routeLabels
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

            // Unify same-color segments into one trunk + branch stubs
            let unified = unifyTrainPolylines(pooledSegments)

            // Simplify then lightly smooth for curvy appearance
            let simplified = unified.compactMap { coords -> [CLLocationCoordinate2D]? in
                guard coords.count >= 2 else { return nil }
                let rdp = simplifyPolyline(coords, tolerance: tolerance)
                return smoothPolyline(rdp, segmentsPerCurve: 3)
            }

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
                polylines: simplified
            ))
        }

        // ---- Phase 2: Zoom-adaptive cross-color corridor offsets ----
        //
        // Different-color lines sharing a physical corridor (e.g. ACE blue +
        // BDFM orange on 6th Ave) must render as parallel stripes, not stacked.
        // A single fixed offset only works at one zoom level — it becomes
        // sub-pixel when zoomed out.  Pre-compute 3 tiers with increasing
        // spread so the view can swap sets when the camera distance changes.
        //
        // Tier offsets (perpendicular per-lane spacing):
        //   near  (< 3.5 km camera):  0.0004° ≈  34 m — subtle at street level
        //   mid   (3.5–8 km):         0.0012° ≈ 101 m — visible at neighborhood
        //   far   (> 8 km):           0.005°  ≈ 420 m — visible at full overview

        // Build the grouped input once (same for all tiers).
        var allGroupedPolylines: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = []
        struct PolylineOrigin { let resultIndex: Int; let branchIndex: Int }
        var polylineMapping: [PolylineOrigin] = []

        for (resultIndex, groupResult) in colorGroupResults.enumerated() {
            for (branchIndex, coords) in groupResult.polylines.enumerated() {
                allGroupedPolylines.append((groupIndex: groupResult.groupIndex, coordinates: coords))
                polylineMapping.append(PolylineOrigin(resultIndex: resultIndex, branchIndex: branchIndex))
            }
        }

        let offsetTiers: [(suffix: String, degrees: Double)] = [
            ("near", 0.0004),
            ("mid",  0.0012),
            ("far",  0.005),
        ]

        // ---- Phase 3: Flatten into final polylines ----
        // Catmull-Rom smoothing is now applied after RDP simplification
        // in Phase 1 (segmentsPerCurve: 3) for curvy, natural appearance
        // at all zoom levels.  Route detail views use segmentsPerCurve: 4.
        var subwayByTier: [[FlattenedMapPolyline]] = []

        for (suffix, offsetDeg) in offsetTiers {
            let offsetResult = applyCorridorOffsets(allGroupedPolylines, offsetDegrees: offsetDeg)

            var flat: [FlattenedMapPolyline] = []
            for (i, offset) in offsetResult.enumerated() {
                let origin = polylineMapping[i]
                let groupResult = colorGroupResults[origin.resultIndex]
                let groupKey = groupResult.routeIds.joined(separator: "-")
                guard offset.coordinates.count >= 2 else { continue }
                flat.append(FlattenedMapPolyline(
                    id: "trunk_\(groupKey)_\(origin.branchIndex)_\(suffix)",
                    coordinates: offset.coordinates,
                    color: groupResult.color,
                    lineWidth: 3
                ))
            }
            subwayByTier.append(flat)
        }

        flattenedSubwayPolylines = subwayByTier[0]  // near
        flattenedSubwayMidZoom = subwayByTier[1]     // mid
        flattenedSubwayFarZoom = subwayByTier[2]     // far

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
                        lineWidth: 2
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
                "Flattened \(totalPolylines) polylines (\(subwayNearCount) subway × 3 zoom tiers, \(commuterFlat.count) commuter rail) — \(originalPoints) → \(simplifiedPoints) points (simplified \(reductionPercent)%)"
        )
    }

    // MARK: - Station Loading

    /// Fetches all subway stations and their served lines.
    /// Falls back to bundled offline data when network is unavailable.
    func loadStations() async {
        if !cachedStations.isEmpty { return }

        if let snapshot = Self.sharedSnapshot, !snapshot.stations.isEmpty {
            cachedStations = snapshot.stations
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
        AppLogger.shared.log("OFFLINE", message: "Loaded \(offlineStations.count) offline stations")
    }
}
