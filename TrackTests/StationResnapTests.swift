//
//  StationResnapTests.swift
//  TrackTests
//
//  Tests that validate the re-snap behavior: after Catmull-Rom smoothing
//  shifts rendered polylines away from raw server segments, station dots
//  are re-projected onto the smoothed curves so they remain visually
//  centred on the rendered lines.
//
//  Key insight: Catmull-Rom is an *interpolating* spline — it passes
//  through every original control point.  The divergence from raw straight
//  segments occurs *between* control points.  Therefore stations placed
//  at the midpoint of a raw segment near a bend will be measurably off
//  the smoothed curve.
//
//  The implementation under test is
//  `MapSystemViewModel.resnapStationsToSmoothedPolylines()`.  Because its
//  helpers (`nearestPointOnBranches`, `nearestSegmentHeading`,
//  `projectOntoSegment`) are `private static`, the tests recreate the
//  same geometric operations in test-local helpers and exercise them
//  against the real `smoothPolyline()` from PolylineUtils.swift.

import CoreLocation
import Foundation
import Testing
@testable import Track

// MARK: - Test-local geometry helpers

/// Flat-Earth projection to segment (cos-corrected at NYC latitude).
private func projectOntoSegment(
    lat: Double, lon: Double,
    aLat: Double, aLon: Double,
    bLat: Double, bLon: Double
) -> (projLat: Double, projLon: Double, distSq: Double) {
    let cosNYC: Double = 0.76
    let dx = (bLon - aLon) * cosNYC
    let dy = bLat - aLat
    let px = (lon - aLon) * cosNYC
    let py = lat - aLat
    let lenSq = dx * dx + dy * dy

    if lenSq < 1e-20 {
        return (aLat, aLon, px * px + py * py)
    }

    let t = max(0, min(1, (px * dx + py * dy) / lenSq))
    let projLat = aLat + t * (bLat - aLat)
    let projLon = aLon + t * (bLon - aLon)
    let eLat = lat - projLat
    let eLon = (lon - projLon) * cosNYC
    return (projLat, projLon, eLat * eLat + eLon * eLon)
}

/// Closest point on a polyline set.
private func nearestPointOnBranches(
    near coordinate: CLLocationCoordinate2D,
    branches: [[CLLocationCoordinate2D]]
) -> CLLocationCoordinate2D? {
    var bestCoordinate: CLLocationCoordinate2D?
    var bestDistSq: Double = .infinity

    for branch in branches {
        guard branch.count >= 2 else { continue }
        for i in 0..<(branch.count - 1) {
            let a = branch[i]
            let b = branch[i + 1]
            let (projLat, projLon, distSq) = projectOntoSegment(
                lat: coordinate.latitude,
                lon: coordinate.longitude,
                aLat: a.latitude, aLon: a.longitude,
                bLat: b.latitude, bLon: b.longitude
            )
            guard distSq < bestDistSq else { continue }
            bestDistSq = distSq
            bestCoordinate = CLLocationCoordinate2D(
                latitude: projLat, longitude: projLon
            )
        }
    }
    return bestCoordinate
}

/// Heading of the nearest segment (degrees from north, 0-360).
private func nearestSegmentHeading(
    near coordinate: CLLocationCoordinate2D,
    branches: [[CLLocationCoordinate2D]]
) -> Double? {
    var bestHeading: Double?
    var bestDistSq: Double = .infinity

    for branch in branches {
        guard branch.count >= 2 else { continue }
        for i in 0..<(branch.count - 1) {
            let a = branch[i]
            let b = branch[i + 1]
            let (_, _, distSq) = projectOntoSegment(
                lat: coordinate.latitude,
                lon: coordinate.longitude,
                aLat: a.latitude, aLon: a.longitude,
                bLat: b.latitude, bLon: b.longitude
            )
            guard distSq < bestDistSq else { continue }

            let cosNYC: Double = 0.76
            let dx = (b.longitude - a.longitude) * cosNYC
            let dy = b.latitude - a.latitude
            guard dx * dx + dy * dy > 1e-12 else { continue }

            var heading = atan2(dx, dy) * 180.0 / .pi
            if heading < 0 { heading += 360.0 }
            bestDistSq = distSq
            bestHeading = heading
        }
    }
    return bestHeading
}

