//
//  TripRouteClippingTests.swift
//  TrackTests
//
//  Validates that trip-route polyline clipping produces the correct
//  segments the user actually travels through — no extra route shown,
//  correct stop ID normalization, and proper walk-leg stitching.
//

import CoreLocation
import Testing
import UIKit
@testable import Track

// MARK: - Test Fixtures

private enum ClipFixtures {

    // ── Q26 bus route: 10 stops running north along Hillside Ave ──

    static let q26Stops: [BusStop] = [
        BusStop(id: "MTA_300000", name: "Jamaica Bus Terminal", lat: 40.7020, lon: -73.7930, direction: "N"),
        BusStop(id: "MTA_300001", name: "Hillside Av / 169 St", lat: 40.7080, lon: -73.7890, direction: "N"),
        BusStop(id: "MTA_300002", name: "Hillside Av / 175 St", lat: 40.7120, lon: -73.7860, direction: "N"),
        BusStop(id: "MTA_300003", name: "Hillside Av / 180 St", lat: 40.7160, lon: -73.7830, direction: "N"),
        BusStop(id: "MTA_300004", name: "Hillside Av / Midland Pkwy", lat: 40.7200, lon: -73.7800, direction: "N"),
        BusStop(id: "MTA_300005", name: "Hillside Av / 188 St", lat: 40.7240, lon: -73.7770, direction: "N"),
        BusStop(id: "MTA_300006", name: "Hillside Av / Francis Lewis", lat: 40.7280, lon: -73.7740, direction: "N"),
        BusStop(id: "MTA_300007", name: "Hillside Av / Utopia Pkwy", lat: 40.7320, lon: -73.7710, direction: "N"),
        BusStop(id: "MTA_300008", name: "Hillside Av / Fresh Meadow", lat: 40.7360, lon: -73.7680, direction: "N"),
        BusStop(id: "MTA_300009", name: "Hillside Av / Marathon Pkwy", lat: 40.7400, lon: -73.7650, direction: "N"),
    ]

    /// Polyline matching the Q26 stops (one coord per stop, roughly).
    static let q26Polyline: [CLLocationCoordinate2D] = q26Stops.map {
        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
    }

    // ── E train: 8 stops running west from Queens to Manhattan ──

    static let eTrainStops: [BusStop] = [
        BusStop(id: "E01", name: "Jamaica Center", lat: 40.7023, lon: -73.8009, direction: nil),
        BusStop(id: "E02", name: "Sutphin Blvd", lat: 40.7050, lon: -73.8070, direction: nil),
        BusStop(id: "E03", name: "Parsons Blvd", lat: 40.7073, lon: -73.8140, direction: nil),
        BusStop(id: "E04", name: "169 St", lat: 40.7100, lon: -73.8210, direction: nil),
        BusStop(id: "E05", name: "Kew Gardens", lat: 40.7140, lon: -73.8310, direction: nil),
        BusStop(id: "E06", name: "Forest Hills", lat: 40.7206, lon: -73.8450, direction: nil),
        BusStop(id: "E07", name: "Jackson Heights", lat: 40.7467, lon: -73.8914, direction: nil),
        BusStop(id: "E08", name: "34 St-Penn Station", lat: 40.7505, lon: -73.9914, direction: nil),
    ]

    static let eTrainPolyline: [CLLocationCoordinate2D] = eTrainStops.map {
        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
    }

    // ── Multi-polyline route (two direction variants) ──

    static let directionAPolyline: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9800),
        CLLocationCoordinate2D(latitude: 40.7050, longitude: -73.9800),
        CLLocationCoordinate2D(latitude: 40.7100, longitude: -73.9800),
        CLLocationCoordinate2D(latitude: 40.7150, longitude: -73.9800),
        CLLocationCoordinate2D(latitude: 40.7200, longitude: -73.9800),
    ]

    static let directionBPolyline: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7200, longitude: -73.9800),
        CLLocationCoordinate2D(latitude: 40.7150, longitude: -73.9800),
        CLLocationCoordinate2D(latitude: 40.7100, longitude: -73.9800),
        CLLocationCoordinate2D(latitude: 40.7050, longitude: -73.9800),
        CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9800),
    ]
}

// MARK: - findStop Tests

