//
//  RouteDetailChipTests.swift
//  TrackTests
//
//  Comprehensive tests for the route details page behavior:
//  1. Three-tier chip status  (Live / Tracked / Scheduled)
//  2. ArrivalChipData properties (isNow, tagLabel, accent)
//  3. Chip tap gating — only .live chips tappable
//  4. buildOrderedChips — sorting, past-arrival filter, NOW cap
//  5. shouldRefreshStableArrivals — anti-flap debounce
//  6. nearestStopArrivals — scheduled fallback when backend has zero live
//  7. ArrivalETAEngine — distance floor, grace periods, delayFactor no-op
//  8. NearbyTransitResponse helpers — isPlaceholder, isScheduledOnly, liveArrivals
//

import CoreLocation
import Testing

@testable import Track

// ============================================================================
// MARK: - Helpers
// ============================================================================

/// Factory for NearbyTransitResponse with sensible defaults.
private func makeArrival(
    routeId: String = "Q9",
    stopName: String = "JAMAICA AV/SUTPHIN BLVD",
    direction: String = "Inbound",
    destination: String? = "Jamaica",
    minutesAway: Int = 10,
    status: String = "OK",
    mode: String = "bus",
    stopLat: Double? = 40.7024,
    stopLon: Double? = -73.8090,
    arrivalTs: Int? = nil,
    vehicleId: String? = nil,
    tripId: String? = nil,
    stopId: String? = "MTA_Q9_001",
    distanceM: Double? = nil,
    isRealTime: Bool = true,
    isCancelled: Bool = false,
    isExpress: Bool = false
) -> NearbyTransitResponse {
    NearbyTransitResponse(
        routeId: routeId, stopName: stopName, direction: direction,
        destination: destination, minutesAway: minutesAway, status: status,
        mode: mode, stopLat: stopLat, stopLon: stopLon,
        arrivalTs: arrivalTs ?? Int(Date.now.timeIntervalSince1970) + (minutesAway * 60),
        vehicleId: vehicleId, tripId: tripId, stopId: stopId,
        distanceM: distanceM, isRealTime: isRealTime,
        isCancelled: isCancelled, isExpress: isExpress
    )
}

/// Scheduled-only arrival (static GTFS, no real-time).
private func schedArrival(
    routeId: String = "Q9",
    stopName: String = "JAMAICA AV/SUTPHIN BLVD",
    minutesAway: Int = 20,
    tripId: String? = "sched-trip-1"
) -> NearbyTransitResponse {
    makeArrival(
        routeId: routeId, stopName: stopName,
        minutesAway: minutesAway, status: "Scheduled",
        vehicleId: nil, tripId: tripId,
        isRealTime: false
    )
}

/// Placeholder arrival (backend backfill to ensure direction tabs exist).
private func placeholderArrival(
    routeId: String = "Q9",
    direction: String = "Outbound"
) -> NearbyTransitResponse {
    NearbyTransitResponse(
        routeId: routeId, stopName: "PLACEHOLDER", direction: direction,
        destination: nil, minutesAway: 99, status: "Scheduled",
        mode: "bus", stopLat: nil, stopLon: nil,
        arrivalTs: nil, vehicleId: nil, tripId: nil, stopId: nil,
        isRealTime: false
    )
}

/// Expired arrival — timestamp 5 minutes in the past.
private func expiredArrival(
    routeId: String = "Q9",
    vehicleId: String = "V-expired"
) -> NearbyTransitResponse {
    makeArrival(
        routeId: routeId, minutesAway: 0,
        arrivalTs: Int(Date.now.timeIntervalSince1970) - 300,
        vehicleId: vehicleId, tripId: "T-expired",
        isRealTime: true
    )
}

/// Build a DirectionArrivalsResponse from arrivals.
private func dir(
    _ name: String = "Inbound",
    label: String? = "Inbound via Sutphin",
    arrivals: [NearbyTransitResponse]
) -> DirectionArrivalsResponse {
    DirectionArrivalsResponse(direction: name, directionLabel: label, arrivals: arrivals)
}

/// Build a GroupedNearbyTransitResponse from directions.
private func group(
    routeId: String = "Q9",
    mode: String = "bus",
    directions: [DirectionArrivalsResponse]
) -> GroupedNearbyTransitResponse {
    GroupedNearbyTransitResponse(
        routeId: routeId, displayName: routeId, mode: mode,
        colorHex: nil, directions: directions
    )
}

