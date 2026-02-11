//
//  HomeViewModel.swift
//  Track
//
//  ViewModel for the HomeView, handling smart suggestions and arrivals.
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

    private let repository = TransitRepository()

    /// Refreshes the home screen data based on current context.
    func refresh(context: ModelContext, location: CLLocation?) async {
        isLoading = true
        errorMessage = nil

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

        isLoading = false
    }
}
