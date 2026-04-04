//
//  VehicleInterpolationTests.swift
//  TrackTests
//
//  Comprehensive tests for all recent fixes:
//  1. VehicleInterpolator — interpolateBetweenStops, snap, span guard
//  2. Blend convergence — marker reaches target within bounded ticks
//  3. TravelTime dynamic calculation (vs old hardcoded 3.0)
//  4. NearbyTransitResponse.id stability
//  5. liveArrivals filtering
//  6. Multiple simultaneous buses and trains
//  7. Edge cases and performance
//

import CoreLocation
import Testing

@testable import Track

// MARK: - NYC Polyline Fixtures

/// Real-world-style polylines for testing.
private enum NYCFixtures {
    /// A ~2 km polyline along 7th Avenue in Manhattan (northbound),
    /// crossing about 20 blocks.  10 waypoints.
    static let seventhAvenue: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7440, longitude: -73.9920),  // 0: ~23rd St
        CLLocationCoordinate2D(latitude: 40.7460, longitude: -73.9918),  // 1
        CLLocationCoordinate2D(latitude: 40.7480, longitude: -73.9916),  // 2
        CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9914),  // 3: ~34th St
        CLLocationCoordinate2D(latitude: 40.7525, longitude: -73.9912),  // 4
        CLLocationCoordinate2D(latitude: 40.7550, longitude: -73.9910),  // 5: ~42nd St
        CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9908),  // 6
        CLLocationCoordinate2D(latitude: 40.7610, longitude: -73.9907),  // 7: ~50th St
        CLLocationCoordinate2D(latitude: 40.7640, longitude: -73.9906),  // 8
        CLLocationCoordinate2D(latitude: 40.7670, longitude: -73.9905),  // 9: ~57th St
    ]

    /// A shorter ~500m bus route segment with a curve (L-shape).
    static let busRoute: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.6900, longitude: -73.9850),  // start
        CLLocationCoordinate2D(latitude: 40.6910, longitude: -73.9850),  // north
        CLLocationCoordinate2D(latitude: 40.6920, longitude: -73.9850),  // north
        CLLocationCoordinate2D(latitude: 40.6920, longitude: -73.9840),  // turn east
        CLLocationCoordinate2D(latitude: 40.6920, longitude: -73.9830),  // east
        CLLocationCoordinate2D(latitude: 40.6920, longitude: -73.9820),  // end
    ]

    /// Express route that spans ~70% of the polyline (e.g. A express skipping
    /// local stops).  The old span > 0.5 guard would reject this.
    static let expressPolyline: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7100, longitude: -74.0000),  // 0: Canal St
        CLLocationCoordinate2D(latitude: 40.7200, longitude: -73.9990),  // 1: Spring St
        CLLocationCoordinate2D(latitude: 40.7300, longitude: -73.9980),  // 2: 14th St
        CLLocationCoordinate2D(latitude: 40.7400, longitude: -73.9970),  // 3: 23rd St
        CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9960),  // 4: 34th St
        CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9950),  // 5: 42nd St
        CLLocationCoordinate2D(latitude: 40.7700, longitude: -73.9940),  // 6: 50th St
        CLLocationCoordinate2D(latitude: 40.7800, longitude: -73.9930),  // 7: 59th St
        CLLocationCoordinate2D(latitude: 40.7900, longitude: -73.9920),  // 8: 72nd St
        CLLocationCoordinate2D(latitude: 40.8000, longitude: -73.9910),  // 9: 86th St
    ]

    /// Stop coords ON the express polyline for testing.
    /// Canal St (index 0) and 72nd St (index 8) → span ~0.89 of polyline.
    static let expressFrom = CLLocationCoordinate2D(latitude: 40.7100, longitude: -74.0000)
    static let expressTo   = CLLocationCoordinate2D(latitude: 40.7900, longitude: -73.9920)

    /// Two adjacent stops for local subway testing.
    static let stop23rd = CLLocationCoordinate2D(latitude: 40.7440, longitude: -73.9920)
    static let stop34th = CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9914)
    static let stop42nd = CLLocationCoordinate2D(latitude: 40.7550, longitude: -73.9910)
    static let stop50th = CLLocationCoordinate2D(latitude: 40.7610, longitude: -73.9907)
    static let stop57th = CLLocationCoordinate2D(latitude: 40.7670, longitude: -73.9905)
}

// ==========================================================================
// MARK: - 1. VehicleInterpolator Core Tests
// ==========================================================================

@Suite("VehicleInterpolator Core")
struct VehicleInterpolatorCoreTests {

    // MARK: snap()

    @Test func snapToPolylineFindsNearestPoint() {
        let polyline = NYCFixtures.seventhAvenue
        // Point slightly east of the polyline midpoint
        let offRoute = CLLocationCoordinate2D(latitude: 40.7550, longitude: -73.9900)
        let result = VehicleInterpolator.snap(coordinate: offRoute, to: polyline)

        #expect(result != nil)
        // Should snap to somewhere near waypoint 5 (42nd St area)
        #expect(result!.fractionAlongPolyline > 0.3)
        #expect(result!.fractionAlongPolyline < 0.7)
        // Distance from polyline should be small (< 200m for a nearby point)
        #expect(result!.distanceFromPolyline < 200)
    }

    @Test func snapAtStartReturnsFractionZero() {
        let polyline = NYCFixtures.seventhAvenue
        let result = VehicleInterpolator.snap(coordinate: polyline[0], to: polyline)
        #expect(result != nil)
        #expect(result!.fractionAlongPolyline < 0.01)
    }

    @Test func snapAtEndReturnsFractionOne() {
        let polyline = NYCFixtures.seventhAvenue
        let result = VehicleInterpolator.snap(coordinate: polyline.last!, to: polyline)
        #expect(result != nil)
        #expect(result!.fractionAlongPolyline > 0.99)
    }

    @Test func snapReturnsNilForEmptyPolyline() {
        let result = VehicleInterpolator.snap(
            coordinate: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            to: [])
        #expect(result == nil)
    }

