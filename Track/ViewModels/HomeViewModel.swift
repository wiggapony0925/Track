//
//  HomeViewModel.swift
//  Track
//
//  ViewModel for the HomeView. Fetches nearby transit arrivals
//  (both subway and bus) from the TrackAPI backend based on the
//  user's current location or a draggable search pin.
//  Shows a unified live transit feed with bus tracking on the map.
//

import Foundation
import SwiftUI
import SwiftData
import CoreLocation
import MapKit
import WidgetKit

@Observable
@MainActor
final class HomeViewModel {
    var nearbyStations: [(stationID: String, name: String, distance: Double, routeIDs: [String])] = []
    var upcomingArrivals: [TrainArrival] = []
    var isLoading = false
    var errorMessage: String?
    
    /// The currently tracked route for the widget, loaded from UserDefaults.
    var currentTrackedRoute: TrackedRoute? = nil


    // MARK: - Search

    /// User-entered search text for filtering transit results.
    var searchText = ""

    /// Grouped transit results filtered by the current search query.
    /// Returns all results when the search text is empty.
    /// Searches route names, directions, current arrival stops, AND all stations served by the route.
    var filteredGroupedTransit: [GroupedNearbyTransitResponse] {
        guard !searchText.isEmpty else { return groupedTransit }
        let query = searchText.lowercased()
        
        // Find all routes that serve stations matching the search query
        let matchingStationRoutes = Set(
            cachedStations
                .filter { $0.name.lowercased().contains(query) }
                .flatMap { $0.routes }
        )
        
        return groupedTransit.filter { group in
            // Match by route display name or ID
            group.displayName.lowercased().contains(query) ||
            group.routeId.lowercased().contains(query) ||
            // Match by direction or current arrival stop names
            group.directions.contains { direction in
                direction.direction.lowercased().contains(query) ||
                direction.arrivals.contains { $0.stopName.lowercased().contains(query) }
            } ||
            // Match if this route serves any station matching the query
            matchingStationRoutes.contains(group.displayName) ||
            matchingStationRoutes.contains(group.routeId)
        }
    }
    
    /// LIRR arrivals filtered by search text.
    /// Searches route ID, station ID, direction, and destination.
    var filteredLIRRArrivals: [TrainArrival] {
        guard !searchText.isEmpty else { return lirrArrivals }
        let query = searchText.lowercased()
        return lirrArrivals.filter { arrival in
            arrival.routeID.lowercased().contains(query) ||
            arrival.stationID.lowercased().contains(query) ||
            arrival.stationName.lowercased().contains(query) ||
            arrival.direction.lowercased().contains(query) ||
            (arrival.destination?.lowercased().contains(query) ?? false)
        }
    }
    
    /// Metro-North arrivals filtered by search text.
    /// Searches route ID, station ID, direction, and destination.
    var filteredMNRArrivals: [TrainArrival] {
        guard !searchText.isEmpty else { return mnrArrivals }
        let query = searchText.lowercased()
        return mnrArrivals.filter { arrival in
            arrival.routeID.lowercased().contains(query) ||
            arrival.stationID.lowercased().contains(query) ||
            arrival.stationName.lowercased().contains(query) ||
            arrival.direction.lowercased().contains(query) ||
            (arrival.destination?.lowercased().contains(query) ?? false)
        }
    }
    
    /// Subway arrivals filtered by search text.
    var filteredSubwayArrivals: [TrainArrival] {
        guard !searchText.isEmpty else { return upcomingArrivals }
        let query = searchText.lowercased()
        return upcomingArrivals.filter { arrival in
            arrival.routeID.lowercased().contains(query) ||
            arrival.stationID.lowercased().contains(query) ||
            arrival.stationName.lowercased().contains(query) ||
            arrival.direction.lowercased().contains(query) ||
            (arrival.destination?.lowercased().contains(query) ?? false)
        }
    }
    
    /// Bus arrivals filtered by search text.
    /// Searches both the full routeId and the stripped display name for flexibility.
    var filteredBusArrivals: [BusArrival] {
        guard !searchText.isEmpty else { return busArrivals }
        let query = searchText.lowercased()
        return busArrivals.filter { arrival in
            arrival.routeId.lowercased().contains(query) ||
            arrival.stopId.lowercased().contains(query) ||
            arrival.statusText.lowercased().contains(query)
        }
    }
    
    /// Bus stops filtered by search text.
    var filteredBusStops: [BusStop] {
        guard !searchText.isEmpty else { return nearbyBusStops }
        let query = searchText.lowercased()
        return nearbyBusStops.filter { stop in
            stop.name.lowercased().contains(query)
        }
    }
    
    /// Nearby stations filtered by search text.
    var filteredNearbyStations: [(stationID: String, name: String, distance: Double, routeIDs: [String])] {
        guard !searchText.isEmpty else { return nearbyStations }
        let query = searchText.lowercased()
        return nearbyStations.filter { station in
            station.name.lowercased().contains(query) ||
            station.routeIDs.contains { $0.lowercased().contains(query) }
        }
    }

    // MARK: - Grouped Arrivals for Unified Navigation
    
    /// Groups subway arrivals into `GroupedNearbyTransitResponse` for the unified
    /// tap-to-detail navigation flow (same as Nearby tab).
    var groupedSubwayArrivals: [GroupedNearbyTransitResponse] {
        groupTrainArrivals(filteredSubwayArrivals, mode: "subway")
    }
    
    /// Groups LIRR arrivals into `GroupedNearbyTransitResponse` for the unified
    /// tap-to-detail navigation flow.
    var groupedLIRRArrivals: [GroupedNearbyTransitResponse] {
        groupTrainArrivals(filteredLIRRArrivals, mode: "lirr")
    }
    
    /// Groups Metro-North arrivals into `GroupedNearbyTransitResponse` for the unified
    /// tap-to-detail navigation flow.
    var groupedMNRArrivals: [GroupedNearbyTransitResponse] {
        groupTrainArrivals(filteredMNRArrivals, mode: "mnr")
    }
    
    /// Groups bus arrivals into `GroupedNearbyTransitResponse` for the unified
    /// tap-to-detail navigation flow.
    var groupedBusArrivals: [GroupedNearbyTransitResponse] {
        guard let stop = selectedBusStop else { return [] }
        
        // Group by route_id
        var byRoute: [String: [BusArrival]] = [:]
        for arrival in filteredBusArrivals {
            byRoute[arrival.routeId, default: []].append(arrival)
        }
        
        return byRoute.map { routeId, arrivals in
            let displayName = stripMTAPrefix(routeId)
            // Convert BusArrival → NearbyTransitResponse for the grouped model
            let nearbyArrivals = arrivals.map { bus -> NearbyTransitResponse in
                let minutesAway: Int
                if let expected = bus.expectedArrival {
                    minutesAway = max(0, Int(expected.timeIntervalSinceNow / 60))
                } else {
                    minutesAway = 0
                }
                return NearbyTransitResponse(
                    routeId: bus.routeId,
                    stopName: stop.name,
                    direction: stop.direction ?? "Loop",
                    destination: bus.statusText,
                    minutesAway: minutesAway,
                    status: bus.status,
                    mode: "bus",
                    stopLat: stop.lat,
                    stopLon: stop.lon,
                    arrivalTs: bus.expectedArrival.map { Int($0.timeIntervalSince1970) },
                    vehicleId: bus.vehicleId,
                    tripId: nil,
                    stopId: bus.stopId
                )
            }
            
            return GroupedNearbyTransitResponse(
                routeId: routeId,
                displayName: displayName,
                mode: "bus",
                colorHex: nil,
                directions: [
                    DirectionArrivalsResponse(
                        direction: stop.direction ?? "Loop",
                        arrivals: nearbyArrivals.sorted { $0.minutesAway < $1.minutesAway }
                    )
                ]
            )
        }.sorted { $0.soonestMinutes < $1.soonestMinutes }
    }
    
