import Foundation
import CoreLocation

/// Matches the backend's `NearbyTransitArrival` JSON schema.
struct NearbyTransitResponse: Codable, Identifiable {
    /// Unique identity combining route, stop, ETA, and trip/timestamp
    /// to avoid collisions when two trains share the same minutesAway.
    var id: String {
        let base = "\(routeId)-\(stopName)-\(minutesAway)"
        if let tripId, !tripId.isEmpty { return "\(base)-\(tripId)" }
        if let ts = arrivalTs { return "\(base)-\(ts)" }
        if let vid = vehicleId, !vid.isEmpty { return "\(base)-\(vid)" }
        return base
    }

    let routeId: String
    let stopName: String
    let direction: String
    let destination: String?
    let minutesAway: Int
    let status: String
    let mode: String
    let stopLat: Double?
    let stopLon: Double?
    let arrivalTs: Int?

    let vehicleId: String?
    let tripId: String?
    let stopId: String?

    var isBus: Bool { mode == "bus" }
    var isLIRR: Bool { mode == "lirr" }
    var isMNR: Bool { mode == "mnr" }
    var isCommuterRail: Bool { isLIRR || isMNR }

    /// True when this arrival is a backend-generated placeholder used to ensure
    /// at least two direction tabs exist.  Placeholders have `minutesAway >= 99`,
    /// no live vehicle/trip id, and no real arrival timestamp.
    var isPlaceholder: Bool {
        minutesAway >= 99 && arrivalTs == nil && (vehicleId == nil || vehicleId?.isEmpty == true)
    }

    /// Human-readable display name for the route.
    /// Uses branch name lookup for LIRR/MNR, strips MTA prefix for subway/bus.
    var displayName: String {
        HomeViewModel.resolveDisplayName(routeId: routeId, mode: mode)
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
        case arrivalTs = "arrival_ts"
        case vehicleId = "vehicle_id"
        case tripId = "trip_id"
        case stopId = "stop_id"
    }
}

/// Arrivals for a single direction within a grouped route.
struct DirectionArrivalsResponse: Codable, Identifiable {
    /// Stable identity that handles routes with many directions sharing similar names.
    /// Falls back to just `direction` when `directionLabel` is nil (backward compat).
    var id: String { "\(direction)_\(directionLabel ?? "")" }

    let direction: String
    let directionLabel: String?
    let arrivals: [NearbyTransitResponse]

    /// Live (non-placeholder) arrivals — filters out backend backfill entries
    /// that exist only to guarantee direction tabs.
    var liveArrivals: [NearbyTransitResponse] {
        arrivals.filter { !$0.isPlaceholder }
    }

    init(direction: String, directionLabel: String? = nil, arrivals: [NearbyTransitResponse]) {
        self.direction = direction
        self.directionLabel = directionLabel
        self.arrivals = arrivals
    }

    enum CodingKeys: String, CodingKey {
        case direction
        case directionLabel = "direction_label"
        case arrivals
    }
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
    var isLIRR: Bool { mode == "lirr" }
    var isMNR: Bool { mode == "mnr" }
    var isCommuterRail: Bool { isLIRR || isMNR }

    /// The soonest live arrival across all directions (ignores placeholders).
    var soonestMinutes: Int {
        let live = directions.flatMap(\.liveArrivals)
        return live.map(\.minutesAway).min() ?? 99
    }

    /// The name of the direction (destination) for the soonest live arrival.
    var soonestDirectionName: String? {
        let all = directions.flatMap { dir in 
            dir.liveArrivals.map { (dir.direction, $0.minutesAway) }
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

/// Matches the backend's `DelayPrediction` JSON schema from `/predict/delay`.
struct DelayPredictionResponse: Codable {
    let adjustedMinutes: Int
    let originalMinutes: Int
    let delayFactor: Double
    let adjustmentReason: String?

    enum CodingKeys: String, CodingKey {
        case adjustedMinutes = "adjusted_minutes"
        case originalMinutes = "original_minutes"
        case delayFactor = "delay_factor"
        case adjustmentReason = "adjustment_reason"
    }
}
