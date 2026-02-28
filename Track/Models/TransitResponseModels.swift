import Foundation
import CoreLocation

/// Matches the backend's `NearbyTransitArrival` JSON schema.
struct NearbyTransitResponse: Codable, Identifiable, Equatable {
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
    /// Haversine distance (meters) from the user to this stop, computed server-side.
    /// Preferred over client-side CLLocation.distance for sorting/bucketing.
    var distanceM: Double? = nil

    var isBus: Bool { mode == "bus" }
    var isLIRR: Bool { mode == "lirr" }
    var isMNR: Bool { mode == "mnr" }
    var isCommuterRail: Bool { isLIRR || isMNR }

    /// True when this arrival comes from GTFS-static only — no real-time vehicle
    /// feed has confirmed the trip is currently in motion.
    /// Scheduled arrivals must NOT show "Now", "In Route", or a live map marker.
    var isScheduledOnly: Bool {
        status.lowercased() == "scheduled"
    }

    /// True when this arrival is a backend-generated placeholder used to ensure
    /// at least two direction tabs exist.  Placeholders have `minutesAway >= 99`,
    /// no live vehicle/trip id, and no real arrival timestamp.
    var isPlaceholder: Bool {
        minutesAway >= 99 && arrivalTs == nil && (vehicleId == nil || vehicleId?.isEmpty == true)
    }

    /// Human-readable display name for the route.
    /// Uses branch name lookup for LIRR/MNR, strips MTA prefix for subway/bus.
    var displayName: String {
        BranchNames.resolveDisplayName(routeId: routeId, mode: mode)
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
        case distanceM = "distance_m"
    }
}

/// Arrivals for a single direction within a grouped route.
struct DirectionArrivalsResponse: Codable, Identifiable, Equatable {
    /// Stable identity that handles routes with many directions sharing similar names.
    /// Falls back to just `direction` when `directionLabel` is nil (backward compat).
    var id: String { "\(direction)_\(directionLabel ?? "")" }

    let direction: String
    let directionLabel: String?
    let arrivals: [NearbyTransitResponse]

    /// Live (non-placeholder) arrivals — filters out backend backfill entries
    /// that exist only to guarantee direction tabs, AND arrivals whose timestamp
    /// is more than 90 s in the past (vehicle already passed the stop).
    ///
    /// NOTE: 90 s grace period is intentionally aligned with
    /// `ArrivalETAEngine.isPastArrival` (also 90 s) so that an arrival
    /// disappears from `liveArrivals` at the SAME moment the engine marks
    /// it as past.  Previous values (120 s, 300 s) created windows where
    /// the arrival was still in the data source but the engine showed it
    /// as past — causing ghost "NOW" chips or blank chip sections.
    var liveArrivals: [NearbyTransitResponse] {
        let now = Date.now.timeIntervalSince1970
        return arrivals.filter { arrival in
            // Filter out placeholders
            guard !arrival.isPlaceholder else { return false }
            // Filter out arrivals whose timestamp is more than 90 s in the past.
            // Aligned with ArrivalETAEngine.isPastArrival (90 s) so both layers
            // agree on when an arrival is gone.
            if let ts = arrival.arrivalTs, ts > 0 {
                let elapsed = now - Double(ts)
                if elapsed > 90 { return false }
            }
            // Only filter 0-minute arrivals that are purely static GTFS with no
            // realtime context at all.  Live SIRI buses at minutesAway==0 are
            // literally at the stop and must NOT be dropped — they are the most
            // important arrivals to show.  A scheduled entry has status "Scheduled"
            // so we can distinguish them here.
            if arrival.minutesAway <= 0 && arrival.arrivalTs == nil
                && arrival.isScheduledOnly {
                return false
            }
            return true
        }
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
struct GroupedNearbyTransitResponse: Codable, Identifiable, Equatable {
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

    /// True when at least one direction has a non-placeholder arrival.
    /// Placeholder-only routes (e.g. QM16 with all 99-min stubs) return false
    /// and should be filtered from the home dashboard.
    var hasRealArrivals: Bool {
        directions.contains { dir in
            dir.arrivals.contains { !$0.isPlaceholder }
        }
    }

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case displayName = "display_name"
        case mode
        case colorHex = "color_hex"
        case directions
    }
}

