//
//  BusModels.swift
//  Track
//
//  Data models for bus transit data matching the TrackBackend JSON output.
//  Used by TrackAPI to decode responses from /bus/* endpoints.
//

import Foundation
import CoreLocation

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

/// Matches the backend's `BusVehicle` JSON schema.
struct BusVehicleResponse: Codable, Identifiable {
    /// Unique ID combining vehicle, route, and position for stable SwiftUI identity.
    var id: String {
        if vehicleId.isEmpty {
            return "\(routeId)-\(lat)-\(lon)"
        }
        return vehicleId
    }

    let vehicleId: String
    let routeId: String
    let lat: Double
    let lon: Double
    let bearing: Double?
    let nextStop: String?
    let statusText: String?

    /// Strips "MTA NYCT_" prefix for display.
    var displayRouteName: String {
        stripMTAPrefix(routeId)
    }

    enum CodingKeys: String, CodingKey {
        case vehicleId = "vehicle_id"
        case routeId = "route_id"
        case lat, lon, bearing
        case nextStop = "next_stop"
        case statusText = "status_text"
    }
}

/// Matches the backend's `RouteShape` JSON schema.
struct RouteShapeResponse: Codable {
    let routeId: String
    let polylines: [String]
    let stops: [BusStop]

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case polylines, stops
    }

    /// Decodes all Google-encoded polylines into coordinate arrays.
    var decodedPolylines: [[CLLocationCoordinate2D]] {
        polylines.map { decodePolyline($0) }
    }
}
