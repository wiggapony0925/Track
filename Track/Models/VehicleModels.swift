// Data models for live vehicle positions on the map.
// Used by HomeViewModel for tracking subway trains, LIRR,
// Metro-North, and bus vehicles in real-time.

import Foundation

// MARK: - Train Vehicle

/// Represents a live train vehicle position on the map.
/// Used for subway, LIRR, and Metro-North vehicle tracking.
///
/// Decodes the backend `TransitVehicle` payload from
/// `GET /subway/vehicles/{line}` (real GTFS-RT positions). When the
/// backend feed has no vehicle entity for a trip, the client falls back
/// to interpolated positions built from arrival data — see
/// `HomeViewModel.updateTrainPositions(arrivals:realVehicles:)`.
struct TrainVehicle: Codable, Identifiable, Equatable {
    /// Stable identity. Maps to backend `vehicle_id` (or `trip_id` when
    /// the upstream feed omits a vehicle ID — common for NYCT subway).
    let id: String
    let tripId: String?
    let routeId: String
    /// Compass-style direction code derived client-side from the trip ID
    /// (e.g. "N", "S"). Backend doesn't supply this — defaults to "" when
    /// decoding directly from `/subway/vehicles/{line}`.
    var direction: String
    var lat: Double
    var lon: Double
    var bearing: Double?
    /// Next or current stop name (backend `current_stop_name`).
    var nextStationName: String?
    /// Estimated arrival time at the next station. Derived from arrival
    /// data on the client; backend payload doesn't include this.
    var estimatedArrival: Date?

    /// GTFS-RT VehiclePosition.OccupancyStatus (0=empty … 6=not_accepting).
    /// Optional — NYC subway publishes per-car crowding only on some lines.
    var occupancy: Int? = nil

    /// Current speed in mph (GTFS-RT VehiclePosition.position.speed converted).
    var speedMph: Double? = nil

    /// GTFS stop_id of the current/next stop.
    var currentStopId: String? = nil

    /// Human-readable VehicleStopStatus: INCOMING_AT, STOPPED_AT, IN_TRANSIT_TO.
    var status: String? = nil

    /// Transit mode: "subway", "lirr", "mnr".
    var mode: String? = nil

    /// Unix timestamp of the position report (seconds since epoch).
    var timestamp: Int? = nil

    /// Brand color hex for the route (e.g. "#0039A6" for the A train).
    var colorHex: String? = nil

    /// GTFS-RT VehiclePosition.CongestionLevel enum:
    /// 0=unknown, 1=running_smoothly, 2=stop_and_go, 3=congestion, 4=severe.
    var congestionLevel: Int? = nil

    /// Raw GTFS-RT VehicleStopStatus enum value:
    /// 0=incoming_at, 1=stopped_at, 2=in_transit_to.
    var currentStatusCode: Int? = nil

    /// Minutes until arrival at the next station. Computed live from
    /// `estimatedArrival` using ceil() to match `ArrivalETAEngine.minutesRemaining`.
    var minutesAway: Int? {
        guard let eta = estimatedArrival else { return nil }
        let seconds = eta.timeIntervalSinceNow
        guard seconds > -60 else { return nil }
        return max(0, Int(ceil(seconds / 60)))
    }

    /// True when the GTFS-RT feed reports the train as STOPPED_AT a station.
    /// Useful for status pills ("At platform" badge).
    var isStoppedAtStation: Bool { currentStatusCode == 1 }

    /// True when a backend GTFS-RT VehiclePosition is fresh enough to trust.
    /// Some NYCT feeds can retain old vehicle entities; when that happens the
    /// map should fall back to arrival-based interpolation instead of pinning
    /// a marker to stale stop coordinates.
    func isFreshRealtimePosition(
        now: Date = .now,
        maxAge: TimeInterval = 180
    ) -> Bool {
        guard let timestamp else { return true }
        return now.timeIntervalSince1970 - Double(timestamp) <= maxAge
    }

    enum CodingKeys: String, CodingKey {
        case id = "vehicle_id"
        case tripId = "trip_id"
        case routeId = "route_id"
        case direction
        case lat
        case lon
        case bearing
        case nextStationName = "current_stop_name"
        case estimatedArrival = "estimated_arrival"
        case occupancy = "occupancy_status"
        case speedMph = "speed_mph"
        case currentStopId = "current_stop_id"
        case status
        case mode
        case timestamp
        case colorHex = "color_hex"
        case congestionLevel = "congestion_level"
        case currentStatusCode = "current_status_code"
    }