    @Test func snapReturnsNilForSinglePoint() {
        let result = VehicleInterpolator.snap(
            coordinate: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            to: [CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)])
        #expect(result == nil)
    }

    @Test func snapAcrossMultiplePolylinesChoosesNearestLine() {
        let nearby = NYCFixtures.busRoute
        let distant = NYCFixtures.seventhAvenue
        let offRoute = CLLocationCoordinate2D(latitude: 40.6921, longitude: -73.9835)

        let result = VehicleInterpolator.snap(
            coordinate: offRoute,
            to: [distant, nearby],
            maxDistance: 120
        )

        #expect(result != nil)
        #expect(result!.distanceFromPolyline < 40)
        #expect(abs(result!.coordinate.latitude - 40.6920) < 0.0002)
    }

    @Test func snapAcrossMultiplePolylinesHonorsDistanceLimit() {
        let result = VehicleInterpolator.snap(
            coordinate: CLLocationCoordinate2D(latitude: 40.8000, longitude: -73.9500),
            to: [NYCFixtures.busRoute],
            maxDistance: 50
        )

        #expect(result == nil)
    }

    // MARK: interpolate(along:fraction:)

    @Test func interpolateAtZeroReturnsStart() {
        let polyline = NYCFixtures.seventhAvenue
        let coord = VehicleInterpolator.interpolate(along: polyline, fraction: 0.0)
        #expect(coord != nil)
        #expect(abs(coord!.latitude - polyline.first!.latitude) < 0.0001)
        #expect(abs(coord!.longitude - polyline.first!.longitude) < 0.0001)
    }

    @Test func interpolateAtOneReturnsEnd() {
        let polyline = NYCFixtures.seventhAvenue
        let coord = VehicleInterpolator.interpolate(along: polyline, fraction: 1.0)
        #expect(coord != nil)
        #expect(abs(coord!.latitude - polyline.last!.latitude) < 0.0001)
        #expect(abs(coord!.longitude - polyline.last!.longitude) < 0.0001)
    }

    @Test func interpolateAtHalfIsNearMiddle() {
        let polyline = NYCFixtures.seventhAvenue
        let coord = VehicleInterpolator.interpolate(along: polyline, fraction: 0.5)
        #expect(coord != nil)
        // Middle of 7th Ave polyline should be around 40.755
        #expect(coord!.latitude > 40.750)
        #expect(coord!.latitude < 40.760)
    }

    @Test func interpolateClampsBelowZero() {
        let polyline = NYCFixtures.seventhAvenue
        let coord = VehicleInterpolator.interpolate(along: polyline, fraction: -0.5)
        #expect(coord != nil)
        #expect(abs(coord!.latitude - polyline.first!.latitude) < 0.0001)
    }

    @Test func interpolateClampsAboveOne() {
        let polyline = NYCFixtures.seventhAvenue
        let coord = VehicleInterpolator.interpolate(along: polyline, fraction: 1.5)
        #expect(coord != nil)
        #expect(abs(coord!.latitude - polyline.last!.latitude) < 0.0001)
    }

    // MARK: polylineLength()

    @Test func polylineLengthIsPositiveAndReasonable() {
        let length = VehicleInterpolator.polylineLength(NYCFixtures.seventhAvenue)
        // ~2.5 km along 7th Avenue
        #expect(length > 1500)
        #expect(length < 4000)
    }

    @Test func polylineLengthEmptyIsZero() {
        #expect(VehicleInterpolator.polylineLength([]) == 0)
    }

    @Test func polylineLengthSinglePointIsZero() {
        #expect(VehicleInterpolator.polylineLength([
            CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)
        ]) == 0)
    }

    // MARK: interpolateBetweenStops basic

    @Test func interpolateBetweenStopsAtZeroIsFromStop() {
        let result = VehicleInterpolator.interpolateBetweenStops(
            from: NYCFixtures.stop23rd,
            to: NYCFixtures.stop34th,
            progress: 0.0,
            along: NYCFixtures.seventhAvenue)
        // Should be at or very near 23rd St
        let dist = CLLocation(
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude
        ).distance(from: CLLocation(
            latitude: NYCFixtures.stop23rd.latitude,
            longitude: NYCFixtures.stop23rd.longitude
        ))
        #expect(dist < 50, "At progress=0 should be within 50m of fromStop, got \(dist)m")
    }

    @Test func interpolateBetweenStopsAtOneIsToStop() {
        let result = VehicleInterpolator.interpolateBetweenStops(
            from: NYCFixtures.stop23rd,
            to: NYCFixtures.stop34th,
            progress: 1.0,
            along: NYCFixtures.seventhAvenue)
        let dist = CLLocation(
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude
        ).distance(from: CLLocation(
            latitude: NYCFixtures.stop34th.latitude,
            longitude: NYCFixtures.stop34th.longitude
        ))
        #expect(dist < 50, "At progress=1 should be within 50m of toStop, got \(dist)m")
    }

    @Test func interpolateBetweenStopsMovesMonotonically() {
        // Along the polyline, latitude increases going north on 7th Ave.
        // Positions at 0.0, 0.25, 0.5, 0.75, 1.0 should increase in latitude.
        var prevLat = -Double.infinity
        for p in stride(from: 0.0, through: 1.0, by: 0.25) {
            let result = VehicleInterpolator.interpolateBetweenStops(
                from: NYCFixtures.stop23rd,
                to: NYCFixtures.stop50th,
                progress: p,
                along: NYCFixtures.seventhAvenue)
            #expect(result.coordinate.latitude >= prevLat,
                    "At progress=\(p) lat=\(result.coordinate.latitude) should be >= prevLat=\(prevLat)")
            prevLat = result.coordinate.latitude
        }
    }

    @Test func interpolateBetweenStopsReturnsBearingInRange() {
        let result = VehicleInterpolator.interpolateBetweenStops(
            from: NYCFixtures.stop23rd,
            to: NYCFixtures.stop34th,
            progress: 0.5,
            along: NYCFixtures.seventhAvenue)
        #expect(result.bearing >= 0)
        #expect(result.bearing < 360)
    }
}

// ==========================================================================
// MARK: - 2. Span Guard Tests (Fix #3)
// ==========================================================================

@Suite("Span Guard — Express Routes")
struct SpanGuardTests {

    @Test func expressRouteSpan70PercentFollowsPolyline() {
        // Express from Canal St (frac ~0) to 72nd St (frac ~0.89).
        // Old code (span > 0.5) would fall back to straight-line.
        // New code (span > 0.95) should follow polyline.
        let result = VehicleInterpolator.interpolateBetweenStops(
            from: NYCFixtures.expressFrom,
            to: NYCFixtures.expressTo,
            progress: 0.5,
            along: NYCFixtures.expressPolyline)

        // Midpoint should be near the middle of the polyline (~40.745),
        // not half-way on the straight line from Canal to 72nd.
        // The straight-line midpoint would be ~(40.71+40.79)/2 = 40.75
        // Both are similar for a roughly straight avenue, but the polyline
        // version should be ON the polyline.
        let snapResult = VehicleInterpolator.snap(
            coordinate: result.coordinate, to: NYCFixtures.expressPolyline)
        #expect(snapResult != nil)
        // The interpolated point should be very close to the polyline (< 10m)
        #expect(snapResult!.distanceFromPolyline < 10,
                "Express route midpoint should be on-polyline, got \(snapResult!.distanceFromPolyline)m off")
    }

    @Test func expressRouteSpan90PercentStillFollowsPolyline() {
        // Span of ~90% — just under the new 0.95 threshold
        let from = NYCFixtures.expressPolyline[0]
        let to = NYCFixtures.expressPolyline[8]  // index 8 of 10 → ~89%
        let result = VehicleInterpolator.interpolateBetweenStops(
            from: from, to: to, progress: 0.5,
            along: NYCFixtures.expressPolyline)

        let snap = VehicleInterpolator.snap(
            coordinate: result.coordinate, to: NYCFixtures.expressPolyline)
        #expect(snap != nil)
        #expect(snap!.distanceFromPolyline < 10)
    }

    @Test func invertedFractionsFallBackToStraightLine() {
        // From a point near the end of the polyline TO a point near the start
        // → inverted fractions (end < start) → span < 0 → straight-line fallback
        let from = NYCFixtures.expressPolyline.last!
        let to = NYCFixtures.expressPolyline.first!
        let result = VehicleInterpolator.interpolateBetweenStops(
            from: from, to: to, progress: 0.5,
            along: NYCFixtures.expressPolyline)

        // Should be straight-line midpoint
        let expectedLat = (from.latitude + to.latitude) / 2
        let expectedLon = (from.longitude + to.longitude) / 2
        #expect(abs(result.coordinate.latitude - expectedLat) < 0.0001)
        #expect(abs(result.coordinate.longitude - expectedLon) < 0.0001)
    }

    @Test func normalLocalStopSpanWorks() {
        // Adjacent stops — small span ~0.08 — well within any threshold
        let result = VehicleInterpolator.interpolateBetweenStops(
            from: NYCFixtures.stop34th,
            to: NYCFixtures.stop42nd,
            progress: 0.5,
            along: NYCFixtures.seventhAvenue)
        // Should be between the two stops
        #expect(result.coordinate.latitude > NYCFixtures.stop34th.latitude)
        #expect(result.coordinate.latitude < NYCFixtures.stop42nd.latitude)
    }

    @Test func emptyPolylineFallsBackGracefully() {
        let result = VehicleInterpolator.interpolateBetweenStops(
            from: NYCFixtures.stop23rd,
            to: NYCFixtures.stop34th,
            progress: 0.5,
            along: [])
        // Should be straight-line midpoint
        let expectedLat = (NYCFixtures.stop23rd.latitude + NYCFixtures.stop34th.latitude) / 2
        #expect(abs(result.coordinate.latitude - expectedLat) < 0.0001)
    }
}

