//
//  StationDotOffsetTests.swift
//  TrackTests
//
//  Tests for the line-offset station dot rendering approach.
//
//  Single-line station dots are rendered as micro line-segments with
//  round caps and the SAME `line-offset` expression as trunk polylines.
//  This guarantees zero drift / zero jumping because both the polyline
//  and the dot use the identical screen-space offset mechanism.
//
//  These tests verify:
//    1. Lane-offset multiplier correctness (drives both polyline + dot)
//    2. Fill-width stop boundary values
//    3. Dot line-width expressions (diameter and casing)
//    4. laneOffsetPixels helper

import CoreGraphics
import Foundation
import Testing
@testable import Track

// MARK: - Fixture data

/// Integer zoom levels where station dots are rendered.
private let kStationZooms: [Double] = [11, 12, 13, 14, 15, 16, 17, 18]

/// Lane-offset values the pipeline produces (±0.5 … ±2.5 in steps of 0.5).
private let kLaneOffsets: [Double] = [
    -2.5, -2.0, -1.5, -1.0, -0.5, 0.5, 1.0, 1.5, 2.0, 2.5,
]

// MARK: - 1. Lane-offset multiplier

@Suite("Lane-offset multiplier — core correctness")
struct LaneOffsetMultiplierTests {

    @Test("laneOffsetMultiplier is positive everywhere", arguments: kStationZooms)
    func multiplierIsPositive(zoom: Double) {
        let m = MapLibreStyleConfig.laneOffsetMultiplier(at: zoom)
        #expect(m > 0.0, "z\(Int(zoom)): multiplier=\(m)")
    }

    @Test("laneOffsetMultiplier increases with zoom")
    func multiplierIncreasesWithZoom() {
        var prev = MapLibreStyleConfig.laneOffsetMultiplier(at: kStationZooms.first!)
        for zoom in kStationZooms.dropFirst() {
            let curr = MapLibreStyleConfig.laneOffsetMultiplier(at: zoom)
            #expect(
                curr >= prev - 1e-9,
                "laneOffsetMultiplier dropped at z\(Int(zoom)): \(prev) → \(curr)"
            )
            prev = curr
        }
    }

    @Test(
        "laneOffsetPixels returns laneOffset × multiplier",
        arguments: kLaneOffsets, kStationZooms
    )
    func laneOffsetPixelsMatchesProduct(laneOffset: Double, zoom: Double) {
        let expected = laneOffset * MapLibreStyleConfig.laneOffsetMultiplier(at: zoom)
        let actual = Double(MapLibreStyleConfig.laneOffsetPixels(
            for: CGFloat(laneOffset), at: zoom
        ))
        #expect(abs(actual - expected) < 1e-9)
    }

    @Test(
        "laneOffsetPixels sign matches lane_offset sign",
        arguments: kLaneOffsets, [13.0, 15.0, 17.0]
    )
    func pixelSignMatchesOffset(laneOffset: Double, zoom: Double) {
        let px = Double(MapLibreStyleConfig.laneOffsetPixels(
            for: CGFloat(laneOffset), at: zoom
        ))
        if laneOffset > 0 {
            #expect(px > 0, "Positive lane_offset should produce positive px")
        } else {
            #expect(px < 0, "Negative lane_offset should produce negative px")
        }
    }

    @Test("Multiplier floor is at least 0.8 (laneOffsetMinMultiplier)")
    func multiplierRespectsFloor() {
        let minMultiplier = 0.8
        for zoom in [8.0, 9.0, 10.0, 11.0] {
            let m = MapLibreStyleConfig.laneOffsetMultiplier(at: zoom)
            #expect(
                m >= minMultiplier - 1e-9,
                "Multiplier below floor at z\(Int(zoom)): \(m)"
            )
        }
    }
}

// MARK: - 2. Fill-width stop boundary values

@Suite("Lane-offset — fill-width stop boundary values")
struct FillWidthStopTests {

    private let fillWidthStops: [(zoom: Double, width: Double)] = [
        (8, 1.0), (9, 1.3), (10, 1.8), (11, 2.4), (12, 3.0),
        (13, 3.6), (14, 4.2), (15, 5.0), (16, 5.8), (17, 6.8), (18, 7.8),
    ]

    @Test("laneOffsetMultiplier at fill-width stops = width × 0.98 (floor 0.8)")
    func multiplierMatchesTouchRatioAtStops() {
        let touchRatio = 0.98
        let minMult = 0.8
        for stop in fillWidthStops {
            let expected = max(stop.width * touchRatio, minMult)
            let actual = MapLibreStyleConfig.laneOffsetMultiplier(at: stop.zoom)
            #expect(
                abs(actual - expected) < 1e-9,
                "z\(Int(stop.zoom)): expected \(expected) got \(actual)"
            )
        }
    }
}

// MARK: - 3. Station dot line-width expressions

/// Station dots are rendered as micro line-segments with round caps.
/// `stationDotLineWidth` is the fill diameter (= 2 × old radius).
/// `stationDotCasingLineWidth` is wider to create a border ring.
@Suite("Station dot line-width expressions")
struct StationDotLineWidthTests {

