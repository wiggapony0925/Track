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

    // Draggable search pin
    var searchPinCoordinate: CLLocationCoordinate2D?
    var isSearchPinActive = false

    // Live bus tracking on map
    var selectedRouteId: String?
    var busVehicles: [BusVehicleResponse] = []
    var routeShape: RouteShapeResponse?

    // Live Activity tracking
    var trackingArrivalId: String?

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
    func refreshNearbyTransit(location: CLLocation?) async {
        guard let location = location else {
            errorMessage = "Location required"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            nearbyTransit = try await TrackAPI.fetchNearbyTransit(
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude
            )
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
}
