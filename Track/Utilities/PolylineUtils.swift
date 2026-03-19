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
/// `nonisolated` — pure computation safe for background threads.
nonisolated func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
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
nonisolated func encodePolyline(_ coordinates: [CLLocationCoordinate2D]) -> String {
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
private nonisolated func encodeValue(_ value: Int32, into result: inout String) {
    var v = value < 0 ? ~(value << 1) : (value << 1)
    while v >= 0x20 {
        let chunk = Int32((v & 0x1F) | 0x20) + 63
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
            if d1 < bestDist { bestDist = d1; bestIdx = i; bestReverse = false; bestPrepend = false }

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

// MARK: - Cross-Color Corridor Offsets (Apple Maps Style)

/// Applies perpendicular offsets to polylines of different color groups that
/// share a physical corridor, so they render as parallel colored stripes
/// instead of stacking on top of each other — matching Apple Maps transit.
///
/// **Segment-Level Corridor Detection**
/// Instead of checking corridor membership per-point (which causes lane
/// order to flicker when GPS drift moves a point between grid cells),
/// this algorithm identifies **corridor runs** — contiguous stretches of
/// ≥ minRunLength points where multiple color groups travel together.
/// The group set and lane ordering are frozen for the entire run,
/// producing rock-stable parallel lines.
///
/// **Rigid Shared Centerline**
/// All groups in a corridor offset from the SAME centerline — computed
/// as the average position across all participating groups' nearest
/// points. This eliminates wiggles caused by independent peer lookups.
///
/// **How it works**:
/// 1. Builds a spatial grid of all polylines from all color groups.
/// 2. For each polyline, computes per-point group sets from the grid.
/// 3. Identifies corridor runs: contiguous stretches where ≥2 groups
///    share the neighborhood, using majority-vote within each run.
/// 4. Freezes lane ordering per run (sorted group index — deterministic).
/// 5. Computes a shared centerline per point from nearest peers.
/// 6. Applies perpendicular offset with miter joins on the centerline.
/// 7. Smoothly transitions at corridor boundaries.
///
/// - Parameters:
///   - groupedPolylines: Array of `(groupIndex, coordinates)` tuples.
///   - laneSpacingDegrees: Center-to-center distance between adjacent lanes,
///     in degrees of longitude.  Default 0.00015°.
///   - smoothWindow: Moving-average window (in points) that gradually eases
///     into/out of offset corridors.
/// - Returns: The same polylines with perpendicular offsets applied.
///
/// - Note: **DEPRECATED** — Corridor offsets are now computed server-side in
///   `corridor_pipeline.py` (arc-based v3.2). This client-side implementation
///   is kept only for existing test coverage; do not call from production code.
@available(*, deprecated, message: "Corridor offsets are computed server-side. Use server pipeline.")
nonisolated func applyCorridorOffsets(
    _ groupedPolylines: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])],
    laneSpacingDegrees: Double = 0.00015,
    smoothWindow: Int = 16
) -> [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] {

    let gridSize: Double = 0.0005  // ~56 m cells

    // ── Step 1: Build spatial index ──
    struct GridPoint {
        let groupIdx: Int
        let coord: CLLocationCoordinate2D
    }

    var cellGroups: [Int64: Set<Int>] = [:]
    var cellPoints: [Int64: [GridPoint]] = [:]

    func cellKey(_ lat: Double, _ lon: Double) -> Int64 {
        let gx: Int32 = Int32(lat / gridSize)
        let gy: Int32 = Int32(lon / gridSize)
        let hi: Int64 = Int64(gx) << 32
        let lo: Int64 = Int64(gy & 0x7FFF_FFFF)
        return hi | lo
    }

    func groupsAt(_ lat: Double, _ lon: Double) -> Set<Int> {
        let gx: Int32 = Int32(lat / gridSize)
        let gy: Int32 = Int32(lon / gridSize)
        var groups: Set<Int> = []
        for dx: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                let hi: Int64 = Int64(gx &+ dx) << 32
                let lo: Int64 = Int64((gy &+ dy) & 0x7FFF_FFFF)
                let key: Int64 = hi | lo
                if let g = cellGroups[key] { groups.formUnion(g) }
            }
        }
        return groups
    }

    for (groupIdx, coords) in groupedPolylines {
        for coord in coords {
            let key: Int64 = cellKey(coord.latitude, coord.longitude)
            cellGroups[key, default: []].insert(groupIdx)
            cellPoints[key, default: []].append(GridPoint(groupIdx: groupIdx, coord: coord))
        }
    }

    // ── Step 2: Per-polyline segment-level corridor detection ──
    var result: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = []

    for (groupIdx, coords) in groupedPolylines {
        guard coords.count >= 2 else {
            result.append((groupIdx, coords))
            continue
        }

        // 2a. Compute raw per-point group sets
        var pointGroups = [Set<Int>](repeating: [], count: coords.count)
        for i in 0..<coords.count {
            pointGroups[i] = groupsAt(coords[i].latitude, coords[i].longitude)
        }

        // 2b. Identify corridor runs — contiguous stretches where this
        //     point sees ≥2 groups.  Short runs (< minRunLength) are
        //     crossing artifacts and get zeroed out.
        let minRunLength = 8
        var isInCorridor = [Bool](repeating: false, count: coords.count)
        for i in 0..<coords.count {
            isInCorridor[i] = pointGroups[i].count > 1 && pointGroups[i].contains(groupIdx)
        }

        // Zero out short runs (crossing filter)
        var runStart: Int? = nil
        for i in 0..<coords.count {
            if isInCorridor[i] {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                if i - s < minRunLength {
                    for k in s..<i { isInCorridor[k] = false }
                }
                runStart = nil
            }
        }
        if let s = runStart, coords.count - s < minRunLength {
            for k in s..<coords.count { isInCorridor[k] = false }
        }

        // 2c. For each corridor run, freeze the group set using majority
        //     vote — the most common group set across the run's points.
        //     This prevents point-by-point lane count flickering.
        struct CorridorRun {
            let start: Int
            let end: Int      // inclusive
            let frozenGroups: [Int]  // sorted, frozen for entire run
        }

        var corridorRuns: [CorridorRun] = []
        var rStart: Int? = nil
        for i in 0...coords.count {
            let inCorr = i < coords.count && isInCorridor[i]
            if inCorr {
                if rStart == nil { rStart = i }
            } else if let s = rStart {
                let end = i - 1
                // Majority vote: count how often each group set appears
                var setCounts: [Set<Int>: Int] = [:]
                for k in s...end {
                    let gs: Set<Int> = pointGroups[k]
                    setCounts[gs, default: 0] += 1
                }
                // Pick the group set that appears most often
                let bestSet: Set<Int> = setCounts.max(by: { $0.value < $1.value })?.key ?? []
                let frozen: [Int] = bestSet.sorted()

                // Only keep if this group is in the frozen set and ≥2 groups
                if frozen.count >= 2 && frozen.contains(groupIdx) {
                    corridorRuns.append(CorridorRun(start: s, end: end, frozenGroups: frozen))
                }
                rStart = nil
            }
        }

        // 2d. Build per-point lane offsets and centerline displacements
        //     using frozen corridor assignments.
        var centerDisplacements = [(lon: Double, lat: Double)](repeating: (0, 0), count: coords.count)
        var laneOffsets = [Double](repeating: 0, count: coords.count)

        for run in corridorRuns {
            let frozenGroups = run.frozenGroups
            guard let laneIndex = frozenGroups.firstIndex(of: groupIdx) else { continue }
            let numLanes: Int = frozenGroups.count
            let laneOffset: Double = (Double(laneIndex) - Double(numLanes - 1) / 2.0) * laneSpacingDegrees

            for i in run.start...run.end {
                laneOffsets[i] = laneOffset

                // Compute centerline displacement from nearest peers
                let coord = coords[i]
                var peers: [CLLocationCoordinate2D] = [coord]
                let gx: Int32 = Int32(coord.latitude / gridSize)
                let gy: Int32 = Int32(coord.longitude / gridSize)

                for otherGroup in frozenGroups where otherGroup != groupIdx {
                    var bestDistSq: Double = Double.infinity
                    var bestPeer: CLLocationCoordinate2D? = nil
                    for dx: Int32 in -1...1 {
                        for dy: Int32 in -1...1 {
                            let hi: Int64 = Int64(gx &+ dx) << 32
                            let lo: Int64 = Int64((gy &+ dy) & 0x7FFF_FFFF)
                            let key: Int64 = hi | lo
                            guard let pts = cellPoints[key] else { continue }
                            for p in pts where p.groupIdx == otherGroup {
                                let dlat = p.coord.latitude - coord.latitude
                                let dlon = p.coord.longitude - coord.longitude
                                let dsq = dlat * dlat + dlon * dlon
                                if dsq < bestDistSq {
                                    bestDistSq = dsq
                                    bestPeer = p.coord
                                }
                            }
                        }
                    }
                    let threshSq: Double = gridSize * gridSize * 4.0
                    if let peer = bestPeer, bestDistSq < threshSq {
                        peers.append(peer)
                    }
                }

                let avgLat: Double = peers.map { $0.latitude }.reduce(0.0, +) / Double(peers.count)
                let avgLon: Double = peers.map { $0.longitude }.reduce(0.0, +) / Double(peers.count)

                centerDisplacements[i] = (lon: avgLon - coord.longitude, lat: avgLat - coord.latitude)
            }
        }

        // ── Step 3: Smooth transitions at corridor boundaries ──
        var smoothedCenter = centerDisplacements
        var smoothedOffsets = laneOffsets
        for i in 0..<coords.count {
            let halfWin: Int = smoothWindow / 2
            let lo: Int = max(0, i - halfWin)
            let hi: Int = min(coords.count - 1, i + halfWin)
            let windowSize: Double = Double(hi - lo + 1)
            var sumLon: Double = 0.0
            var sumLat: Double = 0.0
            var sumOff: Double = 0.0
            for k in lo...hi {
                sumLon += centerDisplacements[k].lon
                sumLat += centerDisplacements[k].lat
                sumOff += laneOffsets[k]
            }
            smoothedCenter[i] = (sumLon / windowSize, sumLat / windowSize)
            smoothedOffsets[i] = sumOff / windowSize
        }

        // ── Step 4: Create base geometry (snap to centerline) ──
        var baseCoords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0), count: coords.count)
        for i in 0..<coords.count {
            baseCoords[i] = CLLocationCoordinate2D(
                latitude: coords[i].latitude + smoothedCenter[i].lat,
                longitude: coords[i].longitude + smoothedCenter[i].lon
            )
        }

        // ── Step 5: Compute per-segment unit normals ──
        let segCount = baseCoords.count - 1
        var segNormals = [(Double, Double)](repeating: (0, 0), count: segCount)
        for s in 0..<segCount {
            let dx = baseCoords[s + 1].longitude - baseCoords[s].longitude
            let dy = baseCoords[s + 1].latitude - baseCoords[s].latitude
            let len = sqrt(dx * dx + dy * dy)
            if len > 1e-10 {
                segNormals[s] = (-dy / len, dx / len)
            }
        }

        // ── Step 6: Apply offsets with miter joins ──
        var offsetCoords: [CLLocationCoordinate2D] = []
        offsetCoords.reserveCapacity(coords.count)

        for i in 0..<baseCoords.count {
            let offset = smoothedOffsets[i]
            if abs(offset) < 1e-10 {
                offsetCoords.append(baseCoords[i])
                continue
            }

            if i == 0 {
                let (nLat, nLon) = segNormals[0]
                offsetCoords.append(CLLocationCoordinate2D(
                    latitude: baseCoords[i].latitude + nLat * offset,
                    longitude: baseCoords[i].longitude + nLon * offset
                ))
            } else if i == baseCoords.count - 1 {
                let (nLat, nLon) = segNormals[segCount - 1]
                offsetCoords.append(CLLocationCoordinate2D(
                    latitude: baseCoords[i].latitude + nLat * offset,
                    longitude: baseCoords[i].longitude + nLon * offset
                ))
            } else {
                let (n1Lat, n1Lon) = segNormals[i - 1]
                let (n2Lat, n2Lon) = segNormals[i]

                var mLat = n1Lat + n2Lat
                var mLon = n1Lon + n2Lon
                let mLen = sqrt(mLat * mLat + mLon * mLon)

                if mLen > 1e-10 {
                    mLat /= mLen
                    mLon /= mLen

                    let dot = mLat * n1Lat + mLon * n1Lon
                    let miterScale: Double
                    if abs(dot) > 0.25 {
                        miterScale = min(1.0 / dot, 4.0)
                    } else {
                        miterScale = 4.0
                    }

                    offsetCoords.append(CLLocationCoordinate2D(
                        latitude: baseCoords[i].latitude + mLat * offset * miterScale,
                        longitude: baseCoords[i].longitude + mLon * offset * miterScale
                    ))
                } else {
                    let (nLat, nLon) = segNormals[i - 1]
                    offsetCoords.append(CLLocationCoordinate2D(
                        latitude: baseCoords[i].latitude + nLat * offset,
                        longitude: baseCoords[i].longitude + nLon * offset
                    ))
                }
            }
        }

        result.append((groupIdx, offsetCoords))
    }

    return result
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

        // >90% covered → near-duplicate (reverse direction, express overlay)
        if ratio > 0.90 { continue }

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

        let minRun = 15  // Ignore short fragments — curve-area GPS drift between
                         // GTFS shapes of the same physical track can produce
                         // uncovered runs of 5–12 points that are NOT real branches.
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
///   - segmentsPerCurve: Number of interpolated points between each pair
///     of original points. Higher = smoother but more points.
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

