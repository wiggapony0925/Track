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

// MARK: - Polyline Merging

/// Merges adjacent polyline segments into fewer continuous polylines.
///
/// When a route direction has multiple segments whose endpoints are close
/// together, SwiftUI renders them as separate `MapPolyline` views. This
/// creates visible seams (especially with casing + fill strokes) and
/// increases overlay count. This function joins chains greedily using
/// all four orientations (append, prepend, reversed append, reversed prepend)
/// so even reversed or out-of-order segments get merged.
///
/// - Parameters:
///   - segments: Arrays of coordinates, each representing one polyline segment.
///   - gapThreshold: Maximum distance (in degrees, ~111 m per 0.001°) between
///     endpoints for two segments to be considered joinable.
///     Default `0.002` ≈ 220 m at NYC latitude — generous enough to bridge
///     GTFS shape gaps at transfer points and diverge/converge sections.
/// - Returns: Merged polyline arrays (typically far fewer than the input).
func mergeAdjacentPolylines(
    _ segments: [[CLLocationCoordinate2D]],
    gapThreshold: Double = 0.002
) -> [[CLLocationCoordinate2D]] {
    guard segments.count > 1 else { return segments }

    // Filter out degenerate segments
    var remaining = segments.filter { $0.count >= 2 }
    guard remaining.count > 1 else { return remaining }

    // Squared threshold for fast comparison (avoid sqrt)
    let threshSq = gapThreshold * gapThreshold

    func distSq(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dx = a.longitude - b.longitude
        let dy = a.latitude - b.latitude
        return dx * dx + dy * dy
    }

    var chains: [[CLLocationCoordinate2D]] = [remaining.removeFirst()]

    while !remaining.isEmpty {
        var merged = false
        for i in remaining.indices {
            let seg = remaining[i]
            guard let segFirst = seg.first, let segLast = seg.last else { continue }

            // Try to attach to any existing chain
            for c in chains.indices {
                guard let chainFirst = chains[c].first, let chainLast = chains[c].last else {
                    continue
                }

                if distSq(chainLast, segFirst) <= threshSq {
                    // Append: chain-end → seg-start
                    chains[c].append(contentsOf: seg.dropFirst())
                    remaining.remove(at: i)
                    merged = true
                    break
                } else if distSq(chainFirst, segLast) <= threshSq {
                    // Prepend: seg-end → chain-start
                    chains[c] = seg + chains[c].dropFirst()
                    remaining.remove(at: i)
                    merged = true
                    break
                } else if distSq(chainLast, segLast) <= threshSq {
                    // Append reversed: chain-end → seg-reversed-start
                    chains[c].append(contentsOf: seg.reversed().dropFirst())
                    remaining.remove(at: i)
                    merged = true
                    break
                } else if distSq(chainFirst, segFirst) <= threshSq {
                    // Prepend reversed: seg-reversed-end → chain-start
                    chains[c] = seg.reversed() + chains[c].dropFirst()
                    remaining.remove(at: i)
                    merged = true
                    break
                }
            }
            if merged { break }
        }

        // If no segment could be merged into any chain, start a new chain
        if !merged {
            chains.append(remaining.removeFirst())
        }
    }

    // Second pass: keep merging chains with each other until stable
    var didMerge = true
    while didMerge {
        didMerge = false
        outer: for i in 0..<chains.count {
            for j in (i + 1)..<chains.count {
                guard let iLast = chains[i].last, let jFirst = chains[j].first,
                      let iFirst = chains[i].first, let jLast = chains[j].last
                else { continue }

                if distSq(iLast, jFirst) <= threshSq {
                    chains[i].append(contentsOf: chains[j].dropFirst())
                    chains.remove(at: j)
                    didMerge = true
                    break outer
                } else if distSq(jLast, iFirst) <= threshSq {
                    chains[i] = chains[j] + chains[i].dropFirst()
                    chains.remove(at: j)
                    didMerge = true
                    break outer
                } else if distSq(iLast, jLast) <= threshSq {
                    chains[i].append(contentsOf: chains[j].reversed().dropFirst())
                    chains.remove(at: j)
                    didMerge = true
                    break outer
                } else if distSq(iFirst, jFirst) <= threshSq {
                    chains[i] = chains[j].reversed() + chains[i].dropFirst()
                    chains.remove(at: j)
                    didMerge = true
                    break outer
                }
            }
        }
    }

    return chains.filter { $0.count >= 2 }
}

