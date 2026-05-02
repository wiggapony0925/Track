// ViewModel for "GO" mode — live transit tracking that replaces the
// standard blue dot with a pulsing vehicle icon, auto-pans the map,
// and dims already-passed stops. Extracted from HomeViewModel.

import CoreLocation
import Foundation
import MapKit
import SwiftUI
@preconcurrency import UserNotifications

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

    /// The specific GTFS trip ID being tracked, if known.
    var tripId: String?

    /// Stops the user has already passed in GO mode (for checklist dimming).
    var passedStopIds: Set<String> = []

    /// Transit ETA computed via MKDirections (minutes remaining).
    var transitEtaMinutes: Int?

    /// The visual dimming factor for the map background (0.0 to 1.0).
    /// Used by MapLibreMapView to desaturate/darken non-essential layers.
    var mapDimmingFactor: Double = 0.0
    
    /// Total number of stops in the active route (for progress calculation).
    var totalStopCount: Int = 0
    
    /// Tracks the last time a crowdsourced beacon was sent to the backend.
    private var lastBeaconSentTime: Date = .distantPast
    private let beaconInterval: TimeInterval = 15.0

    // MARK: - Get-Off Notification State

    /// The stop ID where the user should alight (from TripLeg.alightStopId).
    var alightStopId: String?

    /// Human-readable name of the alight stop.
    var alightStopName: String?

    /// Coordinates of the alight stop (for distance checking).
    var alightStopCoordinate: CLLocationCoordinate2D?

    /// Whether the get-off notification has already been fired this session.
    /// Prevents duplicate alerts.
    private var getOffNotificationFired = false

    /// Whether the user is "approaching" their destination (within warning radius).
    /// Published so the UI can show a visual alert banner.
    var isApproachingDestination = false

    /// Distance threshold for the "approaching" warning (meters).
    /// One stop early ≈ 300-400m for subway, 200m for bus.
    private static let approachWarningRadius: CLLocationDistance = 400

    /// Distance threshold for the "arrive now" notification (meters).
    private static let arriveRadius: CLLocationDistance = 150

    // MARK: - Activation

    /// Activates "GO" mode for the currently selected route.
    ///
    /// GO mode replaces the standard blue dot with a pulsing vehicle icon
    /// that snaps to the route polyline. The map auto-pans to follow the
    /// user's position and dims already-passed stops.
    ///
    /// Inspired by the Transit app's hands-free tracking experience.
    func activateGoMode(routeName: String, routeColor: Color, tripId: String? = nil) {
        isGoModeActive = true
        goModeRouteName = routeName
        goModeRouteColor = routeColor
        self.tripId = tripId
        passedStopIds = []
        getOffNotificationFired = false
        isApproachingDestination = false

        // Animate focus mode entrance
        withAnimation(.easeInOut(duration: 0.8)) {
            mapDimmingFactor = 0.4
        }
        
        GoHapticEngine.shared.goActivated()
        
        // Start Live Activity
        Task {
            await LiveActivityManager.shared.startActivity(
                lineId: routeName,
                destination: alightStopName ?? "Your Destination",
                arrivalTime: Date().addingTimeInterval(3600), // Placeholder ETA
                isBus: true,
                minutesAway: nil,
                nextArrivals: []
            )
        }
    }

    /// Sets the destination stop for get-off notifications.
    /// Call after `activateGoMode` when a `TripLeg` provides alight info.
    func setAlightStop(id: String, name: String, lat: Double, lon: Double) {
        alightStopId = id
        alightStopName = name
        alightStopCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        getOffNotificationFired = false
        isApproachingDestination = false
    }

    /// Deactivates "GO" mode and returns to the normal map view.
    func deactivateGoMode() {
        isGoModeActive = false
        mapDimmingFactor = 0.0
        
        // End Live Activity
        LiveActivityManager.shared.endActivity()

        goModeRouteName = nil
        goModeRouteColor = nil
        tripId = nil
        passedStopIds = []
        transitEtaMinutes = nil
        alightStopId = nil
        alightStopName = nil
        alightStopCoordinate = nil
        getOffNotificationFired = false
        isApproachingDestination = false

        // Animate focus mode exit
        withAnimation(.easeInOut(duration: 0.5)) {
            mapDimmingFactor = 0.0
        }
    }

    // MARK: - Stop Tracking

    /// Marks a stop as passed (dimmed in the checklist). Called when
    /// the user's GPS position moves beyond a stop along the route.
    func markStopPassed(_ stopId: String) {
        if !passedStopIds.contains(stopId) {
            passedStopIds.insert(stopId)
            GoHapticEngine.shared.stopPassed()
        }
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
                    updateLiveActivity()
                }
            } else {
                // No bearing data — fall back to proximity only
                passedStopIds.insert(stop.id)
                updateLiveActivity()
            }
        }
        
        // Update total stop count for progress
        totalStopCount = shape.stops.count

        // Check proximity to alight (get-off) stop
        checkGetOffProximity(userLocation: loc)
    }

    /// Updates proximity-only GO guidance when the route shape is not owned by
    /// the current screen. Used by the global GoTripSession so notifications
    /// continue to fire from app-level GPS updates.
    func updateUserLocation(_ location: CLLocation?) {
        guard isGoModeActive, let location else { return }
        // ── Crowdsourced Tracking (Beacon) ──
        broadcastBeaconIfNeeded(location: location)
        checkGetOffProximity(userLocation: location)
    }
    
    /// Sends a location beacon to the backend to help other users track
    /// the vehicle if it's missing from official SIRI feeds.
    private func broadcastBeaconIfNeeded(location: CLLocation) {
        guard let routeId = goModeRouteName, AppSettings.shared.isContributing else { return }
        
        // Throttle to avoid draining battery/bandwidth
        let now = Date()
        guard now.timeIntervalSince(lastBeaconSentTime) >= beaconInterval else { return }
        
        // Only broadcast if moving (to ensure we're actually on the bus)
        // or if we've just started.
        guard location.speed > 1.5 || lastBeaconSentTime == .distantPast else { return }
        
        lastBeaconSentTime = now
        
        let beacon = [
            "route_id": routeId,
            "trip_id": tripId ?? "",
            "lat": location.coordinate.latitude,
            "lon": location.coordinate.longitude,
            "bearing": location.course >= 0 ? location.course : nil,
            "speed": location.speed >= 0 ? location.speed : nil,
            "accuracy": location.horizontalAccuracy,
            "timestamp": now.timeIntervalSince1970
        ] as [String : Any]
        
        Task {
            do {
                let url = URL(string: "https://api.track.jeffrey.ai/tracking/beacon")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: beacon)
                
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    // Beacon accepted
                }
            } catch {
                // Fail silently — non-critical
            }
        }
    }
    
    /// Calculates the journey progress (0.0 to 1.0) and updates
    /// the lock screen Live Activity.
    private func updateLiveActivity() {
        guard isGoModeActive, totalStopCount > 0 else { return }
        
        let progress = Double(passedStopIds.count) / Double(totalStopCount)
        let remaining = totalStopCount - passedStopIds.count
        
        LiveActivityManager.shared.updateActivity(
            statusText: "\(remaining) stops remaining",
            arrivalTime: Date().addingTimeInterval(Double(remaining * 120)), // Very rough estimate
            progress: progress,
            minutesAway: nil
        )
    }

    // MARK: - Get-Off Proximity Check

    /// Checks whether the user is approaching or has arrived at their
    /// alight stop and fires a local notification when appropriate.
    private func checkGetOffProximity(userLocation: CLLocation) {
        guard let coord = alightStopCoordinate, !getOffNotificationFired else { return }

        let alightLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let distance = userLocation.distance(from: alightLoc)

        if distance <= Self.arriveRadius {
            // Arrived — fire notification and set flag
            isApproachingDestination = true
            getOffNotificationFired = true
            
            HapticManager.notification(.success)
            fireGetOffNotification(isNow: true)
            GoHapticEngine.shared.arrived()
        } else if distance <= Self.approachWarningRadius && !isApproachingDestination {
            // Approaching — fire early warning
            isApproachingDestination = true
            fireGetOffNotification(isNow: false)
            GoHapticEngine.shared.approachingDestination()
        }
    }

    /// Sends a local notification telling the user to prepare to get off
    /// or to get off now.
    private func fireGetOffNotification(isNow: Bool) {
        let routeLabel = goModeRouteName ?? "Transit"
        let stopLabel = alightStopName ?? "your stop"

        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "GET_OFF_ALERT"

        if isNow {
            content.title = "Get Off Now!"
            content.body = "You've arrived at \(stopLabel) on the \(routeLabel)."
            content.sound = .defaultCritical
        } else {
            content.title = "Approaching \(stopLabel)"
            content.body = "Prepare to get off the \(routeLabel) at the next stop."
            content.sound = .default
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let identifier = isNow ? "get-off-now" : "get-off-approaching"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                #if DEBUG
                print("[GO_MODE] Get-off notification failed: \(error.localizedDescription)")
                #endif
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

    /// Monotonically increasing token — incremented by `cancelWalkingRoute()`
    /// so in-flight fetches know they're stale and discard their result.
    private var _walkingRouteToken: UInt = 0

    /// Cancels any in-flight walking route fetch and clears the current route.
    func cancelWalkingRoute() {
        _walkingRouteToken &+= 1
        walkingRoute = nil
    }

    /// Fetches walking directions from user to a destination and stores the route polyline.
    /// Uses a token-based staleness check so results from cancelled/outdated fetches
    /// don't overwrite a cleared route (e.g. after sheet dismissal).
    func fetchWalkingRoute(
        from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D
    ) async {
        let token = _walkingRouteToken
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
            // Staleness check: if token changed, the route was cancelled
            guard _walkingRouteToken == token else { return }
            if let route = response.routes.first {
                self.walkingRoute = route
            }
        } catch {
            guard _walkingRouteToken == token else { return }
            AppLogger.shared.logError("Walking route calculation", error: error)
            self.walkingRoute = nil
        }
    }
}