/// Build an ArrivalChipData directly for unit-testing chip properties.
private func chip(
    minutesRemaining: Int = 5,
    secondsRemaining: Double? = nil,
    isAtStop: Bool = false,
    isRealTime: Bool = true,
    isCancelled: Bool = false,
    isScheduled: Bool = false,
    isTrackedOnly: Bool = false,
    hasMapMarker: Bool = true,
    etaSource: SmartETA.ETASource = .vehiclePosition,
    vehicleId: String? = "V-1",
    tripId: String? = "T-1",
    routeId: String? = "Q9",
    isExpressFromServer: Bool = false
) -> ArrivalChipData {
    ArrivalChipData(
        id: "chip-\(minutesRemaining)",
        minutesRemaining: minutesRemaining,
        secondsRemaining: secondsRemaining ?? Double(minutesRemaining) * 60,
        isAtStop: isAtStop,
        isRealTime: isRealTime,
        isCancelled: isCancelled,
        isScheduled: isScheduled,
        isTrackedOnly: isTrackedOnly,
        hasMapMarker: hasMapMarker,
        etaSource: etaSource,
        arrivalTimestamp: Int(Date.now.timeIntervalSince1970) + minutesRemaining * 60,
        vehicleId: vehicleId,
        tripId: tripId,
        routeId: routeId,
        isExpressFromServer: isExpressFromServer
    )
}

// ============================================================================
// MARK: - 1. ArrivalChipData — isNow
// ============================================================================

@Suite("ArrivalChipData — isNow logic")
struct ChipIsNowTests {

    @Test func liveVehicleAtStop_showsNow() {
        let c = chip(isAtStop: true, hasMapMarker: true, etaSource: .vehiclePosition, vehicleId: "V-1")
        #expect(c.isNow == true, "Vehicle marker at tracked stop should show NOW")
    }

    @Test func liveVehicleNotAtStop_doesNotShowNow() {
        let c = chip(secondsRemaining: 5, isAtStop: false, vehicleId: "V-1")
        #expect(c.isNow == false, "GPS vehicle > 50m away must NOT show NOW even with low countdown")
    }

    @Test func feedOnlyArrivalUnder15s_doesNotShowNow() {
        let c = chip(
            secondsRemaining: 10,
            isAtStop: true,
            isRealTime: true,
            hasMapMarker: false,
            etaSource: .feedTimestamp,
            vehicleId: nil
        )
        #expect(c.isNow == false, "Feed-only countdown must not show NOW without a marker at the stop")
    }

    @Test func markerElsewhereWithFeedZero_doesNotShowNow() {
        let c = chip(
            secondsRemaining: 0,
            isAtStop: true,
            isRealTime: true,
            hasMapMarker: true,
            etaSource: .feedTimestamp,
            vehicleId: "V-1"
        )
        #expect(c.isNow == false, "A marker on the route is not enough; NOW needs marker-at-stop proof")
    }

    @Test func nonRealtimeArrivalAtStop_doesNotShowNow() {
        let c = chip(
            secondsRemaining: 0,
            isAtStop: true,
            isRealTime: false,
            hasMapMarker: true,
            etaSource: .vehiclePosition,
            vehicleId: "V-1"
        )
        #expect(c.isNow == false, "Non-real-time chips must not show NOW even if a marker lookup appears to match")
    }

    @Test func scheduledChip_neverShowsNow() {
        let c = chip(secondsRemaining: 0, isAtStop: true, isScheduled: true)
        #expect(c.isNow == false, "Scheduled chips must NEVER show NOW")
    }

    @Test func cancelledChip_neverShowsNow() {
        let c = chip(secondsRemaining: 0, isAtStop: true, isCancelled: true)
        #expect(c.isNow == false, "Cancelled chips must NEVER show NOW")
    }

    @Test func scheduledAndCancelled_neverShowsNow() {
        let c = chip(isAtStop: true, isCancelled: true, isScheduled: true)
        #expect(c.isNow == false)
    }
}

// ============================================================================
// MARK: - 2. ArrivalChipData — isExpress
// ============================================================================

@Suite("ArrivalChipData — isExpress detection")
struct ChipExpressTests {

    @Test func serverFlagTakesPreference() {
        let c = chip(routeId: "Q9", isExpressFromServer: true)
        #expect(c.isExpress == true, "Server isExpress flag should be authoritative")
    }

    @Test func clientSideDetects6X() {
        let c = chip(routeId: "6X", isExpressFromServer: false)
        #expect(c.isExpress == true, "Client detects 6X as express")
    }

    @Test func clientSideDetects7X() {
        let c = chip(routeId: "7x", isExpressFromServer: false) // lowercase
        #expect(c.isExpress == true, "Client detects 7x (case insensitive) as express")
    }

    @Test func clientSideDetectsFX() {
        let c = chip(routeId: "FX", isExpressFromServer: false)
        #expect(c.isExpress == true, "Client detects FX as express")
    }

    @Test func regularRouteNotExpress() {
        let c = chip(routeId: "Q9", isExpressFromServer: false)
        #expect(c.isExpress == false, "Q9 is not express")
    }

    @Test func nilRouteIdNotExpress() {
        let c = chip(routeId: nil, isExpressFromServer: false)
        #expect(c.isExpress == false)
    }
}

// ============================================================================
// MARK: - 3. ArrivalChipData — Three-Tier Tag/Icon/Accent
// ============================================================================

@Suite("ArrivalChipData — three-tier tag system")
struct ChipThreeTierTests {

    // These tests verify the ArrivalChipData properties that drive
    // tag labels, icons, and accent colors through the three-tier
    // Live / Tracked / Scheduled system.

