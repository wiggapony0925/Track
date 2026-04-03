import Foundation
import CoreLocation

/// Backward-compatible alias — prefer `TransitArrivalResponse` in new code.
typealias SubwayArrivalResponse = TransitArrivalResponse

/// Matches the backend's `TrackArrival` JSON schema (snake_case).
/// Renamed from `SubwayArrivalResponse` — works for subway, LIRR, and MNR.
struct TransitArrivalResponse: Codable {
    let routeId: String
    let station: String
    let stationName: String?
    let direction: String
    let destination: String?
    let minutesAway: Int
    let status: String
    let stopLat: Double?
    let stopLon: Double?
    let tripId: String? // Optional since backend might not send it for older cached data
    let arrivalTs: Int? // Optional timestamp in seconds
    /// True when GTFS-RT reports this trip as CANCELED or a stop as SKIPPED.
    var isCancelled: Bool = false

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case station
        case stationName = "station_name"
        case direction
        case destination
        case minutesAway = "minutes_away"
        case status
        case stopLat = "stop_lat"
        case stopLon = "stop_lon"
        case tripId = "trip_id"
        case arrivalTs = "arrival_ts"
        case isCancelled = "is_cancelled"
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
        
        // Build a deterministic identity from trip + stop + time so SwiftUI
        // can diff arrivals across API polls without re-creating every row.
        let stableId: String
        if let tripId {
            stableId = "\(tripId)_\(station)"
        } else {
            stableId = "\(routeId)_\(station)_\(direction)_\(Int(arrivalDate.timeIntervalSince1970))"
        }

        return TrainArrival(
            id: stableId,
            routeID: routeId,
            stationID: station,
            stationName: stationName ?? station,
            stopLat: stopLat,
            stopLon: stopLon,
            direction: direction,
            scheduledTime: arrivalDate,
            estimatedTime: arrivalDate,
            minutesAway: minutesAway,
            destination: destination,
            status: status,
            tripId: tripId,
            isCancelled: isCancelled
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

/// A point where two trunk groups cross at a significant angle.
/// Used by the client to render casing breaks — small gaps in the
/// lower trunk's casing layer that create an over/under visual effect.
struct CrossingPoint: Codable {
    let lat: Double
    let lng: Double
    let trunkIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case lat, lng
        case trunkIndices = "trunk_indices"
    }
}

/// Response containing all subway lines for the system map.
struct AllSubwayLinesResponse: Codable {
    let lines: [SubwayLineOverlay]
    /// Pre-merged trunk-level polylines from the corridor pipeline.
    /// When present, the client renders these directly instead of pooling
    /// per-route GTFS shapes — eliminating duplicate stacked lines and
    /// ensuring polylines pass through snapped station positions.
    let trunkPolylines: [TrunkGroupPolylines]?
    /// Crossing points where different trunk groups intersect.
    /// Used for casing-break rendering (over/under effect).
    let crossings: [CrossingPoint]?

    enum CodingKeys: String, CodingKey {
        case lines
        case trunkPolylines = "trunk_polylines"
        case crossings
    }
}

/// Pre-merged polylines for one MTA trunk colour group.
/// Produced by the corridor pipeline's Phase 1 (merge) + Phase 3 (offset).
struct TrunkGroupPolylines: Codable {
    let trunkIndex: Int
    let colorHex: String
    let routeIds: [String]
    let polylines: [String]
    /// Signed perpendicular offset for low-zoom pixel-space separation.
    /// The iOS client multiplies this by a zoom-interpolated factor and
    /// feeds it to MapLibre's ``lineOffset`` paint property so parallel
    /// trunk groups remain visually distinct at city-wide zoom levels.
    let laneOffset: CGFloat
    /// Local lane offsets aligned 1:1 with ``polylines``. These let the
    /// renderer move only the shared corridor segments instead of shoving
    /// an entire trunk sideways away from raw MTA stop coordinates.
    let polylineLaneOffsets: [CGFloat]

    enum CodingKeys: String, CodingKey {
        case trunkIndex = "trunk_index"
        case colorHex = "color_hex"
        case routeIds = "route_ids"
        case polylines
        case laneOffset = "lane_offset"
        case polylineLaneOffsets = "polyline_lane_offsets"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trunkIndex = try container.decode(Int.self, forKey: .trunkIndex)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        routeIds = try container.decode([String].self, forKey: .routeIds)
        polylines = try container.decode([String].self, forKey: .polylines)
        laneOffset = try container.decodeIfPresent(CGFloat.self, forKey: .laneOffset) ?? 0.0
        polylineLaneOffsets = try container.decodeIfPresent(
            [CGFloat].self,
            forKey: .polylineLaneOffsets
        ) ?? []
    }

    /// Decodes polylines on demand.
    var decodedPolylines: [[CLLocationCoordinate2D]] {
        polylines.map { decodePolyline($0) }
    }
}

/// A single commuter-rail stop within a line overlay.
struct CommuterRailStopOverlay: Codable {
    let stopId: String
    let name: String
    let lat: Double
    let lon: Double

    enum CodingKeys: String, CodingKey {
        case stopId = "stop_id"
        case name
        case lat
        case lon
    }
}

/// Lightweight overlay for drawing a single commuter rail line on the map.
struct CommuterRailLineOverlay: Codable, Identifiable {
    var id: String { routeId }
    let routeId: String
    let name: String
    let colorHex: String
    let polylines: [String]
    let mode: String  // "lirr" or "mnr"
    let stops: [CommuterRailStopOverlay]

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case name
        case colorHex = "color_hex"
        case polylines
        case mode
        case stops
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        routeId = try container.decode(String.self, forKey: .routeId)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        polylines = try container.decode([String].self, forKey: .polylines)
        mode = try container.decode(String.self, forKey: .mode)
        stops = try container.decodeIfPresent([CommuterRailStopOverlay].self, forKey: .stops) ?? []
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

// MARK: - Processed Stations (offset-snapped positions from pipeline Phase 6)

/// A stop position snapped onto a specific route's offset polyline.
struct ProcessedStopPosition: Codable {
    let routeId: String
    let lat: Double
    let lon: Double

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case lat
        case lon
    }
}

/// A station with per-route positions snapped onto the offset polylines.
/// `isTransfer` is true when the station spans ≥ 2 MTA trunk-color groups.
/// iOS draws a colored dot for single-line stops and a white pill bar
/// for transfer hubs.
struct ProcessedStation: Codable, Identifiable {
    var id: String { stationId }
    let stationId: String
    let name: String
    let isTransfer: Bool
    let positions: [ProcessedStopPosition]

    enum CodingKeys: String, CodingKey {
        case stationId = "station_id"
        case name
        case isTransfer = "is_transfer"
        case positions
    }
}

/// Response from ``/subway/stations/processed``.
struct ProcessedStationsResponse: Codable {
    let stations: [ProcessedStation]
}
