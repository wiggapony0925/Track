// Simplified data models used for offline caching.
// These lightweight Codable structs are stored in UserDefaults
// for offline access when underground or without connectivity.

import Foundation

// MARK: - Cached Arrival

/// Simplified arrival data for caching
struct CachedArrival: Codable, Identifiable {
    let id: String
    let routeId: String
    let routeName: String
    let stopName: String
    let direction: String
    let arrivalTime: Date
    let mode: String // "subway", "bus", "lirr"
    
    var minutesAway: Int {
        let seconds = arrivalTime.timeIntervalSince(Date())
        return max(0, Int(seconds / 60))
    }
}

// MARK: - Cached Station

/// Simplified station data for caching
struct CachedStation: Codable, Identifiable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let routes: [String] // Route IDs that serve this station
}
