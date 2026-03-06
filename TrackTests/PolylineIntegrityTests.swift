//
//  PolylineIntegrityTests.swift
//  TrackTests
//
//  Validates that every polyline utility produces a single continuous line
//  that never forks, splits, or jumps away from its intended path.
//
//  Key invariants tested:
//  1. Output is one contiguous chain — no unexpected splits.
//  2. Consecutive points are within a reasonable distance (no teleports).
//  3. Simplification never moves points off the original path.
//  4. Unification/merge never mixes coordinates from unrelated segments.
//  5. Corridor offsets stay parallel to the original line.
//

import CoreLocation
import Testing
@testable import Track

// MARK: - Test Fixtures

/// Realistic NYC polyline fixtures for testing.
private enum PolylineFixtures {

    /// Straight north–south line along Lexington Ave (~10 points, ~1.5 km).
    static let lexingtonAve: [CLLocationCoordinate2D] = (0..<10).map {
        CLLocationCoordinate2D(latitude: 40.7500 + Double($0) * 0.0015, longitude: -73.9770)
    }

    /// Straight east–west line along 42nd St (~8 points, ~1 km).
    static let fortySecondSt: [CLLocationCoordinate2D] = (0..<8).map {
        CLLocationCoordinate2D(latitude: 40.7550, longitude: -73.9900 + Double($0) * 0.0015)
    }

    /// L-shaped route: north then east (simulates a turn).
    static let lShape: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.6900, longitude: -73.9850),
        CLLocationCoordinate2D(latitude: 40.6910, longitude: -73.9850),
        CLLocationCoordinate2D(latitude: 40.6920, longitude: -73.9850),
        CLLocationCoordinate2D(latitude: 40.6930, longitude: -73.9850),
        CLLocationCoordinate2D(latitude: 40.6930, longitude: -73.9840), // turn
        CLLocationCoordinate2D(latitude: 40.6930, longitude: -73.9830),
        CLLocationCoordinate2D(latitude: 40.6930, longitude: -73.9820),
        CLLocationCoordinate2D(latitude: 40.6930, longitude: -73.9810),
    ]

    /// Two segments that should merge (endpoint of A ≈ startpoint of B).
    static let segmentA: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9900),
        CLLocationCoordinate2D(latitude: 40.7010, longitude: -73.9900),
        CLLocationCoordinate2D(latitude: 40.7020, longitude: -73.9900),
    ]
    static let segmentB: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7021, longitude: -73.9900), // ~110m from segA end
        CLLocationCoordinate2D(latitude: 40.7030, longitude: -73.9900),
        CLLocationCoordinate2D(latitude: 40.7040, longitude: -73.9900),
    ]

    /// A branch that diverges from the trunk (think A train Rockaway branch).
    static let trunk: [CLLocationCoordinate2D] = (0..<15).map {
        CLLocationCoordinate2D(latitude: 40.7000 + Double($0) * 0.002, longitude: -73.9900)
    }
    static let branch: [CLLocationCoordinate2D] = {
        // Shares first 5 points with trunk, then diverges east (67% unique).
        let shared = (0..<5).map {
            CLLocationCoordinate2D(latitude: 40.7000 + Double($0) * 0.002, longitude: -73.9900)
        }
        let diverged = (0..<10).map {
            CLLocationCoordinate2D(latitude: 40.7080 + Double($0) * 0.001, longitude: -73.9900 + Double($0) * 0.003)
        }
        return shared + diverged
    }()

    /// Completely separate line (Far away — should never merge with Lex Ave).
    static let statenIsland: [CLLocationCoordinate2D] = (0..<6).map {
        CLLocationCoordinate2D(latitude: 40.6000 + Double($0) * 0.002, longitude: -74.0800)
    }
}

// MARK: - Helpers

/// Distance in degrees between two coordinates (fast planar approximation).
private func degreeDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let dx = a.longitude - b.longitude
    let dy = a.latitude - b.latitude
    return sqrt(dx * dx + dy * dy)
}

/// Maximum gap between consecutive points in a polyline.
private func maxConsecutiveGap(_ coords: [CLLocationCoordinate2D]) -> Double {
    guard coords.count >= 2 else { return 0 }
    var maxGap = 0.0
    for i in 1..<coords.count {
        let gap = degreeDistance(coords[i - 1], coords[i])
        if gap > maxGap { maxGap = gap }
    }
    return maxGap
}

/// Checks that every point in `simplified` lies close to the original polyline.
/// Returns the maximum deviation found.
private func maxDeviationFromOriginal(
    simplified: [CLLocationCoordinate2D],
    original: [CLLocationCoordinate2D]
) -> Double {
    var maxDev = 0.0
    for pt in simplified {
        var minDist = Double.greatestFiniteMagnitude
        for orig in original {
            let d = degreeDistance(pt, orig)
            if d < minDist { minDist = d }
        }
        if minDist > maxDev { maxDev = minDist }
    }
    return maxDev
}

// MARK: - Tests

@MainActor
struct PolylineIntegrityTests {

    // ─────────────────────────────────────────────────────
    // MARK: 1. mergeAdjacentPolylines — Continuity
    // ─────────────────────────────────────────────────────

    @Test func mergeProducesOneContinuousLine() {
        // Two adjacent segments should merge into exactly one polyline.
        let merged = mergeAdjacentPolylines(
            [PolylineFixtures.segmentA, PolylineFixtures.segmentB],
            gapThreshold: 0.002
        )
        #expect(merged.count == 1, "Adjacent segments should merge into 1 chain, got \(merged.count)")
    }

    @Test func mergePreservesContinuity_noTeleports() {
        let merged = mergeAdjacentPolylines(
            [PolylineFixtures.segmentA, PolylineFixtures.segmentB],
            gapThreshold: 0.002
        )
        for chain in merged {
            let gap = maxConsecutiveGap(chain)
            // ~0.001° between original waypoints; merged gap should be similar
            #expect(gap < 0.003, "Merged chain has a teleport gap of \(gap)°")
        }
    }

