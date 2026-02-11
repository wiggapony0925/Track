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

    // Nearby transit (unified)
    var nearbyTransit: [NearbyTransitResponse] = []

    // Grouped nearby transit (one card per route)
    var groupedTransit: [GroupedNearbyTransitResponse] = []

    // Route detail sheet
    var selectedGroupedRoute: GroupedNearbyTransitResponse?
    var isRouteDetailPresented = false

    // Draggable search pin
    var searchPinCoordinate: CLLocationCoordinate2D?
    var isSearchPinActive = false

    // Live bus tracking on map
    var selectedRouteId: String?
    var busVehicles: [BusVehicleResponse] = []
    var routeShape: RouteShapeResponse?

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
    func effectiveLocation(userLocation: CLLocation?) -> CLLocation? {
        if isSearchPinActive, let pin = searchPinCoordinate {
            return CLLocation(latitude: pin.latitude, longitude: pin.longitude)
        }
        return userLocation
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
    func selectGroupedRoute(_ group: GroupedNearbyTransitResponse) async {
        selectedGroupedRoute = group
        isRouteDetailPresented = true

        // Load route shape + vehicles for bus routes
        if group.isBus {
            await selectBusRoute(group.routeId)
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

    /// Fetches all nearby transit (buses + trains) in one call.
    /// Uses the grouped endpoint to deduplicate routes.
    func refreshNearbyTransit(location: CLLocation?) async {
        guard let location = location else {
            errorMessage = "Location required"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            async let flatTask = TrackAPI.fetchNearbyTransit(
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude
            )
            async let groupedTask = TrackAPI.fetchNearbyGrouped(
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude
            )

            nearbyTransit = try await flatTask
            groupedTransit = try await groupedTask
        } catch {
            AppLogger.shared.logError("fetchNearbyTransit", error: error)
            errorMessage = (error as? TrackAPIError)?.description ?? error.localizedDescription
        }

        isLoading = false
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

        guard let location = location else {
            errorMessage = "Location required for bus stops"
            return
        }

        do {
            nearbyBusStops = try await TrackAPI.fetchNearbyBusStops(
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude
            )
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

    /// Starts tracking a bus arrival via Live Activity.
    func trackBusArrival(_ arrival: BusArrival, location: CLLocation?) {
        trackingArrivalId = arrival.id
        let arrivalTime = arrival.expectedArrival ?? Date().addingTimeInterval(300)
        let routeName: String
        if arrival.routeId.hasPrefix("MTA NYCT_") {
            routeName = String(arrival.routeId.dropFirst(9))
        } else {
            routeName = arrival.routeId
        }
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

    /// Updates the list of passed stops based on the user's current
    /// position relative to the route shape stops. Stops whose
    /// latitude is "behind" the user (in the direction of travel) are
    /// dimmed automatically.
    func updatePassedStops(userLocation: CLLocation?) {
        guard isGoModeActive, let loc = userLocation, let shape = routeShape else { return }
        let userCoord = loc.coordinate
        for stop in shape.stops {
            let stopLoc = CLLocation(latitude: stop.lat, longitude: stop.lon)
            let distance = loc.distance(from: stopLoc)
            // Mark stops within 100 m behind the user as passed
            if distance < 100 {
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
        let sourcePlacemark = MKPlacemark(coordinate: source)
        let destPlacemark = MKPlacemark(coordinate: destination)

        let sourceItem = MKMapItem(placemark: sourcePlacemark)
        let destItem = MKMapItem(placemark: destPlacemark)

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
}
