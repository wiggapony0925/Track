//
//  LocalGTFSBundle.swift
//  Track
//
//  On-device read-only SQLite wrapper around the mobile GTFS bundle
//  produced by the backend (`/gtfs/bundle/{filename}`).  Powers offline
//  drag-search:  given a map bbox, return every transit stop visible
//  inside it together with the routes that serve each stop — without
//  ever touching the network.
//
//  Schema (see TrackBackend/app/services/gtfs/mobile_bundle.py):
//      stops          (stop_id, stop_name, stop_lat, stop_lon, parent_station, mode)
//      stops_id_map   (rowid, stop_id)
//      stops_rtree    R*Tree on (min_lat, max_lat, min_lon, max_lon)
//      routes         (route_id, short_name, long_name, color, mode, agency_id)
//      route_stops    (route_id, stop_id, direction_id)
//      metadata       (key, value)
//
//  Concurrency: SQLite handle is opened with SQLITE_OPEN_READONLY |
//  SQLITE_OPEN_FULLMUTEX so it is safe to share across threads.  Hot
//  prepared statements are cached per-thread inside this actor.
//

import Foundation
import SQLite3

// SQLITE_TRANSIENT is a special pointer the SQLite C API uses to mean
// "copy this value into your own memory".  Importing it into Swift
// requires a small bridging cast.
private let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
)

// MARK: - Models

public struct LocalStop: Hashable, Sendable {
    public let stopID: String
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let mode: String
    public let parentStation: String?
}

public struct LocalRoute: Hashable, Sendable {
    public let routeID: String
    public let shortName: String?
    public let longName: String?
    public let colorHex: String?
    public let mode: String
}

public struct LocalStopWithRoutes: Hashable, Sendable {
    public let stop: LocalStop
    public let routes: [LocalRoute]
}

public struct LocalBundleMetadata: Sendable {
    public let regionID: String
    public let schemaVersion: Int
    public let stopsCount: Int
    public let routesCount: Int
    public let routeStopsCount: Int
    public let generatedAt: Date
}

public enum LocalGTFSError: Error, CustomStringConvertible {
    case fileNotFound(URL)
    case openFailed(String)
    case prepareFailed(String)
    case schemaMismatch(expected: Int, found: Int)

    public var description: String {
        switch self {
        case .fileNotFound(let url): return "GTFS bundle not found at \(url.path)"
        case .openFailed(let msg): return "Failed to open GTFS bundle: \(msg)"
        case .prepareFailed(let msg): return "Failed to prepare statement: \(msg)"
        case .schemaMismatch(let e, let f):
            return "GTFS bundle schema_version mismatch — expected \(e), got \(f)"
        }
    }
}

// MARK: - Bundle handle

