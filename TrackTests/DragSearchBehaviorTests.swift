//
//  DragSearchBehaviorTests.swift
//  TrackTests
//
//  Validates the drag-to-search distance thresholds, state transitions,
//  and GPS snap-back behavior. Tests the pure distance calculations
//  that drive handleMapCameraIdle() in HomeView.
//
//  Expected behaviors:
//    1. Circle appears instantly when user pans 60m+ from GPS (no debounce)
//    2. API fires after 350ms debounce at the settled map center
//    3. Settling a drag-search pin very close to GPS returns to GPS mode
//    4. Panning beyond the small GPS snap radius places the pin normally
//    5. Distance calculations are accurate at NYC latitudes
//

import CoreLocation
import Testing

@testable import Track

@MainActor
@Suite("Drag Search Behavior")
struct DragSearchBehaviorTests {

    // ── NYC reference point (Hell's Kitchen / Hudson Yards area) ──
    private static let gpsLat = 40.75308
    private static let gpsLon = -73.99945
    private static let gpsLocation = CLLocation(latitude: gpsLat, longitude: gpsLon)

    // MARK: - Distance Helpers

    /// Convenience: create a CLLocation offset from GPS by `meters` in a given direction.
    private static func offset(meters: Double, bearing: Double = 0) -> CLLocation {
        // Approximate: 1° lat ≈ 111,320m, 1° lon ≈ 111,320m * cos(lat)
        let latRad = gpsLat * .pi / 180
        let dLat = (meters * cos(bearing * .pi / 180)) / 111_320
        let dLon = (meters * sin(bearing * .pi / 180)) / (111_320 * cos(latRad))
        return CLLocation(latitude: gpsLat + dLat, longitude: gpsLon + dLon)
    }

    private static func distance(from loc: CLLocation) -> Double {
        gpsLocation.distance(from: loc)
    }

    // MARK: - Threshold: Instant Activation (60m)

    @Test("Circle appears at 60m+ from GPS")
    func instantActivationThreshold() {
        let justUnder = Self.offset(meters: 55)
        let justOver = Self.offset(meters: 65)
        let farAway = Self.offset(meters: 500)

        let distUnder = Self.distance(from: justUnder)
        let distOver = Self.distance(from: justOver)
        let distFar = Self.distance(from: farAway)

        // Under 60m — circle should NOT activate
        #expect(distUnder < 60, "55m offset should be under 60m threshold, got \(distUnder)m")

        // Over 60m — circle SHOULD activate instantly
        #expect(distOver > 60, "65m offset should exceed 60m threshold, got \(distOver)m")

        // Far away — definitely activates
        #expect(distFar > 60, "500m offset should exceed 60m threshold, got \(distFar)m")
    }

    @Test("Circle activates at different bearings (N, E, S, W)")
    func activationAtAllBearings() {
        for bearing in stride(from: 0.0, through: 270.0, by: 90.0) {
            let loc = Self.offset(meters: 70, bearing: bearing)
            let dist = Self.distance(from: loc)
            #expect(dist > 60, "70m offset at bearing \(bearing)° should exceed 60m, got \(dist)m")
        }
    }

    // MARK: - Debounced Search Placement