// MARK: - Adaptive Curve Refinement (System Map)

/// Refines sharp bends in a polyline by inserting Catmull-Rom interpolated
/// points ONLY at vertices where the turn angle exceeds `angleThreshold`.
///
/// This is a targeted alternative to full `smoothPolyline()`:
/// - Preserves straight segments exactly (no point inflation)
/// - Preserves station-snap points that lie on straight runs
/// - Only smooths the 10-20% of vertices that have visible corners
/// - 5× fewer inserted points than full Catmull-Rom
///
/// Perfect for the system map where MapLibre's `line-join: round` handles
/// gentle curves well, but sharp >25° bends (junction merges, tunnel
/// approaches, elevated curves) still show visible angular corners.
///
/// - Parameters:
///   - coordinates: Original polyline points (≥ 3 points required).
///   - angleThreshold: Minimum turn angle in degrees to trigger smoothing.
///     Default **25°** — gentle curves stay untouched, sharp turns get refined.
///   - insertions: Number of interpolated points to insert at each sharp bend.
///     Default **3** — enough to round the corner without bloating point count.
/// - Returns: Refined coordinate array with smooth corners.
nonisolated func refineSharpBends(
    _ coordinates: [CLLocationCoordinate2D],
    angleThreshold: Double = 25.0,
    insertions: Int = 3
) -> [CLLocationCoordinate2D] {
    guard coordinates.count >= 3 else { return coordinates }

    let cosThreshold = cos(angleThreshold * .pi / 180.0)
    let alpha: Double = 0.5  // centripetal
    var result: [CLLocationCoordinate2D] = [coordinates[0]]

    for i in 1..<(coordinates.count - 1) {
        let prev = coordinates[i - 1]
        let curr = coordinates[i]
        let next = coordinates[i + 1]

        // Compute turn angle at this vertex
        let dx1 = curr.longitude - prev.longitude
        let dy1 = curr.latitude - prev.latitude
        let dx2 = next.longitude - curr.longitude
        let dy2 = next.latitude - curr.latitude

        let len1 = sqrt(dx1 * dx1 + dy1 * dy1)
        let len2 = sqrt(dx2 * dx2 + dy2 * dy2)

        guard len1 > 1e-10, len2 > 1e-10 else {
            result.append(curr)
            continue
        }

        let dot = (dx1 * dx2 + dy1 * dy2) / (len1 * len2)

        // If turn angle is gentle (high cosine = small angle), keep as-is
        if dot > cosThreshold {
            result.append(curr)
            continue
        }

        // Sharp bend detected — insert Catmull-Rom interpolated points
        // around this vertex to smooth the corner
        let p0 = coordinates[max(i - 2, 0)]
        let p1 = prev
        let p2 = curr
        let p3 = next

        let d01 = knotDistance(p0, p1, alpha: alpha)
        let d12 = knotDistance(p1, p2, alpha: alpha)
        let d23 = knotDistance(p2, p3, alpha: alpha)

        guard d12 > 1e-10 else {
            result.append(curr)
            continue
        }

        let t0: Double = 0
        let t1 = t0 + d01
        let t2 = t1 + d12
        let t3 = t2 + d23

        // Insert points in the second half of the segment approaching the bend
        for step in 1...insertions {
            let fraction = 0.5 + 0.5 * Double(step) / Double(insertions + 1)
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

        // Also insert points in the first half of the segment leaving the bend
        let p0b = prev
        let p1b = curr
        let p2b = next
        let p3b = coordinates[min(i + 2, coordinates.count - 1)]

        let d01b = knotDistance(p0b, p1b, alpha: alpha)
        let d12b = knotDistance(p1b, p2b, alpha: alpha)
        let d23b = knotDistance(p2b, p3b, alpha: alpha)

        guard d12b > 1e-10 else { continue }

        let t0b: Double = 0
        let t1b = t0b + d01b
        let t2b = t1b + d12b
        let t3b = t2b + d23b

        for step in 1...insertions {
            let fraction = Double(step) / Double(insertions + 1) * 0.5
            let t = t1b + fraction * (t2b - t1b)
            let (lat, lon) = catmullRomPoint(
                p0: (p0b.latitude, p0b.longitude),
                p1: (p1b.latitude, p1b.longitude),
                p2: (p2b.latitude, p2b.longitude),
                p3: (p3b.latitude, p3b.longitude),
                t: t, t0: t0b, t1: t1b, t2: t2b, t3: t3b
            )
            result.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }

    result.append(coordinates.last!)
    return result
}