@Suite("findStop – Stop ID normalization")
struct FindStopTests {

    @Test func exactMatchReturnsStop() {
        let stop = TripRouteClipping.findStop(
            in: ClipFixtures.q26Stops, id: "MTA_300003"
        )
        #expect(stop != nil)
        #expect(stop?.name == "Hillside Av / 180 St")
    }

    @Test func bareIdMatchesMTAPrefixed() {
        // Engine sends "300003", shape endpoint has "MTA_300003"
        let stop = TripRouteClipping.findStop(
            in: ClipFixtures.q26Stops, id: "300003"
        )
        #expect(stop != nil)
        #expect(stop?.id == "MTA_300003")
        #expect(stop?.name == "Hillside Av / 180 St")
    }

    @Test func prefixedIdMatchesBareStop() {
        // Engine sends "MTA_E03", stops have "E03"
        let stop = TripRouteClipping.findStop(
            in: ClipFixtures.eTrainStops, id: "MTA_E03"
        )
        #expect(stop != nil)
        #expect(stop?.name == "Parsons Blvd")
    }

    @Test func nameExactFallbackWorks() {
        // No ID match at all, fallback to name
        let stop = TripRouteClipping.findStop(
            in: ClipFixtures.q26Stops, id: "UNKNOWN_ID", name: "Hillside Av / 175 St"
        )
        #expect(stop != nil)
        #expect(stop?.id == "MTA_300002")
    }

    @Test func nameSubstringFallbackWorks() {
        // Partial name match (engine might send abbreviated name)
        let stop = TripRouteClipping.findStop(
            in: ClipFixtures.q26Stops, id: "UNKNOWN_ID", name: "Fresh Meadow"
        )
        #expect(stop != nil)
        #expect(stop?.id == "MTA_300008")
    }

    @Test func noMatchReturnsNil() {
        let stop = TripRouteClipping.findStop(
            in: ClipFixtures.q26Stops, id: "ZZZZZ", name: "Nonexistent Station"
        )
        #expect(stop == nil)
    }

    @Test func emptyStopsReturnsNil() {
        let stop = TripRouteClipping.findStop(in: [], id: "300000")
        #expect(stop == nil)
    }

    @Test func caseInsensitiveNameMatch() {
        let stop = TripRouteClipping.findStop(
            in: ClipFixtures.q26Stops, id: "UNKNOWN", name: "hillside av / 169 st"
        )
        #expect(stop != nil)
        #expect(stop?.id == "MTA_300001")
    }
}

// MARK: - clipShape Tests

@Suite("clipShape – Polyline clipping between stops")
struct ClipShapeTests {

