import Foundation
import CoreLocation

/// Matches the backend's `TrackArrival` JSON schema (snake_case).
struct SubwayArrivalResponse: Codable {
    let routeId: String
    let station: String
    let stationName: String?
    let direction: String
    let destination: String?
    let minutesAway: Int
    let status: String
    let tripId: String? // Optional since backend might not send it for older cached data
    let arrivalTs: Int? // Optional timestamp in seconds

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case station
        case stationName = "station_name"
        case direction
        case destination
        case minutesAway = "minutes_away"
        case status
        case tripId = "trip_id"
        case arrivalTs = "arrival_ts"
    }
    
    // Helper to map to domain model (TrainArrival defined in TransitRepository.swift)
    func toTrainArrival() -> TrainArrival {
        let now = Date()
        // If we have precise arrival timestamp, use it. Otherwise approximate from "minutes away".
        let arrivalDate: Date
        if let ts = arrivalTs, ts > 0 {
            arrivalDate = Date(timeIntervalSince1970: TimeInterval(ts))
        } else {
            arrivalDate = now.addingTimeInterval(Double(minutesAway) * 60)
        }
        
        return TrainArrival(
            routeID: routeId,
            stationID: station,
            stationName: stationName ?? station,
            direction: direction,
            scheduledTime: arrivalDate,
            estimatedTime: arrivalDate,
            minutesAway: minutesAway,
            destination: destination,
            status: status,
            tripId: tripId
        )
    }
}

/// Lightweight overlay for drawing a single subway line on the full map.
struct SubwayLineOverlay: Codable, Identifiable {
    var id: String { routeId }
    let routeId: String
    let colorHex: String
    let polylines: [String]

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case colorHex = "color_hex"
        case polylines
    }

    /// Decodes polylines on demand.
    var decodedPolylines: [[CLLocationCoordinate2D]] {
        polylines.map { decodePolyline($0) }
    }
}

/// Response containing all subway lines for the system map.
struct AllSubwayLinesResponse: Codable {
    let lines: [SubwayLineOverlay]
}

/// Lightweight overlay for drawing a single commuter rail line on the map.
struct CommuterRailLineOverlay: Codable, Identifiable {
    var id: String { routeId }
    let routeId: String
    let name: String
    let colorHex: String
    let polylines: [String]
    let mode: String  // "lirr" or "mnr"

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case name
        case colorHex = "color_hex"
        case polylines
        case mode
    }

    /// Decodes polylines on demand.
    var decodedPolylines: [[CLLocationCoordinate2D]] {
        polylines.map { decodePolyline($0) }
    }
}

/// Response containing all LIRR and MNR lines for the system map.
struct AllCommuterRailLinesResponse: Codable {
    let lines: [CommuterRailLineOverlay]
}

struct SubwayStation: Codable, Identifiable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let routes: [String]
}

struct AllSubwayStationsResponse: Codable {
    let stations: [SubwayStation]
}
