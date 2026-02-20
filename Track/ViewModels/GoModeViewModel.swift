//
//  GoModeViewModel.swift
//  Track
//
//  ViewModel for "GO" mode — live transit tracking that replaces the
//  standard blue dot with a pulsing vehicle icon, auto-pans the map,
//  and dims already-passed stops. Extracted from HomeViewModel.
//

import CoreLocation
import Foundation
import MapKit
import SwiftUI

@Observable
@MainActor
final class GoModeViewModel {

    // MARK: - State

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

    // MARK: - Activation

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

    // MARK: - Stop Tracking

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
    private static let stopPassedThreshold: CLLocationDistance = AppSettings.shared
        .stopPassedThresholdMeters

    /// Updates the list of passed stops based on the user's current
    /// position and bearing relative to the route shape stops.
    ///
    /// A stop is marked as passed if the user is within
    /// ``stopPassedThreshold`` meters **and** the user's heading
    /// indicates they are moving away from the stop (or they have
    /// already been marked once).
    func updatePassedStops(userLocation: CLLocation?, routeShape: RouteShapeResponse?) {
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
    func fetchTransitETA(
        from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D
    ) async {
        // In challenge mode, provide a mock ETA instead of calling MKDirections
        if ChallengeMode.isEnabled {
            transitEtaMinutes = 12
            return
        }

        // MKPlacemark is deprecated in iOS 26.0
        let sourceItem = MKMapItem(
            location: CLLocation(latitude: source.latitude, longitude: source.longitude),
            address: nil)
        let destItem = MKMapItem(
            location: CLLocation(latitude: destination.latitude, longitude: destination.longitude),
            address: nil)

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

    /// Walking route to the nearest station (managed by GO mode for navigation).
    var walkingRoute: MKRoute?

    /// Fetches walking directions from user to a destination and stores the route polyline.
    func fetchWalkingRoute(
        from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D
    ) async {
        // In challenge mode, skip walking directions (requires network)
        if ChallengeMode.isEnabled {
            self.walkingRoute = nil
            return
        }

        // MKPlacemark is deprecated in iOS 26.0
        let sourceItem = MKMapItem(
            location: CLLocation(latitude: source.latitude, longitude: source.longitude),
            address: nil)
        let destItem = MKMapItem(
            location: CLLocation(latitude: destination.latitude, longitude: destination.longitude),
            address: nil)

        let request = MKDirections.Request()
        request.source = sourceItem
        request.destination = destItem
        request.transportType = .walking

        let directions = MKDirections(request: request)
        do {
            let response = try await directions.calculate()
            if let route = response.routes.first {
                self.walkingRoute = route
            }
        } catch {
            AppLogger.shared.logError("Walking route calculation", error: error)
            self.walkingRoute = nil
        }
    }
}