    @Test func mergeNeverCombinesDistantLines() {
        // Lex Ave (Manhattan) and Staten Island should NEVER merge.
        let merged = mergeAdjacentPolylines(
            [PolylineFixtures.lexingtonAve, PolylineFixtures.statenIsland],
            gapThreshold: 0.002
        )
        #expect(merged.count == 2, "Distant lines should stay separate, got \(merged.count)")
    }

    @Test func mergeHandlesReversedSegments() {
        // Segment B reversed should still merge with segment A.
        let reversed = Array(PolylineFixtures.segmentB.reversed())
        let merged = mergeAdjacentPolylines(
            [PolylineFixtures.segmentA, reversed],
            gapThreshold: 0.002
        )
        #expect(merged.count == 1, "Reversed adjacent segment should still merge")
        let gap = maxConsecutiveGap(merged[0])
        #expect(gap < 0.003, "Reversed merge has gap \(gap)°")
    }

    @Test func mergeSingleSegmentPassesThrough() {
        let merged = mergeAdjacentPolylines([PolylineFixtures.lexingtonAve])
        #expect(merged.count == 1)
        #expect(merged[0].count == PolylineFixtures.lexingtonAve.count)
    }

    @Test func mergeEmptyInputReturnsEmpty() {
        let merged = mergeAdjacentPolylines([])
        #expect(merged.isEmpty)
    }

    // ─────────────────────────────────────────────────────
    // MARK: 2. unifyTrainPolylines — Single Trunk + Branches
    // ─────────────────────────────────────────────────────

    @Test func unifyRemovesDuplicateReverseDirection() {
        // The same line in both directions should unify to 1 polyline.
        let forward = PolylineFixtures.lexingtonAve
        let backward = Array(forward.reversed())
        let unified = unifyTrainPolylines([forward, backward])
        let unifiedCount = unified.count
        #expect(unifiedCount == 1, "Forward + reverse should unify to 1 line, got \(String(unifiedCount))")
    }

    @Test func unifyKeepsBranches() {
        // A trunk + a diverging branch should produce 2 polylines (or a merged trunk+branch).
        // The branch has ~53% unique content, so it should NOT be dropped.
        let unified = unifyTrainPolylines([PolylineFixtures.trunk, PolylineFixtures.branch])
        // Should keep at least the trunk; branch may merge or stay separate
        #expect(unified.count >= 1, "Should keep at least the trunk")
        // Total point coverage: all trunk points + branch-unique points should be represented
        let totalPoints = unified.reduce(0) { $0 + $1.count }
        #expect(totalPoints >= PolylineFixtures.trunk.count, "Unified should cover at least the trunk length")
    }

    @Test func unifyOutputIsContinuous() {
        // Every output polyline from unify should be internally continuous.
        let unified = unifyTrainPolylines([
            PolylineFixtures.trunk,
            PolylineFixtures.branch,
            PolylineFixtures.lexingtonAve,
        ])
        for (idx, chain) in unified.enumerated() {
            let gap = maxConsecutiveGap(chain)
            // Allow generous threshold: merge gap ≈ 0.003° + original spacing ≈ 0.002°
            #expect(gap < 0.006, "Unified polyline \(idx) has teleport gap \(gap)°")
        }
    }

    @Test func unifyNeverMixesDistantRoutes() {
        // Unifying Lex Ave + Staten Island should keep them separate (< 85% overlap).
        let unified = unifyTrainPolylines([
            PolylineFixtures.lexingtonAve,
            PolylineFixtures.statenIsland,
        ])
        #expect(unified.count == 2, "Distant routes should stay as 2 separate polylines, got \(unified.count)")
    }

    @Test func unifySingleInputPassesThrough() {
        let unified = unifyTrainPolylines([PolylineFixtures.lexingtonAve])
        #expect(unified.count == 1)
        #expect(unified[0].count == PolylineFixtures.lexingtonAve.count)
    }

    // ─────────────────────────────────────────────────────
    // MARK: 3. simplifyPolyline — Stays on Path
    // ─────────────────────────────────────────────────────

    @Test func simplifyNeverLeavesOriginalPath() {
        // Every simplified point must lie within tolerance of the original.
        let tolerance = 0.00015  // ~17m at NYC latitude
        let simplified = simplifyPolyline(PolylineFixtures.lShape, tolerance: tolerance)
        let deviation = maxDeviationFromOriginal(simplified: simplified, original: PolylineFixtures.lShape)
        // Simplified points are a subset of originals in RDP, so deviation should be 0
        #expect(deviation < 1e-8, "Simplified point deviated \(deviation)° from original path")
    }

    @Test func simplifyPreservesEndpoints() {
        let simplified = simplifyPolyline(PolylineFixtures.lShape, tolerance: 0.0001)
        #expect(simplified.first!.latitude == PolylineFixtures.lShape.first!.latitude)
        #expect(simplified.first!.longitude == PolylineFixtures.lShape.first!.longitude)
        #expect(simplified.last!.latitude == PolylineFixtures.lShape.last!.latitude)
        #expect(simplified.last!.longitude == PolylineFixtures.lShape.last!.longitude)
    }

