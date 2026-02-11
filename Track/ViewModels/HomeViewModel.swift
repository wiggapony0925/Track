//
//  HomeViewModel.swift
//  Track
//
//  ViewModel for the HomeView. Fetches nearby transit arrivals
//  (both subway and bus) from the TrackAPI backend based on the
//  user's current location. Shows a unified live transit feed.
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

    // Live Activity tracking
    var trackingArrivalId: String?

    private let repository = TransitRepository()
    private let liveActivityManager = LiveActivityManager.shared

    /// Refreshes the view based on current location and transport mode.
    func refresh(location: CLLocation?) async {
        isLoading = true
        errorMessage = nil

        switch selectedMode {
        case .nearby:
            await refreshNearbyTransit(location: location)
        case .subway:
            await refreshSubway(location: location)
        case .bus:
            await refreshBus(location: location)
        }

        isLoading = false
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
        // Clear bus data when switching modes
        nearbyBusStops = []
        busArrivals = []
        selectedBusStop = nil

        // Fetch nearby stations
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

        // Fetch arrivals for the first nearby station's line
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
        // Clear subway data when switching modes
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

        // Fetch arrivals for the first nearby stop
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
