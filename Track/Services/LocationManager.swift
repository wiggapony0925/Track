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
        manager.distanceFilter = 50
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        manager.startUpdatingLocation()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            currentLocation = locations.last
            // Cache location for widget access via App Group
            if let location = locations.last {
                let defaults = UserDefaults(suiteName: "group.com.track.shared") ?? UserDefaults.standard
                defaults.set(location.coordinate.latitude, forKey: "lastLatitude")
                defaults.set(location.coordinate.longitude, forKey: "lastLongitude")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        MainActor.assumeIsolated {
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
