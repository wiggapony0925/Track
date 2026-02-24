//
//  TrainArrival.swift
//  Track
//
//  Model representing a single upcoming train arrival at a station.
//  Used by TransitRepository and displayed in the subway dashboard.
//

import Foundation

/// Represents a single upcoming train arrival at a station.
struct TrainArrival: Identifiable {
    let id = UUID()
    let routeID: String
    let stationID: String
    let stationName: String
    let stopLat: Double?
    let stopLon: Double?
    let direction: String
    let scheduledTime: Date
    let estimatedTime: Date
    let minutesAway: Int
    let destination: String?
    let status: String
    let tripId: String?
}
