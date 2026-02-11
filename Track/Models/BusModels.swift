//
//  BusModels.swift
//  Track
//
//  Data models for bus transit data matching the TrackBackend JSON output.
//  Used by TrackAPI to decode responses from /bus/* endpoints.
//

import Foundation

/// A bus stop returned by the backend (from the OBA API).
struct BusStop: Identifiable, Codable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let direction: String?
}

/// A real-time bus arrival returned by the backend (from the SIRI API).
struct BusArrival: Identifiable, Codable {
    /// Computed ID for SwiftUI list identity.
    var id: String { vehicleId + stopId }

    let routeId: String
    let vehicleId: String
    let stopId: String

    /// Human-readable status, e.g. "Approaching", "3 stops away".
    let statusText: String

    let expectedArrival: Date?
    let distanceMeters: Double?

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case vehicleId = "vehicle_id"
        case stopId = "stop_id"
        case statusText = "status_text"
        case expectedArrival = "expected_arrival"
        case distanceMeters = "distance_meters"
    }
}
