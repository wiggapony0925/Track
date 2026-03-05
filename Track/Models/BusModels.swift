//
//  BusModels.swift
//  Track
//
//  Data models for bus transit data matching the TrackBackend JSON output.
//  Used by TrackAPI to decode responses from /bus/* endpoints.
//

import CoreLocation
import Foundation

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
struct BusArrival: Identifiable, Codable, Equatable {
    /// Computed ID for SwiftUI list identity.
    var id: String { vehicleId + stopId }

    let routeId: String
    let vehicleId: String
    let stopId: String
    let stopName: String?

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
        case stopName = "stop_name"
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
struct BusVehicleResponse: Codable, Identifiable, Equatable {
    /// Stable identity that does NOT include lat/lon.
    /// Including coordinates in `id` causes SwiftUI to treat every interpolation
    /// tick as a brand-new annotation, forcing the Map to destroy and recreate
    /// views — the #1 cause of map slowness during live tracking.
    var id: String {
        if vehicleId.isEmpty {
            return "\(routeId)-unknown-\(nextStop ?? "none")"
        }
        return vehicleId
    }

    let vehicleId: String
    let routeId: String
    var lat: Double
    var lon: Double
    var bearing: Double?
    let nextStop: String?
    let statusText: String?
    /// SIRI DirectionRef: 0 or 1, used to filter vehicles by selected direction.
    let directionRef: Int?
    /// Expected arrival time at next stop from SIRI MonitoredCall.
    var expectedArrival: Date?

    /// Future stops for this vehicle (from SIRI OnwardCalls).
    /// Used to sync the arrivals list with vehicle movement in real-time.
    var onwardCalls: [BusArrival]? = []

    /// MTA SIRI spooking detection: `false` when the vehicle is not actively
    /// transmitting GPS data and its position is interpolated from the static
    /// schedule.  The chip UI should show "Scheduled" instead of "Live".
    var isRealtime: Bool = true

    /// Strips "MTA NYCT_" prefix for display.
    var displayRouteName: String {
        stripMTAPrefix(routeId)
    }

    /// Minutes until arrival at next stop, or nil if unavailable.
    /// Uses ceil() to match ArrivalETAEngine.minutesRemaining and row countdowns.
    var minutesAway: Int? {
        guard let eta = expectedArrival else { return nil }
        let seconds = eta.timeIntervalSinceNow
        guard seconds > -60 else { return nil }
        return max(0, Int(ceil(seconds / 60)))
    }

    enum CodingKeys: String, CodingKey {
        case vehicleId = "vehicle_id"
        case routeId = "route_id"
        case lat, lon, bearing
        case nextStop = "next_stop"
        case statusText = "status_text"
        case directionRef = "direction_ref"
        case expectedArrival = "expected_arrival"
        case onwardCalls = "onward_calls"
        case isRealtime = "is_realtime"
    }

    /// Returns a copy with an interpolated position for smooth map animation.
    func withInterpolatedPosition(lat: Double, lon: Double, bearing: Double) -> BusVehicleResponse {
        var copy = self
        copy.lat = lat
        copy.lon = lon
        copy.bearing = bearing
        return copy
    }
}

/// Polylines and stops for one direction of a route.
struct DirectionShapeResponse: Codable, Identifiable {
    /// Stable identity that handles multiple branches sharing the same GTFS `directionId`.
    /// Combines `directionId` with `headsign` so routes with 3+ directions
    /// (e.g. subway branches, bus short-turns) never collide in SwiftUI `ForEach`.
    var id: String { "\(directionId)_\(headsign)" }

    let directionId: Int
    let headsign: String
    let polylines: [String]
    let stops: [BusStop]
    /// Express/local service classification from GTFS routes.txt.
    /// Values: "express", "local", "mixed", or nil (buses, shuttles, crosstown, etc.)
    let serviceType: String?

    enum CodingKeys: String, CodingKey {
        case directionId = "direction_id"
        case headsign, polylines, stops
        case serviceType = "service_type"
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
    var stops: [BusStop]
    let directions: [DirectionShapeResponse]
    /// Express/local service classification from GTFS routes.txt.
    /// Values: "express", "local", "mixed", or nil (shuttles, crosstown, etc.)
    let serviceType: String?

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case polylines, stops, directions
        case serviceType = "service_type"
    }

    /// Decodes all Google-encoded polylines into coordinate arrays (combined).
    var decodedPolylines: [[CLLocationCoordinate2D]] {
        polylines.map { decodePolyline($0) }
    }