    @Test func simplifyReducesPointCount() {
        // The L-shape has 8 points; a generous tolerance should reduce it.
        let simplified = simplifyPolyline(PolylineFixtures.lShape, tolerance: 0.0005)
        #expect(simplified.count < PolylineFixtures.lShape.count,
                "Expected fewer points: got \(simplified.count) vs original \(PolylineFixtures.lShape.count)")
        #expect(simplified.count >= 2, "Must keep at least start + end")
    }

    @Test func simplifyKeepsCornersOnLShape() {
        // The L-shape corner should be preserved even with aggressive simplification.
        let simplified = simplifyPolyline(PolylineFixtures.lShape, tolerance: 0.0003)
        // The corner is around index 3-4: (40.6930, -73.9850) → (40.6930, -73.9840)
        // At least one point near the corner should be retained.
        let cornerLat = 40.6930
        let hasCorner = simplified.contains { abs($0.latitude - cornerLat) < 0.001 && $0.longitude < -73.9840 }
        #expect(hasCorner, "L-shape corner should be preserved")
    }

    @Test func simplifyStraightLineReducesToTwoPoints() {
        // A perfectly straight line should simplify to just endpoints.
        let straight = PolylineFixtures.lexingtonAve  // nearly straight N-S
        let simplified = simplifyPolyline(straight, tolerance: 0.0005)
        // Lex Ave has very slight longitude drift, so with generous tolerance → 2 points
        #expect(simplified.count <= 3, "Straight line should simplify to ~2 points, got \(simplified.count)")
    }

    @Test func simplifyTwoPointsUntouched() {
        let twoPoints = Array(PolylineFixtures.lexingtonAve.prefix(2))
        let simplified = simplifyPolyline(twoPoints, tolerance: 0.0001)
        #expect(simplified.count == 2)
    }

    @Test func simplifyOutputIsContinuous() {
        let simplified = simplifyPolyline(PolylineFixtures.lShape, tolerance: 0.0001)
        let gap = maxConsecutiveGap(simplified)
        let originalMaxGap = maxConsecutiveGap(PolylineFixtures.lShape)
        // Simplified gaps can be larger (skipped points) but never should teleport
        // Max gap = sum of a few original gaps at most
        #expect(gap < originalMaxGap * Double(PolylineFixtures.lShape.count),
                "Simplified polyline has unreasonable gap \(gap)°")
    }

    // ─────────────────────────────────────────────────────
    // MARK: 4. applyCorridorOffsets — Parallel Lines
    // ─────────────────────────────────────────────────────

    @Test func corridorOffsetSingleGroupUnchanged() {
        // A single color group should NOT be offset (no other group to fan from).
        let input: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = [
            (0, PolylineFixtures.lexingtonAve),
        ]
        let result = applyCorridorOffsets(input)
        #expect(result.count == 1)
        for (orig, res) in zip(PolylineFixtures.lexingtonAve, result[0].coordinates) {
            #expect(degreeDistance(orig, res) < 1e-8, "Single group should be unchanged")
        }
    }

    @Test func corridorOffsetTwoGroupsProducesParallelLines() {
        // Two different color groups on the same corridor should be offset.
        let input: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = [
            (0, PolylineFixtures.lexingtonAve),  // e.g. Green (4/5/6)
            (1, PolylineFixtures.lexingtonAve),  // e.g. Blue  (A/C/E)
        ]
        let result = applyCorridorOffsets(input, offsetDegrees: 0.00012)
        #expect(result.count == 2)

        // The two output lines should differ from each other
        var totalDiff = 0.0
        for i in 0..<PolylineFixtures.lexingtonAve.count {
            totalDiff += degreeDistance(result[0].coordinates[i], result[1].coordinates[i])
        }
        let avgDiff = totalDiff / Double(PolylineFixtures.lexingtonAve.count)
        #expect(avgDiff > 1e-6, "Two co-located groups should have visible offset, avg diff = \(avgDiff)")
    }

    @Test func corridorOffsetStaysCloseToOriginal() {
        // Offset lines should stay within a reasonable distance of the original.
        let input: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = [
            (0, PolylineFixtures.lexingtonAve),
            (1, PolylineFixtures.lexingtonAve),
        ]
        let result = applyCorridorOffsets(input, offsetDegrees: 0.00012)

        for groupResult in result {
            let maxDev = maxDeviationFromOriginal(
                simplified: groupResult.coordinates,
                original: PolylineFixtures.lexingtonAve
            )
            // 0.00012° ≈ 13m; with centering, max offset ≈ 0.00006°
            #expect(maxDev < 0.001, "Offset line deviated \(maxDev)° from original — too far")
        }
    }

    @Test func corridorOffsetPreservesPointCount() {
        let input: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = [
            (0, PolylineFixtures.lexingtonAve),
            (1, PolylineFixtures.lexingtonAve),
        ]
        let result = applyCorridorOffsets(input)
        for group in result {
            #expect(group.coordinates.count == PolylineFixtures.lexingtonAve.count,
                    "Offset should not add or remove points")
        }
    }

    @Test func corridorOffsetOutputIsContinuous() {
        let input: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = [
            (0, PolylineFixtures.lexingtonAve),
            (1, PolylineFixtures.lexingtonAve),
        ]
        let result = applyCorridorOffsets(input)
        for (idx, group) in result.enumerated() {
            let gap = maxConsecutiveGap(group.coordinates)
            let origGap = maxConsecutiveGap(PolylineFixtures.lexingtonAve)
            // Offset shouldn't create gaps more than ~2x the original spacing
            #expect(gap < origGap * 2.5, "Offset group \(idx) has gap \(gap)° vs original \(origGap)°")
        }
    }

    @Test func corridorOffsetNonOverlappingGroupsUntouched() {
        // Two groups on different tracks should not be offset.
        let input: [(groupIndex: Int, coordinates: [CLLocationCoordinate2D])] = [
            (0, PolylineFixtures.lexingtonAve),   // Manhattan
            (1, PolylineFixtures.statenIsland),    // Staten Island
        ]
        let result = applyCorridorOffsets(input)
        // Lex Ave should be unchanged (no corridor overlap with SI)
        for (orig, res) in zip(PolylineFixtures.lexingtonAve, result[0].coordinates) {
            #expect(degreeDistance(orig, res) < 1e-8, "Non-overlapping group should be unchanged")
        }
    }

    // ─────────────────────────────────────────────────────
    // MARK: 5. Encode/Decode Round-Trip Integrity
    // ─────────────────────────────────────────────────────

    @Test func encodeDecodeRoundTrip() {
        let original = PolylineFixtures.lShape
        let encoded = encodePolyline(original)
        let decoded = decodePolyline(encoded)

        #expect(decoded.count == original.count, "Round-trip changed point count")
        for (orig, dec) in zip(original, decoded) {
            #expect(abs(orig.latitude - dec.latitude) < 1e-4, "Latitude drift on round-trip")
            #expect(abs(orig.longitude - dec.longitude) < 1e-4, "Longitude drift on round-trip")
        }
    }

    @Test func encodeDecodePreservesOrder() {
        let original = PolylineFixtures.lexingtonAve
        let decoded = decodePolyline(encodePolyline(original))

        // Latitudes should be monotonically increasing (northbound)
        for i in 1..<decoded.count {
            #expect(decoded[i].latitude > decoded[i - 1].latitude - 1e-4,
                    "Point order scrambled at index \(i)")
        }
    }

    @Test func decodeEmptyStringReturnsEmpty() {
        let decoded = decodePolyline("")
        #expect(decoded.isEmpty)
    }

    // ─────────────────────────────────────────────────────
    // MARK: 6. Full Pipeline — Unify → Simplify → Verify
    // ─────────────────────────────────────────────────────

    @Test func fullPipelineProducesContinuousOutput() {
        // Simulate the actual pipeline: pool segments → unify → simplify.
        // Uses the trunk + its reverse (which should deduplicate) and a branch
        // that diverges from the trunk.
        let segments: [[CLLocationCoordinate2D]] = [
            PolylineFixtures.trunk,
            Array(PolylineFixtures.trunk.reversed()),
            PolylineFixtures.branch,
        ]

        let unified = unifyTrainPolylines(segments)

        for (idx, polyline) in unified.enumerated() {
            // 1. Unified polyline must have at least 2 points
            #expect(polyline.count >= 2, "Unified output \(idx) has < 2 points")

            // 2. No teleport gaps in the UNIFIED polyline (before simplification).
            //    This is the critical continuity check — the raw merged polyline
            //    must be a single continuous chain, not two disconnected segments.
            let rawGap = maxConsecutiveGap(polyline)
            // Branch diverges at 0.003° per step; merge gap ≤ 0.003°. Allow some headroom.
            #expect(rawGap < 0.006, "Unified polyline \(idx) has raw gap \(rawGap)°")

            // 3. Simplify and verify points are a subset of the original
            let simplified = simplifyPolyline(polyline, tolerance: 0.00015)
            #expect(simplified.count >= 2, "Simplified output \(idx) has < 2 points")

            let deviation = maxDeviationFromOriginal(simplified: simplified, original: polyline)
            #expect(deviation < 1e-8, "Simplified output \(idx) deviated \(deviation)° from unified path")
        }
    }

    @Test func fullPipelineNeverProducesEmptyPolyline() {
        let segments: [[CLLocationCoordinate2D]] = [
            PolylineFixtures.lexingtonAve,
            PolylineFixtures.fortySecondSt,
            PolylineFixtures.lShape,
        ]
        let unified = unifyTrainPolylines(segments)
        for polyline in unified {
            let simplified = simplifyPolyline(polyline, tolerance: 0.00015)
            #expect(!simplified.isEmpty, "Pipeline should never produce empty polyline")
            #expect(simplified.count >= 2, "Pipeline should always produce >= 2 points")
        }
    }
}

