import Foundation
import CoreLocation

/// Matches the backend's `NearbyTransitArrival` JSON schema.
struct NearbyTransitResponse: Codable, Identifiable, Equatable {
    /// Stable identity for SwiftUI diffing — must NOT include volatile fields
    /// like `minutesAway` that change every poll cycle (would make every chip
    /// look "new" each tick → churn → auto-select jumps → marker teleport).
    /// Priority:
    ///   1. tripId  — unique per GTFS trip, most stable
    ///   2. vehicleId — unique per vehicle, stable during a trip
    ///   3. arrivalTs — predicted timestamp, stable for scheduled data
    ///   4. direction + destination — coarse but stable for placeholders /
    ///      scheduled-only arrivals that lack any live identifier
    var id: String {
        let base = "\(routeId)-\(stopName)"
        if let tripId, !tripId.isEmpty { return "\(base)-trip:\(tripId)" }
        if let vid = vehicleId, !vid.isEmpty { return "\(base)-veh:\(vid)" }
        if let ts = arrivalTs { return "\(base)-ts:\(ts)" }
        // Final fallback uses only stable descriptive fields. Two
        // ambiguous scheduled-no-ts arrivals to the same destination
        // will collide — that is acceptable; identity churn is not.
        let dest = destination ?? ""
        return "\(base)-dir:\(direction)-dst:\(dest)"
    }

