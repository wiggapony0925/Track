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

        // In challenge mode, provide a mock NYC location immediately
        // so the app can demonstrate its capabilities without GPS.
        // Coordinates: Midtown Manhattan (near Penn Station / Herald Square)
        if ChallengeMode.isEnabled {
            currentLocation = CLLocation(latitude: 40.75306, longitude: -73.99944)
            authorizationStatus = .authorizedWhenInUse
            // Seed App Group UserDefaults so widgets also use the mock location
            let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? UserDefaults.standard
            defaults.set(40.75306, forKey: "lastLatitude")
            defaults.set(-73.99944, forKey: "lastLongitude")
            defaults.set(true, forKey: "hasLastLocation")
            // Do NOT set delegate — prevents real GPS from overwriting mock coords
            return
        }

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = AppSettings.shared.distanceFilterMeters
    }

    func requestPermission() {
        if ChallengeMode.isEnabled { return }
        manager.requestWhenInUseAuthorization()
    }

    /// Re-reads the current authorization status from CLLocationManager and
    /// publishes it. Called when the app returns to the foreground so the UI
    /// transitions immediately if the user just granted access in iOS Settings.
    func refreshAuthorizationStatus() {
        if ChallengeMode.isEnabled { return }
        let current = manager.authorizationStatus
        authorizationStatus = current
        if current == .authorizedWhenInUse || current == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func startUpdating() {
        if ChallengeMode.isEnabled { return }
        manager.startUpdatingLocation()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            if ChallengeMode.isEnabled { return }
            currentLocation = locations.last
            // Cache location for widget access via App Group
            if let location = locations.last {
                let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? UserDefaults.standard
                defaults.set(location.coordinate.latitude, forKey: "lastLatitude")
                defaults.set(location.coordinate.longitude, forKey: "lastLongitude")
                defaults.set(true, forKey: "hasLastLocation")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        MainActor.assumeIsolated {
            if ChallengeMode.isEnabled { return }
            authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            locationError = error.localizedDescription
        }
    }

    /// Returns distance in meters between current location and a coordinate
    func distanceTo(latitude: Double, longitude: Double) -> Double? {
        guard let current = currentLocation else { return nil }
        let target = CLLocation(latitude: latitude, longitude: longitude)
        return current.distance(from: target)
    }
}
