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
        Task { @MainActor in
            authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
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
