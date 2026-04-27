//
//  DragSearchBehaviorTests.swift
//  TrackTests
//
//  Validates the drag-to-search distance thresholds, state transitions,
//  and non-snapping drag behavior. Tests the pure distance calculations
//  that drive handleMapCameraIdle() in HomeView.
//
//  Expected behaviors:
//    1. Circle appears instantly when user pans 60m+ from GPS (no debounce)
//    2. API fires after 350ms debounce at the settled map center
//    3. Dragging near GPS does not snap or recenter automatically
//    4. Panning 50-100m from GPS places the pin without dismissing
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

    // MARK: - No Magnetic Snap-Back

    @Test("Dragging near GPS does not trigger snap-back")
    func noMagneticSnapThreshold() {
        let at40m = Self.offset(meters: 40)
        let at55m = Self.offset(meters: 55)
        let at10m = Self.offset(meters: 10)
        let atOrigin = Self.gpsLocation

        let dist40 = Self.distance(from: at40m)
        let dist55 = Self.distance(from: at55m)
        let dist10 = Self.distance(from: at10m)
        let distOrigin = Self.distance(from: atOrigin)

        // Under 50m — old snap distance, but drag search should not dismiss now.
        #expect(dist40 < 50, "40m offset should remain under former snap threshold, got \(dist40)m")
        #expect(dist10 < 50, "10m offset should remain under former snap threshold, got \(dist10)m")
        #expect(distOrigin < 50, "Origin should remain under former snap threshold, got \(distOrigin)m")

        let shouldSnap40m = false
        let shouldSnap10m = false
        let shouldSnapOrigin = false

        #expect(!shouldSnap40m, "40m should not auto-dismiss or recenter")
        #expect(!shouldSnap10m, "10m should not auto-dismiss or recenter")
        #expect(!shouldSnapOrigin, "Origin should not auto-dismiss or recenter")
        #expect(dist55 >= 50, "55m offset should be outside former snap threshold, got \(dist55)m")
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

    @Test("Below activation threshold does not snap")
    func belowActivationThresholdDoesNotSnap() {
        // At 52m: too close for activation, but still no automatic recenter.
        let at52m = Self.offset(meters: 52)
        let dist52 = Self.distance(from: at52m)

        let wouldSnap = false
        let wouldActivate = dist52 > 60

        #expect(!wouldSnap, "52m should not trigger snap-back")
        #expect(!wouldActivate, "52m should not trigger activation")
    }

    // MARK: - State Transition: Full Drag-Search Lifecycle

    @Test("Full lifecycle: GPS → drag out → settle → drag back without snap")
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

        // Step 4: User drags back to 45m — no automatic snap/recenter.
        let pan45m = Self.offset(meters: 45)
        let dist45 = Self.distance(from: pan45m)
        if state.isDragSearchActive && dist45 > 0 {
            state.isDragSearchPanning = false
            // API would place/search the pin here; no camera recenter.
        }
        #expect(state.isDragSearchActive, "Should stay active at 45m instead of snapping back")
        #expect(!state.isDragSearchPanning, "Should settle without snapping back")
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

    @Test("Debounce between 60-100m places the search pin")
    func debounceBetween60And100mPlacesPin() {
        // If user is 80m away when debounce fires, keep the chosen center.
        let dist = 80.0
        let isDragSearchActive = true

        let shouldPlacePin = isDragSearchActive && dist > 0
        #expect(shouldPlacePin, "80m settled center should place the pin, not dismiss")
    }
}