    let routeId: String
    let stopName: String
    let direction: String
    let destination: String?
    /// Minutes until arrival.  Defaults to `99` (placeholder sentinel)
    /// when the backend sends `null` — e.g. direction stubs with no
    /// live data.  The `isPlaceholder` guard catches these.
    var minutesAway: Int = 99
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
    /// True when this trip runs express/limited service (skips stops).
    /// Set by the backend for subway express routes (A, B, D, E, 2-5, N, Q, Z,
    /// 6X, 7X, FX) and SBS/express/limited buses.
    var isExpress: Bool = false
    /// Resolved backend brand color for this arrival's route.
    var colorHex: String? = nil
    /// Resolved backend bus service type for bus arrivals.
    var busServiceType: String? = nil
    /// Typed service variant for pill rendering.  Decoded from the
    /// backend's lowercase token ("local" | "limited" | "express" |
    /// "sbs" | "super_express" | "shuttle" | "unknown").  Defaults to
    /// `.unknown` when missing so old API payloads keep decoding.
    var serviceVariant: ServiceVariant = .unknown
    /// Optional override label for the variant pill (e.g. "Super Express
    /// via Madison Av").  When nil, the pill uses
    /// `serviceVariant.displayLabel`.
    var variantLabel: String? = nil
    /// Schedule deviation in seconds (positive = late, negative = early).
    /// Drives the chip's "Late 3m" / "Early 1m" badge.  Nil when feed omits delay.
    var delaySeconds: Int? = nil
    /// True when the upstream feed flags this vehicle as stalled
    /// (SIRI ProgressRate/ProgressStatus = "noProgress").  Drives a red
    /// "Stalled" chip pill.  Bus-only.
    var isStalled: Bool = false
    /// SIRI MonitoredCall.ArrivalProximityText (e.g. "at stop", "approaching").
    /// Bus-only.
    var arrivalProximityText: String? = nil
    /// True when this arrival's real-time position is provided by anonymous user beacons ('Ghost' vehicle).
    var isCrowdsourced: Bool = false

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
        case isExpress = "is_express"
        case colorHex = "color_hex"
        case busServiceType = "bus_service_type"
        case serviceVariant = "service_variant"
        case variantLabel = "variant_label"
        case delaySeconds = "delay_seconds"
        case isStalled = "is_stalled"
        case isCrowdsourced = "is_crowdsourced"
        case arrivalProximityText = "arrival_proximity_text"
    }

    /// Memberwise initializer (restores the auto-generated one that the
    /// custom `init(from:)` below suppresses).
    nonisolated init(
        routeId: String,
        stopName: String,
        direction: String,
        destination: String? = nil,
        minutesAway: Int = 99,
        status: String,
        mode: String,
        stopLat: Double? = nil,
        stopLon: Double? = nil,
        arrivalTs: Int? = nil,
        vehicleId: String? = nil,
        tripId: String? = nil,
        stopId: String? = nil,
        distanceM: Double? = nil,
        isRealTime: Bool = false,
        isCancelled: Bool = false,
        isExpress: Bool = false,
        colorHex: String? = nil,
        busServiceType: String? = nil,
        serviceVariant: ServiceVariant = .unknown,
        variantLabel: String? = nil,
        delaySeconds: Int? = nil,
        isStalled: Bool = false,
        isCrowdsourced: Bool = false,
        arrivalProximityText: String? = nil
    ) {
        self.routeId = routeId
        self.stopName = stopName
        self.direction = direction
        self.destination = destination
        self.minutesAway = minutesAway
        self.status = status
        self.mode = mode
        self.stopLat = stopLat
        self.stopLon = stopLon
        self.arrivalTs = arrivalTs
        self.vehicleId = vehicleId
        self.tripId = tripId
        self.stopId = stopId
        self.distanceM = distanceM
        self.isRealTime = isRealTime
        self.isCancelled = isCancelled
        self.isExpress = isExpress
        self.colorHex = colorHex
        self.busServiceType = busServiceType
        self.serviceVariant = serviceVariant
        self.variantLabel = variantLabel
        self.delaySeconds = delaySeconds
        self.isStalled = isStalled
        self.isCrowdsourced = isCrowdsourced
        self.arrivalProximityText = arrivalProximityText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routeId = try c.decode(String.self, forKey: .routeId)
        stopName = try c.decode(String.self, forKey: .stopName)
        direction = try c.decode(String.self, forKey: .direction)
        destination = try c.decodeIfPresent(String.self, forKey: .destination)
        minutesAway = try c.decodeIfPresent(Int.self, forKey: .minutesAway) ?? 99
        status = try c.decode(String.self, forKey: .status)
        mode = try c.decode(String.self, forKey: .mode)
        stopLat = try c.decodeIfPresent(Double.self, forKey: .stopLat)
        stopLon = try c.decodeIfPresent(Double.self, forKey: .stopLon)
        arrivalTs = try c.decodeIfPresent(Int.self, forKey: .arrivalTs)
        vehicleId = try c.decodeIfPresent(String.self, forKey: .vehicleId)
        tripId = try c.decodeIfPresent(String.self, forKey: .tripId)
        stopId = try c.decodeIfPresent(String.self, forKey: .stopId)
        distanceM = try c.decodeIfPresent(Double.self, forKey: .distanceM)
        isRealTime = try c.decodeIfPresent(Bool.self, forKey: .isRealTime) ?? false
        isCancelled = try c.decodeIfPresent(Bool.self, forKey: .isCancelled) ?? false
        isExpress = try c.decodeIfPresent(Bool.self, forKey: .isExpress) ?? false
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        busServiceType = try c.decodeIfPresent(String.self, forKey: .busServiceType)
        serviceVariant = try c.decodeIfPresent(ServiceVariant.self, forKey: .serviceVariant) ?? .unknown
        variantLabel = try c.decodeIfPresent(String.self, forKey: .variantLabel)
        delaySeconds = try c.decodeIfPresent(Int.self, forKey: .delaySeconds)
        isStalled = try c.decodeIfPresent(Bool.self, forKey: .isStalled) ?? false
        isCrowdsourced = try c.decodeIfPresent(Bool.self, forKey: .isCrowdsourced) ?? false
        arrivalProximityText = try c.decodeIfPresent(String.self, forKey: .arrivalProximityText)
    }
}

/// Arrivals for a single direction within a grouped route.
struct DirectionArrivalsResponse: Codable, Identifiable, Equatable {
    /// Stable identity that handles routes with many directions sharing similar names.
    /// Includes backend direction/branch metadata when present so branch tabs that
    /// share a rendered label don't collide in SwiftUI `ForEach`.
    var id: String {
        [direction, directionLabel, directionId, branchId]
            .compactMap { value in
                guard let value,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return value
            }
            .joined(separator: "_")
    }

