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

@Observable
final class HomeViewModel {
    var nearbyStations: [(stationID: String, name: String, distance: Double, routeIDs: [String])] = []
    var upcomingArrivals: [TrainArrival] = []
    var isLoading = false
    var errorMessage: String?

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

    // Service alerts & accessibility
    var serviceAlerts: [TransitAlert] = []
    var elevatorOutages: [ElevatorStatus] = []

    // Route detail sheet
    var selectedGroupedRoute: GroupedNearbyTransitResponse?
    var selectedDirectionIndex: Int?
    var isRouteDetailPresented = false

    // Draggable search pin
    var searchPinCoordinate: CLLocationCoordinate2D?
    var isSearchPinActive = false
    
    // Walking route to the nearest station
    var walkingRoute: MKRoute?
    var nearestStopCoordinate: CLLocationCoordinate2D?

    // Live bus/train tracking on map
    var selectedRouteId: String?
    var busVehicles: [BusVehicleResponse] = []
    var routeShape: RouteShapeResponse?

    // Full subway system map (pre-decoded for performance)
    struct CachedSubwayLine: Identifiable {
        let id: String
        let color: Color
        let coordinates: [[CLLocationCoordinate2D]]
    }
    var cachedSystemMap: [CachedSubwayLine] = []

    // Full subway station list with served lines
    struct CachedSubwayStation: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let routes: [String]
    }
    var cachedStations: [CachedSubwayStation] = []

    init() {
        Task {
            await loadSystemMap()
            await loadStations()
        }
    }

    /// Fetches the full subway system map (polylines for all 22 lines).
    func loadSystemMap() async {
        do {
            let response = try await TrackAPI.fetchAllSubwayShapes()
            
            // Pre-decode coordinates on a background thread to avoid UI hitch
            let decoded = response.lines.map { line in
                CachedSubwayLine(
                    id: line.routeId,
                    color: Color(hex: line.colorHex),
                    coordinates: line.decodedPolylines
                )
            }
            
            await MainActor.run {
                self.cachedSystemMap = decoded
            }
        } catch {
            AppLogger.shared.logError("loadSystemMap", error: error)
        }
    }
    
    /// Fetches all subway stations and their served lines.
    func loadStations() async {
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
        } catch {
            AppLogger.shared.logError("loadStations", error: error)
        }
    }

    // Live Activity tracking
    var trackingArrivalId: String?

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
    private let liveActivityManager = LiveActivityManager.shared

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
        }

        isLoading = false
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
        searchPinCoordinate = nil
        isSearchPinActive = false
        await refresh(location: userLocation)
    }

    // MARK: - Route Detail

    /// Opens the route detail sheet for a grouped route and loads its
    /// route shape / vehicle positions on the map.
    /// Also centers the map on the nearest station and calculates walking directions.
    func selectGroupedRoute(_ group: GroupedNearbyTransitResponse, directionIndex: Int = 0, userLocation: CLLocation?) async {
        selectedGroupedRoute = group
        selectedDirectionIndex = directionIndex
        isRouteDetailPresented = true
        
        // Reset previous route data
        walkingRoute = nil
        nearestStopCoordinate = nil
        busVehicles = []
        routeShape = nil
        
        selectedRouteId = group.routeId

        if group.isBus {
            // Load route shape + vehicles for bus routes
            await selectBusRoute(group.routeId)
        } else {
            // For subway: fetch the full line geometry from the backend
            do {
                routeShape = try await TrackAPI.fetchSubwayShape(routeID: group.displayName)
            } catch {
                AppLogger.shared.logError("fetchSubwayShape(\(group.displayName))", error: error)
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

    // MARK: - Bus Route Detail (Live Vehicles + Route Shape)

    /// Selects a bus route and fetches live vehicle positions + route shape.
    func selectBusRoute(_ routeId: String) async {
        selectedRouteId = routeId
        busVehicles = []
        routeShape = nil

        async let vehiclesTask = TrackAPI.fetchBusVehicles(routeID: routeId)
        async let shapeTask = TrackAPI.fetchRouteShape(routeID: routeId)

        do {
            busVehicles = try await vehiclesTask
        } catch {
            AppLogger.shared.logError("fetchBusVehicles(\(routeId))", error: error)
        }

        do {
            routeShape = try await shapeTask
        } catch {
            AppLogger.shared.logError("fetchRouteShape(\(routeId))", error: error)
        }
    }

    /// Refreshes only the vehicle positions for the currently selected route.
    func refreshBusVehicles() async {
        guard let routeId = selectedRouteId else { return }
        do {
            busVehicles = try await TrackAPI.fetchBusVehicles(routeID: routeId)
        } catch {
            AppLogger.shared.logError("refreshBusVehicles(\(routeId))", error: error)
        }
    }

    /// Clears the selected route and removes bus markers from the map.
    func clearBusRoute() {
        selectedRouteId = nil
        busVehicles = []
        routeShape = nil
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
            errorMessage = (error as? TrackAPIError)?.description ?? error.localizedDescription
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
            errorMessage = (error as? TrackAPIError)?.description ?? error.localizedDescription
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
            errorMessage = (error as? TrackAPIError)?.description ?? error.localizedDescription
        }
    }

    // MARK: - LIRR

    private func refreshLIRR() async {
        nearbyStations = []
        upcomingArrivals = []
        nearbyBusStops = []
        busArrivals = []
        selectedBusStop = nil

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

    // MARK: - Live Activity

    /// Starts tracking a subway arrival via Live Activity.
    func trackSubwayArrival(_ arrival: TrainArrival, location: CLLocation?) {
        trackingArrivalId = arrival.id.uuidString
        liveActivityManager.startActivity(
            lineId: arrival.routeID,
            destination: arrival.direction,
            arrivalTime: arrival.estimatedTime,
            isBus: false,
            stationId: arrival.stationID
        )
    }

    /// Starts tracking a LIRR arrival via Live Activity.
    func trackLIRRArrival(_ arrival: TrainArrival, location: CLLocation?) {
        trackingArrivalId = arrival.id.uuidString
        liveActivityManager.startActivity(
            lineId: "LIRR",
            destination: arrival.direction,
            arrivalTime: arrival.estimatedTime,
            isBus: false,
            stationId: arrival.stationID
        )
    }

    /// Starts tracking a bus arrival via Live Activity.
    func trackBusArrival(_ arrival: BusArrival, location: CLLocation?) {
        trackingArrivalId = arrival.id
        let arrivalTime = arrival.expectedArrival ?? Date().addingTimeInterval(300)
        let routeName = stripMTAPrefix(arrival.routeId)
        liveActivityManager.startActivity(
            lineId: routeName,
            destination: arrival.statusText,
            arrivalTime: arrivalTime,
            isBus: true,
            stationId: arrival.stopId
        )
    }

    /// Starts tracking a nearby transit arrival via Live Activity.
    func trackNearbyArrival(_ arrival: NearbyTransitResponse, location: CLLocation?) {
        trackingArrivalId = arrival.id
        let arrivalTime = Date().addingTimeInterval(Double(arrival.minutesAway) * 60)
        liveActivityManager.startActivity(
            lineId: arrival.displayName,
            destination: arrival.direction,
            arrivalTime: arrivalTime,
            isBus: arrival.isBus,
            stationId: arrival.stopName
        )
    }

    /// Stops tracking the current Live Activity.
    func stopTracking() {
        trackingArrivalId = nil
        liveActivityManager.endActivity()
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

        // Start Live Activity for the route
        let arrivalTime = Date().addingTimeInterval(Double(transitEtaMinutes ?? 10) * 60)
        liveActivityManager.startActivity(
            lineId: routeName,
            destination: "In Transit",
            arrivalTime: arrivalTime,
            isBus: selectedRouteId?.contains("MTA") == true,
            stationId: routeName
        )
    }

    /// Deactivates "GO" mode and returns to the normal map view.
    func deactivateGoMode() {
        isGoModeActive = false
        goModeRouteName = nil
        goModeRouteColor = nil
        passedStopIds = []
        transitEtaMinutes = nil
        liveActivityManager.endActivity()
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