// ==========================================================================
// MARK: - 3. Blend Convergence Tests (Fix #2)
// ==========================================================================

@Suite("Blend Convergence")
struct BlendConvergenceTests {

    /// Simulates the blend loop from updateTrainPositions.
    /// Returns the position after `ticks` iterations of blending.
    private func simulateBlend(
        from start: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D,
        ticks: Int
    ) -> CLLocationCoordinate2D {
        var current = start
        for _ in 0..<ticks {
            let distance = CLLocation(latitude: current.latitude, longitude: current.longitude)
                .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
            let blendFactor = distance > 200 ? 0.7 : 0.55
            let newLat = current.latitude + (target.latitude - current.latitude) * blendFactor
            let newLon = current.longitude + (target.longitude - current.longitude) * blendFactor
            current = CLLocationCoordinate2D(latitude: newLat, longitude: newLon)
        }
        return current
    }

    @Test func blendConvergesWithin3TicksForSmallDistance() {
        // ~200m offset — typical inter-tick movement
        let start = CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9920)
        let target = CLLocationCoordinate2D(latitude: 40.7518, longitude: -73.9920)

        let after3 = simulateBlend(from: start, to: target, ticks: 3)
        let remainingDist = CLLocation(latitude: after3.latitude, longitude: after3.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))

        // After 3 ticks with blend 0.55, residual = (1-0.55)^3 = 0.091 → ~9% remaining
        // For 200m initial, that's ~18m — well within acceptable range
        #expect(remainingDist < 25,
                "After 3 ticks should be within 25m of target, got \(remainingDist)m")
    }

    @Test func blendConvergesWithin5TicksForLargeDistance() {
        // ~500m offset — happens when the next-stop shifts
        let start = CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9920)
        let target = CLLocationCoordinate2D(latitude: 40.7545, longitude: -73.9920)

        let after5 = simulateBlend(from: start, to: target, ticks: 5)
        let remainingDist = CLLocation(latitude: after5.latitude, longitude: after5.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))

        // With the distance-adaptive blend (0.7 when >200m), convergence is fast
        #expect(remainingDist < 15,
                "After 5 ticks should be within 15m, got \(remainingDist)m")
    }

    @Test func blendReaches90PercentIn3Ticks() {
        let start = CLLocationCoordinate2D(latitude: 40.7400, longitude: -73.9920)
        let target = CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9920)
        let initialDist = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))

        let after3 = simulateBlend(from: start, to: target, ticks: 3)
        let remainingDist = CLLocation(latitude: after3.latitude, longitude: after3.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))

        let covered = initialDist - remainingDist
        let coverageRatio = covered / initialDist
        #expect(coverageRatio > 0.90,
                "Should cover >90% in 3 ticks, coverage=\(coverageRatio * 100)%")
    }

    @Test func oldBlendFactorWouldNotConverge() {
        // Prove the OLD 0.35 factor fails to converge adequately
        let start = CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9920)
        let target = CLLocationCoordinate2D(latitude: 40.7518, longitude: -73.9920)

        // Old blend: fixed 0.35
        var current = start
        for _ in 0..<3 {
            let newLat = current.latitude + (target.latitude - current.latitude) * 0.35
            let newLon = current.longitude + (target.longitude - current.longitude) * 0.35
            current = CLLocationCoordinate2D(latitude: newLat, longitude: newLon)
        }
        let oldRemaining = CLLocation(latitude: current.latitude, longitude: current.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))

        // New blend
        let newResult = simulateBlend(from: start, to: target, ticks: 3)
        let newRemaining = CLLocation(latitude: newResult.latitude, longitude: newResult.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))

        #expect(newRemaining < oldRemaining,
                "New blend (\(newRemaining)m) should converge faster than old (\(oldRemaining)m)")
        // Old: (1-0.35)^3 = 0.274 → 27% remaining (~55m for 200m)
        // New: (1-0.55)^3 = 0.091 → 9% remaining (~18m for 200m)
    }

    @Test func blendDoesNotOvershoot() {
        let start = CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9920)
        let target = CLLocationCoordinate2D(latitude: 40.7510, longitude: -73.9920)

        for ticks in 1...10 {
            let pos = simulateBlend(from: start, to: target, ticks: ticks)
            // Latitude should never exceed the target (going north)
            #expect(pos.latitude <= target.latitude + 0.00001,
                    "Blend should never overshoot at tick \(ticks)")
            #expect(pos.latitude >= start.latitude,
                    "Blend should never go backwards at tick \(ticks)")
        }
    }

    @Test func blendHandlesIdenticalPositions() {
        let same = CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9920)
        let result = simulateBlend(from: same, to: same, ticks: 5)
        #expect(abs(result.latitude - same.latitude) < 0.00001)
        #expect(abs(result.longitude - same.longitude) < 0.00001)
    }

    @Test func distanceAdaptiveBlendKicksInForLargeJump() {
        // When distance > 200m, blend factor should be 0.7 (faster catch-up)
        let start = CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9920)
        let farTarget = CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9920)  // ~1.1 km

        let after1 = simulateBlend(from: start, to: farTarget, ticks: 1)
        let initialDist = CLLocation(
            latitude: start.latitude,
            longitude: start.longitude
        ).distance(from: CLLocation(
            latitude: farTarget.latitude,
            longitude: farTarget.longitude
        ))
        let after1Dist = CLLocation(
            latitude: after1.latitude,
            longitude: after1.longitude
        ).distance(from: CLLocation(
            latitude: farTarget.latitude,
            longitude: farTarget.longitude
        ))

        // With 0.7 blend on first tick, should cover 70%
        let firstTickCoverage = (initialDist - after1Dist) / initialDist
        #expect(firstTickCoverage > 0.65 && firstTickCoverage < 0.75,
                "First tick coverage should be ~70%, got \(firstTickCoverage * 100)%")
    }
}

