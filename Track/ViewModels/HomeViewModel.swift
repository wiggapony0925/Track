//
//  HomeViewModel.swift
//  Track
//
//  ViewModel for the HomeView, handling smart suggestions and arrivals.
//  Supports both Subway and Bus transport modes.
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

    private let repository = TransitRepository()

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

        // Get smart suggestion
        suggestion = SmartSuggester.predict(
            context: context,
            currentLocation: location,
            currentTime: Date()
        )

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
}
