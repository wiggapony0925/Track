// Google-encoded polyline encoding and decoding utilities.
// Used by TrackAPI response types and HomeViewModel to convert
// between encoded polyline strings and coordinate arrays.

import CoreLocation

/// Decodes a Google-encoded polyline string into an array of coordinates.
/// `nonisolated` — pure computation safe for background threads.
nonisolated func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
    var coordinates: [CLLocationCoordinate2D] = []
    var index = encoded.startIndex
    var lat: Int64 = 0
    var lon: Int64 = 0

    while index < encoded.endIndex {
        var shift: Int64 = 0
        var result: Int64 = 0
        var byte: Int64

        repeat {
            byte = Int64(encoded[index].asciiValue ?? 0) - 63
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
            byte = Int64(encoded[index].asciiValue ?? 0) - 63
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
nonisolated func encodePolyline(_ coordinates: [CLLocationCoordinate2D]) -> String {
    var encoded = ""
    var prevLat: Int64 = 0
    var prevLon: Int64 = 0

    for coord in coordinates {
        let lat = Int64(round(coord.latitude * 1e5))
        let lon = Int64(round(coord.longitude * 1e5))

        encodeValue(lat - prevLat, into: &encoded)
        encodeValue(lon - prevLon, into: &encoded)

        prevLat = lat
        prevLon = lon
    }

    return encoded
}

/// Encodes a single signed value into the Google polyline encoding format.
private nonisolated func encodeValue(_ value: Int64, into result: inout String) {
    var v = value < 0 ? ~(value << 1) : (value << 1)
    while v >= 0x20 {
        let chunk = Int64((v & 0x1F) | 0x20) + 63
        result.append(Character(UnicodeScalar(Int(chunk))!))
        v >>= 5
    }
    result.append(Character(UnicodeScalar(Int(v + 63))!))
}

// MARK: - Polyline Consolidation

/// Greedily connects multiple polyline chains into a single continuous line.
///
/// After `mergeAdjacentPolylines` or `unifyTrainPolylines` there may still
/// be multiple separate chains for a single route direction — e.g. when
/// GTFS shape fragments have gaps wider than the merge threshold.  This
/// function bridges those gaps by repeatedly attaching the nearest
/// unconnected chain (checking all four endpoint orientations) until
/// every chain is part of one continuous polyline.
///
/// The result is a single array suitable for drawing one `MLNPolylineFeature`
/// on the map, avoiding visible seams between direction segments.
///
/// - Parameter chains: Arrays of coordinates, each a separate polyline chain.
/// - Returns: A single coordinate array forming one continuous line.
nonisolated func consolidateIntoSinglePolyline(
    _ chains: [[CLLocationCoordinate2D]]
) -> [CLLocationCoordinate2D] {
    let valid = chains.filter { $0.count >= 2 }
    guard valid.count > 1 else { return valid.first ?? [] }

    func distSq(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dx = a.longitude - b.longitude
        let dy = a.latitude - b.latitude
        return dx * dx + dy * dy
    }

    // Skip near-duplicate points at the join seam  (≤ ~15 m at NYC lat).
    let overlapSq: Double = 0.00015 * 0.00015

    var result = valid[0]
    var remaining = Array(valid.dropFirst())

    while !remaining.isEmpty {
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        var bestReverse = false
        var bestPrepend = false

        guard let rLast = result.last, let rFirst = result.first else { break }

        for i in remaining.indices {
            guard let sFirst = remaining[i].first, let sLast = remaining[i].last else { continue }

            // result.last → seg.first  (append, normal order)
            let d1 = distSq(rLast, sFirst)
            if d1 < bestDist {
                bestDist = d1; bestIdx = i
                bestReverse = false; bestPrepend = false
            }

            // result.last → seg.last   (append, reversed)
            let d2 = distSq(rLast, sLast)
            if d2 < bestDist { bestDist = d2; bestIdx = i; bestReverse = true; bestPrepend = false }

            // seg.last → result.first  (prepend, normal order)
            let d3 = distSq(sLast, rFirst)
            if d3 < bestDist { bestDist = d3; bestIdx = i; bestReverse = false; bestPrepend = true }

            // seg.first → result.first (prepend, reversed)
            let d4 = distSq(sFirst, rFirst)
            if d4 < bestDist { bestDist = d4; bestIdx = i; bestReverse = true; bestPrepend = true }
        }

        var next = bestReverse ? Array(remaining[bestIdx].reversed()) : remaining[bestIdx]

        // Drop overlapping head/tail points at the seam so Catmull-Rom
        // doesn't create a micro-zigzag at the junction.
        if bestPrepend {
            while next.count > 1, let nl = next.last, let rf = result.first,
                  distSq(nl, rf) < overlapSq {
                next.removeLast()
            }
            result = next + result
        } else {
            while next.count > 1, let nf = next.first, let rl = result.last,
                  distSq(rl, nf) < overlapSq {
                next.removeFirst()
            }
            result.append(contentsOf: next)
        }
        remaining.remove(at: bestIdx)
    }

    return result
}

// MARK: - Duplicate Segment Removal

/// Removes near-duplicate polyline segments that overlap >85% with
/// already-kept segments.
///
/// Lighter than `unifyTrainPolylines` — does NOT extract branch stubs.
/// Designed for single-direction pipes where duplicate GTFS variants
/// (express/local, short-turn) should simply be dropped to avoid
/// stacking two identical visual lines.
///
/// - Parameters:
///   - segments: Arrays of coordinates, each a polyline segment.
///   - cellSize: Spatial grid cell size in degrees for coverage checks.
///     Default `0.001` ≈ 84 m at NYC latitude.
/// - Returns: Segments with near-duplicates removed (longest first).
nonisolated func removeDuplicateSegments(
    _ segments: [[CLLocationCoordinate2D]],
    cellSize: Double = 0.001
) -> [[CLLocationCoordinate2D]] {
    guard segments.count > 1 else { return segments }
    let valid = segments.filter { $0.count >= 2 }
    guard valid.count > 1 else { return valid }

    // Sort longest first so the primary path is kept as baseline.
    let sorted = valid.sorted { $0.count > $1.count }

    func cellKey(_ coord: CLLocationCoordinate2D) -> Int64 {
        let lc = Int64(floor(coord.latitude / cellSize))
        let nc = Int64(floor(coord.longitude / cellSize))
        return lc &* 10_000_000 &+ nc
    }

    var grid: Set<Int64> = []

    func isCovered(_ pt: CLLocationCoordinate2D) -> Bool {
        let lc = Int(floor(pt.latitude / cellSize))
        let nc = Int(floor(pt.longitude / cellSize))
        for dl in -1...1 {
            for dn in -1...1 {
                if grid.contains(Int64(lc + dl) &* 10_000_000 &+ Int64(nc + dn)) { return true }
            }
        }
        return false
    }

    var kept: [[CLLocationCoordinate2D]] = [sorted[0]]
    for pt in sorted[0] { grid.insert(cellKey(pt)) }

    for i in 1..<sorted.count {
        let seg = sorted[i]
        let coveredCount = seg.reduce(0) { $0 + (isCovered($1) ? 1 : 0) }
        let ratio = Double(coveredCount) / Double(seg.count)
        if ratio > 0.85 { continue }       // near-duplicate → drop
        kept.append(seg)
        for pt in seg { grid.insert(cellKey(pt)) }
    }

    return kept
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
nonisolated func mergeAdjacentPolylines(
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

/// Joins already direction-ordered route fragments without reversing any fragment.
///
/// Bus route shapes can include one-way terminal loops and short variants where
/// reversing a fragment to make endpoints meet creates a believable but wrong
/// path. Use this after fragments have already been filtered/clipped by stop
/// order so the renderer only stitches true neighbors.
nonisolated func mergeOrderedPolylines(
    _ segments: [[CLLocationCoordinate2D]],
    gapThreshold: Double = 0.002
) -> [[CLLocationCoordinate2D]] {
    let valid = segments.filter { $0.count >= 2 }
    guard valid.count > 1 else { return valid }

    let threshSq = gapThreshold * gapThreshold

    func distSq(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dx = a.longitude - b.longitude
        let dy = a.latitude - b.latitude
        return dx * dx + dy * dy
    }

    var chains: [[CLLocationCoordinate2D]] = []
    for segment in valid {
        guard let segFirst = segment.first, let segLast = segment.last else { continue }

        if let index = chains.firstIndex(where: { chain in
            guard let last = chain.last else { return false }
            return distSq(last, segFirst) <= threshSq
        }) {
            chains[index].append(contentsOf: segment.dropFirst())
        } else if let index = chains.firstIndex(where: { chain in
            guard let first = chain.first else { return false }
            return distSq(segLast, first) <= threshSq
        }) {
            chains[index] = segment + chains[index].dropFirst()
        } else {
            chains.append(segment)
        }
    }

    var didMerge = true
    while didMerge {
        didMerge = false
        outer: for i in 0..<chains.count {
            for j in (i + 1)..<chains.count {
                guard let iLast = chains[i].last,
                      let iFirst = chains[i].first,
                      let jLast = chains[j].last,
                      let jFirst = chains[j].first
                else { continue }

                if distSq(iLast, jFirst) <= threshSq {
                    chains[i].append(contentsOf: chains[j].dropFirst())
                    chains.remove(at: j)
                    didMerge = true
                    break outer
                }
                if distSq(jLast, iFirst) <= threshSq {
                    chains[i] = chains[j] + chains[i].dropFirst()
                    chains.remove(at: j)
                    didMerge = true
                    break outer
                }
            }
        }
    }

    return chains.filter { $0.count >= 2 }
}

// MARK: - Train Polyline Unification (Branch-Extracting)

/// Unifies train polyline segments by keeping ONE trunk polyline and
/// extracting only the unique branch stubs from remaining segments.
///
/// **Why this matters**: Within a same-color trunk group (e.g. A/C/E = blue),
/// overlapping lines are visually identical. The old approach kept *entire*
/// segments when they had ≥15% unique content — but a segment that's 70%
/// shared with the trunk still redraws most of the trunk as a second stacked
/// `MapPolyline`, wasting GPU overlays and creating "3 lines per route."
///
/// **Approach**:
/// 1. The longest segment becomes the trunk baseline.
/// 2. A spatial grid tracks which map cells are already "covered" by kept points.
/// 3. Each subsequent segment is checked point-by-point against the grid:
///    - **>90% covered** → near-duplicate (reverse direction, express overlay) → drop.
///    - **<15% covered** → mostly unique corridor (e.g. Staten Island) → keep whole.
///    - **15–90% covered** → partial overlap (branch). Extract only the contiguous
///      unique runs (the divergent tails) and discard the shared trunk portion.
/// 4. Extracted stubs are validated with a **wider proximity check** (9×9 grid,
///    ~550 m radius) at three sample points (start, midpoint, end of the
///    uncovered run). If all three are near existing kept polylines, the stub
///    is a corridor variant (express/local parallel tracks that stay in the
///    same geographic area) and is dropped. Real branches — like Q Brighton
///    or A Far Rockaway — deviate significantly in the middle even when both
///    endpoints share junctions with the trunk.
///
/// This produces 1 trunk + N short branch stubs instead of N full-length
/// overlapping polylines — dramatically fewer MapPolyline overlays.
///
/// - Parameters:
///   - segments: All decoded polyline segments for a train route/color group.
///   - overlapThreshold: Spatial grid cell size in degrees. Default 0.001° ≈ 110 m.
///     The 3×3 neighbor check gives effective radius ≈ 220 m.
/// - Returns: Deduplicated polylines: one trunk + short branch stubs.
nonisolated func unifyTrainPolylines(
    _ segments: [[CLLocationCoordinate2D]],
    overlapThreshold: Double = 0.001
) -> [[CLLocationCoordinate2D]] {
    guard segments.count > 1 else { return segments }

    let valid = segments.filter { $0.count >= 2 }
    guard valid.count > 1 else { return valid }

    // Sort longest first — the trunk baseline
    let sorted = valid.sorted { $0.count > $1.count }

    // ── Spatial grid for O(1) "is this point already covered?" queries ──
    // Cell size = overlapThreshold (~0.001° ≈ 111 m at equator, ~84 m at NYC).
    // Checking 3×3 neighborhood gives effective radius ≈ 170–220 m — generous
    // enough for same-track GPS drift between different GTFS shapes.
    let cell = overlapThreshold

    // Pack (latCell, lonCell) into a single Int64 for Set efficiency.
    // Using wrapping arithmetic avoids overflow traps at cell boundaries.
    func cellKey(_ coord: CLLocationCoordinate2D) -> (Int, Int) {
        (Int(floor(coord.latitude / cell)), Int(floor(coord.longitude / cell)))
    }

    func packedKey(_ lc: Int, _ nc: Int) -> Int64 {
        Int64(lc) &* 10_000_000 &+ Int64(nc)
    }

    var grid: Set<Int64> = []

    func addPoints(_ coords: [CLLocationCoordinate2D]) {
        for pt in coords {
            let (lc, nc) = cellKey(pt)
            grid.insert(packedKey(lc, nc))
        }
    }

    /// Standard coverage check: 3×3 neighborhood (±1 cell ≈ 220 m at NYC).
    func isCovered(_ pt: CLLocationCoordinate2D) -> Bool {
        let (lc, nc) = cellKey(pt)
        for dl in -1...1 {
            for dn in -1...1 {
                if grid.contains(packedKey(lc + dl, nc + dn)) { return true }
            }
        }
        return false
    }

    /// Wider proximity check: 9×9 neighborhood (±4 cells ≈ 550 m at NYC).
    /// Used to decide if an extracted branch stub is a genuine branch
    /// (reaches new territory) or a corridor variant (express/local
    /// parallel tracks that rejoin the trunk).
    func isNearGrid(_ pt: CLLocationCoordinate2D) -> Bool {
        let (lc, nc) = cellKey(pt)
        for dl in -4...4 {
            for dn in -4...4 {
                if grid.contains(packedKey(lc + dl, nc + dn)) { return true }
            }
        }
        return false
    }

    // Seed grid with trunk (longest segment)
    var kept: [[CLLocationCoordinate2D]] = [sorted[0]]
    addPoints(sorted[0])

    for segIdx in 1..<sorted.count {
        let seg = sorted[segIdx]

        // Per-point coverage check against the spatial grid
        var covered = [Bool](repeating: false, count: seg.count)
        var coveredCount = 0
        for i in 0..<seg.count {
            if isCovered(seg[i]) {
                covered[i] = true
                coveredCount += 1
            }
        }

        let ratio = Double(coveredCount) / Double(seg.count)

        // >95% covered → near-duplicate (reverse direction, express overlay).
        // Previous 90% threshold was too aggressive — short express
        // bypasses or branch tails that diverge for just a few blocks
        // could hit 91-94% overlap and be wrongly discarded.
        if ratio > 0.95 { continue }

        // <15% covered → mostly unique corridor, keep whole segment
        if ratio < 0.15 {
            kept.append(seg)
            addPoints(seg)
            continue
        }

        // ── Partial overlap: extract only the unique branch stubs ──
        //
        // Instead of keeping the entire 200-point segment (which redraws
        // 140 points of shared trunk as a second stacked MapPolyline),
        // extract only the contiguous runs of uncovered points — the
        // divergent branch tails.

        let minRun = 8   // Ignore very short fragments — curve-area GPS drift
                         // between GTFS shapes can produce uncovered runs of
                         // 3-6 points that are NOT real branches.  Previous
                         // threshold of 15 was too aggressive and dropped
                         // legitimate short branch stubs near junctions.
        var runs: [(start: Int, end: Int)] = []
        var runStart: Int? = nil

        for i in 0..<seg.count {
            if !covered[i] {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                if i - s >= minRun {
                    runs.append((start: s, end: i - 1))
                }
                runStart = nil
            }
        }
        // Handle run extending to the end of the segment
        if let s = runStart, seg.count - s >= minRun {
            runs.append((start: s, end: seg.count - 1))
        }

        guard !runs.isEmpty else { continue }

        for (rStart, rEnd) in runs {
            // ── Branch validation ──
            // A "corridor variant" (express/local parallel tracks, or a
            // different service pattern that stays in the same geographic
            // corridor) has its start, midpoint, AND end all near
            // existing kept polylines.
            // A genuine branch (e.g. Q Brighton, A Far Rockaway) deviates
            // through different territory — its midpoint is far from the
            // trunk even if both endpoints happen to share junctions.
            // Use the wider 7×7 grid (~500 m radius) for this check.
            let runMid = (rStart + rEnd) / 2
            if isNearGrid(seg[rStart]) && isNearGrid(seg[runMid]) && isNearGrid(seg[rEnd]) {
                continue  // entire run stays in the trunk corridor — variant
            }

            // Extend a few points into the covered area so the branch
            // stub visually connects seamlessly to the trunk polyline.
            // IMPORTANT: The extension points are snapped to the nearest
            // point on the trunk (kept[0]) instead of using the segment's
            // own GPS coordinates. This prevents "double lines" where two
            // GTFS shapes for the same physical track have slightly offset
            // coordinates (northbound vs southbound traces, ~10-30 m apart).
            let extStart = max(0, rStart - 5)
            let extEnd = min(seg.count - 1, rEnd + 5)

            var stub: [CLLocationCoordinate2D] = []
            stub.reserveCapacity(extEnd - extStart + 1)

            let trunk = kept[0]  // longest segment = trunk baseline

            for j in extStart...extEnd {
                if covered[j] {
                    // This point is in the overlapping zone → snap to trunk
                    let pt = seg[j]
                    var bestDist = Double.greatestFiniteMagnitude
                    var bestCoord = pt
                    for tk in trunk {
                        let dx = tk.longitude - pt.longitude
                        let dy = tk.latitude - pt.latitude
                        let d = dx * dx + dy * dy
                        if d < bestDist {
                            bestDist = d
                            bestCoord = tk
                        }
                    }
                    stub.append(bestCoord)
                } else {
                    // Unique branch territory → keep original coordinate
                    stub.append(seg[j])
                }
            }

            guard stub.count >= 2 else { continue }
            kept.append(stub)
            addPoints(stub)
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
nonisolated func simplifyPolyline(
    _ coordinates: [CLLocationCoordinate2D],
    tolerance: Double
) -> [CLLocationCoordinate2D] {
    guard coordinates.count >= 3 else { return coordinates }
    return rdpSimplify(coordinates, tolerance: tolerance)
}

/// Recursive Ramer-Douglas-Peucker implementation.
private nonisolated func rdpSimplify(
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
private nonisolated func perpendicularDistance(
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

// MARK: - Spike Removal

/// Removes sharp V-shaped spikes from a polyline.
///
/// After ``consolidateIntoSinglePolyline`` greedily joins GTFS segments,
/// the join point can create a brief reversal (spike) — e.g. the line goes
/// south, dips further south for 1-3 points, then jumps back north.  These
/// spikes get amplified by Catmull-Rom into prominent visual artifacts.
///
/// **Algorithm:** For every interior vertex, compute the angle between the
/// incoming and outgoing edges.  If the angle is sharper than the threshold
/// (i.e. a near-180° reversal), the vertex is a spike tip and is removed.
/// The pass repeats until no more spikes are found, so multi-point spikes
/// are progressively trimmed.
///
/// - Parameters:
///   - coordinates: Polyline vertices.
///   - angleThreshold: Minimum deflection angle in degrees that constitutes
///     a spike.  Default 160° catches sharp U-turns while leaving legitimate
///     subway curves (which rarely exceed 120°) untouched.
/// - Returns: Cleaned polyline with spike vertices removed.
nonisolated func removeSpikes(
    _ coordinates: [CLLocationCoordinate2D],
    angleThreshold: Double = 160.0
) -> [CLLocationCoordinate2D] {
    guard coordinates.count >= 3 else { return coordinates }

    let cosThreshold = cos(angleThreshold * .pi / 180.0)  // cosine of threshold angle

    var coords = coordinates
    var changed = true

    // Repeat until stable — multi-point spikes need several passes.
    while changed {
        changed = false
        guard coords.count >= 3 else { break }

        var cleaned: [CLLocationCoordinate2D] = [coords[0]]
        var i = 1
        while i < coords.count - 1 {
            let prev = cleaned.last!
            let curr = coords[i]
            let next = coords[i + 1]

            // Incoming vector (prev → curr)
            let ax = curr.longitude - prev.longitude
            let ay = curr.latitude  - prev.latitude
            // Outgoing vector (curr → next)
            let bx = next.longitude - curr.longitude
            let by = next.latitude  - curr.latitude

            let magA = sqrt(ax * ax + ay * ay)
            let magB = sqrt(bx * bx + by * by)

            if magA > 1e-12, magB > 1e-12 {
                let cosAngle = (ax * bx + ay * by) / (magA * magB)
                // cosAngle ≈ -1 means ~180° reversal (spike)
                // cosThreshold for 160° ≈ -0.94
                if cosAngle < cosThreshold {
                    // Skip this vertex — it's a spike tip
                    changed = true
                    i += 1
                    continue
                }
            }

            cleaned.append(curr)
            i += 1
        }
        // Always keep the last point
        cleaned.append(coords.last!)
        coords = cleaned
    }

    return coords
}

// MARK: - Catmull-Rom Spline Smoothing

/// Smooths a polyline using Catmull-Rom spline interpolation.
///
/// This produces the clean, curvy look that Apple Maps uses. Raw GTFS
/// waypoints have sharp angular bends; Catmull-Rom generates smooth curves
/// that pass through every original control point while looking natural.
/// Removes near-duplicate consecutive vertices that are closer than
/// `minSpacing` degrees.  These tiny segments (often injected by station
/// snap) cause Catmull-Rom to overshoot and produce visible loops.
///
/// Always preserves the first and last points.
///
/// - Parameters:
///   - coordinates: Original polyline points.
///   - minSpacing: Minimum Euclidean distance in degrees between kept
///     consecutive points. `0.0001°` ≈ 11 m at NYC latitude.
/// - Returns: Filtered coordinate array with near-duplicates removed.
nonisolated func removeNearDuplicates(
    _ coordinates: [CLLocationCoordinate2D],
    minSpacing: Double = 0.0001
) -> [CLLocationCoordinate2D] {
    guard coordinates.count >= 2 else { return coordinates }

    var result: [CLLocationCoordinate2D] = [coordinates[0]]
    let thresholdSq = minSpacing * minSpacing

    for i in 1..<(coordinates.count - 1) {
        let prev = result.last!
        let cur = coordinates[i]
        let dx = cur.longitude - prev.longitude
        let dy = cur.latitude - prev.latitude
        if (dx * dx + dy * dy) >= thresholdSq {
            result.append(cur)
        }
    }

    // Always keep the last point
    result.append(coordinates.last!)
    return result
}

// MARK: - Catmull-Rom Smoothing

///
/// - Parameters:
///   - coordinates: Original polyline points (must have ≥ 2 points).
///   - segmentsPerCurve: **Maximum** number of interpolated points between
///     each pair of original points. Actual count scales with segment
///     length — very short segments (< 20 m) use fewer subdivisions to
///     avoid point-count explosion without sacrificing visual quality.
///     Default **4** gives good visual smoothing without bloating point count.
///   - alpha: Catmull-Rom parameterization (0 = uniform, 0.5 = centripetal,
///     1.0 = chordal). Default **0.5** (centripetal) avoids cusps and
///     self-intersections — the standard for map rendering.
/// - Returns: A smoothed coordinate array. Returns the original if < 3 points.
nonisolated func smoothPolyline(
    _ coordinates: [CLLocationCoordinate2D],
    segmentsPerCurve: Int = 4,
    alpha: Double = 0.5
) -> [CLLocationCoordinate2D] {
    guard coordinates.count >= 3 else { return coordinates }

    // Adaptive subdivision thresholds (in degrees).
    // Segments shorter than minLenForFull get proportionally fewer points.
    // At NYC latitude, 0.00018° ≈ 20 m — below this, 2 segments is enough.
    let minLenForFull = 0.00045  // ~50 m — use full segmentsPerCurve above this
    let minLenForAny  = 0.00004 // ~4.5 m — below this, just emit endpoint (no interp)

    var result: [CLLocationCoordinate2D] = []
    let n = coordinates.count

    for i in 0..<(n - 1) {
        let p0 = coordinates[max(i - 1, 0)]
        let p1 = coordinates[i]
        let p2 = coordinates[i + 1]
        let p3 = coordinates[min(i + 2, n - 1)]

        if i == 0 { result.append(p1) }

        let d01 = knotDistance(p0, p1, alpha: alpha)
        let d12 = knotDistance(p1, p2, alpha: alpha)
        let d23 = knotDistance(p2, p3, alpha: alpha)

        guard d12 > 1e-10 else {
            result.append(p2)
            continue
        }

        // Adaptive segment count based on edge length in degrees.
        let edgeLenDeg: Double = {
            let dx = p2.longitude - p1.longitude
            let dy = p2.latitude  - p1.latitude
            return sqrt(dx * dx + dy * dy)
        }()

        let effectiveSegments: Int
        if edgeLenDeg < minLenForAny {
            // Segment so short that interpolation adds no visible quality.
            result.append(p2)
            continue
        } else if edgeLenDeg < minLenForFull {
            // Scale linearly between 2 and segmentsPerCurve.
            let ratio = (edgeLenDeg - minLenForAny) / (minLenForFull - minLenForAny)
            effectiveSegments = max(2, Int(Double(segmentsPerCurve) * ratio))
        } else {
            effectiveSegments = segmentsPerCurve
        }

        let t0: Double = 0
        let t1: Double = t0 + d01
        let t2: Double = t1 + d12
        let t3: Double = t2 + d23

        for step in 1...effectiveSegments {
            let fraction = Double(step) / Double(effectiveSegments)
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
private nonisolated func catmullRomPoint(
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
private nonisolated func knotDistance(
    _ a: CLLocationCoordinate2D,
    _ b: CLLocationCoordinate2D,
    alpha: Double
) -> Double {
    let dx = b.longitude - a.longitude
    let dy = b.latitude - a.latitude
    let distSq = dx * dx + dy * dy
    return pow(distSq, alpha * 0.5)
}

// MARK: - Circular-Arc Fillet Smoothing

/// Replaces sharp bends in a polyline with **true circular arc** segments.
///
/// ## Why circular arcs instead of Bézier or Catmull-Rom?
///
/// Transit maps like the MTA subway have multiple coloured lines running
/// in parallel through shared corridors.  When those lines curve around a
/// bend, a curve parallel to a **circle arc** is itself a circle arc
/// (just with radius R ± d).  Bézier and Catmull-Rom splines do NOT have
/// this property — their parallel offsets develop cusps and loops.
///
/// This is the same insight Transit App uses (circle-arc rounding, 2016),
/// but we go further with **offset-adaptive radius**: the minimum fillet
/// radius at each vertex scales with the local corridor width so that
/// when MapLibre applies ``lineOffset`` for parallel trunks, the
/// **innermost** line never gets a radius smaller than the rendered line
/// width.  This eliminates the pinch/collapse artifacts that appear at
/// tight junction bends when 3-5 trunk lines fan out.
///
/// ### Mathematics
///
/// Given two consecutive edges meeting at a vertex **V** with half-angle
/// `α/2` (where α = π − turn_angle):
///
/// 1. The arc centre **O** lies on the angle bisector at distance
///    `R / sin(α/2)` from **V**.
/// 2. Tangent points **A** (incoming) and **D** (outgoing) are at distance
///    `R / tan(α/2)` from **V** along each edge.
/// 3. Arc sweep = `π − α` radians, sampled at uniform angular steps.
///
/// - Parameters:
///   - coordinates: Original polyline points (≥ 3 required).
///   - angleThreshold: Minimum turn angle (degrees) to trigger filleting.
///     Default **20°** — the tightest corners that `line-join: round`
///     can't hide.
///   - baseRadiusDeg: Base fillet radius in degrees.  Default **0.00025°**
///     ≈ 28 m at NYC — enough to round subway tunnel curves without
///     shifting polylines off station-snapped positions.
///   - arcPoints: Points to sample along each arc.  Default **8**.
/// - Returns: Smoothed coordinate array.  Straight segments pass through
///   unchanged; only sharp vertices are replaced with arcs.
nonisolated func refineSharpBends(
    _ coordinates: [CLLocationCoordinate2D],
    angleThreshold: Double = 20.0,
    baseRadiusDeg: Double = 0.00025,
    arcPoints: Int = 8
) -> [CLLocationCoordinate2D] {
    circularArcFillet(
        coordinates,
        radiusDeg: baseRadiusDeg,
        angleThreshold: angleThreshold,
        arcPoints: arcPoints
    )
}

// MARK: - Offset-Adaptive Junction Fillet (System Map)

/// Smooths sharp vertices in a **system-map trunk polyline** using
/// circular arc fillets whose minimum radius adapts to the local
/// corridor width (``laneOffset``).
///
/// ## Offset-adaptive radius
///
/// When multiple parallel lines share a corridor through MapLibre's
/// ``lineOffset`` property, a **fixed** fillet radius fails:
///
///   - Too small → the innermost parallel line (R − n×lane_width)
///     collapses to zero or negative radius → self-intersection.
///   - Too large → straight segments are over-smoothed, polylines drift
///     off station coordinates.
///
/// This function scales the fillet radius at each vertex:
///
///     R_effective = max(R_base, |laneOffset| × scaleFactor)
///
/// Because we use **true circle arcs** (not Bézier), every parallel
/// offset of the fillet is also a circle arc — the mathematical
/// guarantee that eliminates cusp/loop artifacts at bends.
///
/// - Parameters:
///   - coordinates: Trunk polyline points (≥ 3 required).
///   - laneOffset: Signed pixel-space offset for this trunk's corridor
///     position.  Magnitude indicates how many lane-widths from centre.
///   - angleThreshold: Turn angle (degrees) to trigger filleting.
///   - baseRadiusDeg: Base radius (degrees).  ~0.00020° ≈ 22 m.
///   - scaleFactor: Multiplier from |laneOffset| to additional radius.
///     Default **0.00012°** per lane unit ≈ 13 m per offset step.
///   - arcPoints: Points per arc.
/// - Returns: Smoothed polyline.
nonisolated func junctionAwareFillet(
    _ coordinates: [CLLocationCoordinate2D],
    laneOffset: Double,
    angleThreshold: Double = 25.0,
    baseRadiusDeg: Double = 0.00020,
    scaleFactor: Double = 0.00012,
    arcPoints: Int = 8
) -> [CLLocationCoordinate2D] {
    let adaptiveRadius = max(baseRadiusDeg, abs(laneOffset) * scaleFactor)
    return circularArcFillet(
        coordinates,
        radiusDeg: adaptiveRadius,
        angleThreshold: angleThreshold,
        arcPoints: arcPoints
    )
}

// MARK: - Circular-Arc Fillet Core

/// Shared implementation for ``refineSharpBends`` and ``junctionAwareFillet``.
///
/// Replaces sharp vertices with true circular arc segments using a
/// three-pass algorithm:
/// 1. Compute ideal tangent pull-back for each interior vertex.
/// 2. Budget adjacent fillets so they never overlap (90% edge budget).
/// 3. Emit arc geometry at each filleted vertex.
///
/// - Parameters:
///   - coordinates: Polyline vertices (≥ 3 required).
///   - radiusDeg: Fillet radius in degrees.
///   - angleThreshold: Minimum turn angle (degrees) to trigger filleting.
///   - arcPoints: Points to sample along each arc.
/// - Returns: Smoothed coordinate array.
private nonisolated func circularArcFillet(
    _ coordinates: [CLLocationCoordinate2D],
    radiusDeg: Double,
    angleThreshold: Double,
    arcPoints: Int
) -> [CLLocationCoordinate2D] {
    guard coordinates.count >= 3 else { return coordinates }

    let n = coordinates.count
    let cosThreshold = cos(angleThreshold * .pi / 180.0)
    let R = radiusDeg

    // ── Pass 1: compute ideal tangent distance for every interior vertex ──
    struct VertexInfo {
        var tangentDist: Double = 0.0
        var tanHalf: Double = 0.0
        var needsFillet: Bool = false
    }
    var info = [VertexInfo](repeating: VertexInfo(), count: n)
    var edgeLen = [Double](repeating: 0.0, count: n - 1)
    for i in 0..<(n - 1) {
        let dx = coordinates[i + 1].longitude - coordinates[i].longitude
        let dy = coordinates[i + 1].latitude  - coordinates[i].latitude
        edgeLen[i] = sqrt(dx * dx + dy * dy)
    }

    for i in 1..<(n - 1) {
        let len1 = edgeLen[i - 1]
        let len2 = edgeLen[i]
        guard len1 > 1e-10, len2 > 1e-10 else { continue }

        let prev = coordinates[i - 1], curr = coordinates[i], next = coordinates[i + 1]
        let dx1 = curr.longitude - prev.longitude
        let dy1 = curr.latitude  - prev.latitude
        let dx2 = next.longitude - curr.longitude
        let dy2 = next.latitude  - curr.latitude

        let dot = (dx1 * dx2 + dy1 * dy2) / (len1 * len2)
        if dot > cosThreshold { continue }

        let clampedDot = max(-0.9999, min(0.9999, dot))
        let turnAngle = acos(clampedDot)
        let halfAngle = (Double.pi - turnAngle) / 2.0
        guard halfAngle > 1e-6 else { continue }

        let th = tan(halfAngle)
        guard th > 1e-10 else { continue }

        let idealDist = R / th
        let soloClamped = min(idealDist, 0.40 * min(len1, len2))
        info[i] = VertexInfo(tangentDist: soloClamped, tanHalf: th, needsFillet: true)
    }

    // ── Pass 1.5: budget adjacent fillets so they never overlap ──
    for e in 0..<(n - 1) {
        let wantLeft  = info[e].needsFillet     ? info[e].tangentDist     : 0.0
        let wantRight = info[e + 1].needsFillet ? info[e + 1].tangentDist : 0.0
        let total = wantLeft + wantRight
        guard total > edgeLen[e] * 0.90 else { continue }
        let budget = edgeLen[e] * 0.90
        let scale = budget / total
        if info[e].needsFillet     { info[e].tangentDist     = wantLeft  * scale }
        if info[e + 1].needsFillet { info[e + 1].tangentDist = wantRight * scale }
    }

    // ── Pass 2: emit arc geometry ──
    var result: [CLLocationCoordinate2D] = [coordinates[0]]

    for i in 1..<(n - 1) {
        guard info[i].needsFillet else {
            result.append(coordinates[i])
            continue
        }

        let prev = coordinates[i - 1]
        let curr = coordinates[i]
        let next = coordinates[i + 1]

        let dx1 = curr.longitude - prev.longitude
        let dy1 = curr.latitude  - prev.latitude
        let dx2 = next.longitude - curr.longitude
        let dy2 = next.latitude  - curr.latitude

        let len1 = edgeLen[i - 1]
        let len2 = edgeLen[i]

        let budgetedDist = info[i].tangentDist
        let effectiveR = budgetedDist * info[i].tanHalf

        guard effectiveR > 1e-10, budgetedDist > 1e-10 else {
            result.append(curr)
            continue
        }

        let u1x = dx1 / len1, u1y = dy1 / len1
        let u2x = dx2 / len2, u2y = dy2 / len2

        let aLon = curr.longitude - u1x * budgetedDist
        let aLat = curr.latitude  - u1y * budgetedDist
        let dLon = curr.longitude + u2x * budgetedDist
        let dLat = curr.latitude  + u2y * budgetedDist

        let cross = u1x * u2y - u1y * u2x

        let perpX: Double, perpY: Double
        if cross > 0 {
            perpX = -u1y; perpY =  u1x
        } else {
            perpX =  u1y; perpY = -u1x
        }

        let cLon = aLon + perpX * effectiveR
        let cLat = aLat + perpY * effectiveR

        let startAngle = atan2(aLat - cLat, aLon - cLon)
        let endAngle   = atan2(dLat - cLat, dLon - cLon)

        var sweep = endAngle - startAngle
        if cross > 0 {
            if sweep > 0 { sweep -= 2.0 * .pi }
        } else {
            if sweep < 0 { sweep += 2.0 * .pi }
        }

        // Safety: skip arcs that sweep > 180° (near-reversal)
        if abs(sweep) > Double.pi {
            result.append(curr)
            continue
        }

        for step in 0...arcPoints {
            let t = Double(step) / Double(arcPoints)
            let angle = startAngle + t * sweep
            let pLon = cLon + effectiveR * cos(angle)
            let pLat = cLat + effectiveR * sin(angle)
            result.append(CLLocationCoordinate2D(latitude: pLat, longitude: pLon))
        }
    }

    result.append(coordinates.last!)
    return result
}

// MARK: - Self-Intersection Removal

/// Detects and removes **all** backtracking loops in a polyline.
///
/// Walks the coordinate list tracking visited grid cells.  When a cell
/// is revisited after traversing enough intermediate vertices (≥ 3),
/// the segment between the first and last visit is checked for loop
/// characteristics (net displacement < 20 % of arc length).  If a loop
/// is confirmed it is cut out, keeping the longer non-looping portion.
///
/// The function iterates until no more loops are found, so polylines with
/// multiple backtrack artifacts are fully cleaned in a single call.
///
/// - Parameters:
///   - coordinates: Polyline vertices.
///   - cellSize: Spatial grid cell size in degrees for revisit detection.
///     Default `0.001` ≈ 84 m at NYC latitude.
///   - maxPasses: Safety cap on iteration count. Default **5**.
/// - Returns: Cleaned polyline with all detected backtrack loops removed.
nonisolated func removePolylineBacktracks(
    _ coordinates: [CLLocationCoordinate2D],
    cellSize: Double = 0.001,
    maxPasses: Int = 5
) -> [CLLocationCoordinate2D] {
    guard coordinates.count >= 6 else { return coordinates }

    typealias Cell = Int64

    func cellKey(_ coord: CLLocationCoordinate2D) -> Cell {
        let latCell = Int64(floor(coord.latitude / cellSize))
        let lonCell = Int64(floor(coord.longitude / cellSize))
        return latCell &* 10_000_000 &+ lonCell
    }

    /// Finds and removes the single largest backtrack loop.
    /// Returns `nil` when no loop is detected.
    func removeOneLoop(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D]? {
        guard coords.count >= 6 else { return nil }

        var firstVisit: [Cell: Int] = [:]
        var lastVisit:  [Cell: Int] = [:]

        for i in coords.indices {
            let cell = cellKey(coords[i])
            if firstVisit[cell] == nil { firstVisit[cell] = i }
            lastVisit[cell] = i
        }

        var bestGap   = 0
        var loopStart = -1
        var loopEnd   = -1

        for (cell, fi) in firstVisit {
            guard let li = lastVisit[cell] else { continue }
            let gap = li - fi
            guard gap >= 3, gap > bestGap else { continue }

            let sx = coords[fi].longitude, sy = coords[fi].latitude
            let ex = coords[li].longitude, ey = coords[li].latitude
            let net = sqrt((ex - sx) * (ex - sx) + (ey - sy) * (ey - sy))

            var arc = 0.0
            for j in fi..<li {
                let dx = coords[j + 1].longitude - coords[j].longitude
                let dy = coords[j + 1].latitude  - coords[j].latitude
                arc += sqrt(dx * dx + dy * dy)
            }

            if arc > 0, net / arc < 0.20 {
                bestGap   = gap
                loopStart = fi
                loopEnd   = li
            }
        }

        guard loopStart >= 0, loopEnd > loopStart else { return nil }

        let before  = Array(coords[..<(loopStart + 1)])
        let after   = Array(coords[loopEnd...])
        let cleaned = before + after
        guard cleaned.count >= 2 else { return nil }
        return cleaned
    }

    var result = coordinates
    for _ in 0..<maxPasses {
        guard let cleaned = removeOneLoop(result) else { break }
        result = cleaned
    }
    return result
}