// ==========================================================================
// MARK: - 4. Dynamic TravelTime Tests (Fix #1)
// ==========================================================================

@Suite("Dynamic TravelTime Calculation")
struct DynamicTravelTimeTests {

    /// Simulates the travelTime calculation from updateTrainPositions.
    private func computeTravelTime(
        prevStopLat: Double, prevStopLon: Double,
        nextStopLat: Double, nextStopLon: Double,
        scheduleGapMinutes: Double? = nil
    ) -> Double {
        // Mirror the logic in updateTrainPositions
        if let gap = scheduleGapMinutes, gap > 0.5, gap < 20 {
            return gap
        }
        let dist = CLLocation(latitude: prevStopLat, longitude: prevStopLon)
            .distance(from: CLLocation(latitude: nextStopLat, longitude: nextStopLon))
        let speedMpm: Double = dist > 2000 ? 750 : 500
        return max(1.0, dist / speedMpm)
    }

    @Test func adjacentLocalStopsGiveReasonableTravelTime() {
        // 23rd St to 34th St on 7th Ave — about 680m
        let tt = computeTravelTime(
            prevStopLat: 40.7440, prevStopLon: -73.9920,
            nextStopLat: 40.7500, nextStopLon: -73.9914)
        // 680m / 500 m/min ≈ 1.36 min
        #expect(tt > 1.0)
        #expect(tt < 3.0)
    }

    @Test func expressStopsGiveLongerTravelTime() {
        // Canal St to 34th St — about 4.5 km
        let tt = computeTravelTime(
            prevStopLat: 40.7100, prevStopLon: -74.0000,
            nextStopLat: 40.7500, nextStopLon: -73.9960)
        // 4500m / 750 m/min ≈ 6 min (uses express speed since > 2km)
        #expect(tt > 4.0)
        #expect(tt < 10.0)
    }

    @Test func scheduleGapOverridesDistanceEstimate() {
        let tt = computeTravelTime(
            prevStopLat: 40.7100, prevStopLon: -74.0000,
            nextStopLat: 40.7500, nextStopLon: -73.9960,
            scheduleGapMinutes: 5.0)
        #expect(tt == 5.0)
    }

    @Test func tooSmallScheduleGapIgnored() {
        // Gap of 0.3 min → invalid, should fall back to distance
        let tt = computeTravelTime(
            prevStopLat: 40.7440, prevStopLon: -73.9920,
            nextStopLat: 40.7500, nextStopLon: -73.9914,
            scheduleGapMinutes: 0.3)
        #expect(tt != 0.3, "Gap < 0.5 should be ignored")
        #expect(tt > 1.0)
    }

    @Test func tooLargeScheduleGapIgnored() {
        // Gap of 25 min → invalid, should fall back to distance
        let tt = computeTravelTime(
            prevStopLat: 40.7440, prevStopLon: -73.9920,
            nextStopLat: 40.7500, nextStopLon: -73.9914,
            scheduleGapMinutes: 25.0)
        #expect(tt != 25.0, "Gap > 20 should be ignored")
    }

    @Test func minimumTravelTimeIsOneMinute() {
        // Two very close stops — should be clamped to 1.0 min
        let tt = computeTravelTime(
            prevStopLat: 40.7500, prevStopLon: -73.9920,
            nextStopLat: 40.7501, nextStopLon: -73.9920)
        #expect(tt >= 1.0)
    }

    @Test func oldHardcoded3MinWouldBeWrongForExpress() {
        // Express: Canal → 34th. Distance-based should be ~6 min.
        // Hardcoded 3.0 would put progress too far ahead.
        let tt = computeTravelTime(
            prevStopLat: 40.7100, prevStopLon: -74.0000,
            nextStopLat: 40.7500, nextStopLon: -73.9960)
        #expect(tt > 3.0,
                "Express stop travelTime should be > 3 min, got \(tt)")
    }

    @Test func oldHardcoded3MinWouldBeWrongForCloseStops() {
        // Short local hop: 34th → 42nd. Should be ~1.3 min.
        // Hardcoded 3.0 would make progress too slow (marker sits at prev stop).
        let tt = computeTravelTime(
            prevStopLat: 40.7500, prevStopLon: -73.9914,
            nextStopLat: 40.7550, nextStopLon: -73.9910)
        #expect(tt < 3.0,
                "Close stops travelTime should be < 3.0 min, got \(tt)")
    }

    @Test func progressNormalizesCorrectlyWithDynamicTravelTime() {
        // Simulate: 2 minutes until arrival, dynamic travelTime = 4 min
        // progress should be 1.0 - (2.0 / 4.0) = 0.5
        let minutesUntilArrival = 2.0
        let travelTime = computeTravelTime(
            prevStopLat: 40.7100, prevStopLon: -74.0000,
            nextStopLat: 40.7500, nextStopLon: -73.9960)
        let t = min(max(minutesUntilArrival / travelTime, 0.0), 1.0)
        let progress = 1.0 - t
        #expect(progress > 0.0, "Progress should be > 0")
        #expect(progress < 1.0, "Progress should be < 1")

        // With hardcoded 3.0: would be 1.0 - (2.0/3.0) = 0.33
        let oldProgress = 1.0 - min(max(minutesUntilArrival / 3.0, 0.0), 1.0)
        // Dynamic should give different (more accurate) result
        #expect(abs(progress - oldProgress) > 0.05,
                "Dynamic travelTime should produce different progress than hardcoded 3.0")
    }
}

// ==========================================================================
// MARK: - 5. NearbyTransitResponse.id Stability Tests
// ==========================================================================

@Suite("Arrival ID Stability")
struct ArrivalIdStabilityTests {

    private func makeArrival(
        routeId: String = "A",
        stopName: String = "34 St",
        minutesAway: Int = 5,
        tripId: String? = "TRIP-001",
        vehicleId: String? = "VEH-001",
        arrivalTs: Int? = 1709500000
    ) -> NearbyTransitResponse {
        NearbyTransitResponse(
            routeId: routeId,
            stopName: stopName,
            direction: "Northbound",
            destination: "Uptown",
            minutesAway: minutesAway,
            status: "EXPECTED",
            mode: "subway",
            stopLat: 40.75,
            stopLon: -73.99,
            arrivalTs: arrivalTs,
            vehicleId: vehicleId,
            tripId: tripId,
            stopId: "A27"
        )
    }

    @Test func idDoesNotChangeWhenMinutesAwayChanges() {
        let a1 = makeArrival(minutesAway: 5)
        let a2 = makeArrival(minutesAway: 4)
        let a3 = makeArrival(minutesAway: 3)
        #expect(a1.id == a2.id, "ID should be stable across minute changes")
        #expect(a2.id == a3.id)
    }

    @Test func idPrefersTripIdOverVehicleId() {
        let a = makeArrival(tripId: "TRIP-X", vehicleId: "VEH-Y")
        #expect(a.id.contains("TRIP-X"))
        #expect(!a.id.contains("VEH-Y"))
    }