    /// Helper: Groups `TrainArrival` arrays into `GroupedNearbyTransitResponse`.
    /// Works for subway, LIRR, and Metro-North.
    private func groupTrainArrivals(_ arrivals: [TrainArrival], mode: String) -> [GroupedNearbyTransitResponse] {
        // Filter out stale arrivals (minutesAway == 0 with past timestamps)
        let liveArrivals = arrivals.filter { $0.minutesAway > 0 || $0.estimatedTime > Date() }
        
        // Group by route_id
        var byRoute: [String: [TrainArrival]] = [:]
        for arrival in liveArrivals {
            byRoute[arrival.routeID, default: []].append(arrival)
        }
        
        return byRoute.map { routeId, routeArrivals in
            // Sub-group by direction
            var byDirection: [String: [TrainArrival]] = [:]
            for arrival in routeArrivals {
                let dirLabel = arrival.destination ?? arrival.direction
                byDirection[dirLabel, default: []].append(arrival)
            }
            
            let directions = byDirection.map { direction, dirArrivals -> DirectionArrivalsResponse in
                let nearbyArrivals = dirArrivals
                    .sorted { $0.minutesAway < $1.minutesAway }
                    .map { train -> NearbyTransitResponse in
                        NearbyTransitResponse(
                            routeId: train.routeID,
                            stopName: train.stationName,
                            direction: train.direction,
                            destination: train.destination,
                            minutesAway: train.minutesAway,
                            status: train.status,
                            mode: mode,
                            stopLat: nil,
                            stopLon: nil,
                            arrivalTs: Int(train.estimatedTime.timeIntervalSince1970),
                            vehicleId: nil,
                            tripId: train.tripId,
                            stopId: train.stationID
                        )
                    }
                return DirectionArrivalsResponse(direction: direction, arrivals: nearbyArrivals)
            }.sorted { $0.direction < $1.direction }
            
            let colorHex: String? = mode == "subway" ? nil : nil
            
            return GroupedNearbyTransitResponse(
                routeId: routeId,
                displayName: routeId,
                mode: mode,
                colorHex: colorHex,
                directions: directions
            )
        }.sorted { $0.soonestMinutes < $1.soonestMinutes }
    }

    // Bus mode
    var selectedMode: TransportMode = .nearby
    var nearbyBusStops: [BusStop] = []
    var busArrivals: [BusArrival] = []
    var selectedBusStop: BusStop?

    // Bus routes (browse all routes)
    var allBusRoutes: [BusRoute] = []

    // Nearby transit (unified)
    var nearbyTransit: [NearbyTransitResponse] = []

    // Grouped nearby transit (one card per route)
    var groupedTransit: [GroupedNearbyTransitResponse] = []

    // Nearest metro recommendation (shown when no nearby transit)
    var nearestTransit: NearbyTransitResponse?
    /// Distance in meters from the user to the nearest transit stop.
    var nearestTransitDistance: Double?

    // LIRR mode
    var lirrArrivals: [TrainArrival] = []

    // Metro-North mode
    var mnrArrivals: [TrainArrival] = []

    // Service alerts & accessibility
    var serviceAlerts: [TransitAlert] = []
    var elevatorOutages: [ElevatorStatus] = []

    // Route detail sheet
    var selectedGroupedRoute: GroupedNearbyTransitResponse?
    var selectedDirectionIndex: Int = 0
    var isRouteDetailPresented = false

    // Draggable search pin
    var searchPinCoordinate: CLLocationCoordinate2D?
    var isSearchPinActive = false
    
    // Walking route to the nearest station
    var walkingRoute: MKRoute?
    var nearestStopCoordinate: CLLocationCoordinate2D?
    var selectedStopId: String?

    // Live bus/train tracking on map
    var selectedRouteId: String?
    var highlightedVehicleId: String?
    var busVehicles: [BusVehicleResponse] = []
    
    struct TrainVehicle: Identifiable {
        let id: String
        let tripId: String?
        let routeId: String
        let direction: String
        var lat: Double
        var lon: Double
        var bearing: Double?
        var nextStationName: String?
    }
    var trainVehicles: [TrainVehicle] = []
    
    var routeShape: RouteShapeResponse?

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
    var cachedSystemMap: [CachedTransitLine] = []

    /// Pre-computed subway lines with perpendicular offsets applied to shared corridors.
    /// Computed once when cachedSystemMap is set, so the View never recalculates it.
    struct OffsetSubwayLine: Identifiable {
        let id: String
        let color: Color
        let coordinates: [[CLLocationCoordinate2D]]
    }
    var cachedOffsetSubwayLines: [OffsetSubwayLine] = []
    
    // MARK: - Flattened Map Polylines (Performance Optimized)
    
    /// A single polyline segment ready for rendering with a stable ID.
    /// This flattens nested structures to avoid nested ForEach loops in SwiftUI Map,
    /// which dramatically improves rendering performance.
    struct FlattenedMapPolyline: Identifiable {
        let id: String           // Stable unique ID: "routeId_branchIndex"
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let lineWidth: CGFloat
        let isDashed: Bool
    }
    
    /// Pre-computed flattened subway polylines for the system map view.
    /// Uses stable IDs and avoids nested ForEach for optimal MapKit rendering.
    var flattenedSubwayPolylines: [FlattenedMapPolyline] = []
    
    /// Pre-computed flattened commuter rail (LIRR/MNR) polylines for the system map view.
    var flattenedCommuterRailPolylines: [FlattenedMapPolyline] = []