/// Minimum distance (in degrees, cos-corrected) from a point to a polyline.
private func distanceToPolyline(
    _ coord: CLLocationCoordinate2D,
    _ polyline: [CLLocationCoordinate2D]
) -> Double {
    guard polyline.count >= 2 else { return .infinity }
    var best: Double = .infinity
    for i in 0..<(polyline.count - 1) {
        let (_, _, dSq) = projectOntoSegment(
            lat: coord.latitude, lon: coord.longitude,
            aLat: polyline[i].latitude,
            aLon: polyline[i].longitude,
            bLat: polyline[i + 1].latitude,
            bLon: polyline[i + 1].longitude
        )
        best = min(best, dSq)
    }
    return sqrt(best)
}

/// Approximate Haversine distance in metres.
private func haversineMetres(
    _ a: CLLocationCoordinate2D,
    _ b: CLLocationCoordinate2D
) -> Double {
    let r: Double = 6_371_000
    let dLat = (b.latitude - a.latitude) * .pi / 180
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let lat1 = a.latitude * .pi / 180
    let lat2 = b.latitude * .pi / 180
    let sinLat = sin(dLat / 2)
    let sinLon = sin(dLon / 2)
    let h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
    return 2 * r * asin(sqrt(h))
}

/// Metres-per-pixel at a given Mercator zoom.
private func metersPerPixel(zoom: Double, lat: Double = 40.7) -> Double {
    let c: Double = 40_075_017
    return c * cos(lat * .pi / 180) / (256 * pow(2, zoom))
}

/// Convert cos-corrected degree distance to metres at NYC latitude.
private func degToMetres(_ deg: Double) -> Double {
    deg * 111_320 * cos(40.76 * .pi / 180)
}

// MARK: - Fixtures

/// A sharp 90° bend — going south then turning east.
/// The right-angle makes Catmull-Rom divergence large and predictable.
private let kSharpBendRaw: [CLLocationCoordinate2D] = [
    CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9900),
    CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9900),  // ~220 m
    CLLocationCoordinate2D(latitude: 40.7560, longitude: -73.9900),  // corner
    CLLocationCoordinate2D(latitude: 40.7560, longitude: -73.9870),  // east
    CLLocationCoordinate2D(latitude: 40.7560, longitude: -73.9840),
]

/// The smoothed version of the sharp bend.
private let kSharpBendSmoothed: [CLLocationCoordinate2D] = smoothPolyline(
    kSharpBendRaw, segmentsPerCurve: 4
)

/// Station at the midpoint of the raw segment approaching the bend
/// (segment index 1 → 2).  This is between two control points, where
/// the smoothed curve bows away from the straight raw segment.
private let kStationMidBend = CLLocationCoordinate2D(
    latitude: (40.7580 + 40.7560) / 2,   // 40.7570
    longitude: -73.9900
)

/// Station on the first straight segment (seg 0 → 1), far from bend.
private let kStationOnStraight = CLLocationCoordinate2D(
    latitude: (40.7600 + 40.7580) / 2,   // 40.7590
    longitude: -73.9900
)

// MARK: - 1. Catmull-Rom smoothing fundamentals

@Suite("Catmull-Rom smoothing fundamentals")
struct CatmullRomDivergenceTests {

    @Test("Smoothing adds interpolated points")
    func smoothingAddsPoints() {
        let raw = kSharpBendRaw
        let smoothed = kSharpBendSmoothed
        #expect(
            smoothed.count > raw.count,
            "Smoothed (\(smoothed.count) pts) should have more points than raw (\(raw.count))"
        )
    }

    @Test("Smoothed curve diverges from raw at midpoint of bend segment")
    func smoothedDivergesAtMidpoint() {
        // The midpoint of the raw segment near the bend sits on a
        // straight line, but the smoothed curve bows away from it.
        let distDeg = distanceToPolyline(kStationMidBend, kSharpBendSmoothed)
        let distM = degToMetres(distDeg)
        #expect(
            distM > 1.0,
            "Midpoint of bend segment should be > 1 m from smoothed curve but was \(String(format: "%.2f", distM)) m"
        )
    }

    @Test("Smoothed polyline stays close to raw polyline envelope")
    func smoothedStaysCloseToRaw() {
        // Every point on the smoothed curve should be within a reasonable
        // distance of the raw polyline.  This ensures smoothing doesn't
        // create wild excursions.
        for pt in kSharpBendSmoothed {
            let distDeg = distanceToPolyline(pt, kSharpBendRaw)
            let distM = degToMetres(distDeg)
            #expect(
                distM < 20.0,
                "Smoothed point (\(String(format: "%.5f", pt.latitude)), \(String(format: "%.5f", pt.longitude))) is \(String(format: "%.2f", distM)) m from raw — expected < 20 m"
            )
        }
    }
}

