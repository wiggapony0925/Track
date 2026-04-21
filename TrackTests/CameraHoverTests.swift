//
//  CameraHoverTests.swift
//  TrackTests
//
//  Tests for the AutomaticHover system:
//    1. HoverBounds — coordinate and distance clamping
//    2. CameraHoverEngine — target resolution and bounds enforcement
//    3. HoverTarget — equatability
//

import CoreLocation
import Foundation
import Testing
@testable import Track

// MARK: - Shared Test Coordinates

/// Grand Central Terminal — canonical NYC transit center.
private let kGrandCentral = CLLocationCoordinate2D(latitude: 40.7527, longitude: -73.9772)

/// Times Square — mid-Manhattan.
private let kTimesSquare = CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855)

/// Atlantic Terminal, Brooklyn — outer borough test point.
private let kAtlanticTerminal = CLLocationCoordinate2D(latitude: 40.6845, longitude: -73.9770)

/// Out-of-bounds point — middle of the Atlantic Ocean.
private let kAtlantic = CLLocationCoordinate2D(latitude: 30.0, longitude: -50.0)

/// Out-of-bounds point — upstate New York.
private let kUpstate = CLLocationCoordinate2D(latitude: 44.0, longitude: -75.0)

// MARK: - 1. HoverBounds Tests

@Suite("HoverBounds — coordinate clamping")
struct HoverBoundsCoordinateTests {

    @Test("Valid NYC coordinates pass through unchanged")
    func validCoordinateIsUnchanged() {
        let original = kGrandCentral
        let clamped = HoverBounds.clamp(original)
        #expect(
            abs(clamped.latitude - original.latitude) < 1e-9,
            "Latitude changed for in-bounds coordinate"
        )
        #expect(
            abs(clamped.longitude - original.longitude) < 1e-9,
            "Longitude changed for in-bounds coordinate"
        )
    }

    @Test("Out-of-bounds latitude is clamped to max")
    func latitudeClampedToMax() {
        let clamped = HoverBounds.clamp(kUpstate)
        #expect(clamped.latitude <= HoverBounds.maxLatitude)
        #expect(clamped.latitude >= HoverBounds.minLatitude)
    }

    @Test("Out-of-bounds lat/lon clamped to bounds corners")
    func oceanCoordinateClamped() {
        let clamped = HoverBounds.clamp(kAtlantic)
        #expect(clamped.latitude >= HoverBounds.minLatitude)
        #expect(clamped.latitude <= HoverBounds.maxLatitude)
        #expect(clamped.longitude >= HoverBounds.minLongitude)
        #expect(clamped.longitude <= HoverBounds.maxLongitude)
    }

    @Test("contains() is true for NYC coordinates")
    func containsNYCCoords() {
        #expect(HoverBounds.contains(kGrandCentral))
        #expect(HoverBounds.contains(kTimesSquare))
        #expect(HoverBounds.contains(kAtlanticTerminal))
    }

    @Test("contains() is false for out-of-bounds coordinates")
    func doesNotContainOutOfBounds() {
        #expect(!HoverBounds.contains(kAtlantic))
        #expect(!HoverBounds.contains(kUpstate))
    }
}

@Suite("HoverBounds — distance clamping")
struct HoverBoundsDistanceTests {

    @Test("Valid distance passes through unchanged")
    func validDistanceUnchanged() {
        let d = 3_000.0   // 3 km — typical user zoom
        #expect(HoverBounds.clamp(distance: d) == d)
    }

    @Test("Distance below min is clamped to minDistance")
    func tooCloseDistanceClamped() {
        let clamped = HoverBounds.clamp(distance: 10)   // 10 m — inside a building
        #expect(clamped == HoverBounds.minDistance)
    }

    @Test("Distance above max is clamped to maxDistance")
    func tooFarDistanceClamped() {
        let clamped = HoverBounds.clamp(distance: 500_000)  // 500 km
        #expect(clamped == HoverBounds.maxDistance)
    }

    @Test("distanceIsValid recognizes in-range distances")
    func validityCheck() {
        #expect(HoverBounds.distanceIsValid(500))
        #expect(HoverBounds.distanceIsValid(3_000))
        #expect(HoverBounds.distanceIsValid(50_000))
    }

    @Test("distanceIsValid rejects out-of-range distances")
    func invalidityCheck() {
        #expect(!HoverBounds.distanceIsValid(0))
        #expect(!HoverBounds.distanceIsValid(100))      // below min
        #expect(!HoverBounds.distanceIsValid(200_000))  // above max
    }
}

// MARK: - 2. CameraHoverEngine Tests

@Suite("CameraHoverEngine — coordinate target resolution")
struct CameraHoverEngineCoordinateTests {

    @Test("Resolving .coordinate returns a .camera position")
    func coordinateResolvesToCamera() {
        let pos = CameraHoverEngine.resolve(.coordinate(kGrandCentral))
        #expect(pos.camera != nil, ".coordinate should produce a .camera position")
    }

    @Test("Resolved coordinate matches the target (no spurious clamping for valid coord)")
    func resolvedCenterMatchesTarget() {
        let pos = CameraHoverEngine.resolve(.coordinate(kGrandCentral))
        guard let cam = pos.camera else {
            Issue.record("Expected .camera but got \(pos)")
            return
        }
        #expect(abs(cam.centerCoordinate.latitude - kGrandCentral.latitude) < 1e-6)
        #expect(abs(cam.centerCoordinate.longitude - kGrandCentral.longitude) < 1e-6)
    }