    @Test func idFallsBackToVehicleIdWhenNoTripId() {
        let a = makeArrival(tripId: nil, vehicleId: "VEH-Y")
        #expect(a.id.contains("VEH-Y"))
    }

    @Test func idFallsBackToArrivalTsWhenNoTripOrVehicle() {
        let a = makeArrival(tripId: nil, vehicleId: nil, arrivalTs: 1709500000)
        #expect(a.id.contains("1709500000"))
    }

    @Test func idFallsBackToMinutesAwayAsLastResort() {
        let a = makeArrival(minutesAway: 7, tripId: nil, vehicleId: nil, arrivalTs: nil)
        #expect(a.id.contains("7"))
    }

    @Test func idIncludesRouteAndStop() {
        let a = makeArrival(routeId: "L", stopName: "1 Av")
        #expect(a.id.hasPrefix("L-1 Av"))
    }

    @Test func emptyTripIdFallsToVehicle() {
        let a = makeArrival(tripId: "", vehicleId: "VEH-1")
        #expect(a.id.contains("VEH-1"))
    }

    @Test func emptyVehicleIdFallsToTs() {
        let a = makeArrival(tripId: nil, vehicleId: "", arrivalTs: 999)
        #expect(a.id.contains("999"))
    }

    @Test func duplicateIdsFromDifferentStopsAreDifferent() {
        let a = makeArrival(stopName: "14 St", tripId: "T1")
        let b = makeArrival(stopName: "23 St", tripId: "T1")
        #expect(a.id != b.id)
    }

    @Test func sameStopDifferentTripsAreDifferent() {
        let a = makeArrival(tripId: "T1")
        let b = makeArrival(tripId: "T2")
        #expect(a.id != b.id)
    }
}

// ==========================================================================
// MARK: - 6. liveArrivals Filtering Tests
// ==========================================================================

@Suite("LiveArrivals Filtering")
struct LiveArrivalsFilteringTests {

    private func makeDirection(arrivals: [NearbyTransitResponse]) -> DirectionArrivalsResponse {
        DirectionArrivalsResponse(
            direction: "Northbound",
            directionLabel: "Uptown",
            arrivals: arrivals
        )
    }

    private func arrival(
        minutesAway: Int = 5,
        status: String = "EXPECTED",
        arrivalTs: Int? = nil,
        vehicleId: String? = "V1",
        tripId: String? = "T1"
    ) -> NearbyTransitResponse {
        NearbyTransitResponse(
            routeId: "A",
            stopName: "34 St",
            direction: "Northbound",
            destination: "Uptown",
            minutesAway: minutesAway,
            status: status,
            mode: "subway",
            stopLat: 40.75,
            stopLon: -73.99,
            arrivalTs: arrivalTs,
            vehicleId: vehicleId,
            tripId: tripId,
            stopId: "A27"
        )
    }

    @Test func filtersPlaceholders() {
        // Placeholder: minutesAway >= 99, no arrivalTs, no vehicleId
        let placeholder = arrival(minutesAway: 99, vehicleId: nil, tripId: nil)
        let direction = makeDirection(arrivals: [placeholder])
        #expect(direction.liveArrivals.isEmpty)
    }

    @Test func filtersCancelled() {
        var cancelled = arrival()
        cancelled.isCancelled = true
        let direction = makeDirection(arrivals: [cancelled])
        #expect(direction.liveArrivals.isEmpty)
    }

    @Test func filtersOldArrivalTs() {
        // arrivalTs more than 90s in the past
        let oldTs = Int(Date.now.timeIntervalSince1970) - 120
        let old = arrival(arrivalTs: oldTs)
        let direction = makeDirection(arrivals: [old])
        #expect(direction.liveArrivals.isEmpty)
    }

    @Test func keepsRecentArrivalTs() {
        // arrivalTs 30s in the past — within the 90s grace window
        let recentTs = Int(Date.now.timeIntervalSince1970) - 30
        let recent = arrival(arrivalTs: recentTs)
        let direction = makeDirection(arrivals: [recent])
        #expect(direction.liveArrivals.count == 1)
    }

    @Test func filtersScheduledZeroMinNoTs() {
        let sched = arrival(minutesAway: 0, status: "scheduled", arrivalTs: nil)
        let direction = makeDirection(arrivals: [sched])
        #expect(
            direction.liveArrivals.isEmpty,
            "Scheduled 0-min with no arrivalTs should be filtered"
        )
    }

    @Test func keepsScheduledWithArrivalTs() {
        let futureTs = Int(Date.now.timeIntervalSince1970) + 300
        let sched = arrival(minutesAway: 0, status: "scheduled", arrivalTs: futureTs)
        let direction = makeDirection(arrivals: [sched])
        #expect(direction.liveArrivals.count == 1)
    }

    @Test func keepsNormalLiveArrival() {
        let futureTs = Int(Date.now.timeIntervalSince1970) + 300
        let normal = arrival(minutesAway: 5, arrivalTs: futureTs)
        let direction = makeDirection(arrivals: [normal])
        #expect(direction.liveArrivals.count == 1)
    }

    @Test func mixedArrivalsBatchFiltering() {
        let futureTs = Int(Date.now.timeIntervalSince1970) + 300
        let futureTs2 = futureTs + 180  // distinct ts to avoid dedup
        let oldTs = Int(Date.now.timeIntervalSince1970) - 200

        let arrivals = [
            // keep
            arrival(
                minutesAway: 5, arrivalTs: futureTs,
                vehicleId: "V1", tripId: "T1"
            ),
            // placeholder → drop
            arrival(minutesAway: 99, vehicleId: nil, tripId: nil),
            // old ts → drop
            arrival(
                minutesAway: 3, arrivalTs: oldTs,
                vehicleId: "V2", tripId: "T2"
            ),
            // sched 0 → drop
            arrival(
                minutesAway: 0, status: "scheduled",
                arrivalTs: nil, vehicleId: "V3", tripId: "T3"
            ),
            // keep
            arrival(
                minutesAway: 8, arrivalTs: futureTs2,
                vehicleId: "V4", tripId: "T4"
            ),
        ]
        let direction = makeDirection(arrivals: arrivals)
        #expect(direction.liveArrivals.count == 2)
    }
}

// ==========================================================================
// MARK: - 7. Multiple Simultaneous Vehicles Tests
// ==========================================================================

@Suite("Multiple Vehicles Simulation")
struct MultipleVehiclesTests {

    @Test func fiveBusesInterpolateIndependentlyAlongPolyline() {
        let polyline = NYCFixtures.busRoute
        let totalLength = VehicleInterpolator.polylineLength(polyline)
        #expect(totalLength > 100, "Bus route should have meaningful length")

        // Five buses at different progress points
        let progresses = [0.0, 0.25, 0.5, 0.75, 1.0]
        var positions: [CLLocationCoordinate2D] = []

        for p in progresses {
            let result = VehicleInterpolator.interpolateBetweenStops(
                from: polyline.first!, to: polyline.last!,
                progress: p, along: polyline)
            positions.append(result.coordinate)
        }

        // All positions should be distinct
        for i in 0..<positions.count {
            for j in (i + 1)..<positions.count {
                let dist = CLLocation(
                    latitude: positions[i].latitude,
                    longitude: positions[i].longitude
                ).distance(from: CLLocation(
                    latitude: positions[j].latitude,
                    longitude: positions[j].longitude
                ))
                #expect(
                    dist > 1,
                    "Buses at different progress should have different positions (\(i) vs \(j))"
                )
            }
        }