    @Test func clipsToCorrectSegment() {
        // Board at stop 2, alight at stop 6 (indices 2..6 of the polyline)
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.q26Polyline],
            stops: ClipFixtures.q26Stops,
            boardStopId: "300002",     // bare ID
            alightStopId: "300006"     // bare ID
        )
        // Should contain 5 points (stops 2,3,4,5,6)
        #expect(clipped.count == 5)
        // First point should be near stop 2
        #expect(abs(clipped.first!.latitude - 40.7120) < 0.001)
        // Last point should be near stop 6
        #expect(abs(clipped.last!.latitude - 40.7280) < 0.001)
    }

    @Test func doesNotReturnFullRoute() {
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.q26Polyline],
            stops: ClipFixtures.q26Stops,
            boardStopId: "300002",
            alightStopId: "300006"
        )
        // Full route has 10 points; clipped segment should be shorter
        #expect(clipped.count < ClipFixtures.q26Polyline.count)
    }

    @Test func handlesExactMTAIds() {
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.q26Polyline],
            stops: ClipFixtures.q26Stops,
            boardStopId: "MTA_300001",
            alightStopId: "MTA_300004"
        )
        #expect(clipped.count == 4) // stops 1,2,3,4
        #expect(abs(clipped.first!.latitude - 40.7080) < 0.001)
        #expect(abs(clipped.last!.latitude - 40.7200) < 0.001)
    }

    @Test func fallsBackToNameWhenIdMissing() {
        // Supply stop names instead of IDs (simulating unknown IDs)
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.q26Polyline],
            stops: ClipFixtures.q26Stops,
            boardStopId: "FAKE_001",
            alightStopId: "FAKE_002",
            boardStopName: "Hillside Av / 175 St",
            alightStopName: "Hillside Av / 188 St"
        )
        // Should match stops 2 and 5 → 4 points
        #expect(clipped.count == 4)
    }

    @Test func nilBoardIdReturnsFirstPolyline() {
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.q26Polyline],
            stops: ClipFixtures.q26Stops,
            boardStopId: nil,
            alightStopId: "300005"
        )
        // Without board ID, returns entire first polyline
        #expect(clipped.count == ClipFixtures.q26Polyline.count)
    }

    @Test func emptyPolylinesReturnsEmpty() {
        let clipped = TripRouteClipping.clipShape(
            polylines: [],
            stops: ClipFixtures.q26Stops,
            boardStopId: "300002",
            alightStopId: "300006"
        )
        #expect(clipped.isEmpty)
    }

    @Test func shortPolylinesFiltered() {
        // A polyline with only 1 point should be filtered out
        let shortPoly = [CLLocationCoordinate2D(latitude: 40.7, longitude: -73.8)]
        let clipped = TripRouteClipping.clipShape(
            polylines: [shortPoly],
            stops: ClipFixtures.q26Stops,
            boardStopId: "300002",
            alightStopId: "300006"
        )
        #expect(clipped.isEmpty)
    }

    @Test func picksCorrectDirectionPolyline() {
        // Two polylines: direction A goes north, direction B goes south
        // Board at south stop (40.7050), alight at north stop (40.7150)
        // Should pick direction A since it has lower snap distance
        let stops = [
            BusStop(id: "S1", name: "South", lat: 40.7050, lon: -73.9800, direction: nil),
            BusStop(id: "S2", name: "North", lat: 40.7150, lon: -73.9800, direction: nil),
        ]
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.directionAPolyline, ClipFixtures.directionBPolyline],
            stops: stops,
            boardStopId: "S1",
            alightStopId: "S2"
        )
        #expect(!clipped.isEmpty)
        // Result should go south-to-north (ascending latitude)
        if clipped.count >= 2 {
            #expect(clipped.first!.latitude < clipped.last!.latitude)
        }
    }

    @Test func boardEqualsAlightReturnsFallback() {
        // Edge case: same board and alight stop → startIdx == endIdx → guard fails
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.eTrainPolyline],
            stops: ClipFixtures.eTrainStops,
            boardStopId: "E03",
            alightStopId: "E03"
        )
        // Falls back to returning the full polyline
        #expect(clipped.count == ClipFixtures.eTrainPolyline.count)
    }

    @Test func eTrainClipsCorrectly() {
        // Parsons Blvd (E03) to 34 St-Penn Station (E08)
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.eTrainPolyline],
            stops: ClipFixtures.eTrainStops,
            boardStopId: "E03",
            alightStopId: "E08"
        )
        // Should be stops E03 through E08 = 6 points
        #expect(clipped.count == 6)
        #expect(abs(clipped.first!.latitude - 40.7073) < 0.001)
        #expect(abs(clipped.last!.latitude - 40.7505) < 0.001)
    }

    @Test func clippedSegmentIsContinuous() {
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.q26Polyline],
            stops: ClipFixtures.q26Stops,
            boardStopId: "300001",
            alightStopId: "300007"
        )
        // Check no teleports — each pair of consecutive points is close
        for i in 1..<clipped.count {
            let dlat = abs(clipped[i].latitude - clipped[i-1].latitude)
            let dlon = abs(clipped[i].longitude - clipped[i-1].longitude)
            #expect(dlat < 0.01, "Latitude jump too large at index \(i)")
            #expect(dlon < 0.01, "Longitude jump too large at index \(i)")
        }
    }
}

// MARK: - nearestIndex Tests

@Suite("nearestIndex / nearestIndexWithDistance")
struct NearestIndexTests {

    @Test func findsExactMatch() {
        let target = CLLocationCoordinate2D(latitude: 40.7200, longitude: -73.7800)
        let idx = TripRouteClipping.nearestIndex(
            in: ClipFixtures.q26Polyline, to: target
        )
        #expect(idx == 4) // Stop index 4 is at (40.7200, -73.7800)
    }