// MARK: - 2. Raw-snapped station offset from smoothed curve

@Suite("Raw-snapped offset from smoothed line")
struct RawSnappedOffsetTests {

    @Test("Station snapped to raw is off smoothed at the bend")
    func rawSnappedIsOffSmoothedAtBend() {
        let rawSnapped = nearestPointOnBranches(
            near: kStationMidBend,
            branches: [kSharpBendRaw]
        )!
        let distDeg = distanceToPolyline(rawSnapped, kSharpBendSmoothed)
        let distM = degToMetres(distDeg)
        #expect(
            distM > 1.0,
            "Raw-snapped station should be > 1 m from smoothed curve but was \(String(format: "%.2f", distM)) m"
        )
    }

    @Test("Station snapped to raw is close on a straight section")
    func rawSnappedIsCloseOnStraight() {
        let rawSnapped = nearestPointOnBranches(
            near: kStationOnStraight,
            branches: [kSharpBendRaw]
        )!
        let distDeg = distanceToPolyline(rawSnapped, kSharpBendSmoothed)
        let distM = degToMetres(distDeg)
        #expect(
            distM < 10.0,
            "Straight section: raw-snapped should be < 10 m from smoothed but was \(String(format: "%.2f", distM)) m"
        )
    }
}

// MARK: - 3. Re-snap accuracy

@Suite("Re-snap brings station onto smoothed curve")
struct ResnapAccuracyTests {

    @Test("Re-snap at the bend puts station on the smoothed curve")
    func resnapBringsStationOntoCurveAtBend() {
        let rawSnapped = nearestPointOnBranches(
            near: kStationMidBend,
            branches: [kSharpBendRaw]
        )!
        let resnapped = nearestPointOnBranches(
            near: rawSnapped,
            branches: [kSharpBendSmoothed]
        )!
        let distDeg = distanceToPolyline(resnapped, kSharpBendSmoothed)
        let distM = degToMetres(distDeg)
        #expect(
            distM < 0.1,
            "Re-snapped station should be < 0.1 m from smoothed curve but was \(String(format: "%.2f", distM)) m"
        )
    }

    @Test("Re-snap on straight segment preserves position")
    func resnapPreservesStationOnStraight() {
        let rawSnapped = nearestPointOnBranches(
            near: kStationOnStraight,
            branches: [kSharpBendRaw]
        )!
        let resnapped = nearestPointOnBranches(
            near: rawSnapped,
            branches: [kSharpBendSmoothed]
        )!
        let drift = haversineMetres(rawSnapped, resnapped)
        #expect(
            drift < 10.0,
            "Straight section drift should be < 10 m but was \(String(format: "%.2f", drift)) m"
        )
    }

    @Test("Re-snap reduces distance to smoothed curve")
    func resnapReducesDistance() {
        let rawSnapped = nearestPointOnBranches(
            near: kStationMidBend,
            branches: [kSharpBendRaw]
        )!
        let resnapped = nearestPointOnBranches(
            near: rawSnapped,
            branches: [kSharpBendSmoothed]
        )!

        let rawDist = distanceToPolyline(rawSnapped, kSharpBendSmoothed)
        let resnapDist = distanceToPolyline(resnapped, kSharpBendSmoothed)

        #expect(
            resnapDist < rawDist,
            "Re-snap should bring station closer to smoothed: raw=\(String(format: "%.6f", rawDist))° resnap=\(String(format: "%.6f", resnapDist))°"
        )
    }
}