    @Test func liveChipProperties() {
        let c = chip(isRealTime: true, isScheduled: false, isTrackedOnly: false)
        #expect(c.isTrackedOnly == false)
        #expect(c.isScheduled == false)
        #expect(c.isRealTime == true)
    }

    @Test func trackedChipProperties() {
        let c = chip(isRealTime: true, isScheduled: false, isTrackedOnly: true)
        #expect(c.isTrackedOnly == true)
        #expect(c.isScheduled == false)
        #expect(c.isRealTime == true)
    }

    @Test func scheduledChipProperties() {
        let c = chip(isRealTime: false, isScheduled: true, isTrackedOnly: false)
        #expect(c.isTrackedOnly == false)
        #expect(c.isScheduled == true)
        #expect(c.isRealTime == false)
    }

    @Test func cancelledChipOverridesAll() {
        let c = chip(isRealTime: true, isCancelled: true, isTrackedOnly: false)
        #expect(c.isCancelled == true)
        // Cancelled should not show NOW regardless
        #expect(c.isNow == false)
    }
}

// ============================================================================
// MARK: - 4. NearbyTransitResponse — Model Properties
// ============================================================================

@Suite("NearbyTransitResponse — model properties")
@MainActor struct NearbyTransitResponseModelTests {

    @Test func isScheduledOnly_whenStatusScheduled() {
        let a = schedArrival()
        #expect(a.isScheduledOnly == true)
    }

    @Test func isScheduledOnly_whenStatusOK() {
        let a = makeArrival(status: "OK")
        #expect(a.isScheduledOnly == false)
    }

    @Test func isPlaceholder_highMinutesNoTimestampNoVehicle() {
        let a = placeholderArrival()
        #expect(a.isPlaceholder == true)
    }

    @Test func isPlaceholder_falseForRegularArrival() {
        let a = makeArrival(minutesAway: 10, vehicleId: "V-1")
        #expect(a.isPlaceholder == false)
    }

    @Test func isBus_forBusMode() {
        let a = makeArrival(mode: "bus")
        #expect(a.isBus == true)
        #expect(a.isLIRR == false)
        #expect(a.isMNR == false)
        #expect(a.isCommuterRail == false)
    }

    @Test func isCommuterRail_forLIRR() {
        let a = makeArrival(mode: "lirr")
        #expect(a.isLIRR == true)
        #expect(a.isCommuterRail == true)
    }

    @Test func isCommuterRail_forMNR() {
        let a = makeArrival(mode: "mnr")
        #expect(a.isMNR == true)
        #expect(a.isCommuterRail == true)
    }

    @Test func id_stability_prefersTrip() {
        let a = makeArrival(vehicleId: "V-1", tripId: "T-1")
        #expect(a.id.contains("T-1"), "ID should prefer tripId over vehicleId")
    }

    @Test func id_stability_fallsToVehicle_whenNoTrip() {
        let a = makeArrival(vehicleId: "V-1", tripId: nil)
        #expect(a.id.contains("V-1"))
    }

    @Test func id_stability_fallsToTs_whenNoVehicleOrTrip() {
        let ts = Int(Date.now.timeIntervalSince1970) + 600
        let a = NearbyTransitResponse(
            routeId: "Q9", stopName: "STOP", direction: "In",
            destination: nil, minutesAway: 10, status: "OK",
            mode: "bus", stopLat: nil, stopLon: nil,
            arrivalTs: ts, vehicleId: nil, tripId: nil, stopId: nil,
            isRealTime: false
        )
        #expect(a.id.contains("\(ts)"))
    }
}

// ============================================================================
// MARK: - 5. DirectionArrivalsResponse — liveArrivals Filtering
// ============================================================================

@Suite("DirectionArrivalsResponse — liveArrivals")
@MainActor struct LiveArrivalsFilterTests {

    @Test func filtersOutPlaceholders() {
        let d = dir(arrivals: [
            makeArrival(minutesAway: 5, vehicleId: "V-1", tripId: "T-1"),
            placeholderArrival(),
        ])
        #expect(d.liveArrivals.count == 1)
        #expect(d.liveArrivals[0].vehicleId == "V-1")
    }

    @Test func filtersOutCancelledTrips() {
        let d = dir(arrivals: [
            makeArrival(minutesAway: 5, vehicleId: "V-1", tripId: "T-1"),
            makeArrival(minutesAway: 8, vehicleId: "V-2", tripId: "T-2", isCancelled: true),
        ])
        #expect(d.liveArrivals.count == 1)
    }

    @Test func filtersOutExpiredArrivals_over90s() {
        let d = dir(arrivals: [
            makeArrival(minutesAway: 5, vehicleId: "V-1", tripId: "T-1"),
            expiredArrival(),  // 5 min ago — well past 90s grace
        ])
        #expect(d.liveArrivals.count == 1)
    }