    @Test("Explicit distance is respected when within bounds")
    func explicitDistanceRespected() {
        let requested = 1_500.0
        let pos = CameraHoverEngine.resolve(.coordinate(kGrandCentral, distance: requested))
        #expect(pos.camera?.distance == requested)
    }

    @Test("Explicit distance below min is clamped")
    func tooCloseDistanceClamping() {
        let pos = CameraHoverEngine.resolve(.coordinate(kGrandCentral, distance: 5))
        #expect((pos.camera?.distance ?? 0) >= HoverBounds.minDistance)
    }

    @Test("Explicit distance above max is clamped")
    func tooFarDistanceClamping() {
        let pos = CameraHoverEngine.resolve(.coordinate(kGrandCentral, distance: 999_999))
        #expect((pos.camera?.distance ?? Double.infinity) <= HoverBounds.maxDistance)
    }
}

@Suite("CameraHoverEngine — out-of-bounds clamping")
struct CameraHoverEngineClampTests {

    @Test("Out-of-bounds center is clamped to NYC metro")
    func outOfBoundsCenterClamped() {
        let pos = CameraHoverEngine.resolve(.coordinate(kAtlantic))
        guard let cam = pos.camera else {
            Issue.record("Expected .camera")
            return
        }
        #expect(cam.centerCoordinate.latitude >= HoverBounds.minLatitude)
        #expect(cam.centerCoordinate.latitude <= HoverBounds.maxLatitude)
        #expect(cam.centerCoordinate.longitude >= HoverBounds.minLongitude)
        #expect(cam.centerCoordinate.longitude <= HoverBounds.maxLongitude)
    }
}

@Suite("CameraHoverEngine — special targets")
struct CameraHoverEngineSpecialTests {

    @Test(".userLocation resolves to .userLocation (no camera wrapping)")
    func userLocationPassthrough() {
        let pos = CameraHoverEngine.resolve(.userLocation)
        // .userLocation is renderer-managed — should NOT become a .camera case
        if case .userLocation = pos {
            // pass
        } else {
            Issue.record("Expected .userLocation, got \(pos)")
        }
    }

    @Test(".vehicle produces a tighter zoom than .coordinate default")
    func vehicleZoomIsTighter() {
        let vehiclePos = CameraHoverEngine.resolve(.vehicle(at: kGrandCentral))
        let defaultPos = CameraHoverEngine.resolve(.coordinate(kGrandCentral))
        let vehicleDist = vehiclePos.camera?.distance ?? Double.infinity
        let defaultDist = defaultPos.camera?.distance ?? 0
        #expect(vehicleDist < defaultDist, "Vehicle hover should zoom in closer than default")
    }

    @Test(".fitTwo centers on midpoint")
    func fitTwoCentersOnMidpoint() {
        let from = kGrandCentral
        let to = kAtlanticTerminal
        let expectedLat = (from.latitude + to.latitude) / 2
        let expectedLon = (from.longitude + to.longitude) / 2
        let pos = CameraHoverEngine.resolve(.fitTwo(from: from, to: to))
        guard let cam = pos.camera else {
            Issue.record("Expected .camera")
            return
        }
        #expect(abs(cam.centerCoordinate.latitude - expectedLat) < 1e-5)
        #expect(abs(cam.centerCoordinate.longitude - expectedLon) < 1e-5)
    }

    @Test(".fitTwo wider source produces higher altitude")
    func fitTwoScalesWithDistance() {
        let nearby = CameraHoverEngine.resolve(.fitTwo(from: kGrandCentral, to: kTimesSquare))
        let farAway = CameraHoverEngine.resolve(.fitTwo(from: kGrandCentral, to: kAtlanticTerminal))
        let nearbyDist = nearby.camera?.distance ?? 0
        let farDist = farAway.camera?.distance ?? 0
        #expect(farDist > nearbyDist, "Wider span should produce greater altitude")
    }

    @Test(".walkingPath closer stops produce lower altitude")
    func walkingPathCloserIsLower() {
        // Times Sq and GCT are ~0.8 km apart — should produce a tighter zoom
        // than GCT and Atlantic Terminal (~7 km apart).
        let close = CameraHoverEngine.resolve(.walkingPath(user: kTimesSquare, stop: kGrandCentral))
        let far   = CameraHoverEngine.resolve(.walkingPath(user: kGrandCentral, stop: kAtlanticTerminal))
        #expect((close.camera?.distance ?? 0) < (far.camera?.distance ?? Double.infinity))
    }
}

// MARK: - 3. HoverTarget Equatability Tests

@Suite("HoverTarget — equatability")
struct HoverTargetEquatabilityTests {

    @Test("Same coordinate targets are equal")
    func sameCoordinatesEqual() {
        let a = HoverTarget.coordinate(kGrandCentral)
        let b = HoverTarget.coordinate(kGrandCentral)
        #expect(a == b)
    }

    @Test("Different coordinate targets are not equal")
    func differentCoordinatesNotEqual() {
        let a = HoverTarget.coordinate(kGrandCentral)
        let b = HoverTarget.coordinate(kTimesSquare)
        #expect(a != b)
    }

    @Test(".userLocation equals itself")
    func userLocationSelfEqual() {
        #expect(HoverTarget.userLocation == HoverTarget.userLocation)
    }

    @Test(".nyc equals itself")
    func nycSelfEqual() {
        #expect(HoverTarget.nyc == HoverTarget.nyc)
    }

    @Test("Different case targets are not equal")
    func differentCasesNotEqual() {
        #expect(HoverTarget.nyc != HoverTarget.userLocation)
        #expect(HoverTarget.coordinate(kGrandCentral) != HoverTarget.vehicle(at: kGrandCentral))
    }
}
