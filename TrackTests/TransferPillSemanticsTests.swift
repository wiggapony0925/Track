//
//  TransferPillSemanticsTests.swift
//  TrackTests
//
//  Regression tests for the white transfer-pill semantics.
//  A pill should mean "these routes share one local station footprint",
//  not "everything in the wider complex got merged together".
//

import CoreLocation
import Testing
@testable import Track

@Suite("Transfer pill complex clustering semantics")
struct TransferPillComplexClusteringTests {

    // Court Sq: underground G is a separate local stop footprint from
    // Court Sq-23 St (E/F), even though they share one complex.
    private let courtSqEF = CLLocationCoordinate2D(
        latitude: 40.747846,
        longitude: -73.946000
    )
    private let courtSqG = CLLocationCoordinate2D(
        latitude: 40.746554,
        longitude: -73.943832
    )

    // Lexington Av / 59 St / 63 St:
    // 4/5/6 and N/R/W share the 59 St footprint; 63 St should stay separate.
    private let lex59IRT = CLLocationCoordinate2D(
        latitude: 40.762526,
        longitude: -73.967967
    )
    private let lex59BMT = CLLocationCoordinate2D(
        latitude: 40.762660,
        longitude: -73.967258
    )
    private let lex63 = CLLocationCoordinate2D(
        latitude: 40.764629,
        longitude: -73.966113
    )

    // Times Sq: 1/2/3 and N/Q/R/W are close enough to read as one
    // local footprint at this zoomed-out system-map level.
    private let timesSq123 = CLLocationCoordinate2D(
        latitude: 40.755290,
        longitude: -73.987495
    )
    private let timesSqNQRW = CLLocationCoordinate2D(
        latitude: 40.754672,
        longitude: -73.986754
    )

    @Test("Court Sq underground platforms stay split")
    func courtSqUndergroundPlatformsStaySplit() {
        #expect(
            !MapSystemViewModel.sameStructureComplexStationsShouldMerge(
                courtSqEF,
                courtSqG
            )
        )
    }

    @Test("Lex 59 IRT and BMT still merge into one local footprint")
    func lex59LocalPlatformsStillMerge() {
        #expect(
            MapSystemViewModel.sameStructureComplexStationsShouldMerge(
                lex59IRT,
                lex59BMT
            )
        )
    }

    @Test("Lex 63 stays separate from the 59 St footprint")
    func lex63StaysSeparateFrom59StreetFootprint() {
        #expect(
            !MapSystemViewModel.sameStructureComplexStationsShouldMerge(
                lex59IRT,
                lex63
            )
        )
    }

    @Test("Times Sq 1/2/3 and N/Q/R/W still share one local footprint")
    func timesSquareStillMergesCorePlatforms() {
        #expect(
            MapSystemViewModel.sameStructureComplexStationsShouldMerge(
                timesSq123,
                timesSqNQRW
            )
        )
    }
}

@Suite("Transfer pill width semantics")
struct TransferPillWidthSemanticsTests {

    @Test("Crossing-only transfers stay compact but still read as pills")
    func crossingOnlyTransfersStayCompact() {
        let zoom = 15.0
        let rendered = MapLibreStyleConfig.transferPillRenderedWidthPoints(
            colorGroupCount: 3,
            corridorSpan: 0,
            zoom: zoom
        )
        let pillHeight = MapLibreStyleConfig.transferPillHeight
            * MapLibreStyleConfig.transferPillScale(at: zoom)
        let widenedThreshold = MapLibreStyleConfig.transferPillCorridorWidthPoints(
            corridorSpan: 1.0,
            zoom: zoom
        )

        #expect(rendered > pillHeight + 1e-6)
        #expect(rendered < widenedThreshold - 1e-6)
    }

    @Test("Parallel shared corridors widen the pill")
    func parallelSharedCorridorsWidenPill() {
        let zoom = 15.0
        let compact = MapLibreStyleConfig.transferPillRenderedWidthPoints(
            colorGroupCount: 2,
            corridorSpan: 0,
            zoom: zoom
        )
        let widened = MapLibreStyleConfig.transferPillRenderedWidthPoints(
            colorGroupCount: 2,
            corridorSpan: 1.5,
            zoom: zoom
        )
        let corridorWidth = MapLibreStyleConfig.transferPillCorridorWidthPoints(
            corridorSpan: 1.5,
            zoom: zoom
        )

        #expect(widened > compact)
        #expect(widened <= corridorWidth + 1e-6)
    }

    @Test("Width buckets grow monotonically with corridor span")
    func widthBucketsGrowMonotonically() {
        let small = MapLibreStyleConfig.transferPillBaseWidthBucket(
            colorGroupCount: 2,
            corridorSpan: 0.5,
            zoom: 16
        )
        let medium = MapLibreStyleConfig.transferPillBaseWidthBucket(
            colorGroupCount: 2,
            corridorSpan: 1.5,
            zoom: 16
        )
        let large = MapLibreStyleConfig.transferPillBaseWidthBucket(
            colorGroupCount: 2,
            corridorSpan: 2.5,
            zoom: 16
        )

        #expect(small <= medium)
        #expect(medium <= large)
    }
}