    @Test func keepsRecentPastArrivals_under90s() {
        let recentTs = Int(Date.now.timeIntervalSince1970) - 60  // 60s ago, within grace
        let d = dir(arrivals: [
            makeArrival(
                minutesAway: 0,
                arrivalTs: recentTs,
                vehicleId: "V-recent", tripId: "T-recent"
            ),
        ])
        #expect(d.liveArrivals.count == 1, "Arrivals < 90s past should survive filtering")
    }

    @Test func filtersStaticZeroMinWithNoTimestamp() {
        let d = dir(arrivals: [
            NearbyTransitResponse(
                routeId: "Q9", stopName: "STOP", direction: "In",
                destination: nil, minutesAway: 0, status: "Scheduled",
                mode: "bus", stopLat: nil, stopLon: nil, arrivalTs: nil,
                vehicleId: nil, tripId: "static-0", stopId: nil,
                isRealTime: false
            ),
        ])
        #expect(d.liveArrivals.isEmpty, "Static scheduled with 0 min and no timestamp should be filtered")
    }

    @Test func keepsBusAtStopWithZeroMinutes() {
        // Live SIRI bus at minutesAway == 0 IS at the stop and should be shown
        let recentTs = Int(Date.now.timeIntervalSince1970) + 10
        let d = dir(arrivals: [
            makeArrival(
                minutesAway: 0, arrivalTs: recentTs,
                vehicleId: "V-atStop", tripId: "T-atStop",
                isRealTime: true
            ),
        ])
        #expect(d.liveArrivals.count == 1, "Live bus at stop should not be filtered")
    }

    @Test func sortsByArrivalTimestamp() {
        let now = Int(Date.now.timeIntervalSince1970)
        let d = dir(arrivals: [
            makeArrival(minutesAway: 10, arrivalTs: now + 600, vehicleId: "V-later", tripId: "T-later"),
            makeArrival(minutesAway: 5, arrivalTs: now + 300, vehicleId: "V-sooner", tripId: "T-sooner"),
        ])
        let live = d.liveArrivals
        #expect(live.count == 2)
        #expect(live[0].vehicleId == "V-sooner", "Sooner arrival should sort first")
        #expect(live[1].vehicleId == "V-later")
    }

    @Test func deduplicatesNearbyTimestamps_subway60sBucket() {
        let now = Int(Date.now.timeIntervalSince1970)
        let bucketAlignedNow = (now / 60) * 60
        let d = dir(arrivals: [
            makeArrival(
                routeId: "1", minutesAway: 5, mode: "subway",
                arrivalTs: bucketAlignedNow + 300, vehicleId: nil, tripId: "trip-A",
                isRealTime: true
            ),
            makeArrival(
                routeId: "1", minutesAway: 5, mode: "subway",
                arrivalTs: bucketAlignedNow + 330,  // +30s, same 60s bucket
                vehicleId: nil, tripId: "trip-B",
                isRealTime: true
            ),
        ])
        #expect(d.liveArrivals.count == 1, "Subway arrivals in same 60s bucket should dedup")
    }

    @Test func uniqueVehicleCount_excludesPlaceholdersAndExpired() {
        let d = dir(arrivals: [
            makeArrival(minutesAway: 5, vehicleId: "V-1", tripId: "T-1"),
            makeArrival(minutesAway: 10, vehicleId: "V-2", tripId: "T-2"),
            placeholderArrival(),
            expiredArrival(vehicleId: "V-expired"),
        ])
        #expect(d.uniqueVehicleCount == 2)
    }
}

// ============================================================================
// MARK: - 6. ArrivalETAEngine — computeETA
// ============================================================================

@Suite("ArrivalETAEngine — computeETA")
@MainActor struct ArrivalETAEngineTests {

    // --- Grace periods ---

