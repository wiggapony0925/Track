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