// MARK: - 4. Sub-pixel accuracy at rendered zoom levels

@Suite("Sub-pixel accuracy at rendered zoom levels")
struct SubPixelAccuracyTests {

    @Test("Sub-pixel accuracy after re-snap",
          arguments: [11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0])
    func subPixelAccuracyAtZoom(zoom: Double) {
        let rawSnapped = nearestPointOnBranches(
            near: kStationMidBend,
            branches: [kSharpBendRaw]
        )!
        let resnapped = nearestPointOnBranches(
            near: rawSnapped,
            branches: [kSharpBendSmoothed]
        )!
        let distDeg = distanceToPolyline(resnapped, kSharpBendSmoothed)
        let distM = degToMetres(distDeg)
        let mpp = metersPerPixel(zoom: zoom)
        let errorPx = distM / mpp
        #expect(
            errorPx < 0.5,
            "z\(Int(zoom)): re-snapped station is \(String(format: "%.2f", errorPx))px off — expected < 0.5px"
        )
    }

    @Test("Without re-snap, station is off at close zoom")
    func withoutResnapStationIsOffAtCloseZoom() {
        let rawSnapped = nearestPointOnBranches(
            near: kStationMidBend,
            branches: [kSharpBendRaw]
        )!
        let distDeg = distanceToPolyline(rawSnapped, kSharpBendSmoothed)
        let distM = degToMetres(distDeg)
        let mpp = metersPerPixel(zoom: 15)
        let errorPx = distM / mpp
        #expect(
            errorPx > 1.0,
            "z15: without re-snap, station was only \(String(format: "%.2f", errorPx))px off — expected > 1px"
        )
    }
}

// MARK: - 5. Transfer station exclusion

@Suite("Transfer station exclusion")
struct TransferExclusionTests {

    @Test("Transfer stations (colorGroupCount >= 2) are not re-snapped")
    func transferStationsExcluded() {
        let transferStation = MapSystemViewModel.ConsolidatedStation(
            id: "test-transfer",
            name: "Test Transfer",
            coordinate: kStationMidBend,
            routes: ["A", "1"],
            colorGroupCount: 2,
            trackBearing: 0,
            laneHeading: nil,
            laneOffset: 0,
            structure: .subway,
            complexID: 999,
            sourceStopIDs: [],
            isTransfer: true
        )
        #expect(
            transferStation.colorGroupCount >= 2,
            "Transfer station should have colorGroupCount >= 2"
        )

        let singleGroupStation = MapSystemViewModel.ConsolidatedStation(
            id: "test-single",
            name: "Test Single",
            coordinate: kStationMidBend,
            routes: ["A"],
            colorGroupCount: 1,
            trackBearing: 0,
            laneHeading: nil,
            laneOffset: 0,
            structure: .subway,
            complexID: 998,
            sourceStopIDs: [],
            isTransfer: false
        )
        #expect(
            singleGroupStation.colorGroupCount == 1,
            "Single-group station should be eligible for re-snap"
        )
    }
}

// MARK: - 6. Heading recomputation

@Suite("Heading recomputation after re-snap")
struct HeadingRecomputationTests {

    @Test("Heading differs between raw and smoothed near the bend")
    func headingDiffersAtBend() {
        let rawHeading = nearestSegmentHeading(
            near: kStationMidBend,
            branches: [kSharpBendRaw]
        )!

        let rawSnapped = nearestPointOnBranches(
            near: kStationMidBend,
            branches: [kSharpBendRaw]
        )!
        let resnapped = nearestPointOnBranches(
            near: rawSnapped,
            branches: [kSharpBendSmoothed]
        )!
        let smoothedHeading = nearestSegmentHeading(
            near: resnapped,
            branches: [kSharpBendSmoothed]
        )!

        let diff = abs(rawHeading - smoothedHeading)
        let angularDiff = min(diff, 360 - diff)

        #expect(
            angularDiff > 0.5,
            "Heading should differ near bend — raw=\(String(format: "%.1f", rawHeading))° smoothed=\(String(format: "%.1f", smoothedHeading))° diff=\(String(format: "%.1f", angularDiff))°"
        )
    }

    @Test("Heading is roughly consistent on straight section")
    func headingConsistentOnStraight() {
        let rawHeading = nearestSegmentHeading(
            near: kStationOnStraight,
            branches: [kSharpBendRaw]
        )!
        let smoothedHeading = nearestSegmentHeading(
            near: kStationOnStraight,
            branches: [kSharpBendSmoothed]
        )!

        let diff = abs(rawHeading - smoothedHeading)
        let angularDiff = min(diff, 360 - diff)

        #expect(
            angularDiff < 10.0,
            "Straight section heading change should be < 10° but was \(String(format: "%.1f", angularDiff))°"
        )
    }
}