    let direction: String
    let directionLabel: String?
    /// Compass direction code (N/S/E/W) extracted from the GTFS
    /// `trip_id` by the backend. Used to group branch tabs that share
    /// a physical direction (e.g. A train: Inwood-bound = "N";
    /// Lefferts/Far Rockaway/Rockaway Park = "S").  `nil` for non-
    /// subway feeds (bus / commuter rail).
    let directionId: String?
    /// Stable identifier for a branch within a direction.  Populated
    /// only when the parent route has more than one terminus per
    /// direction (e.g. "S-0", "S-1", "S-2" for the A train's three
    /// southern branches).  `nil` when the route has a single terminus
    /// per direction — the client renders compass-style tabs without
    /// branch chips in that case.
    let branchId: String?
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
            // Deduplicate arrivals that share the same stop + similar arrival
            // time.  MTA GTFS-RT often assigns slightly different trip IDs
            // (or timestamps offset by 1-2 s) to the same physical train,
            // producing ghost duplicates — especially for subway where
            // vehicle_id is unavailable.
            //
            // Strategy: bucket arrival timestamps to 60-second windows so
            // two predictions at 14:30:00 and 14:30:45 collapse into one.
            // For bus (where bunching is real), use a tighter 30-second
            // bucket.  Non-timestamped arrivals fall back to trip/id keys.
            let dedupKey: String
            if let ts = arrival.arrivalTs, ts > 0 {
                let bucketSize = arrival.mode == "bus" ? 30 : 60
                let bucket = ts / bucketSize
                dedupKey = "\(arrival.stopName)-B\(bucket)"
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

    nonisolated init(
        direction: String,
        directionLabel: String? = nil,
        directionId: String? = nil,
        branchId: String? = nil,
        arrivals: [NearbyTransitResponse]
    ) {
        self.direction = direction
        self.directionLabel = directionLabel
        self.directionId = directionId
        self.branchId = branchId
        self.arrivals = arrivals
    }

    enum CodingKeys: String, CodingKey {
        case direction
        case directionLabel = "direction_label"
        case directionId = "direction_id"
        case branchId = "branch_id"
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

    init(
        title: String,
        severity: String,
        affectedRoutes: [String] = [],
        alertType: String? = nil,
        sortOrder: Int = 0
    ) {
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
    /// Express subway variants merged into this group (e.g. ["7X"]).
    var expressRoutes: [String] = []
    /// Bus service classification: "Local", "Limited", "Local / Limited",
    /// "Select Bus Service", "Express", "School", or nil for non-bus routes.
    var busServiceType: String?

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

    /// True when express subway service is active for this route.
    var hasExpressService: Bool { !expressRoutes.isEmpty }

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case displayName = "display_name"
        case mode
        case colorHex = "color_hex"
        case directions
        case sortingKey = "sorting_key"
        case alerts
        case expressRoutes = "express_routes"
        case busServiceType = "bus_service_type"
    }

    /// Memberwise initializer.
    nonisolated init(
        routeId: String,
        displayName: String,
        mode: String,
        colorHex: String? = nil,
        directions: [DirectionArrivalsResponse],
        sortingKey: String = "",
        alerts: [InlineAlertResponse] = [],
        expressRoutes: [String] = [],
        busServiceType: String? = nil
    ) {
        self.routeId = routeId
        self.displayName = displayName
        self.mode = mode
        self.colorHex = colorHex
        self.directions = directions
        self.sortingKey = sortingKey
        self.alerts = alerts
        self.expressRoutes = expressRoutes
        self.busServiceType = busServiceType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routeId = try c.decode(String.self, forKey: .routeId)
        displayName = try c.decode(String.self, forKey: .displayName)
        mode = try c.decode(String.self, forKey: .mode)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        directions = try c.decode([DirectionArrivalsResponse].self, forKey: .directions)
        sortingKey = try c.decodeIfPresent(String.self, forKey: .sortingKey) ?? ""
        alerts = try c.decodeIfPresent([InlineAlertResponse].self, forKey: .alerts) ?? []
        expressRoutes = try c.decodeIfPresent([String].self, forKey: .expressRoutes) ?? []
        busServiceType = try c.decodeIfPresent(String.self, forKey: .busServiceType)
    }
}

// MARK: - Inactive Route (no active service)

/// Matches the backend's `InactiveRoute` JSON schema.
/// Lightweight — no arrivals, just identification info for display.
struct InactiveRouteResponse: Codable, Identifiable {
    var id: String { routeId }

    let routeId: String
    let displayName: String
    let mode: String
    let colorHex: String?
    let busServiceType: String?
    let sortingKey: String

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case displayName = "display_name"
        case mode
        case colorHex = "color_hex"
        case busServiceType = "bus_service_type"
        case sortingKey = "sorting_key"
    }
}