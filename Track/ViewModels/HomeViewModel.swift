//
//  HomeViewModel.swift
//  Track
//
//  ViewModel for the HomeView. Fetches nearby transit arrivals
//  (both subway and bus) from the TrackAPI backend based on the
//  user's current location or a draggable search pin.
//  Shows a unified live transit feed with bus tracking on the map.
//

import CoreLocation
import Foundation
import MapKit
import SwiftData
import SwiftUI
import WidgetKit

@Observable
@MainActor
final class HomeViewModel {
    var nearbyStations: [(stationID: String, name: String, distance: Double, routeIDs: [String])] =
        []
    var upcomingArrivals: [TrainArrival] = []
    var isLoading = false
    var errorMessage: String?

    /// The currently tracked route for the widget, loaded from UserDefaults.
    var currentTrackedRoute: TrackedRoute? = nil

    // MARK: - Search

    /// User-entered search text for filtering transit results.
    var searchText = ""

    // MARK: - Search Helpers

    /// Checks whether a `GroupedNearbyTransitResponse` matches the given query.
    /// Searches display name, route ID, directions, arrival stop names,
    /// destination names, AND all stations served by the route.
    private func groupMatchesQuery(
        _ group: GroupedNearbyTransitResponse, query: String, stationRoutes: Set<String>
    ) -> Bool {
        // Match by route display name or ID
        group.displayName.lowercased().contains(query)
            || group.routeId.lowercased().contains(query)
            // Match by direction, stop name, or destination name
            || group.directions.contains { direction in
                direction.direction.lowercased().contains(query)
                    || direction.arrivals.contains {
                        $0.stopName.lowercased().contains(query)
                            || ($0.destination?.lowercased().contains(query) ?? false)
                    }
            }
            // Match if this route serves any station matching the query
            || stationRoutes.contains(group.displayName)
            || stationRoutes.contains(group.routeId)
    }

    /// Returns the set of route names that serve stations matching the query.
    /// Computed once per search to avoid O(n²) lookups.
    private func stationRoutesForQuery(_ query: String) -> Set<String> {
        Set(
            cachedStations
                .filter { $0.name.lowercased().contains(query) }
                .flatMap { $0.routes }
        )
    }

