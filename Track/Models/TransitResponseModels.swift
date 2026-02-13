import Foundation
import CoreLocation

/// Matches the backend's `NearbyTransitArrival` JSON schema.
struct NearbyTransitResponse: Codable, Identifiable {
    var id: String { "\(routeId)-\(stopName)-\(minutesAway)" }

    let routeId: String
    let stopName: String
    let direction: String
    let destination: String?
    let minutesAway: Int
    let status: String
    let mode: String
    let stopLat: Double?
    let stopLon: Double?

    var isBus: Bool { mode == "bus" }

    /// Strips "MTA NYCT_" prefix for display.
    var displayName: String {
        stripMTAPrefix(routeId)
    }

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case stopName = "stop_name"
        case direction
        case destination
        case minutesAway = "minutes_away"
        case status
        case mode
        case stopLat = "stop_lat"
        case stopLon = "stop_lon"
    }
}

/// Arrivals for a single direction within a grouped route.
struct DirectionArrivalsResponse: Codable, Identifiable {
    var id: String { direction }

    let direction: String
    let arrivals: [NearbyTransitResponse]
}

/// Matches the backend's `GroupedNearbyTransit` JSON schema.
/// One entry per route; directions are swipeable sub-groups.
struct GroupedNearbyTransitResponse: Codable, Identifiable {
    var id: String { routeId }

    let routeId: String
    let displayName: String
    let mode: String
    let colorHex: String?
    let directions: [DirectionArrivalsResponse]

    var isBus: Bool { mode == "bus" }

    /// The soonest arrival across all directions.
    var soonestMinutes: Int {
        directions.flatMap(\.arrivals).map(\.minutesAway).min() ?? 99
    }

    /// The name of the direction (destination) for the soonest arrival.
    var soonestDirectionName: String? {
        let all = directions.flatMap { dir in 
            dir.arrivals.map { (dir.direction, $0.minutesAway) }
        }
        return all.min(by: { $0.1 < $1.1 })?.0
    }

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case displayName = "display_name"
        case mode
        case colorHex = "color_hex"
        case directions
    }
}
