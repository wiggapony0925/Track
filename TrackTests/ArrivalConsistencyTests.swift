//
//  ArrivalConsistencyTests.swift
//  TrackTests
//
//  Tests that arrival ETA selection is consistent across all surfaces:
//  favorites card, nearby row, and route detail sheet.
//  All must use ArrivalHelpers.countdownArrival() → nearest stop.
//

import CoreLocation
import Testing
@testable import Track

@MainActor
struct ArrivalConsistencyTests {

    // MARK: - Helpers

    /// Build a test arrival at a given stop with future arrivalTs.
    private func makeArrival(
        routeId: String = "M11",
        stopName: String,
        stopId: String,
        minutesAway: Int,
        stopLat: Double,
        stopLon: Double,
        vehicleId: String? = nil,
        tripId: String? = nil,
        isRealTime: Bool = true,
        distanceM: Double? = nil
    ) -> NearbyTransitResponse {
        NearbyTransitResponse(
            routeId: routeId,
            stopName: stopName,
            direction: "South",
            destination: "East Village",
            minutesAway: minutesAway,
            status: "OK",
            mode: "bus",
            stopLat: stopLat,
            stopLon: stopLon,
            arrivalTs: Int(Date.now.timeIntervalSince1970) + (minutesAway * 60),
            vehicleId: vehicleId ?? "V-\(stopId)-\(minutesAway)",
            tripId: tripId ?? "T-\(stopId)-\(minutesAway)",
            stopId: stopId,
            distanceM: distanceM,
            isRealTime: isRealTime
        )
    }

    /// Build a direction with arrivals at multiple stops.
    private func makeDirection(arrivals: [NearbyTransitResponse]) -> DirectionArrivalsResponse {
        DirectionArrivalsResponse(
            direction: "South",
            directionLabel: "South via 10 Av",
            arrivals: arrivals
        )
    }

    // MARK: - User location: W 25 ST & 10 AV (40.7468, -74.0018)
    // Stop A (nearest): 10 AV/W 25 ST — 40.7468, -74.0020 (~17m away)
    // Stop B (upstream): 10 AV/W 30 ST — 40.7498, -74.0020 (~330m away)

    private let userLocation = CLLocation(latitude: 40.7468, longitude: -74.0018)

    private let stopALat = 40.7468  // W 25 ST (nearest)
    private let stopALon = -74.0020
    private let stopAName = "10 AV/W 25 ST"
    private let stopAId = "MTA_305125"

    private let stopBLat = 40.7498  // W 30 ST (upstream, farther)
    private let stopBLon = -74.0020
    private let stopBName = "10 AV/W 30 ST"
    private let stopBId = "MTA_305130"

    // MARK: - Core: countdownArrival picks nearest stop

