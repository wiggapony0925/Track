import Foundation
import CoreLocation

/// Matches the backend's `NearbyTransitArrival` JSON schema.
struct NearbyTransitResponse: Codable, Identifiable, Equatable {
    /// Stable identity for SwiftUI diffing — must NOT include volatile fields
    /// like `minutesAway` that change every poll cycle.  Priority:
    ///   1. tripId  — unique per GTFS trip, most stable
    ///   2. vehicleId — unique per vehicle, stable during a trip
    ///   3. arrivalTs — predicted timestamp, stable for scheduled data
    ///   4. minutesAway — last-resort fallback only (scheduled w/o timestamp)
    var id: String {
        let base = "\(routeId)-\(stopName)"
        if let tripId, !tripId.isEmpty { return "\(base)-\(tripId)" }
        if let vid = vehicleId, !vid.isEmpty { return "\(base)-\(vid)" }
        if let ts = arrivalTs { return "\(base)-\(ts)" }
        return "\(base)-\(minutesAway)"
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

    /// True when backed by live GTFS-RT or SIRI data (not purely static GTFS).
    var isRealTime: Bool = false
    /// True when GTFS-RT reports this trip/stop as CANCELED or SKIPPED.
    var isCancelled: Bool = false

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
        case isRealTime = "is_real_time"
        case isCancelled = "is_cancelled"
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
        var seen = Set<String>()
        return arrivals.filter { arrival in
            // Filter out placeholders
            guard !arrival.isPlaceholder else { return false }
            // Filter out cancelled trips — GTFS-RT says this stop is skipped.
            guard !arrival.isCancelled else { return false }
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
            // Deduplicate arrivals that share the same stop + arrival time.
            // MTA can assign slightly different trip IDs to the same physical
            // train at the same stop, producing ghost duplicates (especially
            // for subway where vehicle_id is unavailable).
            let dedupKey: String
            if let ts = arrival.arrivalTs {
                dedupKey = "\(arrival.stopName)-\(ts)"
            } else if let tid = arrival.tripId, !tid.isEmpty {
                dedupKey = "\(arrival.stopName)-\(tid)"
            } else {
                dedupKey = arrival.id  // fallback to existing id
            }
            guard !seen.contains(dedupKey) else { return false }
            seen.insert(dedupKey)
            return true
        }
        // Sort by arrival timestamp so display order is stable even when
        // SmartETA corrections shift the effective minutes (e.g. raw 11→13m,
        // raw 15→12m would appear out of order without this sort).
        .sorted { lhs, rhs in
            if let lt = lhs.arrivalTs, let rt = rhs.arrivalTs { return lt < rt }
            return lhs.minutesAway < rhs.minutesAway
        }
    }

    /// Number of distinct vehicles (by vehicleId/tripId) in this direction.
    /// Much cheaper than `liveArrivals.count` because it skips sorting and
    /// only needs a single pass for dedup.  Used for the direction pill badge.
    var uniqueVehicleCount: Int {
        let now = Date.now.timeIntervalSince1970
        var vehicleKeys = Set<String>()
        for arrival in arrivals {
            guard !arrival.isPlaceholder else { continue }
            guard !arrival.isCancelled else { continue }
            if let ts = arrival.arrivalTs, ts > 0 {
                let elapsed = now - Double(ts)
                if elapsed > 90 { continue }
            }
            if arrival.minutesAway <= 0 && arrival.arrivalTs == nil
                && arrival.isScheduledOnly { continue }
            let key = arrival.vehicleId ?? arrival.tripId ?? arrival.id
            vehicleKeys.insert(key)
        }
        return vehicleKeys.count
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

/// A service alert attached to a grouped route.
struct InlineAlertResponse: Codable, Equatable {
    let title: String
    let severity: String
    let affectedRoutes: [String]
    let alertType: String?    // e.g. "Delays", "Planned - Suspended"
    let sortOrder: Int        // MTA severity rank (higher = more severe)

    enum CodingKeys: String, CodingKey {
        case title
        case severity
        case affectedRoutes = "affected_routes"
        case alertType = "alert_type"
        case sortOrder = "sort_order"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        severity = try container.decode(String.self, forKey: .severity)
        affectedRoutes = try container.decodeIfPresent([String].self, forKey: .affectedRoutes) ?? []
        alertType = try container.decodeIfPresent(String.self, forKey: .alertType)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    init(title: String, severity: String, affectedRoutes: [String] = [], alertType: String? = nil, sortOrder: Int = 0) {
        self.title = title
        self.severity = severity
        self.affectedRoutes = affectedRoutes
        self.alertType = alertType
        self.sortOrder = sortOrder
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
    var directions: [DirectionArrivalsResponse]
    /// Canonical MTA ordering key set by the backend.
    var sortingKey: String = ""
    /// Active service alerts for this route.
    var alerts: [InlineAlertResponse] = []

    var isBus: Bool { mode == "bus" }
    var isLIRR: Bool { mode == "lirr" }
    var isMNR: Bool { mode == "mnr" }
    var isCommuterRail: Bool { isLIRR || isMNR }

    /// The soonest live arrival across all directions (ignores placeholders).
    var soonestMinutes: Int {
        let live = directions.flatMap(\.liveArrivals)
        return live.map(\.minutesAway).min() ?? 99
    }

    /// True when at least one direction has a non-placeholder arrival.
    /// Placeholder-only routes (e.g. QM16 with all 99-min stubs) return false
    /// and should be filtered from the home dashboard.
    var hasRealArrivals: Bool {
        directions.contains { dir in
            dir.arrivals.contains { !$0.isPlaceholder }
        }
    }

    /// True when at least one direction has a non-expired, non-placeholder
    /// arrival.  Unlike ``hasRealArrivals`` (which only checks decode-time
    /// data), this evaluates against the current wall-clock time so stale
    /// cache / SWR entries that have passed are correctly detected.
    var hasLiveArrivals: Bool {
        directions.contains { !$0.liveArrivals.isEmpty }
    }

    /// True when the group had real arrivals at one point but they have ALL
    /// expired (arrivalTs > 90 s in the past).  Placeholder-only groups
    /// return false (they represent routes with no live data at all, not
    /// expired data, and are intentionally kept visible around the clock).
    var isExpired: Bool {
        hasRealArrivals && !hasLiveArrivals
    }

    /// True when at least one direction has a severe or warning alert.
    var hasAlert: Bool { !alerts.isEmpty }

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case displayName = "display_name"
        case mode
        case colorHex = "color_hex"
        case directions
        case sortingKey = "sorting_key"
        case alerts
    }
}
