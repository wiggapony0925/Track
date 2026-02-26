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
    struct CachedSubwayStation: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let routes: [String]
    }

    // MARK: - Properties

    var cachedSystemMap: [CachedTransitLine] = []
    var cachedOffsetSubwayLines: [OffsetSubwayLine] = []

    /// Pre-computed flattened subway polylines for the system map view.
    /// Uses stable IDs and avoids nested ForEach for optimal MapKit rendering.
    var flattenedSubwayPolylines: [FlattenedMapPolyline] = []

    /// Pre-computed flattened commuter rail (LIRR/MNR) polylines for the system map view.
    var flattenedCommuterRailPolylines: [FlattenedMapPolyline] = []

    var cachedStations: [CachedSubwayStation] = []

    /// Guards against redundant network fetches when the ViewModel is
    /// re-created (e.g. HomeView structural identity changes).
    private var hasStartedLoading = false

    // MARK: - Init

    init() {
        if let snapshot = Self.sharedSnapshot {
            cachedSystemMap = snapshot.systemMap
            cachedOffsetSubwayLines = snapshot.offsetSubwayLines
            flattenedSubwayPolylines = snapshot.flattenedSubway
            flattenedCommuterRailPolylines = snapshot.flattenedCommuter
            cachedStations = snapshot.stations
            return
        }

        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        Task {
            await loadSystemMap()
            await loadStations()
            Self.sharedSnapshot = SharedSnapshot(
                systemMap: cachedSystemMap,
                offsetSubwayLines: cachedOffsetSubwayLines,
                flattenedSubway: flattenedSubwayPolylines,
                flattenedCommuter: flattenedCommuterRailPolylines,
                stations: cachedStations
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

    /// Pre-computes flattened polyline arrays with stable IDs for efficient MapKit rendering.
    /// This eliminates nested ForEach loops in the View, dramatically improving performance.
    /// Applies Ramer-Douglas-Peucker simplification to reduce point counts while preserving shape.
    /// Called once after `cachedOffsetSubwayLines` is populated.
    private func computeFlattenedPolylines() {
        let tolerance = AppSettings.shared.polylineSimplificationTolerance

        // Flatten subway polylines from offset lines
        var subwayFlat: [FlattenedMapPolyline] = []
        var originalSubwayPoints = 0
        for line in cachedOffsetSubwayLines {
            for (branchIndex, coords) in line.coordinates.enumerated() {
                // Skip empty or single-point polylines
                guard coords.count >= 2 else { continue }
                originalSubwayPoints += coords.count
                let simplified = simplifyPolyline(coords, tolerance: tolerance)
                subwayFlat.append(
                    FlattenedMapPolyline(
                        id: "\(line.id)_\(branchIndex)",
                        coordinates: simplified,
                        color: line.color,
                        lineWidth: 3
                    ))
            }
        }
        flattenedSubwayPolylines = subwayFlat

        // Flatten commuter rail polylines (LIRR and MNR)
        var commuterFlat: [FlattenedMapPolyline] = []
        var originalCommuterPoints = 0
        for line in cachedSystemMap where line.mode != .subway {
            for (branchIndex, coords) in line.coordinates.enumerated() {
                // Skip empty or single-point polylines
                guard coords.count >= 2 else { continue }
                originalCommuterPoints += coords.count
                let simplified = simplifyPolyline(coords, tolerance: tolerance)
                commuterFlat.append(
                    FlattenedMapPolyline(
                        id: "\(line.id)_\(branchIndex)",
                        coordinates: simplified,
                        color: line.color,
                        lineWidth: 2.5
                    ))
            }
        }
        flattenedCommuterRailPolylines = commuterFlat

        let totalPolylines = subwayFlat.count + commuterFlat.count
        let simplifiedPoints =
            subwayFlat.reduce(0) { $0 + $1.coordinates.count }
            + commuterFlat.reduce(0) { $0 + $1.coordinates.count }
        let originalPoints = originalSubwayPoints + originalCommuterPoints
        let reductionPercent = originalPoints > 0
            ? Int(Double(originalPoints - simplifiedPoints) / Double(originalPoints) * 100)
            : 0
        AppLogger.shared.log(
            "SYSTEM_MAP",
            message:
                "Flattened \(totalPolylines) polylines (\(subwayFlat.count) subway, \(commuterFlat.count) commuter rail) — \(originalPoints) → \(simplifiedPoints) points (simplified \(reductionPercent)%)"
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
