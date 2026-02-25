//
//  VehicleModels.swift
//  Track
//
//  Data models for live vehicle positions on the map.
//  Used by HomeViewModel for tracking subway trains, LIRR,
//  Metro-North, and bus vehicles in real-time.
//

import Foundation

// MARK: - Train Vehicle

/// Represents a live train vehicle position on the map.
/// Used for subway, LIRR, and Metro-North vehicle tracking.
struct TrainVehicle: Identifiable, Equatable {
    let id: String
    let tripId: String?
    let routeId: String
    let direction: String
    var lat: Double
    var lon: Double
    var bearing: Double?
    var nextStationName: String?
    /// Estimated arrival time at the next station, derived from GTFS-RT.
    /// Stored as a Date so `minutesAway` is computed live (matches row countdowns).
    var estimatedArrival: Date?

    /// Minutes until arrival at the next station. Computed live from
    /// `estimatedArrival` using ceil() to match `ArrivalETAEngine.minutesRemaining`.
    var minutesAway: Int? {
        guard let eta = estimatedArrival else { return nil }
        let seconds = eta.timeIntervalSinceNow
        guard seconds > -60 else { return nil }
        return max(0, Int(ceil(seconds / 60)))
    }
}

// MARK: - Bus Snapshot

/// A GPS snapshot for smooth bus position interpolation.
/// Stores the previous position so the map can animate (glide)
/// between updates along the route polyline.
struct BusSnapshot {
    let lat: Double
    let lon: Double
    let timestamp: Date
}