        // Positions should be in order (monotonic along the route)
        // Since the bus route goes north then east, check that later buses
        // are at least not south of earlier ones (approximate)
        for i in 1..<positions.count {
            let snap_prev = VehicleInterpolator.snap(coordinate: positions[i-1], to: polyline)!
            let snap_curr = VehicleInterpolator.snap(coordinate: positions[i], to: polyline)!
            #expect(snap_curr.fractionAlongPolyline >= snap_prev.fractionAlongPolyline - 0.01,
                    "Bus \(i) should be ahead of bus \(i-1) on polyline")
        }
    }

    @Test func threeTrainsBlendIndependently() {
        // Simulate 3 trains, each blending from a different start to different target
        let starts = [
            CLLocationCoordinate2D(latitude: 40.7440, longitude: -73.992),
            CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.991),
            CLLocationCoordinate2D(latitude: 40.7560, longitude: -73.991),
        ]
        let targets = [
            CLLocationCoordinate2D(latitude: 40.7480, longitude: -73.992),
            CLLocationCoordinate2D(latitude: 40.7540, longitude: -73.991),
            CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.990),
        ]

        // Simulate 3 ticks of blending for each
        for i in 0..<3 {
            var current = starts[i]
            for _ in 0..<3 {
                let distance = CLLocation(
                    latitude: current.latitude,
                    longitude: current.longitude
                ).distance(from: CLLocation(
                    latitude: targets[i].latitude,
                    longitude: targets[i].longitude
                ))
                let blendFactor = distance > 200 ? 0.7 : 0.55
                let tLat = targets[i].latitude
                let tLon = targets[i].longitude
                current = CLLocationCoordinate2D(
                    latitude: current.latitude
                        + (tLat - current.latitude) * blendFactor,
                    longitude: current.longitude
                        + (tLon - current.longitude) * blendFactor
                )
            }
            let finalDist = CLLocation(
                latitude: current.latitude,
                longitude: current.longitude
            ).distance(from: CLLocation(
                latitude: targets[i].latitude,
                longitude: targets[i].longitude
            ))
            #expect(
                finalDist < 50,
                "Train \(i) should converge within 50m after 3 ticks, got \(finalDist)m"
            )
        }
    }

    @Test func multipleArrivalIdsRemainStableAcrossPolls() {
        // Simulate 3 poll cycles where minutesAway decreases
        for cycle in [5, 4, 3] {
            var arrivals: [NearbyTransitResponse] = []
            for idx in 0..<8 {
                let routeId: String = idx < 4 ? "B63" : "4"
                let modeStr: String = idx < 4 ? "bus" : "subway"
                let mins: Int = cycle + idx
                let ts: Int = Int(Date.now.timeIntervalSince1970) + mins * 60
                let a = NearbyTransitResponse(
                    routeId: routeId,
                    stopName: "Stop\(idx)",
                    direction: "North",
                    destination: "Terminal",
                    minutesAway: mins,
                    status: "EXPECTED",
                    mode: modeStr,
                    stopLat: 40.7 + Double(idx) * 0.001,
                    stopLon: -73.99,
                    arrivalTs: ts,
                    vehicleId: "V\(idx)",
                    tripId: "T\(idx)",
                    stopId: "S\(idx)"
                )
                arrivals.append(a)
            }

            // All IDs should be based on tripId, not minutesAway
            for a in arrivals {
                #expect(a.id.contains("T"), "ID should use tripId")
                #expect(!a.id.hasSuffix("-\(a.minutesAway)"),
                        "ID should NOT end with minutesAway")
            }

            // IDs should be unique
            let ids: [String] = arrivals.map { $0.id }
            #expect(Set(ids).count == ids.count, "All IDs should be unique at cycle \(cycle)")
        }
    }
}

// ==========================================================================
// MARK: - 8. SmoothBusPosition Tests
// ==========================================================================

@Suite("Smooth Bus Position")
struct SmoothBusPositionTests {

    @Test func smoothBusAtElapsedZeroIsAtPrevious() {
        let prev = CLLocationCoordinate2D(latitude: 40.6900, longitude: -73.9850)
        let current = CLLocationCoordinate2D(latitude: 40.6920, longitude: -73.9820)
        let result = VehicleInterpolator.smoothBusPosition(
            previous: prev, current: current,
            elapsed: 0, duration: 10,
            along: NYCFixtures.busRoute)
        let dist = CLLocation(
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude
        ).distance(from: CLLocation(
            latitude: prev.latitude,
            longitude: prev.longitude
        ))
        #expect(dist < 30, "At elapsed=0 should be near previous position")
    }

    @Test func smoothBusAtElapsedEqualDurationIsAtCurrent() {
        let prev = CLLocationCoordinate2D(latitude: 40.6900, longitude: -73.9850)
        let current = CLLocationCoordinate2D(latitude: 40.6920, longitude: -73.9820)
        let result = VehicleInterpolator.smoothBusPosition(
            previous: prev, current: current,
            elapsed: 10, duration: 10,
            along: NYCFixtures.busRoute)
        let dist = CLLocation(
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude
        ).distance(from: CLLocation(
            latitude: current.latitude,
            longitude: current.longitude
        ))
        #expect(dist < 30, "At elapsed=duration should be near current position")
    }

    @Test func smoothBusProgressesMonotonically() {
        let prev = NYCFixtures.busRoute.first!
        let current = NYCFixtures.busRoute.last!

        var prevFrac = -1.0
        for elapsed in stride(from: 0.0, through: 10.0, by: 1.0) {
            let result = VehicleInterpolator.smoothBusPosition(
                previous: prev, current: current,
                elapsed: elapsed, duration: 10,
                along: NYCFixtures.busRoute)
            let snap = VehicleInterpolator.snap(
                coordinate: result.coordinate,
                to: NYCFixtures.busRoute
            )!
            #expect(snap.fractionAlongPolyline >= prevFrac - 0.01,
                    "Should move forward at elapsed=\(elapsed)")
            prevFrac = snap.fractionAlongPolyline
        }
    }
}

// ==========================================================================
// MARK: - 9. Performance Tests
// ==========================================================================

@Suite("Performance")
struct PerformanceTests {

    @Test func snapPerformanceWith100Waypoints() {
        // Build a 100-point polyline
        var polyline: [CLLocationCoordinate2D] = []
        for i in 0..<100 {
            polyline.append(CLLocationCoordinate2D(
                latitude: 40.70 + Double(i) * 0.001,
                longitude: -74.00 + Double(i) * 0.0001
            ))
        }

        let testPoint = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.995)

        // Snap 1000 times — should complete quickly
        let start = Date()
        for _ in 0..<1000 {
            _ = VehicleInterpolator.snap(coordinate: testPoint, to: polyline)
        }
        let elapsed = Date().timeIntervalSince(start)

