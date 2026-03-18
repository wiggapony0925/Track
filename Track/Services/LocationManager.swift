//
//  LocationManager.swift
//  Track
//
//  Manages user GPS location using CoreLocation.
//

import Foundation
import CoreLocation

@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    var currentLocation: CLLocation?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var locationError: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = AppSettings.shared.distanceFilterMeters
        // Hint to CoreLocation that the user is on foot / using transit.
        // iOS can power-gate the GPS chip more aggressively between fixes.
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = true
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Re-reads the current authorization status from CLLocationManager and
    /// publishes it. Called when the app returns to the foreground so the UI
    /// transitions immediately if the user just granted access in iOS Settings.
    func refreshAuthorizationStatus() {
        let current = manager.authorizationStatus
        authorizationStatus = current
        if current == .authorizedWhenInUse || current == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func startUpdating() {
        manager.startUpdatingLocation()
    }

    /// Request an immediate high-accuracy GPS fix.
    ///
    /// CoreLocation's `distanceFilter = 50m` means after the phone wakes
    /// from suspension it may take several seconds before the next fix
    /// exceeds the filter threshold — especially if the user hasn't
    /// moved much at the new location.  Temporarily dropping the filter
    /// to `kCLDistanceFilterNone` forces an immediate delivery, then
    /// restores the normal filter after the first fix arrives.
    ///
    /// Call this when the app returns to the foreground after a long
    /// suspension so the UI can refresh with the correct location ASAP.
    func requestImmediateFix() {
        manager.distanceFilter = kCLDistanceFilterNone
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.startUpdatingLocation()
        // Restore normal filter after a brief window (enough for 1-2 fixes).
        // Reduced from 3s → 1s to avoid rapid-fire GPS callbacks that trigger
        // cascading refresh cycles and waste energy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.manager.distanceFilter = AppSettings.shared.distanceFilterMeters
            self.manager.desiredAccuracy = kCLLocationAccuracyBest
        }
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in
            currentLocation = latest
            // Cache location for widget access via App Group
            if let location = latest {
                let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? UserDefaults.standard
                defaults.set(location.coordinate.latitude, forKey: "lastLatitude")
                defaults.set(location.coordinate.longitude, forKey: "lastLongitude")
                defaults.set(true, forKey: "hasLastLocation")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // Start location updates outside the Task so that the non-Sendable
        // CLLocationManager parameter is not captured across isolation boundaries.
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
        Task { @MainActor in
            authorizationStatus = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let desc = error.localizedDescription
        Task { @MainActor in
            locationError = desc
        }
    }

    /// Returns distance in meters between current location and a coordinate
    func distanceTo(latitude: Double, longitude: Double) -> Double? {
        guard let current = currentLocation else { return nil }
        let target = CLLocation(latitude: latitude, longitude: longitude)
        return current.distance(from: target)
    }
}