// MARK: - Cross-Color Corridor Offsets (Apple Maps Style)

/// Applies perpendicular offsets to polylines of different color groups that
/// share a physical corridor, so they render as parallel colored stripes
/// instead of stacking on top of each other — matching Apple Maps transit.
///
/// **How it works**:
/// 1. Builds a spatial grid of all polylines from all color groups using
///    a 3×3 neighbor expansion for registration (catches parallel tracks).
/// 2. For each polyline point, determines how many OTHER color groups also
///    have polylines passing through that neighborhood.
/// 3. Where multiple groups share a corridor, assigns each group a stable
///    lane index and applies a perpendicular offset.
/// 4. Smoothly transitions between offset and non-offset segments to
///    avoid visual kinks at corridor boundaries.
///
/// - Parameters:
///   - groupedPolylines: Array of `(groupIndex, coordinates)` tuples.
///   - offsetDegrees: Base offset in degrees per lane. Default 0.00008°
///     ≈ 9 m at NYC latitude — subtle enough that lines stay on top of
///     their stations, but wide enough to show distinct colored stripes
///     when zoomed in to neighborhood level (< 3 km camera distance).
///     At medium/far zoom the offset becomes sub-pixel and lines merge
///     naturally into single-colored corridors — matching Apple Maps.
/// - Returns: The same polylines with perpendicular offsets applied to
///   shared corridor segments.
func applyCorridorOffsets(
    _ groupedPolylines: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])],
    offsetDegrees: Double = 0.00012
) -> [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] {

    let gridSize: Double = 0.0004  // ~44 m cells for corridor detection

    // Step 1: Map each cell + its 3×3 neighbors to the set of group indices.
    // This catches parallel tracks that are in adjacent cells.
    var cellGroups: [Int64: Set<Int>] = [:]

    func cellKey(_ lat: Double, _ lon: Double) -> Int64 {
        let gx = Int32(lat / gridSize)
        let gy = Int32(lon / gridSize)
        return (Int64(gx) << 32) | Int64(gy & 0x7FFF_FFFF)
    }

    func groupsAt(_ lat: Double, _ lon: Double) -> Set<Int> {
        let gx = Int32(lat / gridSize)
        let gy = Int32(lon / gridSize)
        var groups = Set<Int>()
        for dx: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                let key = (Int64(gx &+ dx) << 32) | Int64((gy &+ dy) & 0x7FFF_FFFF)
                if let g = cellGroups[key] { groups.formUnion(g) }
            }
        }
        return groups
    }

    for (groupIdx, coords) in groupedPolylines {
        for coord in coords {
            let key = cellKey(coord.latitude, coord.longitude)
            cellGroups[key, default: []].insert(groupIdx)
        }
    }

    // Step 2: For each polyline, offset points in shared corridors
    var result: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = []

    for (groupIdx, coords) in groupedPolylines {
        guard coords.count >= 2 else {
            result.append((groupIdx, coords))
            continue
        }

        // First pass: compute per-point desired lane offset
        var desiredOffsets = [Double](repeating: 0, count: coords.count)

        for i in 0..<coords.count {
            let coord = coords[i]
            let groups = groupsAt(coord.latitude, coord.longitude)

            if groups.count > 1 {
                let sortedGroups = groups.sorted()
                guard let laneIndex = sortedGroups.firstIndex(of: groupIdx) else { continue }
                let numLanes = sortedGroups.count
                desiredOffsets[i] = (Double(laneIndex) - Double(numLanes - 1) / 2.0) * offsetDegrees
            }
        }

        // Second pass: smooth the offset transitions over 8-point windows
        // to avoid abrupt kinks at corridor boundaries.
        let smoothWindow = 8
        var smoothedOffsets = desiredOffsets
        for i in 0..<coords.count {
            let lo = max(0, i - smoothWindow / 2)
            let hi = min(coords.count - 1, i + smoothWindow / 2)
            let windowSize = hi - lo + 1
            var sum = 0.0
            for k in lo...hi { sum += desiredOffsets[k] }
            smoothedOffsets[i] = sum / Double(windowSize)
        }

        // Third pass: apply perpendicular offsets using smoothed values
        var offsetCoords: [CLLocationCoordinate2D] = []
        offsetCoords.reserveCapacity(coords.count)

        for i in 0..<coords.count {
            let offset = smoothedOffsets[i]
            if abs(offset) < 1e-10 {
                offsetCoords.append(coords[i])
                continue
            }

            // Compute perpendicular direction from the local tangent
            let prev = i > 0 ? coords[i - 1] : coords[i]
            let next = i < coords.count - 1 ? coords[i + 1] : coords[i]
            let dx = next.longitude - prev.longitude
            let dy = next.latitude - prev.latitude
            let len = sqrt(dx * dx + dy * dy)

            if len > 1e-10 {
                // Perpendicular unit vector (rotated 90° CCW)
                let perpLat = -dx / len
                let perpLon = dy / len
                offsetCoords.append(CLLocationCoordinate2D(
                    latitude: coords[i].latitude + perpLat * offset,
                    longitude: coords[i].longitude + perpLon * offset
                ))
            } else {
                offsetCoords.append(coords[i])
            }
        }

        result.append((groupIdx, offsetCoords))
    }

    return result
}