        // 1000 snaps should take < 1 second even on slow hardware
        #expect(elapsed < 1.0, "1000 snaps took \(elapsed)s — too slow")
    }

    @Test func interpolateBetweenStopsPerformance() {
        let polyline = NYCFixtures.expressPolyline
        let from = polyline.first!
        let to = polyline.last!

        let start = Date()
        for i in 0..<1000 {
            let progress = Double(i) / 1000.0
            _ = VehicleInterpolator.interpolateBetweenStops(
                from: from, to: to, progress: progress, along: polyline)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "1000 interpolations took \(elapsed)s — too slow")
    }

    @Test func blendSimulation1000Ticks() {
        // Simulate blending 20 vehicles for 50 ticks each = 1000 blend ops
        let start = Date()
        for v in 0..<20 {
            var current = CLLocationCoordinate2D(
                latitude: 40.70 + Double(v) * 0.005,
                longitude: -73.99)
            let target = CLLocationCoordinate2D(
                latitude: 40.70 + Double(v) * 0.005 + 0.01,
                longitude: -73.99)
            for _ in 0..<50 {
                let dist = CLLocation(
                    latitude: current.latitude,
                    longitude: current.longitude
                ).distance(from: CLLocation(
                    latitude: target.latitude,
                    longitude: target.longitude
                ))
                let blend = dist > 200 ? 0.7 : 0.55
                current = CLLocationCoordinate2D(
                    latitude: current.latitude + (target.latitude - current.latitude) * blend,
                    longitude: current.longitude + (target.longitude - current.longitude) * blend
                )
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.5, "1000 blend ops took \(elapsed)s — too slow")
    }

    @Test func polylineLengthPerformance() {
        var bigPolyline: [CLLocationCoordinate2D] = []
        for i in 0..<500 {
            bigPolyline.append(CLLocationCoordinate2D(
                latitude: 40.70 + Double(i) * 0.0002,
                longitude: -74.00 + Double(i) * 0.00001
            ))
        }

        let start = Date()
        for _ in 0..<500 {
            _ = VehicleInterpolator.polylineLength(bigPolyline)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "500 polylineLength calls on 500-pt polyline took \(elapsed)s")
    }
}

// ==========================================================================
// MARK: - 10. Edge Cases
// ==========================================================================

@Suite("Edge Cases")
struct EdgeCaseTests {

    @Test func twoPointPolyline() {
        let polyline = [
            CLLocationCoordinate2D(latitude: 40.70, longitude: -74.00),
            CLLocationCoordinate2D(latitude: 40.80, longitude: -74.00),
        ]
        let result = VehicleInterpolator.interpolateBetweenStops(
            from: polyline[0], to: polyline[1],
            progress: 0.5, along: polyline)
        #expect(abs(result.coordinate.latitude - 40.75) < 0.001)
    }

    @Test func identicalFromAndToStops() {
        let stop = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)
        let result = VehicleInterpolator.interpolateBetweenStops(
            from: stop, to: stop,
            progress: 0.5, along: NYCFixtures.seventhAvenue)
        // span = 0 → straight-line fallback → midpoint of identical = same point
        #expect(abs(result.coordinate.latitude - stop.latitude) < 0.0001)
    }

    @Test func progressBeyondOneGetsClampedByInterpolate() {
        // interpolate clamps to [0,1]
        let coord = VehicleInterpolator.interpolate(
            along: NYCFixtures.seventhAvenue, fraction: 2.0)
        #expect(coord != nil)
        #expect(abs(coord!.latitude - NYCFixtures.seventhAvenue.last!.latitude) < 0.0001)
    }

    @Test func nearbyTransitResponseWithAllNilIds() {
        let a = NearbyTransitResponse(
            routeId: "X",
            stopName: "Mystery",
            direction: "N",
            destination: nil,
            minutesAway: 99,
            status: "OK",
            mode: "subway",
            stopLat: nil,
            stopLon: nil,
            arrivalTs: nil,
            vehicleId: nil,
            tripId: nil,
            stopId: nil
        )
        // Should still produce an ID (fallback to minutesAway)
        #expect(!a.id.isEmpty)
        #expect(a.id == "X-Mystery-99")
    }

    @Test func trainVehicleMinutesAwayComputedCorrectly() {
        let inFuture = TrainVehicle(
            id: "T1", tripId: "T1", routeId: "A", direction: "N",
            lat: 40.75, lon: -73.99, bearing: 0,
            nextStationName: "34 St",
            estimatedArrival: Date.now.addingTimeInterval(180))  // 3 min from now
        #expect(inFuture.minutesAway == 3)

        let arriving = TrainVehicle(
            id: "T2", tripId: "T2", routeId: "B", direction: "S",
            lat: 40.75, lon: -73.99, bearing: 0,
            nextStationName: "14 St",
            estimatedArrival: Date.now.addingTimeInterval(20))  // 20s → ceil = 1
        #expect(arriving.minutesAway == 1)

        let past = TrainVehicle(
            id: "T3", tripId: "T3", routeId: "C", direction: "N",
            lat: 40.75, lon: -73.99, bearing: 0,
            nextStationName: "42 St",
            estimatedArrival: Date.now.addingTimeInterval(-30))  // 30s past → 0
        #expect(past.minutesAway == 0)

        let longPast = TrainVehicle(
            id: "T4", tripId: "T4", routeId: "D", direction: "S",
            lat: 40.75, lon: -73.99, bearing: 0,
            nextStationName: "Fulton",
            estimatedArrival: Date.now.addingTimeInterval(-90))  // > 60s past → nil
        #expect(longPast.minutesAway == nil)

        let noEta = TrainVehicle(
            id: "T5", tripId: "T5", routeId: "E", direction: "N",
            lat: 40.75, lon: -73.99, bearing: 0,
            nextStationName: nil,
            estimatedArrival: nil)
        #expect(noEta.minutesAway == nil)
    }

    @Test func busVehicleStableId() {
        let bus = BusVehicleResponse(
            vehicleId: "MTA-1234",
            routeId: "B63",
            lat: 40.68, lon: -73.98,
            bearing: 180,
            nextStop: "5 Av",
            statusText: "approaching",
            directionRef: 0,
            expectedArrival: nil
        )
        #expect(bus.id == "MTA-1234")

        // Empty vehicleId fallback
        let fallback = BusVehicleResponse(
            vehicleId: "",
            routeId: "Q10",
            lat: 40.68, lon: -73.98,
            bearing: nil,
            nextStop: "Main St",
            statusText: nil,
            directionRef: 1,
            expectedArrival: nil
        )
        #expect(fallback.id.contains("Q10"))
        #expect(fallback.id.contains("Main St"))
    }

    @Test func interpolateWithCurvedRoute() {
        // The bus route has an L-shaped curve — test that interpolation
        // follows the curve rather than cutting the corner.
        // Use interior stops (2nd and 5th points) so span < 0.95 and polyline
        // interpolation is used instead of straight-line fallback.
        let polyline = NYCFixtures.busRoute
        let from = polyline[1]   // (40.691, -73.985) — northbound leg
        let to = polyline[4]     // (40.692, -73.983) — eastbound leg

        let result = VehicleInterpolator.interpolateBetweenStops(
            from: from, to: to, progress: 0.5, along: polyline)

        // The midpoint by polyline distance should be near the corner (40.692, -73.985)
        // A straight-line midpoint would cut through buildings; the polyline
        // midpoint should stay on the route.
        let snapResult = VehicleInterpolator.snap(
            coordinate: result.coordinate, to: polyline)
        #expect(snapResult != nil)
        #expect(snapResult!.distanceFromPolyline < 5,
                "Curved route midpoint should be on the polyline")
    }
}