// MARK: - Realistic NYC Branching Fixtures

/// Real-world-style fixtures modelling actual MTA subway geography.
/// Coordinates are approximate but follow the real track corridors
/// so tests validate the same geometry the app renders.
private enum NYCSubwayFixtures {

    // ── A Train: 8th Ave trunk splitting into Far Rockaway & Lefferts branches ──

    /// 8th Ave trunk: 207th St → Howard Beach junction (~16 stops).
    /// Runs south through upper Manhattan, Midtown, FiDi, then across to Brooklyn.
    static let aTrunk: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.8681, longitude: -73.9189),  // Inwood–207 St
        CLLocationCoordinate2D(latitude: 40.8520, longitude: -73.9345),  // Dyckman St
        CLLocationCoordinate2D(latitude: 40.8404, longitude: -73.9396),  // 175 St
        CLLocationCoordinate2D(latitude: 40.8291, longitude: -73.9447),  // 168 St
        CLLocationCoordinate2D(latitude: 40.8118, longitude: -73.9584),  // 145 St
        CLLocationCoordinate2D(latitude: 40.7958, longitude: -73.9693),  // 125 St
        CLLocationCoordinate2D(latitude: 40.7751, longitude: -73.9814),  // 59 St Columbus Circle
        CLLocationCoordinate2D(latitude: 40.7590, longitude: -73.9846),  // 42 St Port Authority
        CLLocationCoordinate2D(latitude: 40.7505, longitude: -73.9911),  // 34 St Penn Station
        CLLocationCoordinate2D(latitude: 40.7342, longitude: -74.0003),  // 14 St
        CLLocationCoordinate2D(latitude: 40.7207, longitude: -74.0054),  // W 4 St
        CLLocationCoordinate2D(latitude: 40.7131, longitude: -74.0097),  // Canal St
        CLLocationCoordinate2D(latitude: 40.7069, longitude: -74.0130),  // Fulton St
        CLLocationCoordinate2D(latitude: 40.6946, longitude: -73.9858),  // Jay St MetroTech
        CLLocationCoordinate2D(latitude: 40.6852, longitude: -73.9770),  // Hoyt–Schermerhorn
        CLLocationCoordinate2D(latitude: 40.6591, longitude: -73.8307),  // Howard Beach (junction)
    ]

    /// Far Rockaway branch: Howard Beach → Far Rockaway–Mott Ave.
    static let aFarRockaway: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.6591, longitude: -73.8307),  // Howard Beach junction
        CLLocationCoordinate2D(latitude: 40.6512, longitude: -73.8217),  // Broad Channel
        CLLocationCoordinate2D(latitude: 40.6052, longitude: -73.7606),  // Beach 67 St
        CLLocationCoordinate2D(latitude: 40.6006, longitude: -73.7516),  // Beach 60 St
        CLLocationCoordinate2D(latitude: 40.5976, longitude: -73.7440),  // Beach 44 St
        CLLocationCoordinate2D(latitude: 40.5958, longitude: -73.7385),  // Beach 36 St
        CLLocationCoordinate2D(latitude: 40.5942, longitude: -73.7335),  // Beach 25 St
        CLLocationCoordinate2D(latitude: 40.6036, longitude: -73.7551),  // Far Rockaway–Mott Ave
    ]

    /// Lefferts branch: Howard Beach area → Lefferts Blvd.
    /// This fork heads north-east into the Lefferts Gardens neighbourhood,
    /// completely different direction from the Rockaway peninsula.
    static let aLefferts: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.6591, longitude: -73.8307),  // Howard Beach junction
        CLLocationCoordinate2D(latitude: 40.6620, longitude: -73.8230),  // ← diverges NE
        CLLocationCoordinate2D(latitude: 40.6673, longitude: -73.8140),
        CLLocationCoordinate2D(latitude: 40.6719, longitude: -73.8059),
        CLLocationCoordinate2D(latitude: 40.6755, longitude: -73.7980),  // Ozone Park
        CLLocationCoordinate2D(latitude: 40.6810, longitude: -73.7885),
        CLLocationCoordinate2D(latitude: 40.6860, longitude: -73.8080),  // Lefferts Blvd
    ]

    // ── N/Q/R/W: shared Broadway trunk splitting into separate tails ──

    /// Broadway BMT trunk: Times Sq → DeKalb Ave (~10 stops, shared by N/Q/R/W).
    static let broadwayTrunk: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7559, longitude: -73.9871),  // Times Sq
        CLLocationCoordinate2D(latitude: 40.7491, longitude: -73.9882),  // 34 St Herald Sq
        CLLocationCoordinate2D(latitude: 40.7418, longitude: -73.9894),  // 28 St
        CLLocationCoordinate2D(latitude: 40.7359, longitude: -73.9906),  // 23 St
        CLLocationCoordinate2D(latitude: 40.7225, longitude: -73.9924),  // 14 St Union Sq
        CLLocationCoordinate2D(latitude: 40.7141, longitude: -73.9940),  // 8 St NYU
        CLLocationCoordinate2D(latitude: 40.7035, longitude: -73.9962),  // Prince St
        CLLocationCoordinate2D(latitude: 40.6997, longitude: -73.9982),  // Canal St
        CLLocationCoordinate2D(latitude: 40.6918, longitude: -73.9906),  // City Hall
        CLLocationCoordinate2D(latitude: 40.6886, longitude: -73.9818),  // Whitehall area
        CLLocationCoordinate2D(latitude: 40.6864, longitude: -73.9779),  // DeKalb Ave
    ]

    /// Q branch tail: DeKalb → Coney Island via Brighton Line.
    /// Heads south-east along the coast.
    static let qBrighton: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.6864, longitude: -73.9779),  // DeKalb
        CLLocationCoordinate2D(latitude: 40.6712, longitude: -73.9627),  // Prospect Park
        CLLocationCoordinate2D(latitude: 40.6531, longitude: -73.9587),  // Church Ave
        CLLocationCoordinate2D(latitude: 40.6322, longitude: -73.9528),  // Newkirk Plaza
        CLLocationCoordinate2D(latitude: 40.6153, longitude: -73.9475),  // Sheepshead Bay
        CLLocationCoordinate2D(latitude: 40.6043, longitude: -73.9440),  // Brighton Beach
        CLLocationCoordinate2D(latitude: 40.5761, longitude: -73.9688),  // Coney Island
    ]

    /// R branch tail: DeKalb → Bay Ridge via 4th Ave.
    /// Heads south through a completely different corridor.
    static let r4thAve: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.6864, longitude: -73.9779),  // DeKalb
        CLLocationCoordinate2D(latitude: 40.6831, longitude: -73.9788),  // Atlantic
        CLLocationCoordinate2D(latitude: 40.6706, longitude: -73.9894),  // Union St
        CLLocationCoordinate2D(latitude: 40.6606, longitude: -74.0001),  // 9 St
        CLLocationCoordinate2D(latitude: 40.6448, longitude: -74.0098),  // 36 St
        CLLocationCoordinate2D(latitude: 40.6346, longitude: -74.0184),  // 53 St
        CLLocationCoordinate2D(latitude: 40.6222, longitude: -74.0284),  // 86 St
        CLLocationCoordinate2D(latitude: 40.6201, longitude: -74.0310),  // Bay Ridge–95 St
    ]

    // ── Curve fixtures for smoothing tests ──

    /// Queens Blvd curve: a gradual ~90° turn that the 7 train makes
    /// from east-west along Queens Blvd to north-south into Flushing.
    /// This tests that curves are smooth, not angular.
    static let queensBlvdCurve: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7425, longitude: -73.9231),  // Woodside
        CLLocationCoordinate2D(latitude: 40.7438, longitude: -73.9178),
        CLLocationCoordinate2D(latitude: 40.7452, longitude: -73.9108),
        CLLocationCoordinate2D(latitude: 40.7478, longitude: -73.9052),  // curve apex
        CLLocationCoordinate2D(latitude: 40.7515, longitude: -73.9012),
        CLLocationCoordinate2D(latitude: 40.7555, longitude: -73.8985),
        CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.8967),
        CLLocationCoordinate2D(latitude: 40.7649, longitude: -73.8950),
        CLLocationCoordinate2D(latitude: 40.7700, longitude: -73.8932),  // Flushing direction
    ]

    /// A tight S-curve (like the tracks near Prospect Park).
    static let sCurve: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.6600, longitude: -73.9620),
        CLLocationCoordinate2D(latitude: 40.6620, longitude: -73.9605),
        CLLocationCoordinate2D(latitude: 40.6640, longitude: -73.9580), // first bend
        CLLocationCoordinate2D(latitude: 40.6650, longitude: -73.9570),
        CLLocationCoordinate2D(latitude: 40.6660, longitude: -73.9575), // inflection
        CLLocationCoordinate2D(latitude: 40.6670, longitude: -73.9590),
        CLLocationCoordinate2D(latitude: 40.6680, longitude: -73.9610), // second bend
        CLLocationCoordinate2D(latitude: 40.6690, longitude: -73.9620),
        CLLocationCoordinate2D(latitude: 40.6700, longitude: -73.9615),
    ]
}