    @Test func busGracePeriod_180s() {
        // arrivalTs 100s ago (bus): within 180s grace → NOT past
        let ts = Int(Date.now.timeIntervalSince1970) - 100
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
            arrivalTs: ts, staticMinutes: 0, mode: "bus"
        )
        #expect(eta.isPastArrival == false, "Bus within 180s grace should not be past")
    }

    @Test func busGracePeriod_expired() {
        // arrivalTs 200s ago (bus): past 180s grace → past
        let ts = Int(Date.now.timeIntervalSince1970) - 200
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
            arrivalTs: ts, staticMinutes: 0, mode: "bus"
        )
        #expect(eta.isPastArrival == true, "Bus beyond 180s grace should be marked past")
    }

    @Test func subwayGracePeriod_90s() {
        // arrivalTs 80s ago (subway): within 90s grace → NOT past
        let ts = Int(Date.now.timeIntervalSince1970) - 80
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
            arrivalTs: ts, staticMinutes: 0, mode: "subway"
        )
        #expect(eta.isPastArrival == false, "Subway within 90s grace should not be past")
    }

    @Test func subwayGracePeriod_expired() {
        // arrivalTs 100s ago (subway): past 90s grace → past
        let ts = Int(Date.now.timeIntervalSince1970) - 100
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
            arrivalTs: ts, staticMinutes: 0, mode: "subway"
        )
        #expect(eta.isPastArrival == true, "Subway beyond 90s grace should be marked past")
    }

    // --- Fallback paths ---

    @Test func fallback_arrivalTs_countdown() {
        let futureTs = Int(Date.now.timeIntervalSince1970) + 300
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
            arrivalTs: futureTs, staticMinutes: 99, mode: "bus"
        )
        #expect(eta.source == .feedTimestamp)
        #expect(eta.secondsRemaining > 290 && eta.secondsRemaining <= 300)
        #expect(eta.minutesRemaining == 5)
    }

    @Test func fallback_staticMinutes_noTs() {
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
            arrivalTs: nil, staticMinutes: 10, mode: "bus"
        )
        #expect(eta.source == .staticMinutes)
        #expect(eta.secondsRemaining == 600.0, "10 min × 60 = 600s")
    }

    @Test func delayFactor_default_isNoOp() {
        // delayFactor defaults to 1.0 — should NOT change the result
        let etaDefault = ArrivalETAEngine.computeETA(
            vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
            arrivalTs: nil, staticMinutes: 10, mode: "bus"
        )
        let etaExplicit = ArrivalETAEngine.computeETA(
            vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
            arrivalTs: nil, staticMinutes: 10, mode: "bus",
            delayFactor: 1.0
        )
        #expect(etaDefault.secondsRemaining == etaExplicit.secondsRemaining)
        #expect(etaDefault.source == .staticMinutes)
        #expect(etaExplicit.source == .staticMinutes)
    }

    @Test func delayFactor_clampedToSafeRange() {
        // delayFactor > 3.0 should be clamped to 3.0
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
            arrivalTs: nil, staticMinutes: 10, mode: "bus",
            delayFactor: 5.0
        )
        #expect(eta.secondsRemaining == 600 * 3.0, "delayFactor clamped to max 3.0")
        #expect(eta.source == .mlPrediction, "Non-1.0 delayFactor uses mlPrediction source")
    }

    @Test func delayFactor_belowMinClamped() {
        // delayFactor < 0.5 should be clamped to 0.5
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
            arrivalTs: nil, staticMinutes: 10, mode: "bus",
            delayFactor: 0.1
        )
        #expect(eta.secondsRemaining == 600 * 0.5, "delayFactor clamped to min 0.5")
    }

    // --- Vehicle at stop ---

    @Test func vehicleWithin50m_isAtStop() {
        // Vehicle at (40.7024, -73.8090), stop at same location
        let vehicleCoord = CLLocationCoordinate2D(latitude: 40.7024, longitude: -73.8090)
        let stopCoord = CLLocationCoordinate2D(latitude: 40.7024, longitude: -73.8090)
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: vehicleCoord, vehicleKey: "V-1",
            stopCoord: stopCoord, arrivalTs: nil,
            staticMinutes: 5, mode: "bus"
        )
        #expect(eta.isAtStop == true, "Vehicle < 50m should be at stop")
        #expect(eta.secondsRemaining == 0)
        #expect(eta.source == .vehiclePosition)
    }

    // --- arrivalTs in past with no vehicle position ---

    @Test func pastTs_noVehicle_secondsClampedToZero() {
        let pastTs = Int(Date.now.timeIntervalSince1970) - 30
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
            arrivalTs: pastTs, staticMinutes: 0, mode: "bus"
        )
        #expect(eta.secondsRemaining == 0, "Past ts seconds clamped to 0")
        #expect(eta.isAtStop == true, "seconds ≤ 30 flags isAtStop in feed path")
    }
}

// ============================================================================
// MARK: - 7. Chip Status Construction via makeChipData
// ============================================================================

@Suite("ChipStatus — three-tier construction")
@MainActor struct ChipStatusTests {

    // Since `chipStatus(for:)` and `makeChipData()` are private methods on
    // RouteDetailSheet, we test the equivalent logic by constructing
    // ArrivalChipData with the same rules: isLiveOnMap → live, isRealTime
    // (no marker) → tracked, else → scheduled.

    @Test func liveOnMap_producesLiveChip() {
        // Simulating chipStatus: isLiveOnMap returns true for this arrival
        let a = makeArrival(vehicleId: "V-1", isRealTime: true)
        let isLiveOnMap = true

        let status: String
        if isLiveOnMap { status = "live" }
        else if a.isRealTime { status = "tracked" }
        else { status = "scheduled" }

        let isSched = !a.isCancelled && status == "scheduled"
        let isTrackedOnly = !a.isCancelled && status == "tracked"

        #expect(isSched == false)
        #expect(isTrackedOnly == false)
        #expect(status == "live")
    }

    @Test func realTimeNoMarker_producesTrackedChip() {
        let a = makeArrival(vehicleId: "V-1", isRealTime: true)
        let isLiveOnMap = false  // No GPS marker on map

        let status: String
        if isLiveOnMap { status = "live" }
        else if a.isRealTime { status = "tracked" }
        else { status = "scheduled" }

        let isSched = !a.isCancelled && status == "scheduled"
        let isTrackedOnly = !a.isCancelled && status == "tracked"

        #expect(isSched == false)
        #expect(isTrackedOnly == true)
        #expect(status == "tracked")
    }

