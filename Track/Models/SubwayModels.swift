import Foundation
import CoreLocation

/// Matches the backend's `TrackArrival` JSON schema (snake_case).
struct SubwayArrivalResponse: Codable {
    let station: String
    let direction: String
    let minutesAway: Int
    let status: String

    enum CodingKeys: String, CodingKey {
        case station
        case direction
        case minutesAway = "minutes_away"
        case status
    }
    
    // Helper to map to domain model (TrainArrival defined in TransitRepository.swift)
    func toTrainArrival() -> TrainArrival {
        let now = Date()
        return TrainArrival(
            routeID: station,
            stationID: station,
            direction: direction,
            scheduledTime: now.addingTimeInterval(Double(minutesAway) * 60),
            estimatedTime: now.addingTimeInterval(Double(minutesAway) * 60),
            minutesAway: minutesAway
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