    @Test func findsNearestWhenNotExact() {
        // Slightly off from stop 3's position
        let target = CLLocationCoordinate2D(latitude: 40.7162, longitude: -73.7828)
        let idx = TripRouteClipping.nearestIndex(
            in: ClipFixtures.q26Polyline, to: target
        )
        #expect(idx == 3) // Closest to stop index 3
    }

    @Test func emptyReturnsNil() {
        let idx = TripRouteClipping.nearestIndex(
            in: [],
            to: CLLocationCoordinate2D(latitude: 40.7, longitude: -73.8)
        )
        #expect(idx == nil)
    }

    @Test func withDistanceReturnsZeroForExact() {
        let target = ClipFixtures.q26Polyline[5] // Exact coordinate
        let result = TripRouteClipping.nearestIndexWithDistance(
            in: ClipFixtures.q26Polyline, to: target
        )
        #expect(result != nil)
        #expect(result!.index == 5)
        #expect(result!.distance < 1e-10)
    }

    @Test func withDistanceReturnsPositiveForNearby() {
        let target = CLLocationCoordinate2D(latitude: 40.7165, longitude: -73.7825)
        let result = TripRouteClipping.nearestIndexWithDistance(
            in: ClipFixtures.q26Polyline, to: target
        )
        #expect(result != nil)
        #expect(result!.distance > 0)
    }
}

// MARK: - resolveWalkCoords Tests

@Suite("resolveWalkCoords – Walk leg stitching")
struct ResolveWalkCoordsTests {

    // Helper to build results tuples
    private static func makeResults(
        _ items: [(Int, [CLLocationCoordinate2D]?, Bool)]
    ) -> [(Int, [CLLocationCoordinate2D]?, [[CLLocationCoordinate2D]]?, UIColor, Bool)] {
        items.map { ($0.0, $0.1, nil, UIColor.gray, $0.2) }
    }

    @Test func walkBetweenTwoTransitLegs() {
        let transitA = [
            CLLocationCoordinate2D(latitude: 40.7100, longitude: -73.7900),
            CLLocationCoordinate2D(latitude: 40.7200, longitude: -73.7800),
        ]
        let transitB = [
            CLLocationCoordinate2D(latitude: 40.7220, longitude: -73.7780),
            CLLocationCoordinate2D(latitude: 40.7300, longitude: -73.7700),
        ]

        let results = Self.makeResults([
            (0, transitA, false),
            (1, nil, true),        // walk leg
            (2, transitB, false),
        ])

        let walkCoords = TripRouteClipping.resolveWalkCoords(
            index: 1, results: results, legCount: 3
        )

        #expect(walkCoords.count == 2)
        // Start should be end of transit A
        #expect(abs(walkCoords[0].latitude - 40.7200) < 0.001)
        // End should be start of transit B
        #expect(abs(walkCoords[1].latitude - 40.7220) < 0.001)
    }

    @Test func walkAsFirstLeg() {
        let transitB = [
            CLLocationCoordinate2D(latitude: 40.7220, longitude: -73.7780),
            CLLocationCoordinate2D(latitude: 40.7300, longitude: -73.7700),
        ]

        let results = Self.makeResults([
            (0, nil, true),        // walk leg first
            (1, transitB, false),
        ])

        let walkCoords = TripRouteClipping.resolveWalkCoords(
            index: 0, results: results, legCount: 2
        )

        // No preceding transit → only has end coord (start of transit B)
        #expect(walkCoords.count == 1)
        #expect(abs(walkCoords[0].latitude - 40.7220) < 0.001)
    }

    @Test func walkAsLastLeg() {
        let transitA = [
            CLLocationCoordinate2D(latitude: 40.7100, longitude: -73.7900),
            CLLocationCoordinate2D(latitude: 40.7200, longitude: -73.7800),
        ]

        let results = Self.makeResults([
            (0, transitA, false),
            (1, nil, true),        // walk leg last
        ])

        let walkCoords = TripRouteClipping.resolveWalkCoords(
            index: 1, results: results, legCount: 2
        )

        // No following transit → only has start coord (end of transit A)
        #expect(walkCoords.count == 1)
        #expect(abs(walkCoords[0].latitude - 40.7200) < 0.001)
    }