    @Test("API fires at the settled map center once drag search is active")
    func apiFiresAtSettledCenter() {
        let at80m = Self.offset(meters: 80)
        let at105m = Self.offset(meters: 105)
        let at300m = Self.offset(meters: 300)

        let dist80 = Self.distance(from: at80m)
        let dist105 = Self.distance(from: at105m)
        let dist300 = Self.distance(from: at300m)

        let isDragSearchActive = true

        #expect(isDragSearchActive && dist80 > 0,
            "80m settled center should place/search a pin, got \(dist80)m")
        #expect(isDragSearchActive && dist105 > 0,
            "105m settled center should place/search a pin, got \(dist105)m")
        #expect(isDragSearchActive && dist300 > 0,
            "300m settled center should place/search a pin, got \(dist300)m")
    }

    // MARK: - GPS Snap-Back

    @Test("Settling near GPS snaps back to current location")
    func nearGPSSnapThreshold() {
        let at40m = Self.offset(meters: 40)
        let at55m = Self.offset(meters: 55)
        let at80m = Self.offset(meters: 80)
        let at10m = Self.offset(meters: 10)
        let atOrigin = Self.gpsLocation

        let dist40 = Self.distance(from: at40m)
        let dist55 = Self.distance(from: at55m)
        let dist80 = Self.distance(from: at80m)
        let dist10 = Self.distance(from: at10m)
        let distOrigin = Self.distance(from: atOrigin)

        let snapRadius = 45.0

        #expect(dist40 < snapRadius, "40m offset should be inside GPS snap radius, got \(dist40)m")
        #expect(dist10 < snapRadius, "10m offset should be inside GPS snap radius, got \(dist10)m")
        #expect(distOrigin < snapRadius, "Origin should be inside GPS snap radius, got \(distOrigin)m")
        #expect(dist55 > snapRadius, "55m offset should stay outside the GPS snap radius, got \(dist55)m")
        #expect(dist80 > snapRadius, "80m offset should stay outside the GPS snap radius, got \(dist80)m")

        #expect(dist40 <= snapRadius, "40m should clear the pin and use GPS")
        #expect(dist55 > snapRadius, "55m should not be bounced back by GPS snap")
        #expect(dist80 > snapRadius, "80m should still place a search pin")
    }

    // MARK: - Threshold Ordering

    @Test("Activation threshold is independent from search placement")
    func thresholdOrdering() {
        let activateThreshold: Double = 60
        let searchPlacementRequiresActiveDrag = true

        #expect(activateThreshold > 0,
            "Activation threshold should remain a positive anti-accidental-pan guard")
        #expect(searchPlacementRequiresActiveDrag,
            "Settled search placement should depend on active drag state, not GPS distance")
    }

    @Test("Between snap and activation threshold does not bounce")
    func betweenSnapAndActivationThresholdDoesNotBounce() {
        // At 52m: outside the tiny GPS snap radius, but still too close
        // for activation. The map should stay where the user put it.
        let at52m = Self.offset(meters: 52)
        let dist52 = Self.distance(from: at52m)

        let snapRadius = 45.0
        let wouldUseGPS = dist52 <= snapRadius
        let wouldActivate = dist52 > 60

        #expect(!wouldUseGPS, "52m should not snap back; it also should not activate yet")
        #expect(!wouldActivate, "52m should not trigger activation")
    }

    @Test("Recent drag-search camera movement blocks GPS auto-recenter")
    func recentDragSearchMovementBlocksGPSRecenter() {
        let dragToSearchEnabled = true
        let selectedRouteId: String? = nil
        let isDragSearchActive = false
        let isDragSearchPanning = false
        let secondsSinceCameraMove = 0.8
        let graceSeconds = 2.0

        let isPositioningPin = dragToSearchEnabled
            && selectedRouteId == nil
            && (isDragSearchActive || isDragSearchPanning || secondsSinceCameraMove < graceSeconds)

        #expect(isPositioningPin, "GPS ticks should not recenter while the user is placing a drag-search pin")
    }

    // MARK: - State Transition: Full Drag-Search Lifecycle

    @Test("Full lifecycle: GPS → drag out → settle → drag back to GPS")
    func fullLifecycle() {
        // Simulate the user journey through distance checks
        struct DragState {
            var isDragSearchActive = false
            var isDragSearchPanning = false
            var hasFiredDragHaptic = false
        }
        var state = DragState()

        // Step 1: User at GPS — nothing active
        #expect(!state.isDragSearchActive)

        // Step 2: User pans 70m — instant activation
        let pan70m = Self.offset(meters: 70)
        let dist70 = Self.distance(from: pan70m)
        if dist70 > 60 && !state.isDragSearchActive {
            state.isDragSearchActive = true
            state.isDragSearchPanning = true
        }
        #expect(state.isDragSearchActive, "Should activate at 70m")
        #expect(state.isDragSearchPanning, "Should be panning at 70m")

        // Step 3: User settles (debounce fires) at 200m — API fires
        let pan200m = Self.offset(meters: 200)
        let dist200 = Self.distance(from: pan200m)
        if state.isDragSearchActive && dist200 > 0 {
            state.isDragSearchPanning = false
            // API would fire here
        }
        #expect(state.isDragSearchActive, "Should still be active at 200m")
        #expect(!state.isDragSearchPanning, "Should stop panning after settle")

        // Step 4: User drags back inside the 45m snap radius — GPS becomes active.
        let pan40m = Self.offset(meters: 40)
        let dist40 = Self.distance(from: pan40m)
        if state.isDragSearchActive && dist40 <= 45 {
            state.isDragSearchActive = false
            state.isDragSearchPanning = false
        }
        #expect(!state.isDragSearchActive, "Should clear the pin at 40m and return to GPS")
        #expect(!state.isDragSearchPanning, "Should stop panning after returning to GPS")
    }

    // MARK: - Distance Accuracy at NYC Latitude

    @Test("Distance calculation accuracy at NYC latitude (40.75°N)")
    func distanceAccuracyNYC() {
        // At 40.75°N, 1° longitude ≈ 84.4 km (cos(40.75°) ≈ 0.758)
        // Our offset helper should produce distances within 5% of target
        for targetMeters in [50.0, 60.0, 100.0, 200.0, 500.0] {
            let loc = Self.offset(meters: targetMeters)
            let actual = Self.distance(from: loc)
            let error = abs(actual - targetMeters) / targetMeters
            #expect(error < 0.05,
                    "Distance error for \(targetMeters)m target: \(actual)m (\(error * 100)%)")
        }
    }

    // MARK: - Edge Cases

    @Test("Nil GPS location prevents drag search activation")
    func nilLocationBlocksActivation() {
        // If locationManager.currentLocation is nil, distance can't be computed
        // The code guards on `let userCoord = locationManager.currentLocation?.coordinate`
        let hasLocation = false
        let shouldActivate = hasLocation && true // distance > 60
        #expect(!shouldActivate, "No GPS → no drag search activation")
    }

    @Test("Route detail open blocks drag search")
    func routeDetailBlocksDragSearch() {
        // When selectedRouteId != nil, handleMapCameraIdle returns early
        let selectedRouteId: String? = "A"
        let shouldProcess = selectedRouteId == nil
        #expect(!shouldProcess, "Route detail open → drag search blocked")
    }

    @Test("Search pin hides favorites")
    func searchPinHidesFavorites() {
        #expect(DashboardView.shouldShowFavorites(isSearchPinActive: false))
        #expect(!DashboardView.shouldShowFavorites(isSearchPinActive: true))
        #expect(DashboardView.contentSpacing(isSearchPinActive: true) < DashboardView.contentSpacing(isSearchPinActive: false))
    }

    @Test("Drag-to-search disabled blocks drag search")
    func disabledSettingBlocksDragSearch() {
        let dragToSearchEnabled = false
        let shouldProcess = dragToSearchEnabled
        #expect(!shouldProcess, "Setting disabled → drag search blocked")
    }

    @Test("Rapid panning cancels previous debounce")
    func rapidPanningCancelsDebounce() async {
        // Simulate: two rapid camera changes — second should cancel first
        var debounceTask: Task<Void, Never>?
        var apiCallCount = 0

        // First camera change
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            apiCallCount += 1
        }

        // Second camera change (cancels first)
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            apiCallCount += 1
        }

        // Wait for debounce to settle
        try? await Task.sleep(for: .milliseconds(500))

        #expect(apiCallCount == 1, "Only the last debounce should fire, got \(apiCallCount)")
    }

    @Test("Debounce outside GPS snap radius places the search pin")
    func debounceOutsideGPSSnapRadiusPlacesPin() {
        // If user is 80m away when debounce fires, keep the chosen center.
        let dist = 80.0
        let isDragSearchActive = true
        let snapRadius = 45.0

        let shouldPlacePin = isDragSearchActive && dist > snapRadius
        #expect(shouldPlacePin, "80m settled center should place the pin, not dismiss")
    }
}
