// Utility functions for clipping a full route polyline to only the
// segment the user actually travels (board stop → alight stop).
// Extracted from TripRouteMapView so the logic can be unit-tested.

import CoreLocation
import UIKit

/// Pure-computation helpers — no MainActor needed.
nonisolated enum TripRouteClipping {

    private struct PolylineSnap {
        let coordinate: CLLocationCoordinate2D
        let segmentIndex: Int
        let segmentFraction: Double
        let distanceAlongLine: CLLocationDistance
        let distance: CLLocationDistance
    }

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

    static func findStop(
        in stops: [BusStop],
        id: String?,
        name: String? = nil
    ) -> BusStop? {
        if let id, !id.isEmpty,
           let match = findStop(in: stops, id: id, name: name) {
            return match
        }

        guard let name, !name.isEmpty else { return nil }
        let normalizedTarget = normalizedStopName(name)
        if let match = stops.first(where: {
            normalizedStopName($0.name) == normalizedTarget
        }) {
            return match
        }
        return stops.first(where: {
            let normalized = normalizedStopName($0.name)
            return normalized.contains(normalizedTarget)
                || normalizedTarget.contains(normalized)
        })
    }

    static func normalizedStopName(_ name: String) -> String {
        name.uppercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "AVENUE", with: "AV")
            .replacingOccurrences(of: "STREET", with: "ST")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Shape Clipping

    /// Clips a full route shape to the segment between board and alight stops.
    static func clipShape(
        polylines: [[CLLocationCoordinate2D]],
        stops: [BusStop],
        boardStopId: String?,
        alightStopId: String?,
        boardStopName: String? = nil,
        alightStopName: String? = nil,
        maxEndpointDistanceMeters: CLLocationDistance = 350
    ) -> [CLLocationCoordinate2D] {
        let candidatePolylines = polylines.filter { $0.count >= 2 }
        guard !candidatePolylines.isEmpty else { return [] }

            let boardStop = findStop(in: stops, id: boardStopId, name: boardStopName)
            let alightStop = findStop(in: stops, id: alightStopId, name: alightStopName)

        guard let boardCoord = boardStop.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }),
              let alightCoord = alightStop.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
        else {
            #if DEBUG
            print("[TripRouteClipping] clipShape: stop match failed — board=\(boardStopId ?? "nil") alight=\(alightStopId ?? "nil")")
            print("  shape has \(stops.count) stops, sample IDs: \(stops.prefix(3).map(\.id))")
            #endif
            return []
        }

        var bestSlice: [CLLocationCoordinate2D] = []
        var bestScore = Double.greatestFiniteMagnitude

        for polyline in candidatePolylines {
            guard let boardMatch = snapPoint(boardCoord, to: polyline),
                  let alightMatch = snapPoint(alightCoord, to: polyline),
                  boardMatch.distance <= maxEndpointDistanceMeters,
                  alightMatch.distance <= maxEndpointDistanceMeters
            else {
                continue
            }

            let start = boardMatch.distanceAlongLine <= alightMatch.distanceAlongLine
                ? boardMatch
                : alightMatch
            let end = boardMatch.distanceAlongLine <= alightMatch.distanceAlongLine
                ? alightMatch
                : boardMatch
            guard end.distanceAlongLine > start.distanceAlongLine else { continue }

            let score = boardMatch.distance + alightMatch.distance
            if score < bestScore {
                bestScore = score
                bestSlice = clippedPolyline(polyline, from: start, to: end)
            }
        }

        if !bestSlice.isEmpty {
            return bestSlice
        }
        return []
    }

    private static func clippedPolyline(
        _ polyline: [CLLocationCoordinate2D],
        from start: PolylineSnap,
        to end: PolylineSnap
    ) -> [CLLocationCoordinate2D] {
        guard polyline.count >= 2 else { return polyline }

        var result: [CLLocationCoordinate2D] = [start.coordinate]
        let firstVertex = min(start.segmentIndex + 1, polyline.count - 1)
        let lastVertex = max(0, min(end.segmentIndex, polyline.count - 1))
        if firstVertex <= lastVertex {
            result.append(contentsOf: polyline[firstVertex...lastVertex])
        }
        result.append(end.coordinate)
        return removeNearDuplicates(result)
    }

    private static func snapPoint(
        _ coordinate: CLLocationCoordinate2D,
        to polyline: [CLLocationCoordinate2D]
    ) -> PolylineSnap? {
        guard polyline.count >= 2 else { return nil }

        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var totalLength = CLLocationDistance(0)
        var segmentLengths: [CLLocationDistance] = []
        segmentLengths.reserveCapacity(polyline.count - 1)

        for index in 0..<(polyline.count - 1) {
            let length = CLLocation(
                latitude: polyline[index].latitude,
                longitude: polyline[index].longitude
            ).distance(from: CLLocation(
                latitude: polyline[index + 1].latitude,
                longitude: polyline[index + 1].longitude
            ))
            segmentLengths.append(length)
            totalLength += length
        }
        guard totalLength > 0 else { return nil }

        var distanceBeforeSegment = CLLocationDistance(0)
        var bestCoordinate = polyline[0]
        var bestSegmentIndex = 0
        var bestSegmentFraction = 0.0
        var bestDistanceAlong = CLLocationDistance(0)
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude

        for index in 0..<(polyline.count - 1) {
            let projected = projectPointOntoSegment(
                point: coordinate,
                a: polyline[index],
                b: polyline[index + 1]
            )
            let projectedLocation = CLLocation(
                latitude: projected.coordinate.latitude,
                longitude: projected.coordinate.longitude
            )
            let distance = target.distance(from: projectedLocation)
            if distance < bestDistance {
                bestDistance = distance
                bestCoordinate = projected.coordinate
                bestSegmentIndex = index
                bestSegmentFraction = projected.fraction
                bestDistanceAlong = distanceBeforeSegment + segmentLengths[index] * projected.fraction
            }
            distanceBeforeSegment += segmentLengths[index]
        }

        return PolylineSnap(
            coordinate: bestCoordinate,
            segmentIndex: bestSegmentIndex,
            segmentFraction: bestSegmentFraction,
            distanceAlongLine: bestDistanceAlong,
            distance: bestDistance
        )
    }

    private static func projectPointOntoSegment(
        point: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> (coordinate: CLLocationCoordinate2D, fraction: Double) {
        let dx = b.longitude - a.longitude
        let dy = b.latitude - a.latitude
        let lenSq = dx * dx + dy * dy
        guard lenSq >= 1e-18 else { return (a, 0) }

        let rawFraction = ((point.longitude - a.longitude) * dx + (point.latitude - a.latitude) * dy) / lenSq
        let fraction = min(1, max(0, rawFraction))
        return (
            CLLocationCoordinate2D(
                latitude: a.latitude + dy * fraction,
                longitude: a.longitude + dx * fraction
            ),
            fraction
        )
    }

    private static func removeNearDuplicates(
        _ coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(coordinates.count)
        for coordinate in coordinates {
            if let last = result.last {
                let distance = CLLocation(
                    latitude: last.latitude,
                    longitude: last.longitude
                ).distance(from: CLLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ))
                if distance < 1 { continue }
            }
            result.append(coordinate)
        }
        return result
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

    /// Returns the nearest coordinate index and distance in meters.
    static func nearestIndexWithDistanceMeters(
        in coords: [CLLocationCoordinate2D],
        to target: CLLocationCoordinate2D
    ) -> (index: Int, distance: CLLocationDistance)? {
        guard !coords.isEmpty else { return nil }
        let targetLocation = CLLocation(
            latitude: target.latitude,
            longitude: target.longitude
        )
        var bestIdx = 0
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        for (i, coord) in coords.enumerated() {
            let distance = CLLocation(
                latitude: coord.latitude,
                longitude: coord.longitude
            ).distance(from: targetLocation)
            if distance < bestDist {
                bestDist = distance
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
          guard let boardStop = findStop(in: stops, id: boardStopId, name: boardStopName),
              let alightStop = findStop(in: stops, id: alightStopId, name: alightStopName)
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
