//
//  LocationExtensions.swift
//  Track
//
//  CLLocation extensions for bearing calculations and distance utilities.
//  Extracted from HomeViewModel so they can be reused across the app.
//

import CoreLocation

extension CLLocation {
    /// Calculates the bearing (in degrees, 0–360) from this location
    /// to another location. Used for determining if a stop is behind
    /// the user during GO mode tracking.
    func bearing(to destination: CLLocation) -> CLLocationDirection {
        let lat1 = coordinate.latitude.degreesToRadians
        let lon1 = coordinate.longitude.degreesToRadians
        let lat2 = destination.coordinate.latitude.degreesToRadians
        let lon2 = destination.coordinate.longitude.degreesToRadians

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x).radiansToDegrees

        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }
}

extension Double {
    var degreesToRadians: Double { self * .pi / 180 }
    var radiansToDegrees: Double { self * 180 / .pi }
}