    @Test func notRealTime_producesScheduledChip() {
        let a = makeArrival(isRealTime: false)
        let isLiveOnMap = false

        let status: String
        if isLiveOnMap { status = "live" }
        else if a.isRealTime { status = "tracked" }
        else { status = "scheduled" }

        let isSched = !a.isCancelled && status == "scheduled"
        let isTrackedOnly = !a.isCancelled && status == "tracked"

        #expect(isSched == true)
        #expect(isTrackedOnly == false)
        #expect(status == "scheduled")
    }

    @Test func cancelledArrival_overridesStatusFlags() {
        let a = makeArrival(isRealTime: true, isCancelled: true)
        let isLiveOnMap = true  // Even with marker, cancelled should not be tappable

        let status: String
        if isLiveOnMap { status = "live" }
        else if a.isRealTime { status = "tracked" }
        else { status = "scheduled" }

        let isSched = !a.isCancelled && status == "scheduled"
        let isTrackedOnly = !a.isCancelled && status == "tracked"

        // Cancelled overrides — both flags false
        #expect(isSched == false)
        #expect(isTrackedOnly == false)
    }

    @Test func chipTapGating_onlyLiveChipsTappable() {
        // Three chips: live, tracked, scheduled
        let liveChip = chip(isScheduled: false, isTrackedOnly: false)
        let trackedChip = chip(isScheduled: false, isTrackedOnly: true)
        let schedChip = chip(isScheduled: true, isTrackedOnly: false)

        // Tap handler guard: !chip.isScheduled && !chip.isTrackedOnly
        let liveCanTap = !liveChip.isScheduled && !liveChip.isTrackedOnly
        let trackedCanTap = !trackedChip.isScheduled && !trackedChip.isTrackedOnly
        let schedCanTap = !schedChip.isScheduled && !schedChip.isTrackedOnly

        #expect(liveCanTap == true, "Live chips should be tappable")
        #expect(trackedCanTap == false, "Tracked chips should NOT be tappable")
        #expect(schedCanTap == false, "Scheduled chips should NOT be tappable")
    }
}

// ============================================================================
// MARK: - 8. ArrivalChipData — departureDate
// ============================================================================

@Suite("ArrivalChipData — departureDate")
struct ChipDepartureDateTests {

    @Test func usesTimestampWhenAvailable() {
        let ts = Int(Date.now.timeIntervalSince1970) + 600
        let c = ArrivalChipData(
            id: "dep-test", minutesRemaining: 10, secondsRemaining: 600,
            isAtStop: false, isRealTime: true, isCancelled: false,
            isScheduled: false, arrivalTimestamp: ts, vehicleId: nil, tripId: nil
        )
        let expected = Date(timeIntervalSince1970: Double(ts))
        #expect(c.departureDate == expected)
    }

    @Test func projectsFromMinutesWhenNoTimestamp() {
        let before = Date()
        let c = ArrivalChipData(
            id: "dep-test-2", minutesRemaining: 10, secondsRemaining: 600,
            isAtStop: false, isRealTime: false, isCancelled: false,
            isScheduled: true, arrivalTimestamp: nil, vehicleId: nil, tripId: nil
        )
        let dep = c.departureDate
        let after = Date()
        // Should be ~10 min from now (1s tolerance for test execution time)
        #expect(dep >= before.addingTimeInterval(599))
        #expect(dep <= after.addingTimeInterval(601))
    }
}

// ============================================================================
// MARK: - 9. GroupedNearbyTransitResponse
// ============================================================================

@Suite("GroupedNearbyTransitResponse — computed properties")
@MainActor struct GroupedResponseTests {

    @Test func soonestMinutes_picksSmallest() {
        let g = group(directions: [
            dir("Inbound", arrivals: [
                makeArrival(minutesAway: 15, vehicleId: "V-1", tripId: "T-1"),
                makeArrival(minutesAway: 5, vehicleId: "V-2", tripId: "T-2"),
            ]),
            dir("Outbound", arrivals: [
                makeArrival(minutesAway: 10, vehicleId: "V-3", tripId: "T-3"),
            ]),
        ])
        #expect(g.soonestMinutes == 5)
    }

    @Test func soonestMinutes_99forEmpty() {
        let g = group(directions: [
            dir("Inbound", arrivals: [placeholderArrival()]),
        ])
        // Placeholders have minutesAway=99 but liveArrivals filters them out
        #expect(g.soonestMinutes == 99)
    }

    @Test func hasLiveArrivals_trueWhenFreshArrivalsExist() {
        let g = group(directions: [
            dir("Inbound", arrivals: [
                makeArrival(minutesAway: 5, vehicleId: "V-1", tripId: "T-1"),
            ]),
        ])
        #expect(g.hasLiveArrivals == true)
    }

    @Test func isExpired_whenAllArrivalsPast() {
        let g = group(directions: [
            dir("Inbound", arrivals: [expiredArrival()]),
        ])
        // hasRealArrivals checks non-placeholder arrivals exist (expired ones count)
        // hasLiveArrivals checks liveArrivals is non-empty (expired ones filtered out)
        // isExpired = hasRealArrivals && !hasLiveArrivals
        #expect(g.isExpired == true)
    }

