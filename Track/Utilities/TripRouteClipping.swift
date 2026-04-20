// Utility functions for clipping a full route polyline to only the
// segment the user actually travels (board stop → alight stop).
// Extracted from TripRouteMapView so the logic can be unit-tested.

import CoreLocation
import UIKit

/// Pure-computation helpers — no MainActor needed.
nonisolated enum TripRouteClipping {

    // MARK: - Stop ID Matching

    /// Finds a stop by ID with normalization to handle prefix mismatches
    /// between the trip engine (bare GTFS IDs like "300000") and the shape
    /// endpoint (prefixed IDs like "MTA_300000").
    static func findStop(
        in stops: [BusStop],
        id: String,
        name: String? = nil
    ) -> BusStop? {
        // 1) Exact match
        if let match = stops.first(where: { $0.id == id }) {
            return match
        }

        // 2) Try adding common MTA prefix
        let prefixed = "MTA_" + id
        if let match = stops.first(where: { $0.id == prefixed }) {
            return match
        }

        // 3) Try stripping prefix from stop IDs to compare bare numbers
        let bareId = id.components(separatedBy: "_").last ?? id
        if let match = stops.first(where: {
            let bareStopId = $0.id.components(separatedBy: "_").last ?? $0.id
            return bareStopId == bareId
        }) {
            return match
        }

        // 4) Fallback: match by name (case-insensitive)
        if let name, !name.isEmpty {
            let upper = name.uppercased()
            if let match = stops.first(where: {
                $0.name.uppercased() == upper
            }) {
                return match
            }
            // Substring match for partial names
            if let match = stops.first(where: {
                let sn = $0.name.uppercased()
                return sn.contains(upper) || upper.contains(sn)
            }) {
                return match
            }
        }

        return nil
    }

    // MARK: - Shape Clipping

    /// Clips a full route shape to the segment between board and alight stops.
    static func clipShape(
        polylines: [[CLLocationCoordinate2D]],
        stops: [BusStop],
        boardStopId: String?,
        alightStopId: String?,
        boardStopName: String? = nil,
        alightStopName: String? = nil
    ) -> [CLLocationCoordinate2D] {
        let candidatePolylines = polylines.filter { $0.count >= 2 }
        guard !candidatePolylines.isEmpty else { return [] }

        guard let boardId = boardStopId,
              let alightId = alightStopId else {
            return candidatePolylines.first ?? []
        }

        let boardStop = findStop(in: stops, id: boardId, name: boardStopName)
        let alightStop = findStop(in: stops, id: alightId, name: alightStopName)

        guard let boardCoord = boardStop.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }),
              let alightCoord = alightStop.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
        else {
            #if DEBUG
            print("[TripRouteClipping] clipShape: stop ID match failed — board=\(boardId) alight=\(alightId)")
            print("  shape has \(stops.count) stops, sample IDs: \(stops.prefix(3).map(\.id))")
            #endif
            return candidatePolylines.first ?? []
        }

        var bestSlice: [CLLocationCoordinate2D] = []
        var bestScore = Double.greatestFiniteMagnitude

        for polyline in candidatePolylines {
            guard let boardMatch = nearestIndexWithDistance(in: polyline, to: boardCoord),
                  let alightMatch = nearestIndexWithDistance(in: polyline, to: alightCoord)
            else {
                continue
            }

            let startIdx = min(boardMatch.index, alightMatch.index)
            let endIdx = max(boardMatch.index, alightMatch.index)
            guard startIdx < endIdx, endIdx < polyline.count else { continue }

            let score = boardMatch.distance + alightMatch.distance
            if score < bestScore {
                bestScore = score
                bestSlice = Array(polyline[startIdx...endIdx])
            }
        }

        if !bestSlice.isEmpty {
            return bestSlice
        }

        let flattened = candidatePolylines.flatMap { $0 }
        guard let boardIdx = nearestIndex(in: flattened, to: boardCoord),
              let alightIdx = nearestIndex(in: flattened, to: alightCoord)
        else {
            return candidatePolylines.first ?? []
        }

        let startIdx = min(boardIdx, alightIdx)
        let endIdx = max(boardIdx, alightIdx)
        guard startIdx < endIdx, endIdx < flattened.count else {
            return candidatePolylines.first ?? []
        }
        return Array(flattened[startIdx...endIdx])
    }

    // MARK: - Nearest Index Helpers

    /// Returns the index of the coordinate nearest to the target.
    static func nearestIndex(
        in coords: [CLLocationCoordinate2D],
        to target: CLLocationCoordinate2D
    ) -> Int? {
        guard !coords.isEmpty else { return nil }
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, c) in coords.enumerated() {
            let dlat = c.latitude - target.latitude
            let dlon = c.longitude - target.longitude
            let dist = dlat * dlat + dlon * dlon
            if dist < bestDist {
                bestDist = dist
                bestIdx = i
            }
        }
        return bestIdx
    }

    /// Returns the index and squared-distance of the coordinate nearest to the target.
    static func nearestIndexWithDistance(
        in coords: [CLLocationCoordinate2D],
        to target: CLLocationCoordinate2D
    ) -> (index: Int, distance: Double)? {
        guard !coords.isEmpty else { return nil }
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, c) in coords.enumerated() {
            let dlat = c.latitude - target.latitude
            let dlon = c.longitude - target.longitude
            let dist = dlat * dlat + dlon * dlon
            if dist < bestDist {
                bestDist = dist
                bestIdx = i
            }
        }
        return (bestIdx, bestDist)
    }

    // MARK: - Walk Coordinate Resolution

    /// Builds walk-leg coordinates by stitching together the endpoints of
    /// adjacent transit legs.
    static func resolveWalkCoords(
        index: Int,
        results: [(Int, [CLLocationCoordinate2D]?, [[CLLocationCoordinate2D]]?, UIColor, Bool)],
        legCount: Int
    ) -> [CLLocationCoordinate2D] {
        var startCoord: CLLocationCoordinate2D?
        var endCoord: CLLocationCoordinate2D?

        for i in stride(from: index - 1, through: 0, by: -1) {
            if let coords = results.first(where: { $0.0 == i })?.1, let last = coords.last {
                startCoord = last
                break
            }
        }

        for i in (index + 1)..<legCount {
            if let coords = results.first(where: { $0.0 == i })?.1, let first = coords.first {
                endCoord = first
                break
            }
        }

        if startCoord == nil, endCoord == nil { return [] }
        if let s = startCoord, endCoord == nil { return [s] }
        if startCoord == nil, let e = endCoord { return [e] }

        return [startCoord!, endCoord!]
    }

    // MARK: - Intermediate Stop Extraction

    /// Returns the stops that lie between (inclusive) the board and alight
    /// stops, in route order.  Uses the same ID-normalization as `findStop`.
    static func clipStops(
        stops: [BusStop],
        boardStopId: String?,
        alightStopId: String?,
        boardStopName: String? = nil,
        alightStopName: String? = nil
    ) -> [CLLocationCoordinate2D] {
        guard let boardId = boardStopId,
              let alightId = alightStopId else { return [] }

        guard let boardStop = findStop(in: stops, id: boardId, name: boardStopName),
              let alightStop = findStop(in: stops, id: alightId, name: alightStopName)
        else { return [] }

        guard let boardIdx = stops.firstIndex(where: { $0.id == boardStop.id }),
              let alightIdx = stops.firstIndex(where: { $0.id == alightStop.id })
        else { return [] }

        let startIdx = min(boardIdx, alightIdx)
        let endIdx = max(boardIdx, alightIdx)
        guard startIdx <= endIdx else { return [] }

        return stops[startIdx...endIdx].map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
    }
}