// MARK: - Train Polyline Unification (Branch-Preserving)

/// Unifies train polyline segments by removing near-duplicate shapes while
/// keeping whole segments — preserving branches naturally.
///
/// **Key insight**: within a same-color trunk group (e.g. A/C/E = blue),
/// overlapping lines are visually invisible because they're the same color.
/// So we don't need to extract partial runs — just skip shapes that are
/// near-identical to an already-kept shape (e.g. direction-1 reverse of
/// direction-0, or express overlaying local on the same tracks).
///
/// This naturally preserves the A train's Far Rockaway vs Lefferts Blvd
/// branches, the E train's unique Queens/WTC sections, etc. — because
/// those shapes have significant unique portions that fail the duplicate check.
///
/// - Parameters:
///   - segments: All decoded polyline segments for a train route/color group.
///   - overlapThreshold: Proximity radius in degrees. Default 0.001° ≈ 110 m.
/// - Returns: Deduplicated polylines with all branches preserved.
func unifyTrainPolylines(
    _ segments: [[CLLocationCoordinate2D]],
    overlapThreshold: Double = 0.001
) -> [[CLLocationCoordinate2D]] {
    guard segments.count > 1 else { return segments }

    let valid = segments.filter { $0.count >= 2 }
    guard valid.count > 1 else { return valid }

    // Sort by point count descending — longest segment is the trunk
    let sorted = valid.sorted { $0.count > $1.count }
    let threshSq = overlapThreshold * overlapThreshold

    var kept: [[CLLocationCoordinate2D]] = [sorted[0]]

    for segIdx in 1..<sorted.count {
        let seg = sorted[segIdx]

        // Sample ~20 evenly-spaced points from this segment
        let sampleCount = min(20, seg.count)
        let step = max(1, seg.count / sampleCount)
        var matchCount = 0
        var totalSamples = 0

        sampleLoop: for i in stride(from: 0, to: seg.count, by: step) {
            totalSamples += 1
            let pt = seg[i]

            // Check against sampled points from each kept segment
            for keptSeg in kept {
                let kStep = max(1, keptSeg.count / 40)
                for k in stride(from: 0, to: keptSeg.count, by: kStep) {
                    let kPt = keptSeg[k]
                    let dx = pt.longitude - kPt.longitude
                    let dy = pt.latitude - kPt.latitude
                    if dx * dx + dy * dy < threshSq {
                        matchCount += 1
                        continue sampleLoop
                    }
                }
            }
        }

        let overlapRatio = Double(matchCount) / Double(max(1, totalSamples))

        // >85% coverage → near-duplicate (reverse direction, express overlay)
        // ≤85% → has significant unique portion (branch), keep whole segment
        if overlapRatio <= 0.85 {
            kept.append(seg)
        }
    }

    // Post-merge: join segments whose endpoints are close
    return mergeAdjacentPolylines(kept, gapThreshold: 0.003)
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

// MARK: - Catmull-Rom Spline Smoothing

/// Smooths a polyline using Catmull-Rom spline interpolation.
///
/// This produces the clean, curvy look that Apple Maps uses. Raw GTFS
/// waypoints have sharp angular bends; Catmull-Rom generates smooth curves
/// that pass through every original control point while looking natural.
///
/// - Parameters:
///   - coordinates: Original polyline points (must have ≥ 2 points).
///   - segmentsPerCurve: Number of interpolated points between each pair
///     of original points. Higher = smoother but more points.
///     Default **4** gives good visual smoothing without bloating point count.
///   - alpha: Catmull-Rom parameterization (0 = uniform, 0.5 = centripetal,
///     1.0 = chordal). Default **0.5** (centripetal) avoids cusps and
///     self-intersections — the standard for map rendering.
/// - Returns: A smoothed coordinate array. Returns the original if < 3 points.
func smoothPolyline(
    _ coordinates: [CLLocationCoordinate2D],
    segmentsPerCurve: Int = 4,
    alpha: Double = 0.5
) -> [CLLocationCoordinate2D] {
    guard coordinates.count >= 3 else { return coordinates }

    var result: [CLLocationCoordinate2D] = []
    let n = coordinates.count

    for i in 0..<(n - 1) {
        // Catmull-Rom needs 4 control points: P0, P1, P2, P3
        // Clamp at boundaries by duplicating endpoints
        let p0 = coordinates[max(i - 1, 0)]
        let p1 = coordinates[i]
        let p2 = coordinates[i + 1]
        let p3 = coordinates[min(i + 2, n - 1)]

        // Add the start point of this segment
        if i == 0 { result.append(p1) }

        // Compute knot parameter distances using centripetal parameterization
        let d01 = knotDistance(p0, p1, alpha: alpha)
        let d12 = knotDistance(p1, p2, alpha: alpha)
        let d23 = knotDistance(p2, p3, alpha: alpha)

        // Guard degenerate segments (identical points)
        guard d12 > 1e-10 else {
            result.append(p2)
            continue
        }

        let t0: Double = 0
        let t1: Double = t0 + d01
        let t2: Double = t1 + d12
        let t3: Double = t2 + d23

        // Interpolate between p1 and p2
        for step in 1...segmentsPerCurve {
            let fraction = Double(step) / Double(segmentsPerCurve)
            let t = t1 + fraction * (t2 - t1)

            let (lat, lon) = catmullRomPoint(
                p0: (p0.latitude, p0.longitude),
                p1: (p1.latitude, p1.longitude),
                p2: (p2.latitude, p2.longitude),
                p3: (p3.latitude, p3.longitude),
                t: t, t0: t0, t1: t1, t2: t2, t3: t3
            )
            result.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }

    return result
}

/// Computes a single Catmull-Rom interpolated point given 4 control points
/// and knot values.
private func catmullRomPoint(
    p0: (Double, Double), p1: (Double, Double),
    p2: (Double, Double), p3: (Double, Double),
    t: Double, t0: Double, t1: Double, t2: Double, t3: Double
) -> (Double, Double) {

    func lerp(_ a: (Double, Double), _ b: (Double, Double), _ f: Double) -> (Double, Double) {
        (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f)
    }

    // Guard against division by zero
    let dt10 = t1 - t0; let dt21 = t2 - t1; let dt32 = t3 - t2
    let dt20 = t2 - t0; let dt31 = t3 - t1
    guard dt10.magnitude > 1e-12, dt21.magnitude > 1e-12,
          dt32.magnitude > 1e-12, dt20.magnitude > 1e-12,
          dt31.magnitude > 1e-12 else {
        return p1
    }

    let a1 = lerp(p0, p1, (t - t0) / dt10)
    let a2 = lerp(p1, p2, (t - t1) / dt21)
    let a3 = lerp(p2, p3, (t - t2) / dt32)

    let b1 = lerp(a1, a2, (t - t0) / dt20)
    let b2 = lerp(a2, a3, (t - t1) / dt31)

    return lerp(b1, b2, (t - t1) / dt21)
}

/// Knot distance for centripetal Catmull-Rom parameterization.
private func knotDistance(
    _ a: CLLocationCoordinate2D,
    _ b: CLLocationCoordinate2D,
    alpha: Double
) -> Double {
    let dx = b.longitude - a.longitude
    let dy = b.latitude - a.latitude
    let distSq = dx * dx + dy * dy
    return pow(distSq, alpha * 0.5)
}