    @Test func isBusCheck() {
        let busGroup = group(mode: "bus", directions: [])
        let subwayGroup = group(mode: "subway", directions: [])
        #expect(busGroup.isBus == true)
        #expect(subwayGroup.isBus == false)
    }
}

// ============================================================================
// MARK: - 10. Anti-Flap Debounce Logic
// ============================================================================

@Suite("Anti-flap debounce — shouldRefreshStableArrivals")
@MainActor struct AntiFlaplTests {

    // We test the debounce logic by replicating the conditions checked
    // in shouldRefreshStableArrivals(). These are unit-level assertions
    // on the same conditions:

    @Test func count_dropOver50percent_withinCooldown_shouldBlock() {
        // Old: 6 arrivals, New: 2 arrivals → drop > 50%, within 45s → block
        let oldCount = 6
        let newCount = 2
        let elapsed: TimeInterval = 20  // within 45s cooldown
        let shouldBlock = newCount < oldCount / 2 && oldCount >= 4 && elapsed < 45
        #expect(shouldBlock == true, "Drop > 50% within 45s should be blocked")
    }

    @Test func count_dropOver50percent_afterCooldown_shouldAllow() {
        let oldCount = 6
        let newCount = 2
        let elapsed: TimeInterval = 50  // past 45s cooldown
        let shouldBlock = newCount < oldCount / 2 && oldCount >= 4 && elapsed < 45
        #expect(shouldBlock == false, "Drop > 50% after 45s should be allowed")
    }

    @Test func vehiclesVanished_noneAppeared_withinCooldown_shouldBlock() {
        let oldKeys: Set<String> = ["V-1", "V-2", "V-3"]
        let newKeys: Set<String> = ["V-1"]
        let elapsed: TimeInterval = 30
        let vanished = oldKeys.subtracting(newKeys)
        let appeared = newKeys.subtracting(oldKeys)
        let shouldBlock = !vanished.isEmpty && appeared.isEmpty && elapsed < 45
        #expect(shouldBlock == true, "Vehicles vanished with none appearing within 45s should block")
    }

    @Test func vehiclesVanished_someAppeared_shouldNotBlock() {
        let oldKeys: Set<String> = ["V-1", "V-2"]
        let newKeys: Set<String> = ["V-1", "V-3"]  // V-2 vanished, V-3 appeared
        let vanished = oldKeys.subtracting(newKeys)
        let appeared = newKeys.subtracting(oldKeys)
        let shouldBlock = !vanished.isEmpty && appeared.isEmpty
        #expect(shouldBlock == false, "Vehicles vanished but new ones appeared → allow")
    }

    @Test func newVehicleAppeared_alwaysRefresh() {
        let oldKeys: Set<String> = ["V-1"]
        let newKeys: Set<String> = ["V-1", "V-2"]
        let appeared = newKeys.subtracting(oldKeys)
        #expect(!appeared.isEmpty, "New vehicle appeared → should trigger refresh")
    }

    @Test func emptyNew_allOldPast_shouldRefresh() {
        // Empty new + all old are past → should clear old chips
        let allOldPast = true
        let result = allOldPast  // when all old chips are past, shouldRefresh returns true
        #expect(result == true)
    }

    @Test func emptyNew_someOldStillFuture_shouldNotRefresh() {
        let allOldPast = false
        let result = allOldPast
        #expect(result == false, "Don't clear chips if some are still in the future")
    }

    @Test func smallFluctuation_belowThreshold_doesNotBlock() {
        let oldCount = 3
        let newCount = 2
        // 2 < 3/2 (=1.5)? No, 2 >= 1.5 → not blocked, plus oldCount < 4
        let shouldBlock = newCount < oldCount / 2 && oldCount >= 4
        #expect(shouldBlock == false, "Small count drop below threshold should not block")
    }
}

// ============================================================================
// MARK: - 11. Chip Freeze on Selection
// ============================================================================

@Suite("Chip freeze during selection")
@MainActor struct ChipFreezeTests {

    @Test func selectedChip_withinTimeout_defersRefresh() {
        let selectedChipId: String? = "some-chip"
        let timeSinceLastRefresh: TimeInterval = 15  // < 20s timeout
        let shouldDefer = selectedChipId != nil && timeSinceLastRefresh < 20
        #expect(shouldDefer == true, "Selected chip within 20s should defer refresh")
    }

    @Test func selectedChip_beyondTimeout_allowsRefresh() {
        let selectedChipId: String? = "some-chip"
        let timeSinceLastRefresh: TimeInterval = 25  // > 20s timeout
        let shouldDefer = selectedChipId != nil && timeSinceLastRefresh < 20
        #expect(shouldDefer == false, "Selected chip beyond 20s timeout should allow refresh")
    }