    /// Grouped transit results filtered by the current search query.
    /// Returns all results when the search text is empty.
    /// Searches route names, directions, current arrival stops, destinations,
    /// AND all stations served by the route.
    var filteredGroupedTransit: [GroupedNearbyTransitResponse] {
        guard !searchText.isEmpty else { return groupedTransit }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return groupedTransit.filter {
            groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// LIRR arrivals filtered by search text.
    /// Searches route ID, station ID, station name, direction, and destination.
    var filteredLIRRArrivals: [TrainArrival] {
        guard !searchText.isEmpty else { return lirrArrivals }
        let query = searchText.lowercased()
        return lirrArrivals.filter { arrival in
            arrival.routeID.lowercased().contains(query)
                || arrival.stationID.lowercased().contains(query)
                || arrival.stationName.lowercased().contains(query)
                || arrival.direction.lowercased().contains(query)
                || (arrival.destination?.lowercased().contains(query) ?? false)
        }
    }

    /// Metro-North arrivals filtered by search text.
    /// Searches route ID, station ID, station name, direction, and destination.
    var filteredMNRArrivals: [TrainArrival] {
        guard !searchText.isEmpty else { return mnrArrivals }
        let query = searchText.lowercased()
        return mnrArrivals.filter { arrival in
            arrival.routeID.lowercased().contains(query)
                || arrival.stationID.lowercased().contains(query)
                || arrival.stationName.lowercased().contains(query)
                || arrival.direction.lowercased().contains(query)
                || (arrival.destination?.lowercased().contains(query) ?? false)
        }
    }

    /// Subway arrivals filtered by search text.
    var filteredSubwayArrivals: [TrainArrival] {
        guard !searchText.isEmpty else { return upcomingArrivals }
        let query = searchText.lowercased()
        return upcomingArrivals.filter { arrival in
            arrival.routeID.lowercased().contains(query)
                || arrival.stationID.lowercased().contains(query)
                || arrival.stationName.lowercased().contains(query)
                || arrival.direction.lowercased().contains(query)
                || (arrival.destination?.lowercased().contains(query) ?? false)
        }
    }

    /// Bus arrivals filtered by search text.
    /// Searches both the full routeId, stopId, destination, and the status text.
    var filteredBusArrivals: [BusArrival] {
        guard !searchText.isEmpty else { return busArrivals }
        let query = searchText.lowercased()
        return busArrivals.filter { arrival in
            arrival.routeId.lowercased().contains(query)
                || arrival.stopId.lowercased().contains(query)
                || arrival.statusText.lowercased().contains(query)
                || (arrival.destinationName?.lowercased().contains(query) ?? false)
        }
    }

    /// Bus stops filtered by search text.
    var filteredBusStops: [BusStop] {
        guard !searchText.isEmpty else { return nearbyBusStops }
        let query = searchText.lowercased()
        return nearbyBusStops.filter { stop in
            stop.name.lowercased().contains(query)
                || stop.id.lowercased().contains(query)
        }
    }

    /// Grouped bus arrivals filtered by search text (from the nearby/grouped API).
    var filteredNearbyGroupedBusArrivals: [GroupedNearbyTransitResponse] {
        guard !searchText.isEmpty else { return nearbyGroupedBusArrivals }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return nearbyGroupedBusArrivals.filter {
            groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// Grouped subway arrivals filtered by search text (from the nearby/grouped API).
    var filteredNearbyGroupedSubwayArrivals: [GroupedNearbyTransitResponse] {
        guard !searchText.isEmpty else { return nearbyGroupedSubwayArrivals }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return nearbyGroupedSubwayArrivals.filter {
            groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// Nearby stations filtered by search text.
    var filteredNearbyStations:
        [(stationID: String, name: String, distance: Double, routeIDs: [String])]
    {
        guard !searchText.isEmpty else { return nearbyStations }
        let query = searchText.lowercased()
        return nearbyStations.filter { station in
            station.name.lowercased().contains(query)
                || station.routeIDs.contains { $0.lowercased().contains(query) }
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

    /// Helper: Groups `TrainArrival` arrays into `GroupedNearbyTransitResponse`.
    /// Works for subway, LIRR, and Metro-North.
    private func groupTrainArrivals(_ arrivals: [TrainArrival], mode: String)
        -> [GroupedNearbyTransitResponse]
    {
        // Filter out stale arrivals (minutesAway == 0 with past timestamps)
        let liveArrivals = arrivals.filter { $0.minutesAway > 0 || $0.estimatedTime > Date() }

        // Group by route_id — for LIRR/MNR prefix the raw numeric ID
        var byRoute: [String: [TrainArrival]] = [:]
        for arrival in liveArrivals {
            let key: String
            switch mode {
            case "lirr":
                key =
                    arrival.routeID.hasPrefix("LIRR_") ? arrival.routeID : "LIRR_\(arrival.routeID)"
            case "mnr":
                key = arrival.routeID.hasPrefix("MNR_") ? arrival.routeID : "MNR_\(arrival.routeID)"
            default:
                key = arrival.routeID
            }
            byRoute[key, default: []].append(arrival)
        }

        return byRoute.map { routeId, routeArrivals in
            // Sub-group by direction
            var byDirection: [String: [TrainArrival]] = [:]
            for arrival in routeArrivals {
                let dirLabel = arrival.destination ?? arrival.direction
                byDirection[dirLabel, default: []].append(arrival)
            }

            let directions = byDirection.map {
                direction, dirArrivals -> DirectionArrivalsResponse in
                let nearbyArrivals =
                    dirArrivals
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

            // Resolve display name: use branch name lookup for commuter rail
            let displayName = Self.resolveDisplayName(routeId: routeId, mode: mode)

            return GroupedNearbyTransitResponse(
                routeId: routeId,
                displayName: displayName,
                mode: mode,
                colorHex: colorHex,
                directions: directions
            )
        }.sorted { $0.soonestMinutes < $1.soonestMinutes }
    }

    /// Maps a LIRR/MNR route_id (e.g. "LIRR_9") to a human-readable branch name
    /// (e.g. "Port Washington Branch"). Falls back to stripMTAPrefix for subway/bus.
    private static let lirrBranchNames: [String: String] = [
        "1": "Babylon Branch",
        "2": "Hempstead Branch",
        "3": "Oyster Bay Branch",
        "4": "Ronkonkoma Branch",
        "5": "Montauk Branch",
        "6": "Long Beach Branch",
        "7": "Far Rockaway Branch",
        "8": "West Hempstead Branch",
        "9": "Port Washington Branch",
        "10": "Port Jefferson Branch",
        "11": "Belmont Park",
        "12": "City Terminal Zone",
        "13": "Greenport Service",
    ]

    private static let mnrLineNames: [String: String] = [
        "1": "Hudson Line",
        "2": "Harlem Line",
        "3": "New Haven Line",
        "4": "New Canaan Line",
        "5": "Danbury Line",
        "6": "Waterbury Line",
    ]

    static func resolveDisplayName(routeId: String, mode: String) -> String {
        if mode == "lirr" {
            let numeric = routeId.hasPrefix("LIRR_") ? String(routeId.dropFirst(5)) : routeId
            return lirrBranchNames[numeric] ?? stripMTAPrefix(routeId)
        }
        if mode == "mnr" {
            let numeric = routeId.hasPrefix("MNR_") ? String(routeId.dropFirst(4)) : routeId
            return mnrLineNames[numeric] ?? stripMTAPrefix(routeId)
        }
        return stripMTAPrefix(routeId)
    }

    // Bus mode
    var selectedMode: TransportMode = .nearby
    var nearbyBusStops: [BusStop] = []
    var busArrivals: [BusArrival] = []
    var selectedBusStop: BusStop?

    // Grouped bus arrivals fetched from the nearby/grouped API (bus-only)
    var nearbyGroupedBusArrivals: [GroupedNearbyTransitResponse] = []

    // Grouped subway arrivals fetched from the nearby/grouped API (subway-only)
    var nearbyGroupedSubwayArrivals: [GroupedNearbyTransitResponse] = []

    // Grouped LIRR arrivals fetched from the nearby/grouped API (lirr-only)
    var nearbyGroupedLIRRArrivals: [GroupedNearbyTransitResponse] = []

    // Grouped MNR arrivals fetched from the nearby/grouped API (mnr-only)
    var nearbyGroupedMNRArrivals: [GroupedNearbyTransitResponse] = []

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
    var alertsLastUpdated: Date?
    var elevatorOutages: [ElevatorStatus] = []

    /// Fetch alerts from the API and deliver local notifications for new ones.
    func refreshAlerts() async {
        do {
            serviceAlerts = try await TrackAPI.fetchAlerts()
            alertsLastUpdated = Date()
            AlertNotificationManager.shared.processAlerts(serviceAlerts)
        } catch {}
    }

    // Route detail sheet
    var selectedGroupedRoute: GroupedNearbyTransitResponse?
    var selectedDirectionIndex: Int = 0 {
        didSet {
            rebuildCachedPolylines()
            rebuildDirectionalSplit()
        }
    }
    var isRouteDetailPresented = false

    // Draggable search pin
    var searchPinCoordinate: CLLocationCoordinate2D?
    var isSearchPinActive = false

    // Walking route to the nearest station (forwarded from goMode)
    var nearestStopCoordinate: CLLocationCoordinate2D? {
        didSet { rebuildDirectionalSplit() }
    }
    var selectedStopId: String?

    // Live bus/train tracking on map
    var selectedRouteId: String?
    var highlightedVehicleId: String?
    /// Coordinate of the tracked vehicle/arrival for map zoom-to-center.
    /// Set by `trackNearbyArrival` so the View can animate the camera.
    var trackedVehicleCoordinate: CLLocationCoordinate2D?
    /// Vehicle/trip ID tapped on the map — used to highlight and expand the
    /// matching arrival row in the RouteDetailSheet.
    /// The ID of the currently expanded arrival row in the flat list.
    /// Used to enforce single-row expansion.
    var selectedExpandedArrivalID: String? = nil

    /// Validates the vehicle ID currently selected on the map.
    var tappedVehicleId: String? {
        didSet {
            // When map selection changes, auto-expand the corresponding row
            guard let id = tappedVehicleId else { return }

            // Find the best matching arrival to expand
            // prioritize exact vehicle ID match
            if let match = nearbyTransit.first(where: { $0.vehicleId == id || $0.tripId == id }) {
                // Only change if not already selected to avoid animation glitches
                if selectedExpandedArrivalID != match.id {
                    withAnimation {
                        selectedExpandedArrivalID = match.id
                    }
                }
            }
        }
    }

    /// Toggles the expansion state for a given arrival ID.
    func toggleArrivalExpansion(_ id: String) {
        withAnimation {
            if selectedExpandedArrivalID == id {
                selectedExpandedArrivalID = nil
            } else {
                selectedExpandedArrivalID = id
            }
        }
    }
    var busVehicles: [BusVehicleResponse] = []

    struct TrainVehicle: Identifiable, Equatable {
        let id: String
        let tripId: String?
        let routeId: String
        let direction: String
        var lat: Double
        var lon: Double
        var bearing: Double?
        var nextStationName: String?
        /// Minutes until arrival at the next station, derived from GTFS-RT.
        var minutesAway: Int?
    }
    var trainVehicles: [TrainVehicle] = []

    // Smooth bus interpolation state — stores the previous GPS snapshot
    // so we can glide between updates along the route polyline.
    struct BusSnapshot {
        let lat: Double
        let lon: Double
        let timestamp: Date
    }
    /// Previous GPS positions keyed by vehicle ID for smooth interpolation.
    var previousBusPositions: [String: BusSnapshot] = [:]
    /// When the last bus GPS batch arrived (for elapsed-time calculation).
    var lastBusUpdateTime: Date = .distantPast

    var routeShape: RouteShapeResponse? {
        didSet {
            rebuildCachedPolylines()
            rebuildDirectionalSplit()
        }
    }

    /// Pre-decoded polylines for the currently selected route direction.
    /// Invalidated and rebuilt when `routeShape` or `selectedDirectionIndex` changes
    /// so the map never decodes encoded strings during render.
    private(set) var cachedRoutePolylines: [[CLLocationCoordinate2D]] = []

    /// Single combined polyline for vehicle interpolation (bus simulation / train positions).
    /// Invalidated and rebuilt alongside `cachedRoutePolylines`.
    private(set) var cachedInterpolationPolyline: [CLLocationCoordinate2D] = []

    /// Rebuilds the cached decoded polylines from the current route shape and direction.
    private func rebuildCachedPolylines() {
        guard let shape = routeShape else {
            cachedRoutePolylines = []
            cachedInterpolationPolyline = []
            return
        }
        let groupDirCount = selectedGroupedRoute?.directions.count ?? 0
        let shouldFilter = !shape.directions.isEmpty && groupDirCount > 1

        cachedRoutePolylines =
            shouldFilter
            ? shape.polylinesForDirection(selectedDirectionIndex)
            : shape.decodedPolylines

        // Build a single continuous polyline for interpolation.
        // Prefer direction-filtered segments; fall back to all polylines
        // when the filtered set has too few points (e.g. single-direction routes).
        let combined = cachedRoutePolylines.flatMap { $0 }
        if combined.count >= 2 {
            cachedInterpolationPolyline = combined
        } else {
            let all = shape.decodedPolylines.flatMap { $0 }
            cachedInterpolationPolyline = all.count >= 2 ? all : []
        }
    }

    /// Cached polyline split at the nearest stop: `ahead` keeps full color, `behind` fades.
    /// Pre-computed when inputs change to avoid O(n) distance calculations (where n = number
    /// of polyline points) during every SwiftUI view render cycle.
    private(set) var directionalSplit: (ahead: [CLLocationCoordinate2D], behind: [CLLocationCoordinate2D])?

    /// Rebuilds the cached directional split from current state.
    /// Called when `routeShape`, `nearestStopCoordinate`, or `selectedDirectionIndex` changes.
    private func rebuildDirectionalSplit() {
        guard let nearestCoord = nearestStopCoordinate,
            !cachedInterpolationPolyline.isEmpty,
            let shape = routeShape
        else {
            directionalSplit = nil
            return
        }

        let polyline = cachedInterpolationPolyline

        // Find the closest point on the polyline to the nearest stop
        let nearestLoc = CLLocation(
            latitude: nearestCoord.latitude, longitude: nearestCoord.longitude)
        var closestIdx = 0
        var minDist: CLLocationDistance = .greatestFiniteMagnitude
        for (i, coord) in polyline.enumerated() {
            let d = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                .distance(from: nearestLoc)
            if d < minDist {
                minDist = d
                closestIdx = i
            }
        }

        let splitIdx = max(0, min(closestIdx, polyline.count - 1))

        // stopsForDirection handles the subway fallback from
        // directions[x].stops → top-level stops automatically
        let dirStops = shape.stopsForDirection(selectedDirectionIndex)
        guard !dirStops.isEmpty else {
            directionalSplit = nil
            return
        }

        // Determine polyline flow direction relative to stop ordering
        let firstStopLoc = CLLocation(latitude: dirStops[0].lat, longitude: dirStops[0].lon)
        let firstPolyLoc = CLLocation(
            latitude: polyline[0].latitude, longitude: polyline[0].longitude)
        let lastPolyLoc = CLLocation(
            latitude: polyline.last!.latitude, longitude: polyline.last!.longitude)
        let polyFlowsWithStops =
            firstPolyLoc.distance(from: firstStopLoc)
            <= lastPolyLoc.distance(from: firstStopLoc)

        let beforeSplit = Array(polyline[0...splitIdx])
        let afterSplit = Array(polyline[splitIdx...])

        if polyFlowsWithStops {
            // Polyline flows first→last stop. Before the split = already passed.
            directionalSplit = (ahead: afterSplit, behind: beforeSplit)
        } else {
            directionalSplit = (ahead: beforeSplit, behind: afterSplit)
        }
    }

    // MARK: - Direction-Filtered Vehicles

    /// Bus vehicles filtered to the currently selected direction.
    /// Uses the SIRI `directionRef` (0/1) to match `selectedDirectionIndex`.
    /// Falls back to showing all vehicles if direction data is unavailable.
    var filteredBusVehicles: [BusVehicleResponse] {
        guard let group = selectedGroupedRoute,
            group.directions.count > 1
        else {
            return busVehicles  // single direction → show all
        }
        let filtered = busVehicles.filter { $0.directionRef == selectedDirectionIndex }
        // If no vehicles matched (directionRef missing from backend), show all
        return filtered.isEmpty && !busVehicles.isEmpty ? busVehicles : filtered
    }

    /// Train vehicles filtered to the currently selected direction.
    /// Subway directions use "N"/"S" (or destination names); we match by
    /// checking the direction string of the arrivals in the selected group,
    /// and also map compass codes to ensure GTFS-RT "N"/"S" values match.
    var filteredTrainVehicles: [TrainVehicle] {
        guard let group = selectedGroupedRoute,
            group.directions.count > 1
        else {
            return trainVehicles  // single direction → show all
        }
        let safeIdx = min(selectedDirectionIndex, group.directions.count - 1)
        let selectedDir = group.directions[safeIdx]

        // Collect all direction strings that belong to this direction tab
        // (the direction field, plus any arrival directions/destinations)
        var validDirs = Set<String>()
        validDirs.insert(selectedDir.direction.uppercased())
        for arrival in selectedDir.arrivals {
            validDirs.insert(arrival.direction.uppercased())
            if let dest = arrival.destination {
                validDirs.insert(dest.uppercased())
            }
        }

        // Map compass codes ↔ directional labels so GTFS-RT "N"/"S" values
        // match grouped API labels like "Northbound", "Uptown", etc.
        let compassExpansions: [String: [String]] = [
            "N": ["NORTHBOUND", "UPTOWN"],
            "S": ["SOUTHBOUND", "DOWNTOWN"],
            "E": ["EASTBOUND"],
            "W": ["WESTBOUND"],
            "NE": ["NORTHBOUND", "EASTBOUND"],
            "NW": ["NORTHBOUND", "WESTBOUND"],
            "SE": ["SOUTHBOUND", "EASTBOUND"],
            "SW": ["SOUTHBOUND", "WESTBOUND"],
        ]
        let reverseCompass: [String: String] = [
            "NORTHBOUND": "N", "UPTOWN": "N",
            "SOUTHBOUND": "S", "DOWNTOWN": "S",
            "EASTBOUND": "E", "WESTBOUND": "W",
        ]
        // Expand existing compass codes and add reverse mappings
        for dir in Array(validDirs) {
            if let expansions = compassExpansions[dir] {
                for e in expansions { validDirs.insert(e) }
            }
            if let code = reverseCompass[dir] {
                validDirs.insert(code)
            }
        }

        // Bridge grouped API destination names with GTFS compass codes.
        // The grouped API uses destination names (e.g. "Flushing-Main St")
        // while GTFS-RT vehicles use compass codes ("N"/"S"). When validDirs
        // only contains destination names, the compass expansion above has
        // nothing to work with. Use the route shape's direction data to find
        // which GTFS direction_id corresponds to the selected tab, then map
        // direction_id to the standard GTFS compass convention.
        let hasCompassCode =
            validDirs.contains("N") || validDirs.contains("S")
            || validDirs.contains("E") || validDirs.contains("W")
        if !hasCompassCode, let shape = routeShape, !shape.directions.isEmpty {
            // Try matching the selected direction's name against shape headsigns
            let selectedName = selectedDir.direction.uppercased()
            if let matchedShape = shape.directions.first(where: {
                $0.headsign.uppercased() == selectedName
                    || selectedName.contains($0.headsign.uppercased())
                    || $0.headsign.uppercased().contains(selectedName)
            }) {
                // GTFS convention: direction_id 0 = southbound, 1 = northbound
                let compassCode = matchedShape.directionId == 0 ? "S" : "N"
                validDirs.insert(compassCode)
                if let expansions = compassExpansions[compassCode] {
                    for e in expansions { validDirs.insert(e) }
                }
            } else {
                // No headsign match — fall back to positional mapping.
                // The selected direction tab index often aligns with
                // shape direction order.
                let shapeIdx = min(safeIdx, shape.directions.count - 1)
                let dirId = shape.directions[shapeIdx].directionId
                let compassCode = dirId == 0 ? "S" : "N"
                validDirs.insert(compassCode)
                if let expansions = compassExpansions[compassCode] {
                    for e in expansions { validDirs.insert(e) }
                }
            }
        }

        let filtered = trainVehicles.filter { vehicle in
            validDirs.contains(vehicle.direction.uppercased())
        }
        return filtered
    }

    // MARK: - Sub-ViewModels

    /// System map data (subway/LIRR/MNR polylines and stations).
    /// Loaded once at startup; the View reads directly from this sub-ViewModel.
    let mapSystem = MapSystemViewModel()

    /// GO Mode (live transit tracking) state and logic.
    let goMode = GoModeViewModel()

    // MARK: - Type Aliases (backward compatibility)

    typealias CachedSubwayStation = MapSystemViewModel.CachedSubwayStation
    typealias FlattenedMapPolyline = MapSystemViewModel.FlattenedMapPolyline
    typealias CachedTransitLine = MapSystemViewModel.CachedTransitLine

    // MARK: - System Map Forwarding (backward compatibility)

    /// Forwarding properties so existing views can still use `viewModel.flattenedSubwayPolylines`, etc.
    var flattenedSubwayPolylines: [MapSystemViewModel.FlattenedMapPolyline] {
        mapSystem.flattenedSubwayPolylines
    }
    var flattenedCommuterRailPolylines: [MapSystemViewModel.FlattenedMapPolyline] {
        mapSystem.flattenedCommuterRailPolylines
    }
    var cachedStations: [MapSystemViewModel.CachedSubwayStation] {
        mapSystem.cachedStations
    }

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
        // System map and stations are now loaded by MapSystemViewModel
    }

    /// Syncs the local tracking state with the persisted TrackedRoute in UserDefaults.
    func syncTrackedRoute() {
        currentTrackedRoute = TrackedRoute.load()
    }

    // MARK: - Tracking Helpers

    /// Checks if a nearby arrival matches the currently tracked route.
    func isTracking(_ arrival: NearbyTransitResponse) -> Bool {
        guard let tracked = currentTrackedRoute else { return false }
        return tracked.routeId == arrival.routeId && tracked.stopName == arrival.stopName
            && tracked.direction == arrival.direction
    }

    /// Checks if a subway arrival matches the currently tracked route.
    func isTracking(_ arrival: TrainArrival) -> Bool {
        guard let tracked = currentTrackedRoute else { return false }
        return tracked.routeId == arrival.routeID && tracked.stopName == arrival.stationID
            && tracked.direction == arrival.direction
    }

    /// Checks if a bus arrival matches the currently tracked route.
    func isTracking(_ arrival: BusArrival) -> Bool {
        guard let tracked = currentTrackedRoute else { return false }
        // For bus arrivals, we strip the prefix for display/matching
        let cleanRouteId = stripMTAPrefix(arrival.routeId)
        let trackedCleanId = stripMTAPrefix(tracked.routeId)
        return cleanRouteId == trackedCleanId && tracked.stopName == arrival.stopId
    }

    /// Returns the map-marker key for an arrival — the same identifier
    /// the map uses for `tappedVehicleId`. Bus vehicles use `vehicleId`;
    /// trains use `tripId` (falling back to `vehicleId`).
    /// Returns nil when the arrival has no live vehicle on the map.
    func vehicleKeyForArrival(_ arrival: NearbyTransitResponse) -> String? {
        if arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty,
            busVehicles.contains(where: { $0.vehicleId == vid })
        {
            return vid
        }
        if !arrival.isBus {
            if let tid = arrival.tripId, !tid.isEmpty,
                trainVehicles.contains(where: { $0.tripId == tid })
            {
                return tid
            }
            if let vid = arrival.vehicleId, !vid.isEmpty,
                trainVehicles.contains(where: { $0.id == vid })
            {
                return vid
            }
        }
        return nil
    }

    /// Returns the coordinate of a tapped vehicle marker (bus or train) by its ID.
    /// Used by HomeView to zoom/center the map on the tapped marker.
    func coordinateForTappedVehicle(_ vehicleId: String) -> CLLocationCoordinate2D? {
        // Check bus vehicles
        if let bus = busVehicles.first(where: { $0.vehicleId == vehicleId }) {
            return CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
        }
        // Check train vehicles (by tripId or id)
        if let train = trainVehicles.first(where: { $0.tripId == vehicleId || $0.id == vehicleId })
        {
            return CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
        }
        return nil
    }

    /// Finds the map coordinate for a tracked arrival.
    /// Looks up the live vehicle position first (bus by vehicleId, train by tripId);
    /// falls back to the arrival's stop lat/lon if no live vehicle is found.
    /// Works for all modes: subway, bus, LIRR, Metro-North.
    func coordinateForTrackedArrival(_ arrival: NearbyTransitResponse) -> CLLocationCoordinate2D? {
        // 1. Try to find a live bus vehicle by vehicleId
        if arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty {
            if let vehicle = busVehicles.first(where: { $0.vehicleId == vid }) {
                return CLLocationCoordinate2D(latitude: vehicle.lat, longitude: vehicle.lon)
            }
        }

        // 2. Try to find a live train vehicle by tripId
        if !arrival.isBus, let tripId = arrival.tripId, !tripId.isEmpty {
            if let train = trainVehicles.first(where: { $0.tripId == tripId }) {
                return CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
            }
        }

        // 3. Try to find a train vehicle by vehicleId
        if !arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty {
            if let train = trainVehicles.first(where: { $0.id == vid }) {
                return CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
            }
        }

        // 4. Fall back to the stop's coordinates
        if let lat = arrival.stopLat, let lon = arrival.stopLon {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        return nil
    }

    /// Returns true if the arrival has a live vehicle currently on the map.
    /// Checks bus vehicles by vehicleId and train vehicles by tripId/vehicleId.
    /// Works for all modes: subway, bus, LIRR, Metro-North.
    func isVehicleLiveOnMap(_ arrival: NearbyTransitResponse) -> Bool {
        if arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty {
            return busVehicles.contains(where: { $0.vehicleId == vid })
        }
        if !arrival.isBus {
            if let tripId = arrival.tripId, !tripId.isEmpty {
                if trainVehicles.contains(where: { $0.tripId == tripId }) { return true }
            }
            if let vid = arrival.vehicleId, !vid.isEmpty {
                if trainVehicles.contains(where: { $0.id == vid }) { return true }
            }
        }
        return false
    }

    // MARK: - GO Mode Forwarding (backward compatibility)

    var isGoModeActive: Bool { goMode.isGoModeActive }
    var goModeRouteName: String? { goMode.goModeRouteName }
    var goModeRouteColor: Color? { goMode.goModeRouteColor }
    var passedStopIds: Set<String> { goMode.passedStopIds }
    var transitEtaMinutes: Int? { goMode.transitEtaMinutes }
    var walkingRoute: MKRoute? { goMode.walkingRoute }

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
        AppLogger.shared.log(
            "LOCATION",
            message:
                "GPS outside service area (\(location.coordinate.latitude), \(location.coordinate.longitude)) — using NYC fallback"
        )
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
            siblings =
                nearbyTransit
                .filter {
                    $0.routeId == match.routeId && $0.direction == match.direction
                        && $0.minutesAway > match.minutesAway
                }
                .map { $0.minutesAway }
                .sorted()
        }
        // 2. Check Subway Dedicated
        else if let match = upcomingArrivals.first(where: { isTracking($0) }) {
            foundArrival = (match.minutesAway, match.direction, false)
            siblings =
                upcomingArrivals
                .filter {
                    $0.direction == match.direction && $0.stationID == match.stationID
                        && $0.minutesAway > match.minutesAway
                }
                .map { $0.minutesAway }
                .sorted()
        }
        // 3. Check Bus Dedicated
        else if let match = busArrivals.first(where: { isTracking($0) }) {
            let mins = match.expectedArrival.map { Int($0.timeIntervalSinceNow / 60) } ?? 0
            foundArrival = (mins, "Bus", true)
            siblings =
                busArrivals
                .filter { $0.routeId == match.routeId && $0.stopId == match.stopId }
                .compactMap { $0.expectedArrival }
                .map { Int($0.timeIntervalSinceNow / 60) }
                .filter { $0 > mins }
                .sorted()
        }

        if let current = foundArrival {
            let eta = Date().addingTimeInterval(Double(current.minutesAway) * 60)
            let progress = 1.0 - (Double(current.minutesAway) / 15.0)  // Simple 15-min scale progress

            LiveActivityManager.shared.updateActivity(
                statusText: current.minutesAway <= 1
                    ? "Arriving" : "\(current.minutesAway) stops away",
                arrivalTime: eta,
                progress: max(0, min(1.0, progress)),
                stopsAway: current.minutesAway,
                nextArrivals: Array(siblings.prefix(2))
            )
        } else {
            // Fallback: If no arrival is found (e.g. train just left and next one not yet in feed),
            // keep the widget alive and indicate we're waiting for the next one.
            // Do NOT end the activity; let the next refresh pick up the new train.
            LiveActivityManager.shared.updateActivity(
                statusText: "Waiting for next train...",
                arrivalTime: Date().addingTimeInterval(300),  // 5 min buffer to keep widget alive
                progress: 0.0,
                stopsAway: nil,
                nextArrivals: []
            )
        }
    }

    // MARK: - Search Pin

    /// Activates the search pin and refreshes data for that location.
    /// The `userLocation` parameter is only used as a fallback — once
    /// `isSearchPinActive` is set, `effectiveLocation` will always
    /// return the pin coordinate for all subsequent operations.
    ///
    /// Uses a fast-path refresh that skips global feeds (alerts,
    /// accessibility) since those don't change by location.
    func setSearchPin(_ coordinate: CLLocationCoordinate2D, userLocation: CLLocation?) async {
        searchPinCoordinate = coordinate
        isSearchPinActive = true
        // Fast-path: only fetch location-dependent transit data
        let loc = effectiveLocation(userLocation: userLocation)
        await refreshNearbyTransit(location: loc, skipGlobalFeeds: true)
        syncTrackedRoute()
    }

    /// Deactivates the search pin and returns to user location.
    /// Clears stale transit data so the dashboard shows a loading state
    /// instead of results from the drag-search location (which would
    /// appear as "nothing in your area" since those stops are far away).
    func clearSearchPin(userLocation: CLLocation?) async {
        isSearchPinActive = false
        searchPinCoordinate = nil
        goMode.walkingRoute = nil
        nearestStopCoordinate = nil
        // Clear stale data to avoid showing drag-search results
        // measured against the real GPS (wrong distances)
        groupedTransit = []
        nearbyTransit = []
        nearestTransit = nil
        nearestTransitDistance = nil
    }

    // MARK: - Route Detail

    /// Opens the route detail sheet for a grouped route and loads its
    /// route shape / vehicle positions on the map.
    /// Also centers the map on the nearest station and calculates walking directions.
    func selectGroupedRoute(
        _ group: GroupedNearbyTransitResponse, directionIndex: Int = 0, userLocation: CLLocation?
    ) async {
        selectedGroupedRoute = group
        selectedDirectionIndex = directionIndex
        isRouteDetailPresented = true

        // Log route interaction to Supabase for analytics
        Task {
            await SupabaseManager.shared.logRouteInteraction(
                routeId: group.routeId,
                mode: group.mode,
                type: "click"
            )
        }

        // Reset previous route data
        goMode.walkingRoute = nil
        nearestStopCoordinate = nil
        busVehicles = []
        trainVehicles = []
        cachedTrainArrivals = []
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
                    AppLogger.shared.log(
                        "BUS_SHAPE",
                        message:
                            "Loaded shape for \(group.routeId): \(shape.polylines.count) polylines (\(totalPoints) total points), \(shape.stops.count) stops"
                    )

                    // Enrich the grouped route with any missing directions from the shape.
                    // The nearby API only returns directions for stops near the user,
                    // but the route shape knows ALL directions (e.g. both inbound & outbound).
                    enrichGroupWithShapeDirections(shape)
                } else {
                    AppLogger.shared.log(
                        "BUS_SHAPE", message: "No shape returned for \(group.routeId)")
                }
            } catch {
                AppLogger.shared.logError("fetchRouteShape(\(group.routeId))", error: error)
            }
        } else if group.isLIRR {
            // LIRR: fetch the branch-specific polyline + live arrivals
            do {
                async let shapeTask = TrackAPI.fetchLIRRShape(routeID: group.routeId)
                async let arrivalsTask = TrackAPI.fetchLIRRArrivals()

                routeShape = try await shapeTask
                populateStopsFromArrivals(group: group)
                AppLogger.shared.log(
                    "LIRR_SHAPE",
                    message: "Loaded shape for \(group.routeId) (\(group.displayName))")
                if let shape = routeShape { enrichGroupWithShapeDirections(shape) }

                // Filter arrivals to this specific branch and interpolate
                let allArrivals = try await arrivalsTask
                let routeArrivals = allArrivals.filter { arrival in
                    let id = arrival.routeID.lowercased()
                    let target = group.routeId.lowercased()
                    return id == target
                        || id == target.replacingOccurrences(of: "lirr_", with: "")
                        || "lirr_\(id)" == target
                }
                updateTrainPositions(arrivals: routeArrivals)
            } catch {
                AppLogger.shared.logError("fetchLIRRData(\(group.routeId))", error: error)
            }
        } else if group.isMNR {
            // Metro-North: fetch the line-specific polyline + live arrivals
            do {
                async let shapeTask = TrackAPI.fetchMNRShape(routeID: group.routeId)
                async let arrivalsTask = TrackAPI.fetchMNRArrivals()

                routeShape = try await shapeTask
                populateStopsFromArrivals(group: group)
                AppLogger.shared.log(
                    "MNR_SHAPE", message: "Loaded shape for \(group.routeId) (\(group.displayName))"
                )
                if let shape = routeShape { enrichGroupWithShapeDirections(shape) }

                // Filter arrivals to this specific line and interpolate
                let allArrivals = try await arrivalsTask
                let routeArrivals = allArrivals.filter { arrival in
                    let id = arrival.routeID.lowercased()
                    let target = group.routeId.lowercased()
                    return id == target
                        || id == target.replacingOccurrences(of: "mnr_", with: "")
                        || "mnr_\(id)" == target
                }
                updateTrainPositions(arrivals: routeArrivals)
            } catch {
                AppLogger.shared.logError("fetchMNRData(\(group.routeId))", error: error)
            }
        } else {
            // For subway: fetch the full line geometry AND live arrivals from the backend
            do {
                async let shapeTask = TrackAPI.fetchSubwayShape(routeID: group.displayName)
                async let arrivalsTask = TrackAPI.fetchSubwayArrivals(lineID: group.displayName)

                routeShape = try await shapeTask
                let arrivals = try await arrivalsTask
                updateTrainPositions(arrivals: arrivals)
                if let shape = routeShape { enrichGroupWithShapeDirections(shape) }

            } catch {
                AppLogger.shared.logError("fetchSubwayData(\(group.displayName))", error: error)
            }
        }

        // Find nearest stop and calculate walking route.
        // Use effectiveLocation so drag-to-search computes distances
        // from the explored center, not the user's real GPS position.
        let refLocation = effectiveLocation(userLocation: userLocation)
        let allStops = routeShape?.stopsForDirection(selectedDirectionIndex) ?? []
        if !allStops.isEmpty, let userLoc = refLocation {
            var closestStop: BusStop?
            var minDistance: CLLocationDistance = .greatestFiniteMagnitude

            for stop in allStops {
                let stopLoc = CLLocation(latitude: stop.lat, longitude: stop.lon)
                let distance = userLoc.distance(from: stopLoc)
                if distance < minDistance {
                    minDistance = distance
                    closestStop = stop
                }
            }

            if let closest = closestStop {
                let closestCoord = CLLocationCoordinate2D(
                    latitude: closest.lat, longitude: closest.lon)
                nearestStopCoordinate = closestCoord

                // Fetch walking route in background
                let from = userLoc.coordinate
                Task { await fetchWalkingRoute(from: from, to: closestCoord) }
            }
        } else if allStops.isEmpty {
            // Fallback: zoom to the first arrival's stop coordinates when
            // route shape data is unavailable (common for buses when the
            // OBA API is slow or returns empty data).
            if let first = group.directions.first?.arrivals.first,
                let lat = first.stopLat, let lon = first.stopLon
            {
                let fallbackCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                nearestStopCoordinate = fallbackCoord

                if let userLoc = refLocation {
                    let from = userLoc.coordinate
                    Task { await fetchWalkingRoute(from: from, to: fallbackCoord) }
                }
            }
        }

        // After loading shape and vehicles, check if we need schedule data
        // for directions with no live buses
        if group.isBus {
            await fetchBusScheduleIfNeeded()
        }
    }

    /// Populates the route shape's empty `stops` array from the group's arrival
    /// data. Commuter rail (LIRR/MNR) backends don't include stops in the shape
    /// response, but each arrival carries its stop coordinates. This synthesizes
    /// BusStop objects so the map can show stop markers and the camera zoom logic
    /// can find the nearest stop.
    private func populateStopsFromArrivals(group: GroupedNearbyTransitResponse) {
        guard var shape = routeShape, shape.stops.isEmpty else { return }

        var seenIds = Set<String>()
        var synthesized: [BusStop] = []

        for direction in group.directions {
            for arrival in direction.arrivals {
                guard let lat = arrival.stopLat, let lon = arrival.stopLon else { continue }
                // Use stopId when available; fall back to a composite key
                // of name + coordinates to avoid dedup collisions when
                // different physical stops share the same name.
                let stopId = arrival.stopId ?? "\(arrival.stopName)_\(lat)_\(lon)"
                guard !seenIds.contains(stopId) else { continue }
                seenIds.insert(stopId)
                synthesized.append(
                    BusStop(
                        id: stopId,
                        name: arrival.stopName,
                        lat: lat,
                        lon: lon,
                        direction: nil
                    ))
            }
        }

        if !synthesized.isEmpty {
            shape.stops = synthesized
            routeShape = shape
        }
    }

    /// Enriches the currently selected grouped route with any directions
    /// present in the route shape data but missing from the nearby API response.
    ///
    /// The `/nearby/grouped` endpoint only includes directions that have live
    /// arrivals at stops near the user. However, the route shape knows about
    /// ALL directions (e.g. both inbound and outbound). This method adds
    /// placeholder direction entries so the direction picker shows every
    /// direction the route serves — even if no arrivals are nearby right now.
    ///
    /// Works for all transit modes (bus, subway, LIRR, MNR).
    private func enrichGroupWithShapeDirections(_ shape: RouteShapeResponse) {
        guard let group = selectedGroupedRoute, !shape.directions.isEmpty else { return }

        let existingCount = group.directions.count

        // Build a new directions array ordered by shape direction_id.
        // For each shape direction, either find the matching existing group
        // direction or create a placeholder. This guarantees group index N
        // maps to shape direction_id N.
        var orderedDirections: [DirectionArrivalsResponse] = []
        var usedExistingIndices = Set<Int>()

        for shapeDir in shape.directions.sorted(by: { $0.directionId < $1.directionId }) {
            let headsign = shapeDir.headsign.lowercased()

            // Try to find a matching existing group direction
            var matchedIndex: Int? = nil
            for (idx, existingDir) in group.directions.enumerated()
            where !usedExistingIndices.contains(idx) {
                let existingLower = existingDir.direction.lowercased()

                let exactMatch = !headsign.isEmpty && existingLower == headsign
                let partialMatch =
                    !headsign.isEmpty
                    && (existingLower.contains(headsign) || headsign.contains(existingLower))
                let destMatch =
                    !headsign.isEmpty
                    && existingDir.arrivals.contains(where: { arrival in
                        guard let dest = arrival.destination?.lowercased() else { return false }
                        return dest.contains(headsign) || headsign.contains(dest)
                    })

                if exactMatch || partialMatch || destMatch {
                    matchedIndex = idx
                    break
                }
            }

            if let idx = matchedIndex {
                orderedDirections.append(group.directions[idx])
                usedExistingIndices.insert(idx)
            } else {
                // Create a placeholder for this missing direction
                let directionString =
                    shapeDir.headsign.isEmpty
                    ? "Direction \(shapeDir.directionId)"
                    : shapeDir.headsign
                orderedDirections.append(
                    DirectionArrivalsResponse(
                        direction: directionString,
                        directionLabel: shapeDir.headsign.isEmpty ? nil : "→ \(shapeDir.headsign)",
                        arrivals: []
                    ))
            }
        }

        // Append any existing directions that didn't match any shape direction
        // (e.g. backfilled compass directions from the nearby API)
        for (idx, dir) in group.directions.enumerated() where !usedExistingIndices.contains(idx) {
            orderedDirections.append(dir)
        }

        // Only update if we added directions or reordered them
        let changed =
            orderedDirections.count != existingCount
            || zip(orderedDirections, group.directions).contains(where: {
                $0.direction != $1.direction
            })

        if changed {
            selectedGroupedRoute = GroupedNearbyTransitResponse(
                routeId: group.routeId,
                displayName: group.displayName,
                mode: group.mode,
                colorHex: group.colorHex,
                directions: orderedDirections
            )
            AppLogger.shared.log(
                "ROUTE_DETAIL",
                message:
                    "Enriched \(group.displayName) from \(existingCount) → \(orderedDirections.count) directions (ordered by shape direction_id)"
            )
        }
    }

    /// Returns a camera position centered on the first arrival's stop.
    func cameraPositionForRoute(_ group: GroupedNearbyTransitResponse) -> MapCameraPosition {
        if let first = group.directions.first?.arrivals.first,
            let lat = first.stopLat, let lon = first.stopLon
        {
            return .camera(
                MapCamera(
                    centerCoordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    distance: 3000
                ))
        }
        return .automatic
    }

    /// Computes a camera position that fits the entire route shape on screen,
    /// including the user's location when available. Works for all modes:
    /// subway, bus, LIRR, and Metro-North.
    func cameraPositionFittingRoute(userLocation: CLLocation?, is3D: Bool) -> MapCameraPosition? {
        guard let shape = routeShape else { return nil }

        // Use the effective location (search pin when drag-to-search is active)
        // so the map fits the route relative to where the user is exploring.
        let refLocation = effectiveLocation(userLocation: userLocation)

        // Collect all coordinates: polyline points + stop locations
        var allCoords: [CLLocationCoordinate2D] = []

        // Use direction-specific polylines when a direction is selected
        let group = selectedGroupedRoute
        let hasDirections = (group?.directions.count ?? 0) > 1
        let polylines: [[CLLocationCoordinate2D]]
        if hasDirections, !shape.directions.isEmpty {
            polylines = shape.polylinesForDirection(selectedDirectionIndex)
        } else {
            polylines = shape.decodedPolylines
        }

        for coords in polylines {
            allCoords.append(contentsOf: coords)
        }

        // Also include stop coordinates as a fallback anchor
        let stops = hasDirections ? shape.stopsForDirection(selectedDirectionIndex) : shape.stops
        for stop in stops {
            allCoords.append(CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon))
        }

        guard !allCoords.isEmpty else { return nil }

        // Compute bounding box of route geometry ONLY (without user location)
        var minLat = allCoords[0].latitude
        var maxLat = allCoords[0].latitude
        var minLon = allCoords[0].longitude
        var maxLon = allCoords[0].longitude

        for coord in allCoords {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }

        // Include effective location so the map shows both you (or your search center) and the route
        if let loc = refLocation?.coordinate {
            allCoords.append(loc)
        }

        // Recompute bounding box WITH user location
        var fullMinLat = allCoords[0].latitude
        var fullMaxLat = allCoords[0].latitude
        var fullMinLon = allCoords[0].longitude
        var fullMaxLon = allCoords[0].longitude

        for coord in allCoords {
            fullMinLat = min(fullMinLat, coord.latitude)
            fullMaxLat = max(fullMaxLat, coord.latitude)
            fullMinLon = min(fullMinLon, coord.longitude)
            fullMaxLon = max(fullMaxLon, coord.longitude)
        }

        // Check if including the user location pushes the span beyond max zoom.
        // If the full span (route + user) exceeds max altitude but the route-only
        // span is within limits, center on the nearest stop instead of trying
        // to fit both user and route endpoints across the city.
        let fullLatSpan = (fullMaxLat - fullMinLat) * 111_000
        let fullCenterLat = (fullMinLat + fullMaxLat) / 2
        let fullLonSpan = (fullMaxLon - fullMinLon) * 111_000 * cos(fullCenterLat * .pi / 180)
        let fullSpanMeters = max(fullLatSpan, fullLonSpan)
        let fullPadded = fullSpanMeters * AppSettings.shared.smartZoomPaddingMultiplier

        let routeLatSpan = (maxLat - minLat) * 111_000
        let routeCenterLat = (minLat + maxLat) / 2
        let routeLonSpan = (maxLon - minLon) * 111_000 * cos(routeCenterLat * .pi / 180)
        let routeSpanMeters = max(routeLatSpan, routeLonSpan)
        let routePadded = routeSpanMeters * AppSettings.shared.smartZoomPaddingMultiplier

        // If the route+user span exceeds max zoom, just fit the route itself.
        // If even the route alone exceeds max zoom (very long route like LIRR),
        // center on the nearest stop at max zoom.
        let useRouteOnly = fullPadded > AppSettings.shared.smartZoomMaxAltitude

        let center: CLLocationCoordinate2D
        let distance: Double

        if useRouteOnly && routePadded > AppSettings.shared.smartZoomMaxAltitude {
            // Route itself is too long (e.g. LIRR spanning Manhattan → Montauk).
            // Center on the nearest stop to the effective location (search pin
            // when drag-to-search is active, otherwise the user's GPS).
            if let refLoc = refLocation,
                let nearest = stops.min(by: {
                    let d1 = CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: refLoc)
                    let d2 = CLLocation(latitude: $1.lat, longitude: $1.lon).distance(from: refLoc)
                    return d1 < d2
                })
            {
                center = CLLocationCoordinate2D(latitude: nearest.lat, longitude: nearest.lon)
            } else if let refLoc = refLocation {
                // No stops available (e.g. commuter rail) — stay near the
                // user's current location instead of zooming to the geometric
                // center of a 100-mile route, which would be confusing.
                center = refLoc.coordinate
            } else {
                // No stops AND no user location — don't zoom at all.
                return nil
            }
            distance = AppSettings.shared.smartZoomMaxAltitude
        } else if useRouteOnly {
            // Route fits within max zoom but user location is too far away.
            // Just fit the route without the user location.
            center = CLLocationCoordinate2D(
                latitude: routeCenterLat, longitude: (minLon + maxLon) / 2)
            distance = max(
                AppSettings.shared.smartZoomMinAltitude,
                min(routePadded, AppSettings.shared.smartZoomMaxAltitude)
            )
        } else {
            // Everything fits — use the full bounding box including user location.
            center = CLLocationCoordinate2D(
                latitude: fullCenterLat, longitude: (fullMinLon + fullMaxLon) / 2)
            distance = max(
                AppSettings.shared.smartZoomMinAltitude,
                min(fullPadded, AppSettings.shared.smartZoomMaxAltitude)
            )
        }

        return .camera(
            MapCamera(
                centerCoordinate: center,
                distance: distance,
                heading: 0,
                pitch: is3D ? 60 : 0
            ))
    }

    // MARK: - Route Selection and Refresh
    /// Selects a specific arrival (from flat list or search) and treats it as a route selection.
    func selectArrival(_ arrival: NearbyTransitResponse, userLocation: CLLocation?) async {
        // Find if this arrival already exists in our grouped list
        if let existingGroup = groupedTransit.first(where: { $0.routeId == arrival.routeId }) {
            let dirIndex =
                existingGroup.directions.firstIndex(where: { $0.direction == arrival.direction })
                ?? 0
            await selectGroupedRoute(
                existingGroup, directionIndex: dirIndex, userLocation: userLocation)
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
                mode: arrival.mode,
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
    /// Stores the previous positions for smooth polyline-based interpolation.
    func refreshBusVehicles() async {
        guard let routeId = selectedRouteId,
            selectedGroupedRoute?.isBus == true
        else { return }
        do {
            let vehicles = try await TrackAPI.fetchBusVehicles(routeID: routeId)
            await MainActor.run {
                // Snapshot current positions before overwriting so that
                // updateBusSimulation() can interpolate between old → new.
                if self.busVehicles.isEmpty {
                    // First fetch: seed snapshots from the new data so
                    // interpolation can start on the very next GPS cycle
                    // instead of waiting for a second fetch.
                    for v in vehicles {
                        previousBusPositions[v.vehicleId] = BusSnapshot(
                            lat: v.lat, lon: v.lon, timestamp: Date()
                        )
                    }
                } else {
                    for v in self.busVehicles {
                        previousBusPositions[v.vehicleId] = BusSnapshot(
                            lat: v.lat, lon: v.lon, timestamp: self.lastBusUpdateTime
                        )
                    }
                }
                self.lastBusUpdateTime = Date()
                self.busVehicles = vehicles
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
                withAnimation(.interpolatingSpring(stiffness: 30, damping: 15)) {
                    updateTrainPositions(arrivals: arrivals)
                }
            }
        } catch {
            // Silently ignore failures on fast poll, or log debug
        }
    }

    /// Refreshes vehicle positions for the currently selected LIRR or MNR route.
    /// Uses the same GTFS-RT arrivals → interpolation pipeline as subway.
    func refreshCommuterRailVehicles() async {
        guard let group = selectedGroupedRoute,
            group.isCommuterRail
        else { return }
        do {
            let arrivals: [TrainArrival]
            if group.isLIRR {
                arrivals = try await TrackAPI.fetchLIRRArrivals()
            } else {
                arrivals = try await TrackAPI.fetchMNRArrivals()
            }
            // Filter to only this route's arrivals
            let routeArrivals = arrivals.filter { arrival in
                let id = arrival.routeID.lowercased()
                let target = group.routeId.lowercased()
                // Match both "LIRR_9" and bare "9" forms
                return id == target
                    || id == target.replacingOccurrences(of: "lirr_", with: "")
                    || id == target.replacingOccurrences(of: "mnr_", with: "")
                    || "lirr_\(id)" == target
                    || "mnr_\(id)" == target
            }
            await MainActor.run {
                withAnimation(.interpolatingSpring(stiffness: 30, damping: 15)) {
                    updateTrainPositions(arrivals: routeArrivals)
                }
            }
        } catch {
            AppLogger.shared.logError("refreshCommuterRailVehicles", error: error)
        }
    }

    // MARK: - Bus Schedule

    /// Cached bus schedule for the currently selected bus route.
    var busSchedule: BusScheduleResponse?

    /// Fetches the schedule for the currently selected bus route.
    /// Used to show scheduled departures when no live buses are running.
    func fetchBusScheduleIfNeeded() async {
        guard let group = selectedGroupedRoute, group.isBus else { return }
        do {
            busSchedule = try await TrackAPI.fetchBusSchedule(routeID: group.routeId)
        } catch {
            AppLogger.shared.logError("fetchBusSchedule(\(group.routeId))", error: error)
            busSchedule = nil
        }
    }

    /// Clears the selected route and remove bus/train markers from the map.
    func clearRoute() {
        selectedRouteId = nil
        selectedDirectionIndex = 0
        busVehicles = []
        trainVehicles = []
        cachedTrainArrivals = []
        previousBusPositions = [:]
        lastBusUpdateTime = .distantPast
        routeShape = nil
        errorMessage = nil
        nearestStopCoordinate = nil
        highlightedVehicleId = nil
        trackedVehicleCoordinate = nil
        tappedVehicleId = nil
        selectedStopId = nil
        goMode.walkingRoute = nil
        busSchedule = nil
    }

    // Cache latest arrivals to allow client-side simulation between network fetches
    private(set) var cachedTrainArrivals: [TrainArrival] = []

    /// Re-calculates train positions based on the current time and cached arrivals.
    /// Call this frequently (e.g. every 1s) to animate trains smoothly.
    func updateSimulation() {
        guard !cachedTrainArrivals.isEmpty else { return }
        updateTrainPositions(arrivals: cachedTrainArrivals)
    }

    /// Interpolates bus positions along the route polyline between GPS fetches.
    /// Called every tick (1s) for smooth movement between the 10s GPS refresh.
    func updateBusSimulation() {
        guard !busVehicles.isEmpty, routeShape != nil else { return }
        let elapsed = Date().timeIntervalSince(lastBusUpdateTime)
        let duration: TimeInterval = 10.0  // seconds between GPS poll (matches handleRouteSelection timer)

        let polyline = cachedInterpolationPolyline
        guard polyline.count >= 2 else { return }

        var updated = busVehicles
        for i in updated.indices {
            guard let prev = previousBusPositions[updated[i].vehicleId] else { continue }
            let result = VehicleInterpolator.smoothBusPosition(
                previous: CLLocationCoordinate2D(latitude: prev.lat, longitude: prev.lon),
                current: CLLocationCoordinate2D(
                    latitude: updated[i].lat, longitude: updated[i].lon),
                elapsed: elapsed,
                duration: duration,
                along: polyline
            )
            // Update the vehicle's display position via a mutable copy
            // (BusVehicleResponse is a struct, so this is a value-type update)
            updated[i] = updated[i].withInterpolatedPosition(
                lat: result.coordinate.latitude,
                lon: result.coordinate.longitude,
                bearing: result.bearing
            )
        }
        withAnimation(.interpolatingSpring(stiffness: 30, damping: 15)) {
            self.busVehicles = updated
        }
    }

    /// Solves for "Ghost Trains" by interpolating position between stations
    /// along the actual route polyline for realistic curved movement.
    /// Builds vehicles from ALL directions (not just the selected one) so
    /// `filteredTrainVehicles` can properly filter them.
    private func updateTrainPositions(arrivals: [TrainArrival]) {
        guard let shape = routeShape else { return }
        self.cachedTrainArrivals = arrivals

        // Build stops and polyline per direction so we can match arrivals
        // against the correct direction's stops.
        struct DirectionContext {
            let stops: [BusStop]
            let polyline: [CLLocationCoordinate2D]
        }

        // Build direction contexts for all available directions
        var dirContexts: [DirectionContext] = []
        if !shape.directions.isEmpty {
            for i in 0..<shape.directions.count {
                let ds = shape.stopsForDirection(i)
                let stops = ds.isEmpty ? shape.stops : ds
                let pl = shape.polylinesForDirection(i)
                let polyline: [CLLocationCoordinate2D] =
                    pl.isEmpty
                    ? cachedInterpolationPolyline
                    : pl.flatMap { $0 }
                dirContexts.append(DirectionContext(stops: stops, polyline: polyline))
            }
        }
        // If no direction data, use the combined stops
        if dirContexts.isEmpty {
            dirContexts.append(
                DirectionContext(
                    stops: shape.stops,
                    polyline: cachedInterpolationPolyline
                ))
        }

        // 1. Group arrivals by UNIQUE trip.
        var trips: [String: [TrainArrival]] = [:]

        for arrival in arrivals {
            let key =
                arrival.tripId
                ?? "\(arrival.direction)-\(arrival.destination ?? "unk")-\(arrival.scheduledTime.timeIntervalSince1970)"
            trips[key, default: []].append(arrival)
        }

        var newVehicles: [TrainVehicle] = []

        // 2. Process each trip to find its "current location"
        // Try matching against each direction's stops until we find a match.
        for (tripId, tripArrivals) in trips {
            let sorted = tripArrivals.sorted { $0.estimatedTime < $1.estimatedTime }

            guard
                let nextStop = sorted.first(where: { $0.estimatedTime.timeIntervalSinceNow > -30 })
            else { continue }

            let nextStopIdBase = nextStop.stationID.prefix(3)

            // Try each direction context to find which one has this stop
            for ctx in dirContexts {
                guard
                    let nextStopIndex = ctx.stops.firstIndex(where: {
                        $0.id.hasPrefix(nextStopIdBase)
                    })
                else { continue }

                let dirStops = ctx.stops
                let polyline = ctx.polyline

                var lat = dirStops[nextStopIndex].lat
                var lon = dirStops[nextStopIndex].lon
                var bearing: Double = 0

                let previousIndex = nextStopIndex > 0 ? nextStopIndex - 1 : nextStopIndex
                let nextIndex = nextStopIndex

                if previousIndex != nextIndex {
                    let prevStop = dirStops[previousIndex]
                    let targetStop = dirStops[nextIndex]

                    let timeUntilArrival = nextStop.estimatedTime.timeIntervalSinceNow
                    let minutes = timeUntilArrival / 60.0
                    let travelTime = 3.0
                    let t = min(max(minutes / travelTime, 0.0), 1.0)

                    // progress: 0.0 at prevStop → 1.0 at targetStop
                    let rawProgress = 1.0 - t

                    let progress: Double
                    if AppSettings.shared.simulationEasingEnabled {
                        progress =
                            rawProgress < 0.5
                            ? 2 * rawProgress * rawProgress
                            : 1 - pow(-2 * rawProgress + 2, 2) / 2
                    } else {
                        progress = rawProgress
                    }

                    // Use polyline-aware interpolation if we have a polyline
                    if polyline.count >= 2 {
                        let fromCoord = CLLocationCoordinate2D(
                            latitude: prevStop.lat, longitude: prevStop.lon)
                        let toCoord = CLLocationCoordinate2D(
                            latitude: targetStop.lat, longitude: targetStop.lon)
                        let result = VehicleInterpolator.interpolateBetweenStops(
                            from: fromCoord, to: toCoord,
                            progress: progress, along: polyline)
                        lat = result.coordinate.latitude
                        lon = result.coordinate.longitude
                        bearing = result.bearing
                    } else {
                        // Fallback: straight-line lerp
                        lat = prevStop.lat + (targetStop.lat - prevStop.lat) * progress
                        lon = prevStop.lon + (targetStop.lon - prevStop.lon) * progress
                        bearing =
                            atan2(
                                targetStop.lon - prevStop.lon,
                                targetStop.lat - prevStop.lat
                            ) * 180 / .pi
                        if bearing < 0 { bearing += 360 }
                    }
                }

                let etaMinutes: Int? = {
                    let secs = nextStop.estimatedTime.timeIntervalSinceNow
                    guard secs > -60 else { return nil }
                    return max(0, Int(secs / 60))
                }()

                newVehicles.append(
                    TrainVehicle(
                        id: tripId,
                        tripId: tripId,
                        routeId: nextStop.routeID,
                        direction: nextStop.direction,
                        lat: lat,
                        lon: lon,
                        bearing: bearing,
                        nextStationName: dirStops[nextStopIndex].name,
                        minutesAway: etaMinutes
                    ))
                break  // Found a matching direction, stop searching
            }
        }

        withAnimation(.interpolatingSpring(stiffness: 30, damping: 15)) {
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
    ///
    /// - Parameter skipGlobalFeeds: When `true` (e.g. during drag-to-search),
    ///   skips alerts and accessibility fetches since those are location-independent
    ///   and are loaded during the initial app refresh. This makes area scanning
    ///   noticeably faster.
    func refreshNearbyTransit(location: CLLocation?, skipGlobalFeeds: Bool = false) async {
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

            let rawTransit = try await flatTask
            groupedTransit = try await groupedTask

            // Deduplicate: Keep the first occurrence of each unique ID
            // This prevents duplicate rows if the API returns the same arrival
            // multiple times (e.g. slight timing differences or data glitches).
            var seenIDs = Set<String>()
            nearbyTransit = rawTransit.filter { seenIDs.insert($0.id).inserted }

            // Fetch alerts and accessibility only on full refreshes — these are
            // global feeds that don't change by location. Skipping them during
            // drag-to-search avoids 2 extra network calls per pan gesture.
            if !skipGlobalFeeds {
                async let alertsTask = TrackAPI.fetchAlerts()
                async let accessTask = TrackAPI.fetchAccessibility()
                do {
                    serviceAlerts = try await alertsTask
                    AlertNotificationManager.shared.processAlerts(serviceAlerts)
                } catch {}
                do { elevatorOutages = try await accessTask } catch {}
            }

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
        nearbyGroupedBusArrivals = []
        nearbyGroupedSubwayArrivals = []

        guard let location = location else {
            errorMessage = "Location required for subway arrivals"
            return
        }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        do {
            // Fetch grouped nearby transit filtered to subway mode only.
            // This avoids fetching bus/LIRR/MNR data we don't need.
            async let groupedTask = TrackAPI.fetchNearbyGrouped(lat: lat, lon: lon, mode: "subway")
            async let stationsTask = repository.fetchNearbyStations(
                latitude: lat, longitude: lon
            )

            let allGrouped = try await groupedTask
            nearbyGroupedSubwayArrivals = allGrouped.filter { $0.mode == "subway" }

            nearbyStations = try await stationsTask
        } catch {
            AppLogger.shared.logError("refreshSubway", error: error)
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
        }

        // Fetch alerts and accessibility alongside subway
        await refreshAlerts()
        do { elevatorOutages = try await TrackAPI.fetchAccessibility() } catch {}
    }

    // MARK: - Bus

    private func refreshBus(location: CLLocation?) async {
        nearbyStations = []
        upcomingArrivals = []
        lirrArrivals = []
        nearbyGroupedBusArrivals = []
        nearbyGroupedSubwayArrivals = []

        guard let location = location else {
            errorMessage = "Location required for bus arrivals"
            return
        }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        do {
            // Fetch grouped nearby transit filtered to bus mode only.
            // This avoids fetching subway/LIRR/MNR data we don't need.
            let allGrouped = try await TrackAPI.fetchNearbyGrouped(lat: lat, lon: lon, mode: "bus")
            nearbyGroupedBusArrivals = allGrouped.filter { $0.mode == "bus" }

            do { allBusRoutes = try await TrackAPI.fetchBusRoutes() } catch {}
        } catch {
            AppLogger.shared.logError("refreshBus", error: error)
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
        }

        // Fetch alerts and accessibility alongside bus
        await refreshAlerts()
        do { elevatorOutages = try await TrackAPI.fetchAccessibility() } catch {}
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
        nearbyGroupedBusArrivals = []
        nearbyGroupedSubwayArrivals = []
        nearbyGroupedMNRArrivals = []
        mnrArrivals = []

        do {
            lirrArrivals = try await TrackAPI.fetchLIRRArrivals()
        } catch {
            AppLogger.shared.logError("fetchLIRRArrivals", error: error)
            errorMessage = (error as? TrackAPIError)?.description ?? error.localizedDescription
        }

        // Fetch grouped LIRR arrivals from backend (with display names and colors)
        if let loc = LocationManager().currentLocation {
            do {
                nearbyGroupedLIRRArrivals = try await TrackAPI.fetchNearbyGrouped(
                    lat: loc.coordinate.latitude,
                    lon: loc.coordinate.longitude,
                    mode: "lirr"
                )
            } catch {
                AppLogger.shared.logError("fetchGroupedLIRR", error: error)
                // Fall back to client-side grouping
                nearbyGroupedLIRRArrivals = groupTrainArrivals(lirrArrivals, mode: "lirr")
            }
        } else {
            // No location available — fall back to client-side grouping
            nearbyGroupedLIRRArrivals = groupTrainArrivals(lirrArrivals, mode: "lirr")
        }

        // Fetch alerts and accessibility alongside LIRR
        await refreshAlerts()
        do { elevatorOutages = try await TrackAPI.fetchAccessibility() } catch {}
    }

    // MARK: - Metro-North

    private func refreshMNR() async {
        nearbyStations = []
        upcomingArrivals = []
        nearbyBusStops = []
        busArrivals = []
        selectedBusStop = nil
        nearbyGroupedBusArrivals = []
        nearbyGroupedSubwayArrivals = []
        nearbyGroupedLIRRArrivals = []
        lirrArrivals = []

        do {
            mnrArrivals = try await TrackAPI.fetchMNRArrivals()
        } catch {
            AppLogger.shared.logError("fetchMNRArrivals", error: error)
            errorMessage = (error as? TrackAPIError)?.description ?? error.localizedDescription
        }

        // Fetch grouped MNR arrivals from backend (with display names and colors)
        if let loc = LocationManager().currentLocation {
            do {
                nearbyGroupedMNRArrivals = try await TrackAPI.fetchNearbyGrouped(
                    lat: loc.coordinate.latitude,
                    lon: loc.coordinate.longitude,
                    mode: "mnr"
                )
            } catch {
                AppLogger.shared.logError("fetchGroupedMNR", error: error)
                // Fall back to client-side grouping
                nearbyGroupedMNRArrivals = groupTrainArrivals(mnrArrivals, mode: "mnr")
            }
        } else {
            // No location available — fall back to client-side grouping
            nearbyGroupedMNRArrivals = groupTrainArrivals(mnrArrivals, mode: "mnr")
        }

        // Fetch alerts and accessibility alongside MNR
        await refreshAlerts()
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

        // Record commute pattern for smart suggestions
        SmartSuggester.recordPattern(
            context: DataController.shared.container.mainContext,
            routeID: arrival.routeId,
            direction: arrival.direction,
            startLocation: location ?? CLLocation(latitude: 0, longitude: 0),
            destinationStationID: arrival.stopId ?? arrival.stopName,
            destinationName: arrival.destination ?? arrival.direction,
            cloudSyncHandler: {
                routeId, direction, lat, lon, destId, destName, hour, weekday, freq in
                await SyncManager.shared.syncCommutePattern(
                    routeId: routeId,
                    direction: direction,
                    startLatitude: lat,
                    startLongitude: lon,
                    destinationStationId: destId,
                    destinationName: destName,
                    timeOfDay: hour,
                    dayOfWeek: weekday,
                    frequency: freq
                )
            }
        )

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

        // Update visual highlighting on the map — set tappedVehicleId so
        // the marker scales up and the matching arrival row highlights.
        if arrival.isBus {
            self.tappedVehicleId = arrival.vehicleId
            self.highlightedVehicleId = arrival.vehicleId
            AppLogger.shared.log(
                "TRACKING", message: "Highlighting bus vehicle: \(arrival.vehicleId ?? "none")")
        } else {
            self.tappedVehicleId = arrival.tripId
            self.highlightedVehicleId = arrival.tripId
            AppLogger.shared.log(
                "TRACKING", message: "Highlighting train trip: \(arrival.tripId ?? "none")")
        }

        // Set the zoom-to coordinate so the map centers on the tracked vehicle/stop.
        // Prioritizes live vehicle position; falls back to stop coordinates.
        self.trackedVehicleCoordinate = coordinateForTrackedArrival(arrival)

        // Immediately refresh the Live Activity
        updateLiveActivityFromRefresh()

        // Update local state and reload widgets
        WidgetCenter.shared.reloadAllTimelines()

        // Start Live Activity
        let eta = Date().addingTimeInterval(Double(arrival.minutesAway) * 60)

        // Find sibling arrivals for the "Other upcoming trains" section
        let nextArrivals =
            (groupedTransit.first(where: { $0.routeId == arrival.routeId })?
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
        let nextArrivals =
            upcomingArrivals
            .filter {
                $0.direction == arrival.direction && $0.stationID == arrival.stationID
                    && $0.minutesAway > arrival.minutesAway
            }
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
        let nextArrivals =
            busArrivals
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
        let nextArrivals =
            agencyArrivals
            .filter {
                $0.direction == arrival.direction && $0.stationID == arrival.stationID
                    && $0.minutesAway > arrival.minutesAway
            }
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

    // MARK: - GO Mode Forwarding (methods)

    func activateGoMode(routeName: String, routeColor: Color) {
        goMode.activateGoMode(routeName: routeName, routeColor: routeColor)
    }

    func deactivateGoMode() {
        goMode.deactivateGoMode()
    }

    func markStopPassed(_ stopId: String) {
        goMode.markStopPassed(stopId)
    }

    func isStopPassed(_ stop: BusStop) -> Bool {
        goMode.isStopPassed(stop)
    }

    func updatePassedStops(userLocation: CLLocation?) {
        goMode.updatePassedStops(userLocation: userLocation, routeShape: routeShape)
    }

    func fetchTransitETA(
        from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D
    ) async {
        await goMode.fetchTransitETA(from: source, to: destination)
    }

    func fetchWalkingRoute(
        from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D
    ) async {
        await goMode.fetchWalkingRoute(from: source, to: destination)
    }
}
