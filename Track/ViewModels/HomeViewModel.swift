//
//  HomeViewModel.swift
//  Track
//
//  ViewModel for the HomeView, handling smart suggestions and arrivals.
//  Supports both Subway and Bus transport modes.
//  Provides reliability scoring based on historical trip data.
//

import Foundation
import SwiftData
import CoreLocation

@Observable
final class HomeViewModel {
    var suggestion: RouteSuggestion?
    var nearbyStations: [(stationID: String, name: String, distance: Double, routeIDs: [String])] = []
    var upcomingArrivals: [TrainArrival] = []
    var alerts: [TransitAlert] = []
    var isLoading = false
    var errorMessage: String?

    // Bus mode
    var selectedMode: TransportMode = .subway
    var nearbyBusStops: [BusStop] = []
    var busArrivals: [BusArrival] = []
    var selectedBusStop: BusStop?

    // Live Activity tracking
    var trackingArrivalId: String?

    // Reliability warnings: routeID → average delay in minutes (if > 5)
    var reliabilityWarnings: [String: Int] = [:]

    private let repository = TransitRepository()
    private let liveActivityManager = LiveActivityManager.shared

    /// Refreshes the home screen data based on current context and transport mode.
    func refresh(context: ModelContext, location: CLLocation?) async {
        isLoading = true
        errorMessage = nil

        switch selectedMode {
        case .subway:
            await refreshSubway(context: context, location: location)
        case .bus:
            await refreshBus(location: location)
        }

        isLoading = false
    }

    // MARK: - Subway

    private func refreshSubway(context: ModelContext, location: CLLocation?) async {
        // Clear bus data
        nearbyBusStops = []
        busArrivals = []
        selectedBusStop = nil

        // Get smart suggestion (respects user preference)
        let predictEnabled = UserDefaults.standard.object(forKey: "predictCommuteEnabled") as? Bool ?? true
        if predictEnabled {
            suggestion = SmartSuggester.predict(
                context: context,
                currentLocation: location,
                currentTime: Date()
            )
        } else {
            suggestion = nil
        }

        // Fetch nearby stations
        if let location = location {
            do {
                nearbyStations = try await repository.fetchNearbyStations(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
            } catch {
                errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
            }
        }

        // Fetch arrivals for the suggested station or first nearby
        let stationID = nearbyStations.first?.stationID ?? "L01"
        do {
            upcomingArrivals = try await repository.fetchArrivals(for: stationID)
            alerts = try await repository.fetchAlerts()
        } catch {
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
        }

        // Compute reliability warnings for displayed routes
        let routeIDs = Set(upcomingArrivals.map { $0.routeID })
        for routeID in routeIDs {
            let avgDelay = getReliabilityScore(for: routeID, context: context)
            if avgDelay > 5 {
                reliabilityWarnings[routeID] = avgDelay
            }
        }
    }

    // MARK: - Bus

    private func refreshBus(location: CLLocation?) async {
        // Clear subway data
        nearbyStations = []
        upcomingArrivals = []
        suggestion = nil

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
            errorMessage = (error as? TrackAPIError)?.description ?? error.localizedDescription
        }
    }

    // MARK: - Live Activity

    /// Starts tracking a subway arrival via Live Activity.
    func trackSubwayArrival(_ arrival: TrainArrival, context: ModelContext, location: CLLocation?) {
        trackingArrivalId = arrival.id.uuidString
        liveActivityManager.startActivity(
            lineId: arrival.routeID,
            destination: arrival.direction,
            arrivalTime: arrival.estimatedTime,
            isBus: false,
            stationId: arrival.stationID,
            context: context,
            location: location.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
        )
    }

    /// Starts tracking a bus arrival via Live Activity.
    func trackBusArrival(_ arrival: BusArrival, context: ModelContext, location: CLLocation?) {
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
            stationId: arrival.stopId,
            context: context,
            location: location.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
        )
    }

    /// Stops tracking the current Live Activity.
    func stopTracking(context: ModelContext) {
        trackingArrivalId = nil
        liveActivityManager.endActivity(context: context)
    }

    // MARK: - Reliability

    /// Calculates the average delay (in minutes) for a route based on the last 10 TripLog entries.
    ///
    /// - Parameters:
    ///   - routeID: The route to check.
    ///   - context: SwiftData model context.
    /// - Returns: Average delay in minutes (positive = late). Returns 0 if no data.
    func getReliabilityScore(for routeID: String, context: ModelContext) -> Int {
        let predicate = #Predicate<TripLog> { log in
            log.routeID == routeID && log.actualArrivalTime != nil
        }

        var descriptor = FetchDescriptor<TripLog>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.tripDate, order: .reverse)]
        )
        descriptor.fetchLimit = 10

        do {
            let logs = try context.fetch(descriptor)
            guard !logs.isEmpty else { return 0 }
            let totalDelay = logs.reduce(0) { $0 + $1.delaySeconds }
            let averageDelaySeconds = totalDelay / logs.count
            return averageDelaySeconds / 60
        } catch {
            return 0
        }
    }
}