    @Test func walkWithNoAdjacentTransit() {
        let results = Self.makeResults([
            (0, nil, true),  // walk only, no transit
        ])

        let walkCoords = TripRouteClipping.resolveWalkCoords(
            index: 0, results: results, legCount: 1
        )

        #expect(walkCoords.isEmpty)
    }

    @Test func multipleWalksBetweenTransit() {
        // transit → walk → walk → transit  (unusual but possible)
        let transitA = [
            CLLocationCoordinate2D(latitude: 40.7100, longitude: -73.7900),
            CLLocationCoordinate2D(latitude: 40.7200, longitude: -73.7800),
        ]
        let transitB = [
            CLLocationCoordinate2D(latitude: 40.7300, longitude: -73.7700),
            CLLocationCoordinate2D(latitude: 40.7400, longitude: -73.7600),
        ]

        let results = Self.makeResults([
            (0, transitA, false),
            (1, nil, true),
            (2, nil, true),
            (3, transitB, false),
        ])

        let walk1 = TripRouteClipping.resolveWalkCoords(
            index: 1, results: results, legCount: 4
        )
        let walk2 = TripRouteClipping.resolveWalkCoords(
            index: 2, results: results, legCount: 4
        )

        #expect(walk1.count == 2)
        // Walk 1 spans from end of transit A to start of transit B
        #expect(abs(walk1[0].latitude - 40.7200) < 0.001) // end of A
        #expect(abs(walk1[1].latitude - 40.7300) < 0.001) // start of B

        #expect(walk2.count == 2)
        // Walk 2 also spans from end of transit A to start of transit B
        #expect(abs(walk2[0].latitude - 40.7200) < 0.001)
        #expect(abs(walk2[1].latitude - 40.7300) < 0.001)
    }
}

// MARK: - Integration-style end-to-end clip tests

@Suite("End-to-end polyline clipping scenarios")
struct ClipIntegrationTests {

    @Test func busLegWithBareIdsClipsCorrectly() {
        // Simulates the exact Q26 bug: engine sends bare "300002"/"300006",
        // shape endpoint returns stops with "MTA_300002"/"MTA_300006".
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.q26Polyline],
            stops: ClipFixtures.q26Stops,
            boardStopId: "300002",   // bare GTFS ID
            alightStopId: "300006",  // bare GTFS ID
            boardStopName: "Hillside Av / 175 St",
            alightStopName: "Hillside Av / Francis Lewis"
        )

        // Must NOT return the whole polyline (10 points)
        #expect(clipped.count < ClipFixtures.q26Polyline.count,
                "Clipped result should be shorter than full route")
        // Should be exactly 5 points (stops 2 through 6)
        #expect(clipped.count == 5)
    }

    @Test func subwayLegClipsWithoutPrefix() {
        // Subway stops usually don't have MTA_ prefix
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.eTrainPolyline],
            stops: ClipFixtures.eTrainStops,
            boardStopId: "E03",
            alightStopId: "E08",
            boardStopName: "Parsons Blvd",
            alightStopName: "34 St-Penn Station"
        )

        #expect(clipped.count == 6)
        // Verify it starts at Parsons Blvd, not Jamaica Center
        #expect(abs(clipped.first!.latitude - 40.7073) < 0.001)
    }

    @Test func mixedIdFormatsResolveCorrectly() {
        // Board stop has MTA_ prefix in shape, alight stop has bare ID
        let mixedStops: [BusStop] = [
            BusStop(id: "MTA_100", name: "Stop A", lat: 40.700, lon: -73.900, direction: nil),
            BusStop(id: "MTA_200", name: "Stop B", lat: 40.710, lon: -73.900, direction: nil),
            BusStop(id: "300",     name: "Stop C", lat: 40.720, lon: -73.900, direction: nil),
        ]
        let poly: [CLLocationCoordinate2D] = mixedStops.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }

        // Board with bare ID (should match MTA_100), alight with bare (should match 300)
        let clipped = TripRouteClipping.clipShape(
            polylines: [poly],
            stops: mixedStops,
            boardStopId: "100",
            alightStopId: "300"
        )

        #expect(clipped.count == 3)
        #expect(abs(clipped.first!.latitude - 40.700) < 0.001)
        #expect(abs(clipped.last!.latitude - 40.720) < 0.001)
    }

    @Test func unmatchedIdsWithNamesFallBackCorrectly() {
        // IDs completely wrong but names are correct
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.eTrainPolyline],
            stops: ClipFixtures.eTrainStops,
            boardStopId: "WRONG_1",
            alightStopId: "WRONG_2",
            boardStopName: "Kew Gardens",
            alightStopName: "Jackson Heights"
        )

        // Should resolve via name: Kew Gardens (idx 4) to Jackson Heights (idx 6) = 3 points
        #expect(clipped.count == 3)
        #expect(abs(clipped.first!.latitude - 40.7140) < 0.001)
        #expect(abs(clipped.last!.latitude - 40.7467) < 0.001)
    }

    @Test func completelyUnmatchedReturnsFullPolyline() {
        // No ID match, no name match → graceful fallback
        let clipped = TripRouteClipping.clipShape(
            polylines: [ClipFixtures.eTrainPolyline],
            stops: ClipFixtures.eTrainStops,
            boardStopId: "TOTALLY_WRONG",
            alightStopId: "ALSO_WRONG",
            boardStopName: "Nonexistent Station",
            alightStopName: "Also Nonexistent"
        )

        // Falls back to returning entire first polyline
        #expect(clipped.count == ClipFixtures.eTrainPolyline.count)
    }
}

