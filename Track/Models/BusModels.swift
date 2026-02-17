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
    /// Fully-qualified route IDs served by this stop (e.g. ["MTA NYCT_B63", "MTABC_Q35"]).
    var routeIds: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, lat, lon, direction
        case routeIds = "route_ids"
    }
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
    let status: String

    let expectedArrival: Date?
    let distanceMeters: Double?
    var bearing: Double? = nil
    /// SIRI DirectionRef: 0 or 1
    var directionRef: Int? = nil
    /// SIRI DestinationName: e.g. "JAMAICA via BREWER BL"
    var destinationName: String? = nil

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case vehicleId = "vehicle_id"
        case stopId = "stop_id"
        case statusText = "status_text"
        case status
        case expectedArrival = "expected_arrival"
        case distanceMeters = "distance_meters"
        case bearing
        case directionRef = "direction_ref"
        case destinationName = "destination_name"
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

/// Polylines and stops for one direction of a route.
struct DirectionShapeResponse: Codable, Identifiable {
    var id: Int { directionId }

    let directionId: Int
    let headsign: String
    let polylines: [String]
    let stops: [BusStop]

    enum CodingKeys: String, CodingKey {
        case directionId = "direction_id"
        case headsign, polylines, stops
    }

    /// Decodes all Google-encoded polylines for this direction.
    var decodedPolylines: [[CLLocationCoordinate2D]] {
        polylines.map { decodePolyline($0) }
    }
}

/// Matches the backend's `RouteShape` JSON schema.
struct RouteShapeResponse: Codable {
    let routeId: String
    let polylines: [String]
    let stops: [BusStop]
    let directions: [DirectionShapeResponse]

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case polylines, stops, directions
    }

    /// Decodes all Google-encoded polylines into coordinate arrays (combined).
    var decodedPolylines: [[CLLocationCoordinate2D]] {
        polylines.map { decodePolyline($0) }
    }

    /// Returns decoded polylines for a specific direction index.
    /// Falls back to the combined polylines if no direction data exists.
    func polylinesForDirection(_ directionIndex: Int) -> [[CLLocationCoordinate2D]] {
        guard !directions.isEmpty else { return decodedPolylines }
        let safeIdx = min(directionIndex, directions.count - 1)
        return directions[safeIdx].decodedPolylines
    }

    /// Returns stops for a specific direction index.
    /// Falls back to the combined stops if no direction data exists.
    func stopsForDirection(_ directionIndex: Int) -> [BusStop] {
        guard !directions.isEmpty else { return stops }
        let safeIdx = min(directionIndex, directions.count - 1)
        let dirStops = directions[safeIdx].stops
        return dirStops.isEmpty ? stops : dirStops
    }
}