    // Full subway station list with served lines
    struct CachedSubwayStation: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let routes: [String]
    }
    var cachedStations: [CachedSubwayStation] = []

    // MARK: - Offline Support
    
    /// Whether we're currently using cached data due to network issues
    var isUsingCachedData: Bool {
        OfflineCacheManager.shared.isUsingCachedData
    }
    
    /// Whether the device is currently online
    var isOnline: Bool {
        OfflineCacheManager.shared.isOnline
    }
    
    /// Age of cached data (e.g., "5 min ago")
    var cacheAge: String? {
        OfflineCacheManager.shared.getCacheAge()
    }

    init() {
        syncTrackedRoute()
        Task {
            await loadSystemMap()
            await loadStations()
        }
    }

    /// Fetches the full transit system map (subway, LIRR, MNR polylines).
    /// Falls back to bundled offline data when network is unavailable.
    func loadSystemMap() async {
        // If offline, use bundled static data
        if !OfflineCacheManager.shared.isOnline {
            await loadOfflineSystemMap()
            return
        }
        
        do {
            // Fetch subway shapes from API
            let response = try await TrackAPI.fetchAllSubwayShapes()
            
            // Pre-decode subway coordinates, deduplicate overlapping branches,
            // and simplify geometry for the system-map overview.
            var decoded: [CachedTransitLine] = response.lines.map { line in
                let rawBranches = line.decodedPolylines
                let uniqueBranches = self.deduplicateBranches(rawBranches)
                if rawBranches.count != uniqueBranches.count {
                    AppLogger.shared.log("DEDUP", message: "\(line.routeId): \(rawBranches.count) branches → \(uniqueBranches.count) after dedup")
                }
                let simplified = uniqueBranches.map { self.simplifyPolyline($0) }
                return CachedTransitLine(
                    id: line.routeId,
                    color: Color(hex: line.colorHex),
                    coordinates: simplified,
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
            
            AppLogger.shared.log("SYSTEM_MAP", message: "Loaded \(decoded.count) transit lines (\(subwayCount) subway, \(lirrCount) LIRR, \(mnrCount) MNR) — \(totalBranches) branches, \(totalPoints) total points")
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
    
    // MARK: - Polyline Deduplication & Simplification
    
    /// Removes near-duplicate polylines whose physical tracks overlap heavily.
    /// GTFS often produces multiple shape_ids that trace the same physical track
    /// with minor coordinate differences, causing 2-3 overlapping lines per route.
    /// Uses sample-point proximity: if ≥70% of evenly-spaced sample points on the
    /// candidate lie within ~55m of the existing polyline, they're the same track.
    private func deduplicateBranches(_ branches: [[CLLocationCoordinate2D]]) -> [[CLLocationCoordinate2D]] {
        guard branches.count > 1 else { return branches }
        
        // Sort longest first so we keep the most complete polyline
        let sorted = branches.sorted { $0.count > $1.count }
        var deduped: [[CLLocationCoordinate2D]] = []
        
        let proximity = 0.0005 // ~55 m at NYC latitude
        
        for branch in sorted {
            guard branch.count >= 2 else { continue }
            
            let isDuplicate = deduped.contains { existing in
                guard existing.count >= 2 else { return false }
                // Sample up to 20 evenly-spaced points along the candidate
                let nSamples = min(20, branch.count)
                let sampleStep = max(1, branch.count / nSamples)
                var closeCount = 0
                var totalSamples = 0
                
                var si = 0
                while si < branch.count {
                    let pt = branch[si]
                    totalSamples += 1
                    
                    // Search a window around the proportional position in the existing line
                    let proportion = Double(si) / Double(max(branch.count - 1, 1))
                    let center = Int(proportion * Double(existing.count - 1))
                    let window = max(existing.count / 5, 10)
                    let lo = max(0, center - window)
                    let hi = min(existing.count, center + window)
                    
                    var found = false
                    for ei in lo..<hi {
                        if abs(pt.latitude - existing[ei].latitude) < proximity
                            && abs(pt.longitude - existing[ei].longitude) < proximity {
                            found = true
                            break
                        }
                    }
                    if found { closeCount += 1 }
                    
                    si += sampleStep
                }
                
                return totalSamples > 0 && Double(closeCount) / Double(totalSamples) >= 0.70
            }
            
            if !isDuplicate {
                deduped.append(branch)
            }
        }
        
        return deduped
    }
    
    /// Simplifies a polyline using the Ramer-Douglas-Peucker algorithm.
    /// Removes intermediate points within `tolerance` degrees of the straight
    /// line between their neighbours — ~11 m at 0.0001° tolerance, ~17m at 0.00015°.
    /// Uses the configurable tolerance from AppSettings for optimal performance/quality balance.
    private func simplifyPolyline(_ coords: [CLLocationCoordinate2D], tolerance: Double? = nil) -> [CLLocationCoordinate2D] {
        let effectiveTolerance = tolerance ?? AppSettings.shared.polylineSimplificationTolerance
        guard coords.count > 2 else { return coords }
        
        let first = coords[0]
        let last = coords[coords.count - 1]
        
        var maxDist = 0.0
        var maxIdx = 0
        
        let dx = last.longitude - first.longitude
        let dy = last.latitude - first.latitude
        let lineLenSq = dx * dx + dy * dy
        
        for i in 1..<(coords.count - 1) {
            let dist: Double
            if lineLenSq == 0 {
                let dlat = coords[i].latitude - first.latitude
                let dlon = coords[i].longitude - first.longitude
                dist = sqrt(dlat * dlat + dlon * dlon)
            } else {
                let t = max(0, min(1, ((coords[i].longitude - first.longitude) * dx + (coords[i].latitude - first.latitude) * dy) / lineLenSq))
                let projLat = first.latitude + t * dy
                let projLon = first.longitude + t * dx
                let dlat = coords[i].latitude - projLat
                let dlon = coords[i].longitude - projLon
                dist = sqrt(dlat * dlat + dlon * dlon)
            }
            if dist > maxDist {
                maxDist = dist
                maxIdx = i
            }
        }
        
        if maxDist > effectiveTolerance {
            let left = simplifyPolyline(Array(coords[...maxIdx]), tolerance: effectiveTolerance)
            let right = simplifyPolyline(Array(coords[maxIdx...]), tolerance: effectiveTolerance)
            return left.dropLast() + right
        } else {
            return [first, last]
        }
    }
    
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
            if upper.hasPrefix("LIRR") { lirrCount += 1 }
            else if upper.hasPrefix("MNR") { mnrCount += 1 }
        }
        
        AppLogger.shared.log("BUNDLE", message: "Bundle has \(allRouteIds.count) routes: \(lirrCount) LIRR, \(mnrCount) MNR")
        
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
            
            lines.append(CachedTransitLine(
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
        // Load subway routes from hardcoded offline paths, deduplicating and simplifying
        var offlineLines: [CachedTransitLine] = SubwayRoutesData.allRouteIds.compactMap { routeId -> CachedTransitLine? in
            let rawBranches = SubwayRoutesData.routeBranches(for: routeId)
            guard !rawBranches.isEmpty else { return nil }
            let uniqueBranches = deduplicateBranches(rawBranches)
            let simplified = uniqueBranches.map { simplifyPolyline($0) }
            return CachedTransitLine(
                id: routeId,
                color: SubwayRoutesData.color(for: routeId),
                coordinates: simplified,
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
        AppLogger.shared.log("OFFLINE", message: "Loaded \(offlineLines.count) offline transit routes (\(subwayCount) subway, \(lirrCount) LIRR, \(mnrCount) MNR, \(totalBranches) total branches)")
    }
    
    /// Computes perpendicular offsets for subway lines that share the same tunnel/corridor.
    /// Called once after `cachedSystemMap` is populated so the View never recalculates this.
    ///
    /// The backend already filters express/shuttle variants and deduplicates directions,
    /// so each line arrives with only its unique physical-track branches.
    private func computeSubwayOffsets() {
        let subwayLines = cachedSystemMap.filter { $0.mode == .subway }
        guard !subwayLines.isEmpty else {
            cachedOffsetSubwayLines = []
            return
        }
        
        // 1. Build a grid → set-of-route-IDs lookup.
        //    Snap every coordinate to a ~33m cell so only truly co-located tracks register
        //    as "shared corridor" (avoids false positives from parallel streets).
        //    Use a packed Int64 key instead of String for much faster hashing.
        let gridSize = 0.0003  // ~33m at NYC latitude
        var gridToRoutes: [Int64: Set<String>] = [:]
        
        for line in subwayLines {
            for coords in line.coordinates {
                // Sample every 3rd point for the grid lookup — the offset only matters
                // visually in shared corridors which span many cells, so skipping
                // intermediate points has no visible effect but cuts work by ~67%.
                let step = max(1, min(3, coords.count / 10))
                for i in Swift.stride(from: 0, to: coords.count, by: step) {
                    let coord = coords[i]
                    let gx = Int32(round(coord.latitude / gridSize))
                    let gy = Int32(round(coord.longitude / gridSize))
                    let key = (Int64(gx) << 32) | (Int64(gy) & 0xFFFFFFFF)
                    gridToRoutes[key, default: []].insert(line.id)
                }
            }
        }
        
        // 2. For cells with multiple routes, determine a stable alphabetical ordering.
        var cellOrdering: [Int64: [String]] = [:]
        for (key, routes) in gridToRoutes where routes.count > 1 {
            cellOrdering[key] = routes.sorted()
        }
        
        // If no corridors are shared, skip the per-point offset work entirely.
        if cellOrdering.isEmpty {
            cachedOffsetSubwayLines = subwayLines.map {
                OffsetSubwayLine(id: $0.id, color: $0.color, coordinates: $0.coordinates)
            }
            AppLogger.shared.log("SYSTEM_MAP", message: "No shared corridors — skipped offset computation for \(subwayLines.count) lines")
            return
        }
        
        // 3. Offset each coordinate perpendicular to the direction of travel
        //    based on its slot in shared cells.
        let offsetMeters = AppSettings.shared.subwayLineOffsetMeters
        let metersPerDegLat = 111_000.0
        let metersPerDegLon = 84_300.0  // at ~40.7°N
        
        var result: [OffsetSubwayLine] = []
        
        for line in subwayLines {
            var offsetBranches: [[CLLocationCoordinate2D]] = []
            
            for coords in line.coordinates {
                guard coords.count >= 2 else {
                    offsetBranches.append(coords)
                    continue
                }
                
                var offsetCoords: [CLLocationCoordinate2D] = []
                
                for i in 0..<coords.count {
                    let coord = coords[i]
                    let gx = Int32(round(coord.latitude / gridSize))
                    let gy = Int32(round(coord.longitude / gridSize))
                    let key = (Int64(gx) << 32) | (Int64(gy) & 0xFFFFFFFF)
                    
                    guard let ordering = cellOrdering[key],
                          let slot = ordering.firstIndex(of: line.id) else {
                        offsetCoords.append(coord)
                        continue
                    }
                    
                    let totalLines = ordering.count
                    let centerOffset = Double(slot) - Double(totalLines - 1) / 2.0
                    
                    // Direction of travel from neighboring points
                    let prev = i > 0 ? coords[i - 1] : coords[i]
                    let next = i < coords.count - 1 ? coords[i + 1] : coords[i]
                    
                    let dx = next.longitude - prev.longitude
                    let dy = next.latitude - prev.latitude
                    let length = sqrt(dx * dx + dy * dy)
                    
                    if length < 1e-10 {
                        offsetCoords.append(coord)
                        continue
                    }
                    
                    // Perpendicular (90° CW): (dy, -dx) normalized
                    let perpLat = dx / length
                    let perpLon = -dy / length
                    
                    let offsetLat = centerOffset * offsetMeters / metersPerDegLat * perpLat
                    let offsetLon = centerOffset * offsetMeters / metersPerDegLon * perpLon
                    
                    offsetCoords.append(CLLocationCoordinate2D(
                        latitude: coord.latitude + offsetLat,
                        longitude: coord.longitude + offsetLon
                    ))
                }
                
                offsetBranches.append(offsetCoords)
            }
            
            result.append(OffsetSubwayLine(
                id: line.id,
                color: line.color,
                coordinates: offsetBranches
            ))
        }
        
        cachedOffsetSubwayLines = result
        AppLogger.shared.log("SYSTEM_MAP", message: "Computed subway offsets for \(result.count) lines (\(cellOrdering.count) shared corridor cells)")
        
        // Pre-compute flattened polylines for efficient rendering
        computeFlattenedPolylines()
    }
    
    /// Pre-computes flattened polyline arrays with stable IDs for efficient MapKit rendering.
    /// This eliminates nested ForEach loops in the View, dramatically improving performance.
    /// Called once after `cachedOffsetSubwayLines` is populated.
    private func computeFlattenedPolylines() {
        // Flatten subway polylines from offset lines
        var subwayFlat: [FlattenedMapPolyline] = []
        for line in cachedOffsetSubwayLines {
            for (branchIndex, coords) in line.coordinates.enumerated() {
                // Skip empty or single-point polylines
                guard coords.count >= 2 else { continue }
                subwayFlat.append(FlattenedMapPolyline(
                    id: "\(line.id)_\(branchIndex)",
                    coordinates: coords,
                    color: line.color,
                    lineWidth: 3,
                    isDashed: false
                ))
            }
        }
        flattenedSubwayPolylines = subwayFlat
        
        // Flatten commuter rail polylines (LIRR and MNR)
        var commuterFlat: [FlattenedMapPolyline] = []
        for line in cachedSystemMap where line.mode != .subway {
            for (branchIndex, coords) in line.coordinates.enumerated() {
                // Skip empty or single-point polylines
                guard coords.count >= 2 else { continue }
                commuterFlat.append(FlattenedMapPolyline(
                    id: "\(line.id)_\(branchIndex)",
                    coordinates: coords,
                    color: line.color,
                    lineWidth: 2.5,
                    isDashed: true
                ))
            }
        }
        flattenedCommuterRailPolylines = commuterFlat
        
        let totalPolylines = subwayFlat.count + commuterFlat.count
        let totalPoints = subwayFlat.reduce(0) { $0 + $1.coordinates.count } + commuterFlat.reduce(0) { $0 + $1.coordinates.count }
        AppLogger.shared.log("SYSTEM_MAP", message: "Flattened \(totalPolylines) polylines (\(subwayFlat.count) subway, \(commuterFlat.count) commuter rail) with \(totalPoints) total points")
    }
    
    /// Fetches all subway stations and their served lines.
    /// Falls back to bundled offline data when network is unavailable.
    func loadStations() async {
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

    /// Syncs the local tracking state with the persisted TrackedRoute in UserDefaults.
    func syncTrackedRoute() {
        currentTrackedRoute = TrackedRoute.load()
    }

    // MARK: - Tracking Helpers

    /// Checks if a nearby arrival matches the currently tracked route.
    func isTracking(_ arrival: NearbyTransitResponse) -> Bool {
        guard let tracked = currentTrackedRoute else { return false }
        return tracked.routeId == arrival.routeId &&
               tracked.stopName == arrival.stopName &&
               tracked.direction == arrival.direction
    }

    /// Checks if a subway arrival matches the currently tracked route.
    func isTracking(_ arrival: TrainArrival) -> Bool {
        guard let tracked = currentTrackedRoute else { return false }
        return tracked.routeId == arrival.routeID &&
               tracked.stopName == arrival.stationID &&
               tracked.direction == arrival.direction
    }

    /// Checks if a bus arrival matches the currently tracked route.
    func isTracking(_ arrival: BusArrival) -> Bool {
        guard let tracked = currentTrackedRoute else { return false }
        // For bus arrivals, we strip the prefix for display/matching
        let cleanRouteId = stripMTAPrefix(arrival.routeId)
        let trackedCleanId = stripMTAPrefix(tracked.routeId)
        return cleanRouteId == trackedCleanId && tracked.stopName == arrival.stopId
    }


    // MARK: - GO Mode (Live Transit Tracking)

    /// Whether the user is in "GO" mode — passively tracking a vehicle.
    var isGoModeActive = false

    /// The route being tracked in GO mode (e.g. "L", "B63").
    var goModeRouteName: String?

    /// Route color for the tracked line in GO mode.
    var goModeRouteColor: Color?

    /// Stops the user has already passed in GO mode (for checklist dimming).
    var passedStopIds: Set<String> = []

    /// Transit ETA computed via MKDirections (minutes remaining).
    var transitEtaMinutes: Int?

    private let repository = TransitRepository()

    /// The effective location for data fetching — either the search pin or user location.
    /// If the GPS fix is outside the NYC service area, falls back to Midtown Manhattan
    /// so the app always shows MTA transit data.
    func effectiveLocation(userLocation: CLLocation?) -> CLLocation? {
        if isSearchPinActive, let pin = searchPinCoordinate {
            return CLLocation(latitude: pin.latitude, longitude: pin.longitude)
        }
        guard let location = userLocation else { return nil }
        if AppTheme.MapConfig.isInServiceArea(location.coordinate) {
            return location
        }
        // Outside NYC — fall back to Midtown Manhattan
        AppLogger.shared.log("LOCATION", message: "GPS outside service area (\(location.coordinate.latitude), \(location.coordinate.longitude)) — using NYC fallback")
        let nyc = AppTheme.MapConfig.nycCenter
        return CLLocation(latitude: nyc.latitude, longitude: nyc.longitude)
    }

    /// Refreshes the view based on current location and transport mode.
    func refresh(location: CLLocation?) async {
        isLoading = true
        errorMessage = nil

        let loc = effectiveLocation(userLocation: location)

        switch selectedMode {
        case .nearby:
            await refreshNearbyTransit(location: loc)
        case .subway:
            await refreshSubway(location: loc)
        case .bus:
            await refreshBus(location: loc)
        case .lirr:
            await refreshLIRR()
        case .mnr:
            await refreshMNR()
        }

        syncTrackedRoute()
        updateLiveActivityFromRefresh()
        isLoading = false
    }

    /// Updates the running Live Activity with fresh data from the latest refresh.
    /// This ensures the 'Other upcoming arrivals' and progress stay accurate.
    private func updateLiveActivityFromRefresh() {
        if currentTrackedRoute == nil { return }
        
        // Find matching arrival and its siblings across all possible data sources
        var foundArrival: (minutesAway: Int, destination: String, isBus: Bool)?
        var siblings: [Int] = []
        
        // 1. Check Nearby Transit (Unified)
        if let match = nearbyTransit.first(where: { isTracking($0) }) {
            foundArrival = (match.minutesAway, match.destination ?? match.direction, match.isBus)
            siblings = nearbyTransit
                .filter { $0.routeId == match.routeId && $0.direction == match.direction && $0.minutesAway > match.minutesAway }
                .map { $0.minutesAway }
                .sorted()
        } 
        // 2. Check Subway Dedicated
        else if let match = upcomingArrivals.first(where: { isTracking($0) }) {
            foundArrival = (match.minutesAway, match.direction, false)
            siblings = upcomingArrivals
                .filter { $0.direction == match.direction && $0.stationID == match.stationID && $0.minutesAway > match.minutesAway }
                .map { $0.minutesAway }
                .sorted()
        }
        // 3. Check Bus Dedicated
        else if let match = busArrivals.first(where: { isTracking($0) }) {
            let mins = match.expectedArrival.map { Int($0.timeIntervalSinceNow / 60) } ?? 0
            foundArrival = (mins, "Bus", true)
            siblings = busArrivals
                .filter { $0.routeId == match.routeId && $0.stopId == match.stopId }
                .compactMap { $0.expectedArrival }
                .map { Int($0.timeIntervalSinceNow / 60) }
                .filter { $0 > mins }
                .sorted()
        }

        guard let current = foundArrival else { return }
        
        let eta = Date().addingTimeInterval(Double(current.minutesAway) * 60)
        let progress = 1.0 - (Double(current.minutesAway) / 15.0) // Simple 15-min scale progress
        
        LiveActivityManager.shared.updateActivity(
            statusText: current.minutesAway <= 1 ? "Arriving" : "\(current.minutesAway) stops away",
            arrivalTime: eta,
            progress: max(0, min(1.0, progress)),
            stopsAway: current.minutesAway,
            nextArrivals: Array(siblings.prefix(2))
        )
    }

    // MARK: - Search Pin

    /// Activates the search pin and refreshes data for that location.
    func setSearchPin(_ coordinate: CLLocationCoordinate2D, userLocation: CLLocation?) async {
        searchPinCoordinate = coordinate
        isSearchPinActive = true
        await refresh(location: userLocation)
    }

    /// Deactivates the search pin and returns to user location.
    func clearSearchPin(userLocation: CLLocation?) async {
        isSearchPinActive = false
        searchPinCoordinate = nil
        walkingRoute = nil
        nearestStopCoordinate = nil
    }

    // MARK: - Route Detail

    /// Opens the route detail sheet for a grouped route and loads its
    /// route shape / vehicle positions on the map.
    /// Also centers the map on the nearest station and calculates walking directions.
    func selectGroupedRoute(_ group: GroupedNearbyTransitResponse, directionIndex: Int = 0, userLocation: CLLocation?) async {
        selectedGroupedRoute = group
        selectedDirectionIndex = directionIndex
        isRouteDetailPresented = true
        
        // Log route interaction to Supabase for analytics
        Task {
            await SupabaseManager.shared.logRouteInteraction(
                routeId: group.routeId,
                mode: group.isBus ? "bus" : "subway",
                type: "click"
            )
        }
        
        // Reset previous route data
        walkingRoute = nil
        nearestStopCoordinate = nil
        busVehicles = []
        routeShape = nil
        
        selectedRouteId = group.routeId

        if group.isBus {
            // Load route shape + vehicles for bus routes
            async let vehiclesTask = TrackAPI.fetchBusVehicles(routeID: group.routeId)
            async let shapeTask = TrackAPI.fetchRouteShape(routeID: group.routeId)
            
            do {
                busVehicles = try await vehiclesTask
            } catch {
                AppLogger.shared.logError("fetchBusVehicles(\(group.routeId))", error: error)
            }
            // Polling handled by HomeView.onChange(of: selectedRouteId)

            do {
                routeShape = try await shapeTask
                if let shape = routeShape {
                    // Log decoded polyline details for debugging
                    let decoded = shape.decodedPolylines
                    let totalPoints = decoded.reduce(0) { $0 + $1.count }
                    AppLogger.shared.log("BUS_SHAPE", message: "Loaded shape for \(group.routeId): \(shape.polylines.count) polylines (\(totalPoints) total points), \(shape.stops.count) stops")
                } else {
                    AppLogger.shared.log("BUS_SHAPE", message: "No shape returned for \(group.routeId)")
                }
            } catch {
                AppLogger.shared.logError("fetchRouteShape(\(group.routeId))", error: error)
            }
        } else {
            // For subway: fetch the full line geometry AND live arrivals from the backend
            do {
                async let shapeTask = TrackAPI.fetchSubwayShape(routeID: group.displayName)
                async let arrivalsTask = TrackAPI.fetchSubwayArrivals(lineID: group.displayName)
                
                routeShape = try await shapeTask
                let arrivals = try await arrivalsTask
                updateTrainPositions(arrivals: arrivals)
                
            } catch {
                AppLogger.shared.logError("fetchSubwayData(\(group.displayName))", error: error)
            }
        }
        
        // Find nearest stop and calculate walking route
        if let shape = routeShape, !shape.stops.isEmpty, let userLoc = userLocation {
            var closestStop: BusStop?
            var minDistance: CLLocationDistance = .greatestFiniteMagnitude
            
            for stop in shape.stops {
                let stopLoc = CLLocation(latitude: stop.lat, longitude: stop.lon)
                let distance = userLoc.distance(from: stopLoc)
                if distance < minDistance {
                    minDistance = distance
                    closestStop = stop
                }
            }
            
            if let closest = closestStop {
                nearestStopCoordinate = CLLocationCoordinate2D(latitude: closest.lat, longitude: closest.lon)
                
                // Fetch walking route in background
                Task {
                    await fetchWalkingRoute(from: userLoc.coordinate, to: nearestStopCoordinate!)
                }
            }
        } else if routeShape == nil || routeShape?.stops.isEmpty == true {
            // Fallback: zoom to the first arrival's stop coordinates when
            // route shape data is unavailable (common for buses when the
            // OBA API is slow or returns empty data).
            if let first = group.directions.first?.arrivals.first,
               let lat = first.stopLat, let lon = first.stopLon {
                nearestStopCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                
                if let userLoc = userLocation {
                    Task {
                        await fetchWalkingRoute(from: userLoc.coordinate, to: nearestStopCoordinate!)
                    }
                }
            }
        }
    }

    /// Returns a camera position centered on the first arrival's stop.
    func cameraPositionForRoute(_ group: GroupedNearbyTransitResponse) -> MapCameraPosition {
        if let first = group.directions.first?.arrivals.first,
           let lat = first.stopLat, let lon = first.stopLon {
            return .camera(MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                distance: 3000
            ))
        }
        return .automatic
    }

    /// Selects a specific arrival (from flat list or search) and treats it as a route selection.
    func selectArrival(_ arrival: NearbyTransitResponse, userLocation: CLLocation?) async {
        // Find if this arrival already exists in our grouped list
        if let existingGroup = groupedTransit.first(where: { $0.routeId == arrival.routeId }) {
            let dirIndex = existingGroup.directions.firstIndex(where: { $0.direction == arrival.direction }) ?? 0
            await selectGroupedRoute(existingGroup, directionIndex: dirIndex, userLocation: userLocation)
        } else {
            // Attempt to fetch fresh data for this route to get the full context (colors, directions, other arrivals)
            // If that fails or isn't implemented, we fall back to a minimal group.
            
            // Note: Currently we don't have a direct "fetch single route group" endpoint that aligns perfectly
            // with GroupedNearbyTransitResponse structure without fetching *all* nearby routes.
            // However, we can construct a better "mock" group if we had more info, or we could trigger a refresh.
            // For now, we use the minimal group to immediately show the user what they tapped, 
            // but we ensure the route logic (shape, vehicles) is triggered by selectGroupedRoute.
            
            // Create a minimal group to satisfy the unified logic
            let minimalGroup = GroupedNearbyTransitResponse(
                routeId: arrival.routeId,
                displayName: arrival.displayName,
                mode: arrival.isBus ? "bus" : "subway",
                colorHex: nil,
                directions: [
                    DirectionArrivalsResponse(
                        direction: arrival.direction,
                        arrivals: [arrival]
                    )
                ]
            )
            await selectGroupedRoute(minimalGroup, directionIndex: 0, userLocation: userLocation)
        }
    }


    /// Refreshes only the vehicle positions for the currently selected bus route.
    func refreshBusVehicles() async {
        guard let routeId = selectedRouteId, selectedMode == .bus else { return }
        do {
            let vehicles = try await TrackAPI.fetchBusVehicles(routeID: routeId)
            await MainActor.run {
                withAnimation(.linear(duration: 2.0)) {
                    self.busVehicles = vehicles
                }
            }
        } catch {
            AppLogger.shared.logError("refreshBusVehicles(\(routeId))", error: error)
        }
    }

    /// Refreshes only the vehicle positions for the currently selected subway route.
    func refreshTrainVehicles() async {
        guard let routeId = selectedRouteId else { return }
        do {
            async let arrivalsTask = TrackAPI.fetchSubwayArrivals(lineID: routeId)
            let arrivals = try await arrivalsTask
            await MainActor.run {
                withAnimation(.linear(duration: 2.0)) {
                    updateTrainPositions(arrivals: arrivals)
                }
            }
        } catch {
             // Silently ignore failures on fast poll, or log debug
        }
    }

    /// Clears the selected route and remove bus/train markers from the map.
    func clearRoute() {
        selectedRouteId = nil
        selectedDirectionIndex = 0
        busVehicles = []
        trainVehicles = []
        cachedTrainArrivals = []
        routeShape = nil
        errorMessage = nil
        nearestStopCoordinate = nil
        highlightedVehicleId = nil
        selectedStopId = nil
        walkingRoute = nil
    }

    // Cache latest arrivals to allow client-side simulation between network fetches
    private var cachedTrainArrivals: [TrainArrival] = []

    /// Re-calculates train positions based on the current time and cached arrivals.
    /// Call this frequently (e.g. every 1s) to animate trains smoothly.
    func updateSimulation() {
        guard !cachedTrainArrivals.isEmpty else { return }
        updateTrainPositions(arrivals: cachedTrainArrivals)
    }

    /// Solves for "Ghost Trains" by interpolating position between stations.
    private func updateTrainPositions(arrivals: [TrainArrival]) {
        guard let shape = routeShape else { return }
        self.cachedTrainArrivals = arrivals
        
        // 1. Group arrivals by UNIQUE trip.
        // If tripId is missing, fallback to crude grouping by (Direction + roughly same times)
        // But for now, let's rely on tripId or make a synthetic one.
        var trips: [String: [TrainArrival]] = [:]
        
        for arrival in arrivals {
            let key = arrival.tripId ?? "\(arrival.direction)-\(arrival.destination ?? "unk")-\(arrival.scheduledTime.timeIntervalSince1970)"
            trips[key, default: []].append(arrival)
        }
        
        var newVehicles: [TrainVehicle] = []
        
        // 2. Process each trip to find its "current location"
        for (tripId, tripArrivals) in trips {
            // Sort by time (using estimatedTime for sub-minute precision)
            let sorted = tripArrivals.sorted { $0.estimatedTime < $1.estimatedTime }
            
            // The train is approaching the stop with the smallest POSITIVE time until arrival.
            // Since we animate, `timeIntervalSinceNow` might become slightly negative just as it arrives.
            // Allow a small buffer (e.g. -30s) to keep displaying it arriving at the station before switching to next stop.
            guard let nextStop = sorted.first(where: { $0.estimatedTime.timeIntervalSinceNow > -30 }) else { continue }
            
            // Find this stop in the route shape
            // Note: stop IDs in shape might differ (N vs S suffix).
            // We strip direction suffix for matching.
            let nextStopIdBase = nextStop.stationID.prefix(3)
            
            guard let nextStopIndex = shape.stops.firstIndex(where: { $0.id.hasPrefix(nextStopIdBase) }) else {
               continue
            }
            
            // Determine position
            var lat = shape.stops[nextStopIndex].lat
            var lon = shape.stops[nextStopIndex].lon
            var bearing: Double = 0
            
            // If we can find the previous stop, interpolate!
            // Approaching means it's 'minutesAway' minutes from 'nextStop'.
            // Assume 3 minutes avg travel time between stations.
            let previousIndex = nextStopIndex > 0 ? nextStopIndex - 1 : nextStopIndex
            let nextIndex = nextStopIndex
            
            // Only interpolate if we have a valid previous stop
            if previousIndex != nextIndex {
                let prevStop = shape.stops[previousIndex]
                let targetStop = shape.stops[nextIndex]
                
                // Heuristic: If it's > 4 mins away, assume it's at the previous station (or further back)
                // If it's 0 mins, it's at the target.
                // Interpolation factor t: 0 (at target) to 1 (at previous)
                // Use refined calculation: nextStop.estimatedTime - now
                let timeUntilArrival = nextStop.estimatedTime.timeIntervalSinceNow
                let minutes = timeUntilArrival / 60.0
                
                let travelTime = 3.0 // Assume 3 mins between stops
                let t = min(max(minutes / travelTime, 0.0), 1.0)
                
                // Interpolation
                // t goes from 1 (previous stop) to 0 (target stop).
                
                if AppSettings.shared.simulationEasingEnabled {
                    // Easing: Accelerate out, Decelerate in
                    // normalized progress p = 1.0 - t (0.0 at start, 1.0 at end)
                    let p = 1.0 - t
                    let easedP = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
                    let effectiveT = 1.0 - easedP
                    
                    lat = targetStop.lat * (1.0 - effectiveT) + prevStop.lat * effectiveT
                    lon = targetStop.lon * (1.0 - effectiveT) + prevStop.lon * effectiveT
                } else {
                    // Linear: Constant speed
                    lat = targetStop.lat * (1.0 - t) + prevStop.lat * t
                    lon = targetStop.lon * (1.0 - t) + prevStop.lon * t
                }
                
                // Calculate bearing from prev to target
                bearing = atan2(targetStop.lon - prevStop.lon, targetStop.lat - prevStop.lat) * 180 / .pi
                if bearing < 0 { bearing += 360 }
            }
            
            newVehicles.append(TrainVehicle(
                id: tripId,
                tripId: tripId, // Use the dictionary key as the tripId
                routeId: nextStop.routeID,
                direction: nextStop.direction,
                lat: lat,
                lon: lon,
                bearing: bearing,
                nextStationName: shape.stops[nextStopIndex].name
            ))
        }
        
        withAnimation(.linear(duration: 1.1)) {
            self.trainVehicles = newVehicles
        }
    }

    // MARK: - Nearby Transit (Unified)

    /// Search radius (meters) used for the wider "nearest metro" fallback.
    private static let nearestMetroRadius = AppSettings.shared.nearestMetroFallbackRadiusMeters

    /// Fetches all nearby transit (buses + trains) in one call.
    /// Uses the grouped endpoint to deduplicate routes.
    /// When no results are found within the default radius, fetches
    /// with a wider radius and exposes the closest stop as ``nearestTransit``.
    func refreshNearbyTransit(location: CLLocation?) async {
        guard let location = location else {
            errorMessage = "Location required"
            return
        }

        isLoading = true
        errorMessage = nil
        nearestTransit = nil
        nearestTransitDistance = nil

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        do {
            async let flatTask = TrackAPI.fetchNearbyTransit(lat: lat, lon: lon)
            async let groupedTask = TrackAPI.fetchNearbyGrouped(lat: lat, lon: lon)
            async let alertsTask = TrackAPI.fetchAlerts()
            async let accessTask = TrackAPI.fetchAccessibility()

            nearbyTransit = try await flatTask
            groupedTransit = try await groupedTask

            // Fetch alerts and accessibility silently — don't fail the whole refresh
            do { serviceAlerts = try await alertsTask } catch {}
            do { elevatorOutages = try await accessTask } catch {}
            

        } catch {
            AppLogger.shared.logError("fetchNearbyTransit", error: error)
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
        }

        // If no nearby transit found, search a wider radius for a recommendation
        if nearbyTransit.isEmpty && groupedTransit.isEmpty && errorMessage == nil {
            await fetchNearestMetro(location: location)
        }

        isLoading = false
    }



    /// Searches a wider radius to find the nearest metro stop when
    /// the default radius returns empty results.
    private func fetchNearestMetro(location: CLLocation) async {
        do {
            let results = try await TrackAPI.fetchNearbyTransit(
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude,
                radius: Self.nearestMetroRadius
            )
            guard let closest = results.first else { return }
            nearestTransit = closest

            // Compute distance from user to the stop
            if let stopLat = closest.stopLat, let stopLon = closest.stopLon {
                let stopLocation = CLLocation(latitude: stopLat, longitude: stopLon)
                nearestTransitDistance = location.distance(from: stopLocation)
            }
        } catch {
            AppLogger.shared.logError("fetchNearestMetro", error: error)
        }
    }

    // MARK: - Subway

    private func refreshSubway(location: CLLocation?) async {
        nearbyBusStops = []
        busArrivals = []
        selectedBusStop = nil

        if let location = location {
            do {
                nearbyStations = try await repository.fetchNearbyStations(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
            } catch {
                AppLogger.shared.logError("fetchNearbyStations", error: error)
                errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
            }
        }

        let lineID = nearbyStations.first?.routeIDs.first ?? "L"
        do {
            upcomingArrivals = try await repository.fetchArrivals(for: lineID)
            
        } catch {
            AppLogger.shared.logError("fetchArrivals(\(lineID))", error: error)
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
        }
    }


    // MARK: - Bus

    private func refreshBus(location: CLLocation?) async {
        nearbyStations = []
        upcomingArrivals = []
        lirrArrivals = []

        guard let location = location else {
            errorMessage = "Location required for bus stops"
            return
        }

        do {
            async let stopsTask = TrackAPI.fetchNearbyBusStops(
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude
            )
            async let routesTask = TrackAPI.fetchBusRoutes()

            nearbyBusStops = try await stopsTask

            // Bus routes fetched silently — don't fail the whole refresh
            do { allBusRoutes = try await routesTask } catch {}
        } catch {
            AppLogger.shared.logError("fetchNearbyBusStops", error: error)
        }

        if let firstStop = nearbyBusStops.first {
            await fetchBusArrivals(for: firstStop)
        }
    }
    


    /// Fetches live bus arrivals for a specific stop.
    func fetchBusArrivals(for stop: BusStop) async {
        selectedBusStop = stop
        do {
            busArrivals = try await TrackAPI.fetchBusArrivals(stopID: stop.id)
        } catch {
            AppLogger.shared.logError("fetchBusArrivals(\(stop.id))", error: error)
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
        }
    }
    


    // MARK: - LIRR

    private func refreshLIRR() async {
        nearbyStations = []
        upcomingArrivals = []
        nearbyBusStops = []
        busArrivals = []
        selectedBusStop = nil
        mnrArrivals = []

        do {
            lirrArrivals = try await TrackAPI.fetchLIRRArrivals()
        } catch {
            AppLogger.shared.logError("fetchLIRRArrivals", error: error)
            errorMessage = (error as? TrackAPIError)?.description ?? error.localizedDescription
        }

        // Fetch alerts and accessibility alongside LIRR
        do { serviceAlerts = try await TrackAPI.fetchAlerts() } catch {}
        do { elevatorOutages = try await TrackAPI.fetchAccessibility() } catch {}
    }

    // MARK: - Metro-North

    private func refreshMNR() async {
        nearbyStations = []
        upcomingArrivals = []
        nearbyBusStops = []
        busArrivals = []
        selectedBusStop = nil
        lirrArrivals = []

        do {
            mnrArrivals = try await TrackAPI.fetchMNRArrivals()
        } catch {
            AppLogger.shared.logError("fetchMNRArrivals", error: error)
            errorMessage = (error as? TrackAPIError)?.description ?? error.localizedDescription
        }

        // Fetch alerts and accessibility alongside MNR
        do { serviceAlerts = try await TrackAPI.fetchAlerts() } catch {}
        do { elevatorOutages = try await TrackAPI.fetchAccessibility() } catch {}
    }

    /// Starts tracking a nearby transit arrival via Widget.
    func trackNearbyArrival(_ arrival: NearbyTransitResponse, location: CLLocation?) {
        // Log track interaction to Supabase for analytics
        Task {
            await SupabaseManager.shared.logRouteInteraction(
                routeId: arrival.routeId,
                mode: arrival.isBus ? "bus" : "subway",
                type: "track"
            )
        }
        
        // Save to TrackedRoute for Single Route Widget
        let trackedRoute = TrackedRoute(
            routeId: arrival.routeId,
            displayName: arrival.displayName,
            stopName: arrival.stopName,
            direction: arrival.direction,
            destination: arrival.destination,
            mode: arrival.isBus ? "bus" : "subway",
            trackedAt: Date()
        )
        currentTrackedRoute = trackedRoute
        trackedRoute.save()
        
        // Update visual highlighting on the map
        if arrival.isBus {
            self.highlightedVehicleId = arrival.vehicleId
            AppLogger.shared.log("TRACKING", message: "Highlighting bus vehicle: \(arrival.vehicleId ?? "none")")
        } else {
            self.highlightedVehicleId = arrival.tripId
            AppLogger.shared.log("TRACKING", message: "Highlighting train trip: \(arrival.tripId ?? "none")")
        }
        
        // Immediately refresh the Live Activity
        updateLiveActivityFromRefresh()
        
        // Update local state and reload widgets
        WidgetCenter.shared.reloadAllTimelines()
        
        // Start Live Activity
        let eta = Date().addingTimeInterval(Double(arrival.minutesAway) * 60)
        
        // Find sibling arrivals for the "Other upcoming trains" section
        let nextArrivals = (groupedTransit.first(where: { $0.routeId == arrival.routeId })?
            .directions.first(where: { $0.direction == arrival.direction })?
            .arrivals.filter { $0.minutesAway > arrival.minutesAway }
            .map { $0.minutesAway }
            .sorted() ?? [])
            .prefix(2)

        LiveActivityManager.shared.startActivity(
            lineId: arrival.routeId,
            destination: arrival.destination ?? arrival.direction,
            arrivalTime: eta,
            isBus: arrival.isBus,
            nextArrivals: Array(nextArrivals)
        )
    }

    /// Starts tracking a subway arrival.
    func trackSubwayArrival(_ arrival: TrainArrival, location: CLLocation?) {
        // Log track interaction to Supabase for analytics
        Task {
            await SupabaseManager.shared.logRouteInteraction(
                routeId: arrival.routeID,
                mode: "subway",
                type: "track"
            )
        }
        
        let trackedRoute = TrackedRoute(
            routeId: arrival.routeID,
            displayName: arrival.routeID,
            stopName: arrival.stationID,
            direction: arrival.direction,
            destination: nil,
            mode: "subway",
            trackedAt: Date()
        )
        trackedRoute.save()
        
        currentTrackedRoute = trackedRoute
        WidgetCenter.shared.reloadAllTimelines()

        // Start Live Activity
        let eta = Date().addingTimeInterval(Double(arrival.minutesAway) * 60)
        
        // Find sibling arrivals for the "Other upcoming trains" section
        let nextArrivals = upcomingArrivals
            .filter { $0.direction == arrival.direction && $0.stationID == arrival.stationID && $0.minutesAway > arrival.minutesAway }
            .map { $0.minutesAway }
            .sorted()
            .prefix(2)

        LiveActivityManager.shared.startActivity(
            lineId: arrival.routeID,
            destination: arrival.direction,
            arrivalTime: eta,
            isBus: false,
            nextArrivals: Array(nextArrivals)
        )
    }

    /// Starts tracking a bus arrival.
    func trackBusArrival(_ arrival: BusArrival, location: CLLocation?) {
        // Log track interaction to Supabase for analytics
        Task {
            await SupabaseManager.shared.logRouteInteraction(
                routeId: arrival.routeId,
                mode: "bus",
                type: "track"
            )
        }
        
        let trackedRoute = TrackedRoute(
            routeId: arrival.routeId,
            displayName: stripMTAPrefix(arrival.routeId),
            stopName: arrival.stopId,
            direction: "",
            destination: nil,
            mode: "bus",
            trackedAt: Date()
        )
        trackedRoute.save()
        
        currentTrackedRoute = trackedRoute
        WidgetCenter.shared.reloadAllTimelines()

        // Start Live Activity
        let arrivalTime = arrival.expectedArrival ?? Date().addingTimeInterval(300)
        
        // Find sibling arrivals for the "Other upcoming trains" section
        let nextArrivals = busArrivals
            .filter { $0.routeId == arrival.routeId && $0.stopId == arrival.stopId }
            .compactMap { $0.expectedArrival }
            .filter { $0 > arrivalTime }
            .map { Int($0.timeIntervalSinceNow / 60) }
            .sorted()
            .prefix(2)

        LiveActivityManager.shared.startActivity(
            lineId: stripMTAPrefix(arrival.routeId),
            destination: "Bus Tracking",
            arrivalTime: arrivalTime,
            isBus: true,
            nextArrivals: Array(nextArrivals)
        )
    }

    /// Starts tracking an LIRR arrival.
    func trackLIRRArrival(_ arrival: TrainArrival, location: CLLocation?) {
        trackRailArrival(arrival, location: location, agency: "lirr")
    }

    /// Starts tracking a Metro-North arrival.
    func trackMNRArrival(_ arrival: TrainArrival, location: CLLocation?) {
        trackRailArrival(arrival, location: location, agency: "mnr")
    }

    /// Generic rail arrival tracking (LIRR & MNR).
    private func trackRailArrival(_ arrival: TrainArrival, location: CLLocation?, agency: String) {
        // Log track interaction to Supabase for analytics
        Task {
            await SupabaseManager.shared.logRouteInteraction(
                routeId: arrival.routeID,
                mode: agency,
                type: "track"
            )
        }
        
        let trackedRoute = TrackedRoute(
            routeId: arrival.routeID,
            displayName: arrival.routeID,
            stopName: arrival.stationID,
            direction: arrival.direction,
            destination: nil,
            mode: agency,
            trackedAt: Date()
        )
        trackedRoute.save()
        
        currentTrackedRoute = trackedRoute
        WidgetCenter.shared.reloadAllTimelines()

        // Start Live Activity
        let eta = Date().addingTimeInterval(Double(arrival.minutesAway) * 60)
        
        // Find sibling arrivals for the "Other upcoming trains" section
        let agencyArrivals = agency == "lirr" ? lirrArrivals : mnrArrivals
        let nextArrivals = agencyArrivals
            .filter { $0.direction == arrival.direction && $0.stationID == arrival.stationID && $0.minutesAway > arrival.minutesAway }
            .map { $0.minutesAway }
            .sorted()
            .prefix(2)

        LiveActivityManager.shared.startActivity(
            lineId: arrival.routeID,
            destination: arrival.direction,
            arrivalTime: eta,
            isBus: false,
            nextArrivals: Array(nextArrivals)
        )
    }

    /// Stops tracking and clears widget tracking.
    func stopTracking() {
        currentTrackedRoute = nil
        // Clear tracked route from widget
        TrackedRoute.clear()
        WidgetCenter.shared.reloadAllTimelines()
        
        // End Live Activity
        LiveActivityManager.shared.endActivity()
    }

    // MARK: - GO Mode (Live Transit Tracking)

    /// Activates "GO" mode for the currently selected route.
    ///
    /// GO mode replaces the standard blue dot with a pulsing vehicle icon
    /// that snaps to the route polyline. The map auto-pans to follow the
    /// user's position and dims already-passed stops.
    ///
    /// Inspired by the Transit app's hands-free tracking experience.
    func activateGoMode(routeName: String, routeColor: Color) {
        isGoModeActive = true
        goModeRouteName = routeName
        goModeRouteColor = routeColor
        passedStopIds = []
    }

    /// Deactivates "GO" mode and returns to the normal map view.
    func deactivateGoMode() {
        isGoModeActive = false
        goModeRouteName = nil
        goModeRouteColor = nil
        passedStopIds = []
        transitEtaMinutes = nil
    }

    /// Marks a stop as passed (dimmed in the checklist). Called when
    /// the user's GPS position moves beyond a stop along the route.
    func markStopPassed(_ stopId: String) {
        passedStopIds.insert(stopId)
    }

    /// Returns whether a stop has been passed in GO mode.
    func isStopPassed(_ stop: BusStop) -> Bool {
        passedStopIds.contains(stop.id)
    }

    /// Distance threshold (meters) for marking a stop as passed.
    /// When the user is within this radius of a stop, it is dimmed.
    private static let stopPassedThreshold: CLLocationDistance = AppSettings.shared.stopPassedThresholdMeters

    /// Updates the list of passed stops based on the user's current
    /// position and bearing relative to the route shape stops.
    ///
    /// A stop is marked as passed if the user is within
    /// ``stopPassedThreshold`` meters **and** the user's heading
    /// indicates they are moving away from the stop (or they have
    /// already been marked once).
    func updatePassedStops(userLocation: CLLocation?) {
        guard isGoModeActive, let loc = userLocation, let shape = routeShape else { return }
        let userBearing = loc.course  // -1 if unavailable
        for stop in shape.stops {
            // Already passed — skip
            if passedStopIds.contains(stop.id) { continue }

            let stopLoc = CLLocation(latitude: stop.lat, longitude: stop.lon)
            let distance = loc.distance(from: stopLoc)

            guard distance < Self.stopPassedThreshold else { continue }

            if userBearing >= 0 {
                // Use bearing to confirm the stop is behind the user
                let bearingToStop = loc.bearing(to: stopLoc)
                let angleDiff = abs(userBearing - bearingToStop)
                let normalized = angleDiff > 180 ? 360 - angleDiff : angleDiff
                // If the stop is more than 90° behind, mark as passed
                if normalized > 90 {
                    passedStopIds.insert(stop.id)
                }
            } else {
                // No bearing data — fall back to proximity only
                passedStopIds.insert(stop.id)
            }
        }
    }

    // MARK: - Transit ETA via MKDirections

    /// Uses ``MKDirections`` with ``MKDirectionsTransportType.transit`` to
    /// estimate the time of arrival from the user's current position to
    /// a destination coordinate.
    ///
    /// Reference: https://developer.apple.com/documentation/mapkit/mkdirections
    ///
    /// - Parameters:
    ///   - from: User's current location.
    ///   - to: Destination coordinate (e.g. a bus stop or station).
    func fetchTransitETA(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async {
        // MKPlacemark is deprecated in iOS 26.0
        let sourceItem = MKMapItem(location: CLLocation(latitude: source.latitude, longitude: source.longitude), address: nil)
        let destItem = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)

        let request = MKDirections.Request()
        request.source = sourceItem
        request.destination = destItem
        request.transportType = .transit

        let directions = MKDirections(request: request)
        do {
            let eta = try await directions.calculateETA()
            let minutes = Int(eta.expectedTravelTime / 60)
            transitEtaMinutes = minutes
        } catch {
            AppLogger.shared.logError("Transit ETA calculation", error: error)
            // Transit directions may not be available in all areas — fail silently
            transitEtaMinutes = nil
        }
    }
    
    // MARK: - Walking Route
    
    /// Fetches walking directions from user to a destination and stores the route polyline.
    func fetchWalkingRoute(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async {
        let sourceItem = MKMapItem(location: CLLocation(latitude: source.latitude, longitude: source.longitude), address: nil)
        let destItem = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        
        let request = MKDirections.Request()
        request.source = sourceItem
        request.destination = destItem
        request.transportType = .walking
        
        let directions = MKDirections(request: request)
        do {
            let response = try await directions.calculate()
            if let route = response.routes.first {
                await MainActor.run {
                    self.walkingRoute = route
                }
            }
        } catch {
            AppLogger.shared.logError("Walking route calculation", error: error)
            await MainActor.run {
                self.walkingRoute = nil
            }
        }
    }
}
