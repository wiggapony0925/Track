//
//  TransferPillOffsetTests.swift
//  TrackTests
//
//  Focused tests for the transfer-pill source-coordinate adjustment used
//  by the MapLibre system map. Transfer pills are point icons, so unlike
//  single-line station dots they must be shifted in source space to stay
//  visually centered on shared corridors as low-zoom lane offsets grow.
//

import CoreGraphics
import CoreLocation
import Testing
@testable import Track

private func haversineMeters(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D
) -> Double {
    let radiusMeters: Double = 6_371_000
    let dLat = (end.latitude - start.latitude) * .pi / 180.0
    let dLon = (end.longitude - start.longitude) * .pi / 180.0
    let lat1 = start.latitude * .pi / 180.0
    let lat2 = end.latitude * .pi / 180.0
    let sinLat = sin(dLat / 2.0)
    let sinLon = sin(dLon / 2.0)
    let h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
    return 2.0 * radiusMeters * asin(sqrt(h))
}

@Suite("Transfer pill corridor offset rendering")
struct TransferPillOffsetTests {

    private let base = CLLocationCoordinate2D(
        latitude: 40.7505,
        longitude: -73.9934
    )

    @Test("Positive northbound lane offset shifts the pill west")
    func positiveNorthboundLaneOffsetMovesWest() {
        let shifted = MapLibreMapView.Coordinator.visuallyOffsetTransferCoordinate(
            base,
            headingDegrees: 0.0,
            laneOffset: 1.0,
            zoom: 15.0
        )

        #expect(shifted.longitude < base.longitude)
        #expect(haversineMeters(from: base, to: shifted) > 0.1)
    }

    @Test("Negative northbound lane offset shifts the pill east")
    func negativeNorthboundLaneOffsetMovesEast() {
        let shifted = MapLibreMapView.Coordinator.visuallyOffsetTransferCoordinate(
            base,
            headingDegrees: 0.0,
            laneOffset: -1.0,
            zoom: 15.0
        )

        #expect(shifted.longitude > base.longitude)
        #expect(haversineMeters(from: base, to: shifted) > 0.1)
    }

    @Test("Positive eastbound lane offset shifts the pill north")
    func positiveEastboundLaneOffsetMovesNorth() {
        let shifted = MapLibreMapView.Coordinator.visuallyOffsetTransferCoordinate(
            base,
            headingDegrees: 90.0,
            laneOffset: 1.0,
            zoom: 15.0
        )

        #expect(shifted.latitude > base.latitude)
        #expect(haversineMeters(from: base, to: shifted) > 0.1)
    }

    @Test("Nil heading leaves the pill anchored")
    func nilHeadingLeavesCoordinateUnchanged() {
        let shifted = MapLibreMapView.Coordinator.visuallyOffsetTransferCoordinate(
            base,
            headingDegrees: nil,
            laneOffset: 1.0,
            zoom: 15.0
        )

        #expect(abs(shifted.latitude - base.latitude) < 1e-12)
        #expect(abs(shifted.longitude - base.longitude) < 1e-12)
    }

    @Test("Zero lane offset leaves the pill anchored")
    func zeroLaneOffsetLeavesCoordinateUnchanged() {
        let shifted = MapLibreMapView.Coordinator.visuallyOffsetTransferCoordinate(
            base,
            headingDegrees: 0.0,
            laneOffset: .zero,
            zoom: 15.0
        )

        #expect(abs(shifted.latitude - base.latitude) < 1e-12)
        #expect(abs(shifted.longitude - base.longitude) < 1e-12)
    }
}