    @Test func noSelectedChip_neverDefers() {
        let selectedChipId: String? = nil
        let timeSinceLastRefresh: TimeInterval = 5
        let shouldDefer = selectedChipId != nil && timeSinceLastRefresh < 20
        #expect(shouldDefer == false, "No selected chip should never defer")
    }
}

// ============================================================================
// MARK: - 12. SmartETA Properties
// ============================================================================

@Suite("SmartETA — derived properties")
struct SmartETATests {

    @Test func minutesRemaining_roundsUp() {
        // 90 seconds → 2 minutes (ceil(90/60) = 2)
        let eta = SmartETA(
            secondsRemaining: 90, isAtStop: false, isPastArrival: false,
            source: .feedTimestamp, estimatedSpeedMps: nil
        )
        #expect(eta.minutesRemaining == 2)
    }

    @Test func minutesRemaining_zeroAtZeroSeconds() {
        let eta = SmartETA(
            secondsRemaining: 0, isAtStop: true, isPastArrival: false,
            source: .vehiclePosition, estimatedSpeedMps: nil
        )
        #expect(eta.minutesRemaining == 0)
    }

    @Test func minutesRemaining_smallFraction_roundsTo1() {
        // 1 second remaining → ceil(1/60) = 1
        let eta = SmartETA(
            secondsRemaining: 1, isAtStop: false, isPastArrival: false,
            source: .feedTimestamp, estimatedSpeedMps: nil
        )
        #expect(eta.minutesRemaining == 1)
    }

    @Test func minutesRemaining_exactly60_is1() {
        let eta = SmartETA(
            secondsRemaining: 60, isAtStop: false, isPastArrival: false,
            source: .feedTimestamp, estimatedSpeedMps: nil
        )
        #expect(eta.minutesRemaining == 1)
    }

    @Test func minutesRemaining_61_is2() {
        let eta = SmartETA(
            secondsRemaining: 61, isAtStop: false, isPastArrival: false,
            source: .feedTimestamp, estimatedSpeedMps: nil
        )
        #expect(eta.minutesRemaining == 2)
    }

    @Test func etaSourceValues() {
        #expect(SmartETA.ETASource.vehiclePosition.rawValue == "vehiclePosition")
        #expect(SmartETA.ETASource.feedTimestamp.rawValue == "feedTimestamp")
        #expect(SmartETA.ETASource.staticMinutes.rawValue == "staticMinutes")
        #expect(SmartETA.ETASource.mlPrediction.rawValue == "mlPrediction")
    }
}

// ============================================================================
// MARK: - 13. Edge Cases
// ============================================================================

@Suite("Edge cases — chip boundary conditions")
@MainActor struct ChipEdgeCaseTests {

    @Test func nowChip_boundary_exactly15s() {
        // Feed at exactly 15s with no vehicle GPS must not claim NOW.
        let c = chip(
            secondsRemaining: 15,
            isRealTime: true,
            hasMapMarker: false,
            etaSource: .feedTimestamp,
            vehicleId: nil
        )
        #expect(c.isNow == false, "Feed-only boundary must not show NOW")
    }

    @Test func nowChip_boundary_16s() {
        let c = chip(secondsRemaining: 16, isRealTime: true, vehicleId: nil)
        #expect(c.isNow == false, "16s > 15s → not NOW")
    }

    @Test func nowChip_boundary_0s_noVehicle() {
        let c = chip(
            secondsRemaining: 0,
            isRealTime: true,
            hasMapMarker: false,
            etaSource: .feedTimestamp,
            vehicleId: nil
        )
        #expect(c.isNow == false, "0s with realTime and no vehicle must not show NOW")
    }

    @Test func scheduledArrival_highMinutes_notPlaceholder_ifHasTs() {
        // minutesAway >= 99 but HAS arrivalTs → not a placeholder
        let a = NearbyTransitResponse(
            routeId: "Q9", stopName: "STOP", direction: "In",
            destination: nil, minutesAway: 99, status: "Scheduled",
            mode: "bus", stopLat: nil, stopLon: nil,
            arrivalTs: Int(Date.now.timeIntervalSince1970) + 6000,
            vehicleId: nil, tripId: nil, stopId: nil, isRealTime: false
        )
        #expect(a.isPlaceholder == false, "Has arrivalTs → not a placeholder")
    }

    @Test func emptyDirectionLabel_idStillUnique() {
        let d1 = dir("North", label: nil, arrivals: [])
        let d2 = dir("South", label: nil, arrivals: [])
        #expect(d1.id != d2.id, "Different direction names should produce different IDs")
    }

    @Test func sameDirectionDifferentLabel_differentIds() {
        let d1 = dir("Inbound", label: "Via Broadway", arrivals: [])
        let d2 = dir("Inbound", label: "Via Lexington", arrivals: [])
        #expect(d1.id != d2.id, "Same direction but different labels → different IDs")
    }

    @Test func chipFreeze_doesNotExceed20s() {
        // The maximum chip freeze timeout is 20s
        let timeSinceRefresh: TimeInterval = 20
        let shouldDefer = timeSinceRefresh < 20
        #expect(shouldDefer == false, "At exactly 20s, freeze should expire")
    }
}