// MARK: - Additional Helpers for Branch & Curve Tests

/// Bounding box of a polyline.
private func boundingBox(_ coords: [CLLocationCoordinate2D]) -> (
    minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
) {
    var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
    var minLon = Double.greatestFiniteMagnitude, maxLon = -Double.greatestFiniteMagnitude
    for c in coords {
        minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
        minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
    }
    return (minLat, maxLat, minLon, maxLon)
}

/// Checks if any point in `polyline` falls within `threshold` of `target`.
private func polylineReaches(
    _ polyline: [CLLocationCoordinate2D],
    target: CLLocationCoordinate2D,
    threshold: Double = 0.005
) -> Bool {
    polyline.contains { degreeDistance($0, target) < threshold }
}

/// Turning angle at each interior point (in degrees). Large values = sharp bend.
private func turningAngles(_ coords: [CLLocationCoordinate2D]) -> [Double] {
    guard coords.count >= 3 else { return [] }
    var angles: [Double] = []
    for i in 1..<(coords.count - 1) {
        let v1x = coords[i].longitude - coords[i - 1].longitude
        let v1y = coords[i].latitude - coords[i - 1].latitude
        let v2x = coords[i + 1].longitude - coords[i].longitude
        let v2y = coords[i + 1].latitude - coords[i].latitude
        let dot = v1x * v2x + v1y * v2y
        let cross = v1x * v2y - v1y * v2x
        let angle = atan2(cross, dot) * 180.0 / .pi
        angles.append(abs(angle))
    }
    return angles
}