// ==========================================================================
// MARK: - 11. Integration-style: Full tick simulation
// ==========================================================================

@Suite("Full Tick Simulation")
struct FullTickSimulationTests {

    /// Simulates a complete train position update cycle for multiple trains.
    @Test func threeTrainsMoveSmoothlyOverTenTicks() {
        let polyline = NYCFixtures.seventhAvenue

        // Train configs: (fromStop, toStop, initial minutes away)
        let configs: [(
            from: CLLocationCoordinate2D,
            to: CLLocationCoordinate2D,
            minutesAway: Double
        )] = [
            (NYCFixtures.stop23rd, NYCFixtures.stop34th, 2.0),
            (NYCFixtures.stop34th, NYCFixtures.stop42nd, 1.5),
            (NYCFixtures.stop42nd, NYCFixtures.stop50th, 3.0),
        ]

        for (configIdx, config) in configs.enumerated() {
            var prevPosition: CLLocationCoordinate2D? = nil
            var prevFraction: Double = -1

            for tick in 0..<10 {
                // Simulate time passing (1 second per tick)
                let minutesRemaining = max(0, config.minutesAway - Double(tick) * (1.0 / 60.0))

                // Dynamic travel time
                let dist = CLLocation(
                    latitude: config.from.latitude,
                    longitude: config.from.longitude
                ).distance(from: CLLocation(
                    latitude: config.to.latitude,
                    longitude: config.to.longitude
                ))
                let speedMpm: Double = dist > 2000 ? 750 : 500
                let travelTime = max(1.0, dist / speedMpm)

                let t = min(max(minutesRemaining / travelTime, 0.0), 1.0)
                let rawProgress = 1.0 - t

                // Interpolate on polyline
                let interpResult = VehicleInterpolator.interpolateBetweenStops(
                    from: config.from, to: config.to,
                    progress: rawProgress, along: polyline)

                var targetLat = interpResult.coordinate.latitude
                var targetLon = interpResult.coordinate.longitude

                // Apply blend
                if let prev = prevPosition {
                    let blendDist = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                        .distance(from: CLLocation(latitude: targetLat, longitude: targetLon))
                    let blendFactor = blendDist > 200 ? 0.7 : 0.55
                    targetLat = prev.latitude + (targetLat - prev.latitude) * blendFactor
                    targetLon = prev.longitude + (targetLon - prev.longitude) * blendFactor
                }

                let finalPos = CLLocationCoordinate2D(latitude: targetLat, longitude: targetLon)

                // Verify the position is on or near the polyline
                let snap = VehicleInterpolator.snap(coordinate: finalPos, to: polyline)!
                #expect(snap.distanceFromPolyline < 100,
                        "Train \(configIdx) tick \(tick): should be near polyline, got \(snap.distanceFromPolyline)m off")

                // Verify monotonic progress along polyline
                if prevFraction >= 0 {
                    // Allow tiny regression from blend smoothing, but not large backwards jumps
                    #expect(snap.fractionAlongPolyline >= prevFraction - 0.02,
                            "Train \(configIdx) tick \(tick): should not jump backwards significantly")
                }

                prevPosition = finalPos
                prevFraction = snap.fractionAlongPolyline
            }
        }
    }

    @Test func fiveBusesSmoothPositionOverTenSecondWindow() {
        let polyline = NYCFixtures.busRoute

        // 5 buses at different stages of their 10-second GPS polling cycle
        for busIdx in 0..<5 {
            let startFrac = Double(busIdx) * 0.15  // 0, 0.15, 0.30, 0.45, 0.60
            let endFrac = startFrac + 0.15
            let from = VehicleInterpolator.interpolate(along: polyline, fraction: startFrac)!
            let to = VehicleInterpolator.interpolate(along: polyline, fraction: endFrac)!

            var prevFraction = -1.0

            for elapsed in stride(from: 0.0, through: 10.0, by: 1.0) {
                let result = VehicleInterpolator.smoothBusPosition(
                    previous: from, current: to,
                    elapsed: elapsed, duration: 10,
                    along: polyline)
                let snap = VehicleInterpolator.snap(coordinate: result.coordinate, to: polyline)!

                #expect(snap.distanceFromPolyline < 50,
                        "Bus \(busIdx) at t=\(elapsed)s should be on polyline")

                #expect(snap.fractionAlongPolyline >= prevFraction - 0.01,
                        "Bus \(busIdx) at t=\(elapsed)s should not go backwards")
                prevFraction = snap.fractionAlongPolyline
            }
        }
    }

    @Test func blendConvergesEvenWhenTargetShiftsEveryPoll() {
        // Simulate train where every 6 seconds (6 ticks) the target position
        // jumps forward (new GTFS-RT poll). The blend should still converge.

        var currentPos = CLLocationCoordinate2D(latitude: 40.7440, longitude: -73.992)
        var target = CLLocationCoordinate2D(latitude: 40.7460, longitude: -73.992)

        for poll in 0..<3 {
            // 6 ticks per poll cycle
            for tick in 0..<6 {
                let dist = CLLocation(
                    latitude: currentPos.latitude,
                    longitude: currentPos.longitude
                ).distance(from: CLLocation(
                    latitude: target.latitude,
                    longitude: target.longitude
                ))
                let blend = dist > 200 ? 0.7 : 0.55
                currentPos = CLLocationCoordinate2D(
                    latitude: currentPos.latitude
                        + (target.latitude - currentPos.latitude) * blend,
                    longitude: currentPos.longitude
                        + (target.longitude - currentPos.longitude) * blend
                )

                // Verify we're always heading toward target
                let newDist = CLLocation(
                    latitude: currentPos.latitude,
                    longitude: currentPos.longitude
                ).distance(from: CLLocation(
                    latitude: target.latitude,
                    longitude: target.longitude
                ))
                if tick > 0 {
                    #expect(newDist <= dist + 1,
                            "Poll \(poll) tick \(tick): should converge, not diverge")
                }
            }

            // After 6 ticks, shift target forward (new poll)
            let distAfterPoll = CLLocation(
                latitude: currentPos.latitude,
                longitude: currentPos.longitude
            ).distance(from: CLLocation(
                latitude: target.latitude,
                longitude: target.longitude
            ))
            #expect(
                distAfterPoll < 30,
                "Should be within 30m of target after 6 ticks, got \(distAfterPoll)m"
            )

            // New target 200m further north
            target = CLLocationCoordinate2D(
                latitude: target.latitude + 0.002,
                longitude: target.longitude)
        }
    }
}
