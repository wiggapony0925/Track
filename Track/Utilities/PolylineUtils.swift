//
//  PolylineUtils.swift
//  Track
//
//  Google-encoded polyline encoding and decoding utilities.
//  Used by TrackAPI response types and HomeViewModel to convert
//  between encoded polyline strings and coordinate arrays.
//

import CoreLocation

/// Decodes a Google-encoded polyline string into an array of coordinates.
func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
    var coordinates: [CLLocationCoordinate2D] = []
    var index = encoded.startIndex
    var lat: Int32 = 0
    var lon: Int32 = 0

    while index < encoded.endIndex {
        var shift: Int32 = 0
        var result: Int32 = 0
        var byte: Int32

        repeat {
            byte = Int32(encoded[index].asciiValue ?? 0) - 63
            index = encoded.index(after: index)
            result |= (byte & 0x1F) << shift
            shift += 5
        } while byte >= 0x20 && index < encoded.endIndex

        let dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        lat += dlat

        shift = 0
        result = 0

        guard index < encoded.endIndex else { break }

        repeat {
            byte = Int32(encoded[index].asciiValue ?? 0) - 63
            index = encoded.index(after: index)
            result |= (byte & 0x1F) << shift
            shift += 5
        } while byte >= 0x20 && index < encoded.endIndex

        let dlon = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        lon += dlon

        coordinates.append(
            CLLocationCoordinate2D(
                latitude: Double(lat) / 1e5,
                longitude: Double(lon) / 1e5
            )
        )
    }

    return coordinates
}

/// Encodes an array of coordinates into a Google-encoded polyline string.
/// This is the inverse of `decodePolyline` — used to build polyline strings
/// from known stop coordinates (e.g. subway station locations).
func encodePolyline(_ coordinates: [CLLocationCoordinate2D]) -> String {
    var encoded = ""
    var prevLat: Int32 = 0
    var prevLon: Int32 = 0

    for coord in coordinates {
        let lat = Int32(round(coord.latitude * 1e5))
        let lon = Int32(round(coord.longitude * 1e5))

        encodeValue(lat - prevLat, into: &encoded)
        encodeValue(lon - prevLon, into: &encoded)

        prevLat = lat
        prevLon = lon
    }

    return encoded
}

/// Encodes a single signed value into the Google polyline encoding format.
private func encodeValue(_ value: Int32, into result: inout String) {
    var v = value < 0 ? ~(value << 1) : (value << 1)
    while v >= 0x20 {
        let chunk = Int32((v & 0x1F) | 0x20) + 63
        result.append(Character(UnicodeScalar(Int(chunk))!))
        v >>= 5
    }
    result.append(Character(UnicodeScalar(Int(v + 63))!))
}

// MARK: - Polyline Simplification (Ramer-Douglas-Peucker)

/// Simplifies a polyline by removing points that are within `tolerance`
/// of the line between retained points. Uses the Ramer-Douglas-Peucker
/// algorithm to dramatically reduce point counts while preserving shape.
///
/// - Parameters:
///   - coordinates: The original polyline coordinates.
///   - tolerance: Maximum perpendicular distance a point can deviate before
///     it must be kept. Uses an approximate planar projection (degree
///     differences) which is suitable for small geographic areas like a
///     city transit network. ~0.00015° ≈ 17 m at NYC latitude (40.7°N).
/// - Returns: A simplified coordinate array. Returns the original array
///   unchanged if it has fewer than 3 points.
func simplifyPolyline(
    _ coordinates: [CLLocationCoordinate2D],
    tolerance: Double
) -> [CLLocationCoordinate2D] {
    guard coordinates.count >= 3 else { return coordinates }
    return rdpSimplify(coordinates, tolerance: tolerance)
}

/// Recursive Ramer-Douglas-Peucker implementation.
private func rdpSimplify(
    _ points: [CLLocationCoordinate2D],
    tolerance: Double
) -> [CLLocationCoordinate2D] {
    guard points.count >= 3 else { return points }

    let first = points[0]
    let last = points[points.count - 1]

    var maxDist = 0.0
    var maxIdx = 0

    for i in 1..<(points.count - 1) {
        let d = perpendicularDistance(points[i], lineStart: first, lineEnd: last)
        if d > maxDist {
            maxDist = d
            maxIdx = i
        }
    }

    if maxDist > tolerance {
        let left = rdpSimplify(Array(points[0...maxIdx]), tolerance: tolerance)
        let right = rdpSimplify(Array(points[maxIdx...]), tolerance: tolerance)
        return left.dropLast() + right
    } else {
        return [first, last]
    }
}

/// Perpendicular distance from a point to a line segment (in degrees).
private func perpendicularDistance(
    _ point: CLLocationCoordinate2D,
    lineStart: CLLocationCoordinate2D,
    lineEnd: CLLocationCoordinate2D
) -> Double {
    let dx = lineEnd.longitude - lineStart.longitude
    let dy = lineEnd.latitude - lineStart.latitude
    let lengthSq = dx * dx + dy * dy

    guard lengthSq > 0 else {
        let px = point.longitude - lineStart.longitude
        let py = point.latitude - lineStart.latitude
        return sqrt(px * px + py * py)
    }

    let t = max(0, min(1, (
        (point.longitude - lineStart.longitude) * dx +
        (point.latitude - lineStart.latitude) * dy
    ) / lengthSq))

    let projLon = lineStart.longitude + t * dx
    let projLat = lineStart.latitude + t * dy

    let px = point.longitude - projLon
    let py = point.latitude - projLat
    return sqrt(px * px + py * py)
}