    /// Returns decoded polylines for a specific direction index.
    /// Matches by `name` against `headsign` first, then `directionId` (falling back to array position).
    /// Falls back to the combined polylines if no direction data exists.
    func polylinesForDirection(index: Int, name: String? = nil) -> [[CLLocationCoordinate2D]] {
        matchedDirection(index: index, name: name)?.decodedPolylines ?? decodedPolylines
    }

    /// Returns the `DirectionShapeResponse` that matches the given index/name.
    /// Used by `polylinesForDirection` and by the ViewModel to identify inactive directions.
    func matchedDirection(index: Int, name: String? = nil) -> DirectionShapeResponse? {
        guard !directions.isEmpty else { return nil }
        
        // Prefer matching by name to headsign — but only when the name is
        // long enough for substring matching to be reliable.  Short compass
        // codes like "N" / "S" (used by subway grouping) would false-match
        // against nearly every headsign (e.g. "Inwood-207 St" contains "S")
        // so we skip the loose `contains` check for them.
        if let name = name?.uppercased(), !name.isEmpty {
            // Exact match is always safe
            if let match = directions.first(where: {
                $0.headsign.uppercased() == name
            }) {
                return match
            }
            
            // Substring matching only for names long enough to be meaningful
            // (>= 3 chars avoids compass codes "N","S","NE","SW" etc.)
            if name.count >= 3 {
                if let match = directions.first(where: {
                    let hs = $0.headsign.uppercased()
                    return name.contains(hs) || hs.contains(name)
                }) {
                    return match
                }
            }
        }
        
        // Fallback to GTFS direction_id (0 or 1)
        if let match = directions.first(where: { $0.directionId == index }) {
            return match
        }
        let safeIdx = min(index, directions.count - 1)
        return directions[safeIdx]
    }

    /// Returns stops for a specific direction index.
    /// Matches by `name` against `headsign` first, then `directionId` (falling back to array position).
    /// Falls back to the combined stops if no direction data exists.
    func stopsForDirection(index: Int, name: String? = nil) -> [BusStop] {
        guard !directions.isEmpty else { return stops }
        
        // Prefer matching by name to headsign — same guard as matchedDirection
        // to avoid short compass codes ("N"/"S") false-matching on substrings.
        if let name = name?.uppercased(), !name.isEmpty {
            // Exact match
            if let match = directions.first(where: {
                $0.headsign.uppercased() == name
            }) {
                return match.stops.isEmpty ? stops : match.stops
            }
            
            // Substring matching only for names >= 3 chars
            if name.count >= 3 {
                if let match = directions.first(where: {
                    let hs = $0.headsign.uppercased()
                    return name.contains(hs) || hs.contains(name)
                }) {
                    return match.stops.isEmpty ? stops : match.stops
                }
            }
        }
        
        // Fallback to GTFS direction_id (0 or 1)
        if let match = directions.first(where: { $0.directionId == index }) {
            return match.stops.isEmpty ? stops : match.stops
        }
        let safeIdx = min(index, directions.count - 1)
        let dirStops = directions[safeIdx].stops
        return dirStops.isEmpty ? stops : dirStops
    }
}

// MARK: - Bus Schedule

/// Response from /bus/schedule/{route_id} — today's upcoming scheduled departures.
struct BusScheduleResponse: Codable, Equatable {
    let routeId: String
    let directions: [BusScheduleDirection]

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case directions
    }
}

struct BusScheduleDirection: Codable, Equatable {
    let direction: String
    let headsign: String
    let departures: [BusScheduledDeparture]
}

struct BusScheduledDeparture: Codable, Identifiable, Equatable {
    var id: String { tripId + "_\(departureTime)" }
    let stopName: String
    let stopId: String
    let departureTime: Int  // epoch seconds
    let headsign: String
    let tripId: String

    enum CodingKeys: String, CodingKey {
        case stopName = "stop_name"
        case stopId = "stop_id"
        case departureTime = "departure_time"
        case headsign
        case tripId = "trip_id"
    }

    /// The departure as a Date
    var departureDate: Date {
        Date(timeIntervalSince1970: TimeInterval(departureTime))
    }

    /// Minutes until departure from now.
    /// Uses `ceil()` and a -60 s guard to match `BusVehicleResponse.minutesAway`
    /// and `TrainVehicle.minutesAway` — consistent rounding across all models.
    var minutesAway: Int {
        let seconds = departureDate.timeIntervalSinceNow
        guard seconds > -60 else { return -1 }
        return Int(ceil(seconds / 60))
    }
}