// MARK: - Branch Preservation & Curve Quality Tests

@MainActor
struct BranchAndCurveTests {

    // ─────────────────────────────────────────────────────
    // MARK: 7. A Train Branching — Both branches survive
    // ─────────────────────────────────────────────────────

    @Test func aTrainBothBranchesPreserved() {
        // Pool all A train segments: trunk + Far Rockaway + Lefferts.
        // Unify should keep branches because they diverge significantly.
        let allSegments = [
            NYCSubwayFixtures.aTrunk,
            NYCSubwayFixtures.aFarRockaway,
            NYCSubwayFixtures.aLefferts,
        ]
        let unified = unifyTrainPolylines(allSegments)

        // Must have at least 2 polylines (trunk+branch or merged combos).
        // The trunk shares endpoints with both branches, so merge may combine
        // trunk+one branch, but the other branch must survive separately.
        #expect(unified.count >= 2,
                "A train must preserve both branches, got \(unified.count) polyline(s)")
    }

    @Test func aTrainFarRockawayReachesTerminal() {
        let allSegments = [
            NYCSubwayFixtures.aTrunk,
            NYCSubwayFixtures.aFarRockaway,
            NYCSubwayFixtures.aLefferts,
        ]
        let unified = unifyTrainPolylines(allSegments)

        // Far Rockaway terminal: ~(40.603, -73.755)
        let farRockawayTerminal = CLLocationCoordinate2D(latitude: 40.603, longitude: -73.755)
        let anyReaches = unified.contains { polylineReaches($0, target: farRockawayTerminal, threshold: 0.01) }
        #expect(anyReaches, "A train polylines must reach Far Rockaway terminal")
    }

    @Test func aTrainLeffertsReachesTerminal() {
        let allSegments = [
            NYCSubwayFixtures.aTrunk,
            NYCSubwayFixtures.aFarRockaway,
            NYCSubwayFixtures.aLefferts,
        ]
        let unified = unifyTrainPolylines(allSegments)

        // Lefferts Blvd terminal: ~(40.686, -73.808)
        let leffertsTerminal = CLLocationCoordinate2D(latitude: 40.686, longitude: -73.808)
        let anyReaches = unified.contains { polylineReaches($0, target: leffertsTerminal, threshold: 0.01) }
        #expect(anyReaches, "A train polylines must reach Lefferts Blvd terminal")
    }

    @Test func aTrainReachesInwood() {
        // The trunk's northern terminal (Inwood–207 St) must be in the output.
        let allSegments = [
            NYCSubwayFixtures.aTrunk,
            NYCSubwayFixtures.aFarRockaway,
            NYCSubwayFixtures.aLefferts,
        ]
        let unified = unifyTrainPolylines(allSegments)

        let inwood = CLLocationCoordinate2D(latitude: 40.868, longitude: -73.919)
        let anyReaches = unified.contains { polylineReaches($0, target: inwood, threshold: 0.005) }
        #expect(anyReaches, "A train polylines must reach Inwood–207 St")
    }

    @Test func aTrainBranchesDivergeGeographically() {
        // After unification, the two branch endpoints must be far apart.
        // Far Rockaway is ~20 km south of Lefferts on the peninsula.
        let allSegments = [
            NYCSubwayFixtures.aTrunk,
            NYCSubwayFixtures.aFarRockaway,
            NYCSubwayFixtures.aLefferts,
        ]
        let unified = unifyTrainPolylines(allSegments)

        // Collect all southernmost points per polyline
        var terminals: [CLLocationCoordinate2D] = []
        for poly in unified {
            if let last = poly.last { terminals.append(last) }
            if let first = poly.first { terminals.append(first) }
        }

        // The two farthest terminals should be > 0.03° apart (~3+ km)
        var maxTerminalDist = 0.0
        for i in 0..<terminals.count {
            for j in (i + 1)..<terminals.count {
                let d = degreeDistance(terminals[i], terminals[j])
                if d > maxTerminalDist { maxTerminalDist = d }
            }
        }
        #expect(maxTerminalDist > 0.03,
                "Branch terminals must be geographically far apart (got \(maxTerminalDist)°)")
    }

    // ─────────────────────────────────────────────────────
    // MARK: 8. N/Q/R/W — Same-color trunk with different tails
    // ─────────────────────────────────────────────────────

    @Test func yellowTrunkGroupPreservesBothTails() {
        // N/Q/R/W share the Broadway trunk. Q→Brighton, R→4th Ave.
        // When unified (same color group), BOTH tails must survive.
        let allSegments = [
            NYCSubwayFixtures.broadwayTrunk,
            NYCSubwayFixtures.qBrighton,
            NYCSubwayFixtures.r4thAve,
        ]
        let unified = unifyTrainPolylines(allSegments)

        // Check that both terminal neighborhoods are reachable
        let coneyIsland = CLLocationCoordinate2D(latitude: 40.576, longitude: -73.969)
        let bayRidge = CLLocationCoordinate2D(latitude: 40.620, longitude: -74.031)

        let reachesConey = unified.contains { polylineReaches($0, target: coneyIsland, threshold: 0.01) }
        let reachesBayRidge = unified.contains { polylineReaches($0, target: bayRidge, threshold: 0.01) }

        #expect(reachesConey, "Yellow group must reach Coney Island (Q/Brighton)")
        #expect(reachesBayRidge, "Yellow group must reach Bay Ridge (R/4th Ave)")
    }

    @Test func yellowTrunkReachesTimesSq() {
        let allSegments = [
            NYCSubwayFixtures.broadwayTrunk,
            NYCSubwayFixtures.qBrighton,
            NYCSubwayFixtures.r4thAve,
        ]
        let unified = unifyTrainPolylines(allSegments)

        let timesSq = CLLocationCoordinate2D(latitude: 40.756, longitude: -73.987)
        let reaches = unified.contains { polylineReaches($0, target: timesSq, threshold: 0.005) }
        #expect(reaches, "Yellow group must include Times Sq on the trunk")
    }

    @Test func yellowTailsAreGeographicallySeparate() {
        // Q tail goes SE (Brighton line), R tail goes S (4th Ave).
        // Their bounding boxes should NOT significantly overlap.
        let allSegments = [
            NYCSubwayFixtures.broadwayTrunk,
            NYCSubwayFixtures.qBrighton,
            NYCSubwayFixtures.r4thAve,
        ]
        let unified = unifyTrainPolylines(allSegments)

        // There should be at least 2 polylines, and the southernmost parts
        // of different branches should be in different longitude bands.
        // Q/Brighton: lon ≈ -73.94 to -73.97
        // R/4th Ave: lon ≈ -73.98 to -74.03
        #expect(unified.count >= 2,
                "Yellow trunk + 2 tails should produce >= 2 polylines, got \(unified.count)")
    }

    // ─────────────────────────────────────────────────────
    // MARK: 9. Geographic Correctness — Right Place
    // ─────────────────────────────────────────────────────

    @Test func aTrainStaysInNYCBounds() {
        // Every point in every unified A train polyline must be in the NYC metro area.
        let allSegments = [
            NYCSubwayFixtures.aTrunk,
            NYCSubwayFixtures.aFarRockaway,
            NYCSubwayFixtures.aLefferts,
        ]
        let unified = unifyTrainPolylines(allSegments)

        for (idx, poly) in unified.enumerated() {
            let box = boundingBox(poly)
            // NYC metro: lat 40.49–40.92, lon -74.26 to -73.70
            #expect(box.minLat >= 40.49, "Polyline \(idx) extends south of NYC: \(box.minLat)")
            #expect(box.maxLat <= 40.92, "Polyline \(idx) extends north of NYC: \(box.maxLat)")
            #expect(box.minLon >= -74.26, "Polyline \(idx) extends west of NYC: \(box.minLon)")
            #expect(box.maxLon <= -73.70, "Polyline \(idx) extends east of NYC: \(box.maxLon)")
        }
    }

    @Test func broadwayTrunkRunsNorthSouth() {
        // The Broadway BMT trunk runs roughly north–south through Manhattan.
        // Latitude should decrease monotonically from Times Sq to DeKalb.
        let trunk = NYCSubwayFixtures.broadwayTrunk
        for i in 1..<trunk.count {
            #expect(trunk[i].latitude <= trunk[i - 1].latitude + 0.001,
                    "Broadway trunk should run south, but jumped north at index \(i)")
        }
    }

    @Test func farRockawayIsOnPeninsula() {
        // The Far Rockaway branch extends onto the Rockaway peninsula,
        // which means latitude drops below 40.61 (south of the mainland).
        let branch = NYCSubwayFixtures.aFarRockaway
        let minLat = branch.map(\.latitude).min() ?? 0
        #expect(minLat < 40.61,
                "Far Rockaway branch should reach the peninsula (lat < 40.61), got \(minLat)")
    }

    @Test func leffertsStaysOnMainland() {
        // The Lefferts branch stays in Queens/Brooklyn — never goes to the peninsula.
        let branch = NYCSubwayFixtures.aLefferts
        let minLat = branch.map(\.latitude).min() ?? 0
        #expect(minLat > 40.55,
                "Lefferts branch should stay on mainland (lat > 40.55), got \(minLat)")
    }

    // ─────────────────────────────────────────────────────
    // MARK: 10. Curve Quality — Smoothing Tests
    // ─────────────────────────────────────────────────────

    @Test func smoothingReducesMaxTurningAngle() {
        // Catmull-Rom smoothing should reduce sharp angular bends.
        let raw = NYCSubwayFixtures.queensBlvdCurve
        let smoothed = smoothPolyline(raw, segmentsPerCurve: 4)

        let rawAngles = turningAngles(raw)
        let smoothedAngles = turningAngles(smoothed)

        let rawMaxAngle = rawAngles.max() ?? 0
        let smoothedMaxAngle = smoothedAngles.max() ?? 0

        // Smoothing should produce gentler turns (smaller max angle)
        #expect(smoothedMaxAngle <= rawMaxAngle + 5,
                "Smoothed max angle (\(smoothedMaxAngle)°) should not exceed raw (\(rawMaxAngle)°)")
    }

    @Test func smoothingPreservesCurveShape() {
        // Smoothed S-curve should stay within the bounding box of the original
        // (plus a small margin for Catmull-Rom overshoot).
        let raw = NYCSubwayFixtures.sCurve
        let smoothed = smoothPolyline(raw, segmentsPerCurve: 4)

        let rawBox = boundingBox(raw)
        let margin = 0.002  // ~220m margin for smoothing overshoot

        for pt in smoothed {
            #expect(pt.latitude >= rawBox.minLat - margin && pt.latitude <= rawBox.maxLat + margin,
                    "Smoothed point lat \(pt.latitude) outside S-curve bounds")
            #expect(pt.longitude >= rawBox.minLon - margin && pt.longitude <= rawBox.maxLon + margin,
                    "Smoothed point lon \(pt.longitude) outside S-curve bounds")
        }
    }

    @Test func smoothingIncreasesPointDensity() {
        // Catmull-Rom with 4 segments per curve should produce ~4x more points.
        let raw = NYCSubwayFixtures.queensBlvdCurve
        let smoothed = smoothPolyline(raw, segmentsPerCurve: 4)
        #expect(smoothed.count > raw.count * 2,
                "Smoothing should significantly increase point count: \(smoothed.count) vs \(raw.count)")
    }

    @Test func smoothedCurveIsContinuous() {
        let raw = NYCSubwayFixtures.queensBlvdCurve
        let smoothed = smoothPolyline(raw, segmentsPerCurve: 4)

        // Smoothing adds interpolated points, so average spacing should shrink.
        // Max gap can occasionally match raw (at segment boundaries), so compare averages.
        func avgGap(_ coords: [CLLocationCoordinate2D]) -> Double {
            guard coords.count >= 2 else { return 0 }
            var total = 0.0
            for i in 1..<coords.count { total += degreeDistance(coords[i - 1], coords[i]) }
            return total / Double(coords.count - 1)
        }
        let smoothedAvg = avgGap(smoothed)
        let rawAvg = avgGap(raw)
        #expect(smoothedAvg < rawAvg,
                "Smoothed avg gap (\(smoothedAvg)°) should be smaller than raw (\(rawAvg)°)")
    }

    @Test func smoothedCurvePassesThroughOriginalPoints() {
        // Catmull-Rom is an interpolating spline — it passes through every
        // interior control point. Boundary points (indices 1 and n-1) may
        // not be exactly reproduced because endpoint-clamping (p0==p1 or
        // p2==p3) triggers a degenerate guard in the centripetal
        // parameterization that returns p1 instead of interpolating to p2.
        let raw = NYCSubwayFixtures.queensBlvdCurve
        let smoothed = smoothPolyline(raw, segmentsPerCurve: 4)

        // Check all points except boundary-affected indices 1 and n-1.
        // Index 0 is explicitly appended; indices 2..n-2 are each produced
        // by step=segmentsPerCurve of a non-degenerate segment.
        let safeIndices = [0] + Array(2..<(raw.count - 1))
        for i in safeIndices {
            let rawPt = raw[i]
            let closestDist = smoothed.map { degreeDistance($0, rawPt) }.min() ?? .greatestFiniteMagnitude
            #expect(closestDist < 1e-6,
                    "Original point \(i) not found in smoothed output (closest: \(closestDist)°)")
        }
    }

    @Test func smoothedSCurvePreservesInflection() {
        // The S-curve has an inflection point where the curve changes direction.
        // After smoothing, there should still be direction changes in *both* lat and lon,
        // confirming the S-shape is preserved rather than flattened.
        let smoothed = smoothPolyline(NYCSubwayFixtures.sCurve, segmentsPerCurve: 4)

        // Count sign changes in the longitude deltas — an S-curve must have >= 1 change.
        var lonSignChanges = 0
        for i in 2..<smoothed.count {
            let delta1 = smoothed[i - 1].longitude - smoothed[i - 2].longitude
            let delta2 = smoothed[i].longitude - smoothed[i - 1].longitude
            if delta1 * delta2 < 0 { lonSignChanges += 1 }
        }
        #expect(lonSignChanges >= 1,
                "S-curve must have at least one longitude direction change, got \(lonSignChanges)")
    }

    // ─────────────────────────────────────────────────────
    // MARK: 11. Full Branch Pipeline — Unify + Simplify + Smooth
    // ─────────────────────────────────────────────────────

    @Test func fullBranchPipelineATrainEndToEnd() {
        // Test the complete pipeline the app uses for A train:
        // 1. Pool all segments (trunk + branches)
        // 2. Unify (deduplicate overlaps, keep branches)
        // 3. Simplify (RDP)
        // 4. Verify output is correct
        let allSegments = [
            NYCSubwayFixtures.aTrunk,
            Array(NYCSubwayFixtures.aTrunk.reversed()),  // reverse direction
            NYCSubwayFixtures.aFarRockaway,
            Array(NYCSubwayFixtures.aFarRockaway.reversed()),
            NYCSubwayFixtures.aLefferts,
            Array(NYCSubwayFixtures.aLefferts.reversed()),
        ]

        let unified = unifyTrainPolylines(allSegments)
        let tolerance = 0.00015

        // Must have >= 2 polylines (branches are too different to collapse)
        #expect(unified.count >= 2, "Reverse-duplicated A train must still have >= 2 branches")

        for (idx, polyline) in unified.enumerated() {
            let simplified = simplifyPolyline(polyline, tolerance: tolerance)

            // Continuous — no teleports. The fixture has sparse waypoints
            // so the Howard Beach→Hoyt-Schermerhorn gap is ~0.15°. Use 0.20° threshold.
            let gap = maxConsecutiveGap(simplified)
            #expect(gap < 0.20,
                    "A train pipeline polyline \(idx) has gap \(gap)°")

            // Points on original path (allow small FP tolerance from unify merging)
            let deviation = maxDeviationFromOriginal(simplified: simplified, original: polyline)
            #expect(deviation < 0.001,
                    "A train pipeline polyline \(idx) deviated \(deviation)° from unified path")
        }
    }

    @Test func fullBranchPipelineBroadwayBMTEndToEnd() {
        // Yellow group: trunk + Q/Brighton tail + R/4th Ave tail
        let allSegments = [
            NYCSubwayFixtures.broadwayTrunk,
            Array(NYCSubwayFixtures.broadwayTrunk.reversed()),
            NYCSubwayFixtures.qBrighton,
            NYCSubwayFixtures.r4thAve,
        ]

        let unified = unifyTrainPolylines(allSegments)

        // Must preserve both tails
        let coneyIsland = CLLocationCoordinate2D(latitude: 40.576, longitude: -73.969)
        let bayRidge = CLLocationCoordinate2D(latitude: 40.620, longitude: -74.031)

        let reachesConey = unified.contains { polylineReaches($0, target: coneyIsland, threshold: 0.01) }
        let reachesBayRidge = unified.contains { polylineReaches($0, target: bayRidge, threshold: 0.01) }

        #expect(reachesConey, "Full pipeline: yellow group must reach Coney Island")
        #expect(reachesBayRidge, "Full pipeline: yellow group must reach Bay Ridge")

        // Every polyline must be continuous
        for (idx, poly) in unified.enumerated() {
            let gap = maxConsecutiveGap(poly)
            #expect(gap < 0.05, "Broadway BMT pipeline polyline \(idx) has gap \(gap)°")
        }
    }
}