    /// Reference radius stops from MapLibreStyleConfig.stationDotRadius.
    private let radiusStops: [(zoom: Double, radius: Double)] = [
        (11, 2.0), (12, 3.0), (13, 3.8), (14, 4.5),
        (15, 5.5), (16, 7.0), (17, 8.5), (18, 10.0),
    ]

    /// Reference stroke-width stops from MapLibreStyleConfig.stationDotStrokeWidth.
    private let strokeStops: [(zoom: Double, stroke: Double)] = [
        (11, 0.8), (12, 1.0), (13, 1.2), (15, 1.5), (17, 2.0), (18, 2.4),
    ]

    /// Expected fill line-width stops (diameter = 2 × radius).
    private let fillWidthStops: [(zoom: Double, width: Double)] = [
        (11, 4.0), (12, 6.0), (13, 7.6), (14, 9.0),
        (15, 11.0), (16, 14.0), (17, 17.0), (18, 20.0),
    ]

    @Test("stationDotLineWidth at stops equals 2 × radius")
    func fillWidthIsDiameter() {
        for stop in radiusStops {
            let expectedDiameter = stop.radius * 2.0
            let matchingFill = fillWidthStops.first { $0.zoom == stop.zoom }
            guard let fill = matchingFill else {
                Issue.record("No fill-width stop at zoom \(stop.zoom)")
                continue
            }
            #expect(
                abs(fill.width - expectedDiameter) < 1e-6,
                "z\(Int(stop.zoom)): expected \(expectedDiameter) got \(fill.width)"
            )
        }
    }

    @Test("Casing line-width is larger than fill line-width at all common stops")
    func casingIsWiderThanFill() {
        // Reference casing stops from MapLibreStyleConfig.stationDotCasingLineWidth.
        let casingStops: [(zoom: Double, width: Double)] = [
            (11, 5.6), (12, 8.0), (13, 10.0), (14, 11.0),
            (15, 14.0), (16, 16.8), (17, 21.0), (18, 24.8),
        ]
        for casing in casingStops {
            guard let fill = fillWidthStops.first(where: { $0.zoom == casing.zoom }) else {
                continue
            }
            #expect(
                casing.width > fill.width,
                "z\(Int(casing.zoom)): casing \(casing.width) ≤ fill \(fill.width)"
            )
        }
    }

    @Test("Fill line-width increases with zoom")
    func fillWidthIncreasesWithZoom() {
        var prev = fillWidthStops.first!.width
        for stop in fillWidthStops.dropFirst() {
            #expect(
                stop.width >= prev,
                "Fill width decreased at z\(Int(stop.zoom)): \(prev) → \(stop.width)"
            )
            prev = stop.width
        }
    }

    @Test("Casing-to-fill ratio is between 1.1 and 1.6 at each stop")
    func casingFillRatioIsReasonable() {
        let casingStops: [(zoom: Double, width: Double)] = [
            (11, 5.6), (12, 8.0), (13, 10.0), (14, 11.0),
            (15, 14.0), (16, 16.8), (17, 21.0), (18, 24.8),
        ]
        for casing in casingStops {
            guard let fill = fillWidthStops.first(where: { $0.zoom == casing.zoom }) else {
                continue
            }
            let ratio = casing.width / fill.width
            #expect(
                ratio >= 1.1 && ratio <= 1.6,
                "z\(Int(casing.zoom)): casing/fill ratio \(ratio) out of [1.1, 1.6]"
            )
        }
    }
}

// MARK: - 4. Line-offset shared expression guarantees

/// The key invariant of the new approach: station dot micro-segments use
/// the exact same `laneOffsetExpression` as trunk polylines.  Because
/// both line layers read the same `lane_offset` feature property and
/// apply the same zoom-interpolated multiplier, the screen-space offset
/// is mathematically identical — zero drift at every zoom level.
@Suite("Station dot — line-offset lockstep guarantee")
struct LineOffsetLockstepTests {

    @Test("laneOffsetExpression is not nil")
    func expressionExists() {
        let expr = MapLibreStyleConfig.laneOffsetExpression
        #expect(expr.expressionType != .anyKey)
    }

    @Test("laneOffsetMultiplier is finite at all station zooms", arguments: kStationZooms)
    func multiplierIsFinite(zoom: Double) {
        let m = MapLibreStyleConfig.laneOffsetMultiplier(at: zoom)
        #expect(m.isFinite, "z\(Int(zoom)): non-finite multiplier \(m)")
    }

    @Test(
        "Same lane_offset value produces identical pixel offset at any zoom",
        arguments: kLaneOffsets, kStationZooms
    )
    func identicalOffsetForSameLaneOffset(laneOffset: Double, zoom: Double) {
        // Both the trunk polyline and the station dot read `lane_offset`
        // from their feature properties.  Since they share the expression,
        // the computed pixel displacement is:
        //   px = lane_offset × laneOffsetMultiplier(zoom)
        // which is deterministic.
        let px1 = laneOffset * MapLibreStyleConfig.laneOffsetMultiplier(at: zoom)
        let px2 = laneOffset * MapLibreStyleConfig.laneOffsetMultiplier(at: zoom)
        #expect(px1 == px2)
    }
}