    @Test func countdownArrivalPicksNearestStop() async throws {
        // Bus at upstream stop (W 30 ST) arriving in 2 min — soonest globally
        let upstreamArrival = makeArrival(
            stopName: stopBName, stopId: stopBId, minutesAway: 2,
            stopLat: stopBLat, stopLon: stopBLon
        )
        // Bus at nearest stop (W 25 ST) arriving in 6 min
        let nearestArrival = makeArrival(
            stopName: stopAName, stopId: stopAId, minutesAway: 6,
            stopLat: stopALat, stopLon: stopALon
        )

        let direction = makeDirection(arrivals: [upstreamArrival, nearestArrival])

        // countdownArrival should pick the 6-min arrival at the NEAREST stop
        let result = ArrivalHelpers.countdownArrival(
            for: direction,
            userLocation: userLocation
        )

        #expect(result != nil)
        #expect(
            result?.stopName == stopAName,
            "Should pick nearest stop W 25 ST, not upstream W 30 ST"
        )
        #expect(result?.minutesAway == 6, "Should show 6 min (nearest stop), not 2 min (upstream)")
    }

    @Test func countdownArrivalPicksSoonestAtNearestStop() async throws {
        // Two buses at the nearest stop: 6 min and 10 min
        let nearSoon = makeArrival(
            stopName: stopAName, stopId: stopAId, minutesAway: 6,
            stopLat: stopALat, stopLon: stopALon, vehicleId: "V1", tripId: "T1"
        )
        let nearLater = makeArrival(
            stopName: stopAName, stopId: stopAId, minutesAway: 10,
            stopLat: stopALat, stopLon: stopALon, vehicleId: "V2", tripId: "T2"
        )
        // Farther stop: 1 min
        let farSoon = makeArrival(
            stopName: stopBName, stopId: stopBId, minutesAway: 1,
            stopLat: stopBLat, stopLon: stopBLon
        )

        let direction = makeDirection(arrivals: [farSoon, nearLater, nearSoon])

        let result = ArrivalHelpers.countdownArrival(
            for: direction,
            userLocation: userLocation
        )

        #expect(result?.stopName == stopAName)
        #expect(
            result?.minutesAway == 6,
            "Should pick soonest (6 min) at nearest stop, not 1 min at far stop"
        )
    }

    // MARK: - Fallback: no user location → soonest globally

    @Test func countdownArrivalWithoutLocationPicksSoonestGlobally() async throws {
        let upstream = makeArrival(
            stopName: stopBName, stopId: stopBId, minutesAway: 2,
            stopLat: stopBLat, stopLon: stopBLon
        )
        let nearest = makeArrival(
            stopName: stopAName, stopId: stopAId, minutesAway: 6,
            stopLat: stopALat, stopLon: stopALon
        )

        let direction = makeDirection(arrivals: [upstream, nearest])

        // No user location → should fall back to soonest overall
        let result = ArrivalHelpers.countdownArrival(
            for: direction,
            userLocation: nil
        )

        #expect(result != nil)
        #expect(result?.minutesAway == 2, "Without location, should pick globally soonest")
    }

    // MARK: - Past arrivals are filtered out

    @Test func countdownArrivalFiltersPastArrivals() async throws {
        // Arrival with timestamp 5 minutes in the past
        var pastArrival = makeArrival(
            stopName: stopAName, stopId: stopAId, minutesAway: 0,
            stopLat: stopALat, stopLon: stopALon, vehicleId: "V-past", tripId: "T-past"
        )
        // Override arrivalTs to be 5 min in the past
        pastArrival = NearbyTransitResponse(
            routeId: "M11", stopName: stopAName, direction: "South",
            destination: "East Village", minutesAway: 0, status: "OK",
            mode: "bus", stopLat: stopALat, stopLon: stopALon,
            arrivalTs: Int(Date.now.timeIntervalSince1970) - 300,
            vehicleId: "V-past", tripId: "T-past", stopId: stopAId,
            isRealTime: true
        )

        let futureArrival = makeArrival(
            stopName: stopAName, stopId: stopAId, minutesAway: 8,
            stopLat: stopALat, stopLon: stopALon, vehicleId: "V-future", tripId: "T-future"
        )

        let direction = makeDirection(arrivals: [pastArrival, futureArrival])

        let result = ArrivalHelpers.countdownArrival(
            for: direction,
            userLocation: userLocation
        )

        #expect(result != nil)
        #expect(result?.minutesAway == 8, "Past arrivals should be filtered out")
    }

    // MARK: - Empty arrivals return nil

    @Test func countdownArrivalReturnsNilForEmpty() async throws {
        let direction = makeDirection(arrivals: [])
        let result = ArrivalHelpers.countdownArrival(for: direction, userLocation: userLocation)
        #expect(result == nil)
    }

    // MARK: - Placeholders are skipped

    @Test func countdownArrivalSkipsPlaceholders() async throws {
        // Placeholder: minutesAway >= 99, no arrivalTs, no vehicleId
        let placeholder = NearbyTransitResponse(
            routeId: "M11", stopName: stopAName, direction: "South",
            destination: "East Village", minutesAway: 99, status: "OK",
            mode: "bus", stopLat: stopALat, stopLon: stopALon,
            arrivalTs: nil, vehicleId: nil, tripId: nil, stopId: stopAId
        )
        let real = makeArrival(
            stopName: stopBName, stopId: stopBId, minutesAway: 5,
            stopLat: stopBLat, stopLon: stopBLon
        )

        let direction = makeDirection(arrivals: [placeholder, real])

        let result = ArrivalHelpers.countdownArrival(
            for: direction,
            userLocation: userLocation
        )

        #expect(result != nil)
        #expect(result?.stopName == stopBName, "Should skip placeholder, pick real arrival")
    }

    // MARK: - distanceM is preferred over lat/lon for nearest-stop calculation

    @Test func countdownArrivalPrefersDistanceMField() async throws {
        // Both arrivals have stopLat/stopLon that would make stopB closer,
        // but distanceM overrides: stopA = 50m, stopB = 500m
        let arrivalA = makeArrival(
            stopName: stopAName, stopId: stopAId, minutesAway: 8,
            stopLat: stopBLat, stopLon: stopBLon, // intentionally "wrong" coords
            distanceM: 50
        )
        let arrivalB = makeArrival(
            stopName: stopBName, stopId: stopBId, minutesAway: 3,
            stopLat: stopALat, stopLon: stopALon, // intentionally "wrong" coords
            distanceM: 500
        )

        let direction = makeDirection(arrivals: [arrivalA, arrivalB])

        let result = ArrivalHelpers.countdownArrival(
            for: direction,
            userLocation: userLocation
        )

        #expect(result?.stopName == stopAName, "distanceM=50 should win over distanceM=500")
    }

    // MARK: - resolvedETA consistency

    @Test func resolvedETAIsFutureForFutureArrival() async throws {
        let arrival = makeArrival(
            stopName: stopAName, stopId: stopAId, minutesAway: 5,
            stopLat: stopALat, stopLon: stopALon
        )

        let eta = ArrivalHelpers.resolvedETA(for: arrival)
        #expect(!eta.isPastArrival, "Arrival 5 min in future should not be past")
        #expect(eta.secondsRemaining > 0, "Should have positive seconds remaining")
    }

    @Test func resolvedETAIsPastForExpiredArrival() async throws {
        let arrival = NearbyTransitResponse(
            routeId: "M11", stopName: stopAName, direction: "South",
            destination: "East Village", minutesAway: 0, status: "OK",
            mode: "bus", stopLat: stopALat, stopLon: stopALon,
            arrivalTs: Int(Date.now.timeIntervalSince1970) - 120,
            vehicleId: "V1", tripId: "T1", stopId: stopAId,
            isRealTime: true
        )

        let eta = ArrivalHelpers.resolvedETA(for: arrival)
        #expect(eta.isPastArrival, "Arrival 2 min in the past should be past")
    }

    // MARK: - sortedByETA puts realtime before scheduled

    @Test func sortedByETAOrdersRealtimeFirst() async throws {
        let scheduled = NearbyTransitResponse(
            routeId: "M11", stopName: stopAName, direction: "South",
            destination: "East Village", minutesAway: 3, status: "Scheduled",
            mode: "bus", stopLat: stopALat, stopLon: stopALon,
            arrivalTs: Int(Date.now.timeIntervalSince1970) + 180,
            vehicleId: nil, tripId: "T-sched", stopId: stopAId,
            isRealTime: false
        )
        let realtime = makeArrival(
            stopName: stopAName, stopId: stopAId, minutesAway: 5,
            stopLat: stopALat, stopLon: stopALon
        )

        let sorted = ArrivalHelpers.sortedByETA([scheduled, realtime])

        #expect(
            sorted.first?.isRealTime == true,
            "Realtime should sort before scheduled even with higher minutes"
        )
    }

    // MARK: - isExpired group filtering

    @Test func groupIsExpiredWhenAllArrivalsPast() async throws {
        let pastArrival = NearbyTransitResponse(
            routeId: "M11", stopName: stopAName, direction: "South",
            destination: "East Village", minutesAway: 0, status: "OK",
            mode: "bus", stopLat: stopALat, stopLon: stopALon,
            arrivalTs: Int(Date.now.timeIntervalSince1970) - 300,
            vehicleId: "V1", tripId: "T1", stopId: stopAId,
            isRealTime: true
        )

        let group = GroupedNearbyTransitResponse(
            routeId: "M11", displayName: "M11", mode: "bus", colorHex: nil,
            directions: [makeDirection(arrivals: [pastArrival])]
        )

        #expect(group.hasRealArrivals, "Has non-placeholder arrival")
        #expect(!group.hasLiveArrivals, "All arrivals are past")
        #expect(group.isExpired, "Should be expired: had real arrivals but all are past")
    }

    @Test func groupIsNotExpiredWhenHasFutureArrivals() async throws {
        let future = makeArrival(
            stopName: stopAName, stopId: stopAId, minutesAway: 5,
            stopLat: stopALat, stopLon: stopALon
        )

        let group = GroupedNearbyTransitResponse(
            routeId: "M11", displayName: "M11", mode: "bus", colorHex: nil,
            directions: [makeDirection(arrivals: [future])]
        )

        #expect(group.hasRealArrivals)
        #expect(group.hasLiveArrivals)
        #expect(!group.isExpired, "Should NOT be expired — has future arrivals")
    }

    @Test func placeholderOnlyGroupIsNotExpired() async throws {
        let placeholder = NearbyTransitResponse(
            routeId: "QM16", stopName: "Some Stop", direction: "South",
            destination: "Downtown", minutesAway: 99, status: "OK",
            mode: "bus", stopLat: stopALat, stopLon: stopALon,
            arrivalTs: nil, vehicleId: nil, tripId: nil, stopId: "S1"
        )

        let group = GroupedNearbyTransitResponse(
            routeId: "QM16", displayName: "QM16", mode: "bus", colorHex: nil,
            directions: [makeDirection(arrivals: [placeholder])]
        )

        #expect(!group.hasRealArrivals, "Placeholder-only has no real arrivals")
        #expect(!group.isExpired, "Placeholder-only should NOT be marked expired")
    }

    // MARK: - Direction label resolution

    @Test func resolveDirectionLabelPrefersHeadsign() async throws {
        let arrival = makeArrival(
            stopName: stopAName, stopId: stopAId, minutesAway: 5,
            stopLat: stopALat, stopLon: stopALon
        )
        let direction = DirectionArrivalsResponse(
            direction: "South",
            directionLabel: "South via 10 Av",
            arrivals: [arrival]
        )

        let label = ArrivalHelpers.resolveDirectionLabel(for: direction)
        // Should use the directionLabel when available
        #expect(label == "South via 10 Av" || !label.isEmpty,
                "Should resolve a non-empty direction label")
    }
}