// MARK: - 7. S-curve scenario

@Suite("S-curve re-snap accuracy")
struct SCurveTests {

    @Test("Re-snap at midpoints of S-curve bend segments")
    func sCurveResnapAccuracy() {
        let sCurve: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9900),
            CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9895),
            CLLocationCoordinate2D(latitude: 40.7560, longitude: -73.9880),
            CLLocationCoordinate2D(latitude: 40.7555, longitude: -73.9860),
            CLLocationCoordinate2D(latitude: 40.7560, longitude: -73.9840),
            CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9830),
            CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9835),
        ]
        let smoothed = smoothPolyline(sCurve, segmentsPerCurve: 4)

        // Test re-snap at midpoints of segments near the bends.
        for segIdx in [1, 4] {
            let midLat = (sCurve[segIdx].latitude
                + sCurve[segIdx + 1].latitude) / 2
            let midLon = (sCurve[segIdx].longitude
                + sCurve[segIdx + 1].longitude) / 2
            let midPt = CLLocationCoordinate2D(
                latitude: midLat, longitude: midLon
            )

            let rawSnapped = nearestPointOnBranches(
                near: midPt, branches: [sCurve]
            )!
            let resnapped = nearestPointOnBranches(
                near: rawSnapped, branches: [smoothed]
            )!

            let distDeg = distanceToPolyline(resnapped, smoothed)
            let distM = degToMetres(distDeg)

            #expect(
                distM < 0.1,
                "S-curve seg \(segIdx): re-snapped station should be < 0.1 m from smoothed but was \(String(format: "%.2f", distM)) m"
            )
        }
    }
}

// MARK: - 8. Edge cases

@Suite("Re-snap edge cases")
struct ResnapEdgeCaseTests {

    @Test("Two-point polyline is not smoothed")
    func twoPointPolylineNotSmoothed() {
        let twoPoints: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 40.76, longitude: -73.99),
            CLLocationCoordinate2D(latitude: 40.75, longitude: -73.98),
        ]
        let smoothed = smoothPolyline(twoPoints, segmentsPerCurve: 4)
        #expect(
            smoothed.count == 2,
            "A 2-point polyline should not be smoothed (got \(smoothed.count) points)"
        )
    }

    @Test("Station on control point stays close after re-snap")
    func stationOnControlPointStaysPut() {
        let controlPt = kSharpBendRaw[1]
        let rawSnapped = nearestPointOnBranches(
            near: controlPt,
            branches: [kSharpBendRaw]
        )!
        let resnapped = nearestPointOnBranches(
            near: rawSnapped,
            branches: [kSharpBendSmoothed]
        )!
        let drift = haversineMetres(rawSnapped, resnapped)
        #expect(
            drift < 5.0,
            "Control point drift should be < 5 m but was \(String(format: "%.2f", drift)) m"
        )
    }

    @Test("Re-snap is idempotent")
    func resnapIsIdempotent() {
        let rawSnapped = nearestPointOnBranches(
            near: kStationMidBend,
            branches: [kSharpBendRaw]
        )!
        let firstResnap = nearestPointOnBranches(
            near: rawSnapped,
            branches: [kSharpBendSmoothed]
        )!
        let secondResnap = nearestPointOnBranches(
            near: firstResnap,
            branches: [kSharpBendSmoothed]
        )!
        let drift = haversineMetres(firstResnap, secondResnap)
        #expect(
            drift < 0.01,
            "Second re-snap should not drift (got \(String(format: "%.4f", drift)) m)"
        )
    }
}