// MARK: - ClipStops tests (intermediate stop extraction)

@Suite("Clip stops extraction for station dots")
struct ClipStopsTests {

    @Test func extractsIntermediateStopsInclusive() {
        let stops = TripRouteClipping.clipStops(
            stops: ClipFixtures.q26Stops,
            boardStopId: "MTA_300002",
            alightStopId: "MTA_300006"
        )
        // Board (idx 2) to alight (idx 6) inclusive = 5 stops
        #expect(stops.count == 5)
        #expect(abs(stops.first!.latitude - 40.7120) < 0.001) // Stop 2
        #expect(abs(stops.last!.latitude - 40.7280) < 0.001)  // Stop 6
    }

    @Test func bareIdsResolveToMTAPrefixed() {
        // Same as Q26 bug scenario: engine sends bare IDs
        let stops = TripRouteClipping.clipStops(
            stops: ClipFixtures.q26Stops,
            boardStopId: "300002",
            alightStopId: "300006"
        )
        #expect(stops.count == 5)
    }

    @Test func subwayStopsExtractCorrectly() {
        let stops = TripRouteClipping.clipStops(
            stops: ClipFixtures.eTrainStops,
            boardStopId: "E03",
            alightStopId: "E08"
        )
        // E03 (idx 2) to E08 (idx 7) inclusive = 6 stops
        #expect(stops.count == 6)
        #expect(abs(stops.first!.latitude - 40.7073) < 0.001) // Parsons Blvd
        #expect(abs(stops.last!.latitude - 40.7505) < 0.001)  // 34 St-Penn
    }

    @Test func nameFallbackResolvesStops() {
        let stops = TripRouteClipping.clipStops(
            stops: ClipFixtures.eTrainStops,
            boardStopId: "WRONG_1",
            alightStopId: "WRONG_2",
            boardStopName: "Kew Gardens",
            alightStopName: "Jackson Heights"
        )
        // Kew Gardens (idx 4) to Jackson Heights (idx 6) = 3 stops
        #expect(stops.count == 3)
    }

    @Test func unmatchedReturnsEmpty() {
        let stops = TripRouteClipping.clipStops(
            stops: ClipFixtures.eTrainStops,
            boardStopId: "TOTALLY_WRONG",
            alightStopId: "ALSO_WRONG",
            boardStopName: "Nonexistent",
            alightStopName: "Also Nonexistent"
        )
        #expect(stops.isEmpty)
    }

    @Test func nilIdsReturnEmpty() {
        let stops = TripRouteClipping.clipStops(
            stops: ClipFixtures.q26Stops,
            boardStopId: nil,
            alightStopId: nil
        )
        #expect(stops.isEmpty)
    }

    @Test func singleStopRangeReturnsOne() {
        // Board and alight at same stop
        let stops = TripRouteClipping.clipStops(
            stops: ClipFixtures.eTrainStops,
            boardStopId: "E05",
            alightStopId: "E05"
        )
        #expect(stops.count == 1)
    }
}