    /// Memberwise init kept for client-built vehicles (interpolated markers,
    /// previews, tests). Real vehicles are constructed via `init(from:)`.
    init(
        id: String,
        tripId: String? = nil,
        routeId: String,
        direction: String,
        lat: Double,
        lon: Double,
        bearing: Double? = nil,
        nextStationName: String? = nil,
        estimatedArrival: Date? = nil,
        occupancy: Int? = nil,
        speedMph: Double? = nil,
        currentStopId: String? = nil,
        status: String? = nil,
        mode: String? = nil,
        timestamp: Int? = nil,
        colorHex: String? = nil,
        congestionLevel: Int? = nil,
        currentStatusCode: Int? = nil
    ) {
        self.id = id
        self.tripId = tripId
        self.routeId = routeId
        self.direction = direction
        self.lat = lat
        self.lon = lon
        self.bearing = bearing
        self.nextStationName = nextStationName
        self.estimatedArrival = estimatedArrival
        self.occupancy = occupancy
        self.speedMph = speedMph
        self.currentStopId = currentStopId
        self.status = status
        self.mode = mode
        self.timestamp = timestamp
        self.colorHex = colorHex
        self.congestionLevel = congestionLevel
        self.currentStatusCode = currentStatusCode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tripId = try c.decodeIfPresent(String.self, forKey: .tripId)
        routeId = try c.decode(String.self, forKey: .routeId)
        // Backend `/subway/vehicles/{line}` doesn't supply `direction` —
        // it's derived client-side from the trip_id when needed.
        direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? ""
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        bearing = try c.decodeIfPresent(Double.self, forKey: .bearing)
        nextStationName = try c.decodeIfPresent(String.self, forKey: .nextStationName)
        estimatedArrival = try c.decodeIfPresent(Date.self, forKey: .estimatedArrival)
        occupancy = try c.decodeIfPresent(Int.self, forKey: .occupancy)
        speedMph = try c.decodeIfPresent(Double.self, forKey: .speedMph)
        currentStopId = try c.decodeIfPresent(String.self, forKey: .currentStopId)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        congestionLevel = try c.decodeIfPresent(Int.self, forKey: .congestionLevel)
        currentStatusCode = try c.decodeIfPresent(Int.self, forKey: .currentStatusCode)
    }
}

/// Backend-owned live vehicle detail object. This wraps the old mode-specific
/// vehicle payload with freshness/confidence metadata so map rendering stays
/// O(n): decode details, filter stale/low-confidence entries, then project.
struct LiveVehicleDetailResponse: Decodable, Identifiable, Equatable {
    var id: String { vehicleId }

    let vehicleId: String
    let routeId: String
    let mode: String
    let tripId: String?
    let patternId: String?
    let directionId: String?
    let headsign: String?
    let lat: Double
    let lon: Double
    let bearing: Double?
    let nextStopId: String?
    let nextStopName: String?
    let downstreamStopCount: Int
    let downstreamStopIds: [String]
    let positionSource: String
    let positionAgeSeconds: Double?
    let isStale: Bool
    let isRealtime: Bool
    let positionConfidence: Double
    let status: String?
    let busVehicle: BusVehicleResponse?
    let trainVehicle: TrainVehicle?

    enum CodingKeys: String, CodingKey {
        case vehicleId = "vehicle_id"
        case routeId = "route_id"
        case mode
        case tripId = "trip_id"
        case patternId = "pattern_id"
        case directionId = "direction_id"
        case headsign
        case lat, lon, bearing
        case nextStopId = "next_stop_id"
        case nextStopName = "next_stop_name"
        case downstreamStopCount = "downstream_stop_count"
        case downstreamStopIds = "downstream_stop_ids"
        case positionSource = "position_source"
        case positionAgeSeconds = "position_age_seconds"
        case isStale = "is_stale"
        case isRealtime = "is_realtime"
        case positionConfidence = "position_confidence"
        case status
        case vehicle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vehicleId = try c.decode(String.self, forKey: .vehicleId)
        routeId = try c.decode(String.self, forKey: .routeId)
        mode = try c.decode(String.self, forKey: .mode)
        tripId = try c.decodeIfPresent(String.self, forKey: .tripId)
        patternId = try c.decodeIfPresent(String.self, forKey: .patternId)
        if let stringDirection = try? c.decodeIfPresent(String.self, forKey: .directionId) {
            directionId = stringDirection
        } else if let intDirection = try? c.decode(Int.self, forKey: .directionId) {
            directionId = String(intDirection)
        } else {
            directionId = nil
        }
        headsign = try c.decodeIfPresent(String.self, forKey: .headsign)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        bearing = try c.decodeIfPresent(Double.self, forKey: .bearing)
        nextStopId = try c.decodeIfPresent(String.self, forKey: .nextStopId)
        nextStopName = try c.decodeIfPresent(String.self, forKey: .nextStopName)
        downstreamStopCount = try c.decodeIfPresent(Int.self, forKey: .downstreamStopCount) ?? 0
        downstreamStopIds = try c.decodeIfPresent([String].self, forKey: .downstreamStopIds) ?? []
        positionSource = try c.decodeIfPresent(String.self, forKey: .positionSource) ?? "unknown"
        positionAgeSeconds = try c.decodeIfPresent(Double.self, forKey: .positionAgeSeconds)
        isStale = try c.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
        isRealtime = try c.decodeIfPresent(Bool.self, forKey: .isRealtime) ?? true
        positionConfidence = try c.decodeIfPresent(Double.self, forKey: .positionConfidence) ?? 1.0
        status = try c.decodeIfPresent(String.self, forKey: .status)

        if mode.lowercased() == "bus" {
            busVehicle = try? c.decodeIfPresent(BusVehicleResponse.self, forKey: .vehicle)
            trainVehicle = nil
        } else {
            busVehicle = nil
            trainVehicle = try? c.decodeIfPresent(TrainVehicle.self, forKey: .vehicle)
        }
    }
}

// MARK: - Bus Snapshot

/// A GPS snapshot for smooth bus position interpolation.
/// Stores the previous position so the map can animate (glide)
/// between updates along the route polyline.
struct BusSnapshot {
    let lat: Double
    let lon: Double
    let timestamp: Date
}