public final class LocalGTFSBundle: @unchecked Sendable {
    public static let supportedSchemaVersion = 2

    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "track.gtfs.local", qos: .userInitiated)

    public let url: URL
    public let metadata: LocalBundleMetadata

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalGTFSError.fileNotFound(url)
        }

        var handle: OpaquePointer?
        // FULLMUTEX = serialized mode; safe to share the handle across
        // threads (we still serialize via `queue` for predictable
        // statement-level ordering, but this guards against any stray
        // SDK call paths).
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, openFlags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let h = handle { sqlite3_close_v2(h) }
            throw LocalGTFSError.openFailed(msg)
        }

        // Defensive PRAGMAs — we are read-only but these speed lookups.
        sqlite3_exec(handle, "PRAGMA query_only = ON;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA cache_size = -8192;", nil, nil, nil) // 8 MB

        self.db = handle
        self.url = url
        self.metadata = try Self.readMetadata(db: handle)

        guard metadata.schemaVersion == Self.supportedSchemaVersion else {
            sqlite3_close_v2(handle)
            throw LocalGTFSError.schemaMismatch(
                expected: Self.supportedSchemaVersion,
                found: metadata.schemaVersion
            )
        }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Metadata

    private static func readMetadata(db: OpaquePointer) throws -> LocalBundleMetadata {
        var values: [String: String] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT key, value FROM metadata"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw LocalGTFSError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let value = String(cString: sqlite3_column_text(stmt, 1))
            values[key] = value
        }

        return LocalBundleMetadata(
            regionID: values["region_id"] ?? "unknown",
            schemaVersion: Int(values["schema_version"] ?? "0") ?? 0,
            stopsCount: Int(values["stops_count"] ?? "0") ?? 0,
            routesCount: Int(values["routes_count"] ?? "0") ?? 0,
            routeStopsCount: Int(values["route_stops_count"] ?? "0") ?? 0,
            generatedAt: Date(
                timeIntervalSince1970: TimeInterval(values["generated_at"] ?? "0") ?? 0
            )
        )
    }

    // MARK: - Bbox query (drag-search)

    /// Returns every stop inside the given bbox, optionally restricted
    /// to a subset of modes ("subway", "bus", "lirr", "mnr", "rail",
    /// "ferry").  Uses the R*Tree index — sub-millisecond at city scale.
    public func stops(
        inBbox minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        modes: Set<String>? = nil,
        limit: Int = 500
    ) -> [LocalStop] {
        return queue.sync { [self] in
            stopsLocked(
                minLat: minLat, maxLat: maxLat,
                minLon: minLon, maxLon: maxLon,
                modes: modes, limit: limit
            )
        }
    }

    private func stopsLocked(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double,
        modes: Set<String>?, limit: Int
    ) -> [LocalStop] {
        // Build mode filter inline — set is small, escape via the IN list.
        let modeFilter: String
        if let modes, !modes.isEmpty {
            let safe = modes.compactMap { $0.allSatisfy { $0.isLetter } ? "'\($0)'" : nil }
            modeFilter = safe.isEmpty ? "" : "AND s.mode IN (\(safe.joined(separator: ",")))"
        } else {
            modeFilter = ""
        }

        let sql = """
        SELECT s.stop_id, s.stop_name, s.stop_lat, s.stop_lon, s.parent_station, s.mode
          FROM stops_rtree rt
          JOIN stops_id_map m ON m.rowid = rt.id
          JOIN stops s ON s.stop_id = m.stop_id
         WHERE rt.min_lat <= ? AND rt.max_lat >= ?
           AND rt.min_lon <= ? AND rt.max_lon >= ?
           \(modeFilter)
         LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, maxLat)
        sqlite3_bind_double(stmt, 2, minLat)
        sqlite3_bind_double(stmt, 3, maxLon)
        sqlite3_bind_double(stmt, 4, minLon)
        sqlite3_bind_int(stmt, 5, Int32(limit))

        var results: [LocalStop] = []
        results.reserveCapacity(min(limit, 256))

        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(
                LocalStop(
                    stopID: String(cString: sqlite3_column_text(stmt, 0)),
                    name: String(cString: sqlite3_column_text(stmt, 1)),
                    latitude: sqlite3_column_double(stmt, 2),
                    longitude: sqlite3_column_double(stmt, 3),
                    mode: String(cString: sqlite3_column_text(stmt, 5)),
                    parentStation: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                        ? nil : String(cString: sqlite3_column_text(stmt, 4))
                )
            )
        }
        return results
    }

    // MARK: - Routes for stops

    /// Returns the set of routes that serve any of the given stops.
    /// Used after a bbox query to enrich the on-screen list with route
    /// badges, colors, and names.
    public func routes(forStops stopIDs: [String]) -> [String: [LocalRoute]] {
        guard !stopIDs.isEmpty else { return [:] }
        return queue.sync { [self] in
            routesLocked(forStops: stopIDs)
        }
    }

    private func routesLocked(forStops stopIDs: [String]) -> [String: [LocalRoute]] {
        // Process in chunks of 500 to stay well under SQLITE_MAX_VARIABLE_NUMBER (999).
        var out: [String: [LocalRoute]] = [:]
        out.reserveCapacity(stopIDs.count)
        let chunkSize = 500
        var index = 0
        while index < stopIDs.count {
            let end = min(index + chunkSize, stopIDs.count)
            let chunk = Array(stopIDs[index..<end])
            queryChunk(chunk, into: &out)
            index = end
        }
        return out
    }

    private func queryChunk(_ stopIDs: [String], into out: inout [String: [LocalRoute]]) {
        let placeholders = Array(repeating: "?", count: stopIDs.count).joined(separator: ",")
        let sql = """
        SELECT rs.stop_id,
               r.route_id, r.short_name, r.long_name, r.color, r.mode
          FROM route_stops rs
          JOIN routes r ON r.route_id = rs.route_id
         WHERE rs.stop_id IN (\(placeholders))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        for (i, sid) in stopIDs.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), sid, -1, SQLITE_TRANSIENT)
        }

        var seen: Set<String> = []  // (stopID|routeID) dedup
        seen.reserveCapacity(stopIDs.count * 4)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let stopID = String(cString: sqlite3_column_text(stmt, 0))
            let routeID = String(cString: sqlite3_column_text(stmt, 1))
            let dedupKey = stopID + "|" + routeID
            if !seen.insert(dedupKey).inserted { continue }

            let route = LocalRoute(
                routeID: routeID,
                shortName: sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 2)),
                longName: sqlite3_column_type(stmt, 3) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 3)),
                colorHex: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 4)),
                mode: String(cString: sqlite3_column_text(stmt, 5))
            )
            out[stopID, default: []].append(route)
        }
    }

    // MARK: - Convenience: drag-search in one call

    /// Single-call drag-search: bbox → stops + routes per stop.  iOS
    /// callers that just want "what's visible in the rectangle" use
    /// this instead of two separate calls.
    public func dragSearch(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double,
        modes: Set<String>? = nil,
        limit: Int = 200
    ) -> [LocalStopWithRoutes] {
        let stopList = stops(
            inBbox: minLat, maxLat: maxLat,
            minLon: minLon, maxLon: maxLon,
            modes: modes, limit: limit
        )
        guard !stopList.isEmpty else { return [] }
        let routesByStop = routes(forStops: stopList.map(\.stopID))
        return stopList.map { stop in
            LocalStopWithRoutes(stop: stop, routes: routesByStop[stop.stopID] ?? [])
        }
    }

    // MARK: - Headway estimates (Phase D — offline scheduled fallback)

    /// Estimated wait time, in minutes, for the next vehicle on `routeID`
    /// at the given local date.  Uses the `route_headways` table baked
    /// into the bundle (trips per (route, day_type, hour) bucket).  We
    /// return ceil(headway / 2) under the standard assumption that a
    /// rider who arrives at a random moment within the hour waits, on
    /// average, half the headway.
    ///
    /// Returns `nil` when no schedule data exists for that bucket
    /// (overnight gaps, suspended service, unknown route) so callers
    /// can fall back to a generic placeholder.
    public func expectedWaitMinutes(routeID: String, at date: Date = Date()) -> Int? {
        let cal = Calendar(identifier: .gregorian)
        let components = cal.dateComponents([.weekday, .hour], from: date)
        // Calendar.weekday: 1 = Sunday, 7 = Saturday
        let dayType: Int
        switch components.weekday ?? 0 {
        case 1: dayType = 2  // Sunday
        case 7: dayType = 1  // Saturday
        default: dayType = 0 // Weekday (Mon-Fri)
        }
        let hour = components.hour ?? 0

        return queue.sync { [self] in
            tripsLocked(routeID: routeID, dayType: dayType, hour: hour).flatMap { trips in
                guard trips > 0 else { return nil }
                let headway = max(1, 60 / trips)
                // Average wait is half the headway, ceil to whole minutes.
                return max(1, (headway + 1) / 2)
            }
        }
    }

    private func tripsLocked(routeID: String, dayType: Int, hour: Int) -> Int? {
        let sql = "SELECT trips FROM route_headways WHERE route_id = ? AND day_type = ? AND hour = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, routeID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(dayType))
        sqlite3_bind_int(stmt, 3, Int32(hour))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
