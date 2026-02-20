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
    /// Minutes until arrival at the next station, derived from GTFS-RT.
    var minutesAway: Int?
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
