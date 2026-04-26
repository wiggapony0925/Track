//
//  LocationContextConsistencyTests.swift
//  TrackTests
//
//  Stress-tests the "GPS ↔ dropped pin" state machine that drives every
//  feature that needs to know where the user "is":
//
//    • LocationContext (source of truth)
//    • ChatView.syncBias()  → biasSource / biasLabel / biasLat / biasLon
//    • PlanViewModel.originDisplayName / payload label
//    • MainTabView's locationContext ↔ chatBiasPin mirror
//
//  Every test exercises rapid, repeated toggling — the "spam" scenario the
//  user reported — and verifies that all consumers land on exactly the same
//  answer after each transition.
//
//  Run with: ⌘U  or  `xcodebuild test -scheme Track -only-testing:TrackTests/LocationContextConsistencyTests`

import CoreLocation
import Testing
@testable import Track

// MARK: - Fixtures

private let gpsCoord   = CLLocationCoordinate2D(latitude: 40.7536, longitude: -73.9990) // Hudson Yards
private let pinCoord   = CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855) // Times Square
private let pinCoord2  = CLLocationCoordinate2D(latitude: 40.7484, longitude: -74.0040) // Chelsea

// ---------------------------------------------------------------------------
// MARK: - LocationContext — source of truth
// ---------------------------------------------------------------------------

@MainActor
@Suite("LocationContext — source of truth")
struct LocationContextSourceTests {

    @Test("Starts as GPS with no pin")
    func initialState() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        #expect(!ctx.isUsingDroppedPin)
        #expect(ctx.source == .gps)
        #expect(ctx.displayLabel == "current location")
        #expect(ctx.effectiveCoordinate?.latitude == gpsCoord.latitude)
    }

    @Test("Pin overrides GPS immediately")
    func pinOverridesGPS() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        ctx.setDroppedPin(pinCoord)

        #expect(ctx.isUsingDroppedPin)
        #expect(ctx.source == .droppedPin)
        #expect(ctx.displayLabel == "dropped pin")
        #expect(ctx.effectiveCoordinate?.latitude == pinCoord.latitude)
        #expect(ctx.effectiveCoordinate?.longitude == pinCoord.longitude)
    }

    @Test("Clearing pin reverts to GPS")
    func clearingPinRevertsToGPS() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        ctx.setDroppedPin(pinCoord)
        ctx.clearDroppedPin()

        #expect(!ctx.isUsingDroppedPin)
        #expect(ctx.source == .gps)
        #expect(ctx.effectiveCoordinate?.latitude == gpsCoord.latitude)
    }

    @Test("setDroppedPin(nil) is equivalent to clearDroppedPin()")
    func setNilEquivalentToClear() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        ctx.setDroppedPin(pinCoord)
        ctx.setDroppedPin(nil)

        #expect(!ctx.isUsingDroppedPin)
        #expect(ctx.source == .gps)
    }

    @Test("Rapid toggle: GPS → pin → GPS × 10 always lands on GPS")
    func rapidToggleAlwaysLandsOnGPS() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        for _ in 0..<10 {
            ctx.setDroppedPin(pinCoord)
            ctx.setDroppedPin(nil)
        }

        #expect(!ctx.isUsingDroppedPin)
        #expect(ctx.source == .gps)
        #expect(ctx.effectiveCoordinate?.latitude == gpsCoord.latitude)
    }

    @Test("Rapid toggle: GPS → pin × 10 always lands on pin")
    func rapidToggleAlwaysLandsOnPin() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        for _ in 0..<10 {
            ctx.setDroppedPin(nil)
            ctx.setDroppedPin(pinCoord)
        }

        #expect(ctx.isUsingDroppedPin)
        #expect(ctx.source == .droppedPin)
        #expect(ctx.effectiveCoordinate?.latitude == pinCoord.latitude)
    }

    @Test("Switching between two different pins always reflects the last one")
    func switchingBetweenPins() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        for i in 0..<20 {
            let coord = i.isMultiple(of: 2) ? pinCoord : pinCoord2
            ctx.setDroppedPin(coord)
        }
        // Last iteration (i=19, odd) → pinCoord2
        #expect(ctx.isUsingDroppedPin)
        #expect(ctx.effectiveCoordinate?.latitude == pinCoord2.latitude)
    }

    @Test("GPS jitter below 5m threshold does NOT churn observers")
    func gpsJitterIgnored() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        let initial = ctx.gpsCoordinate

        // Offset by ~2m (well under 0.00005° ≈ 5m threshold)
        let jittered = CLLocationCoordinate2D(
            latitude: gpsCoord.latitude + 0.00001,
            longitude: gpsCoord.longitude + 0.00001
        )
        ctx.setGPSCoordinate(jittered)

        // Should still hold the original value
        #expect(ctx.gpsCoordinate?.latitude == initial?.latitude)
    }

    @Test("GPS update beyond 5m threshold IS applied")
    func gpsBeyondJitterThreshold() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        let movedFarther = CLLocationCoordinate2D(
            latitude: gpsCoord.latitude + 0.001,   // ~111m north
            longitude: gpsCoord.longitude
        )
        ctx.setGPSCoordinate(movedFarther)

        #expect(abs((ctx.gpsCoordinate?.latitude ?? 0) - movedFarther.latitude) < 0.0001)
    }

    @Test("No GPS and no pin → effectiveCoordinate is nil")
    func noGPSNoPinIsNil() {
        let ctx = LocationContext()
        #expect(ctx.effectiveCoordinate == nil)
    }

    @Test("Pin active but no GPS still gives pin coordinate")
    func pinWithoutGPS() {
        let ctx = LocationContext()
        ctx.setDroppedPin(pinCoord)

        #expect(ctx.isUsingDroppedPin)
        #expect(ctx.effectiveCoordinate?.latitude == pinCoord.latitude)
    }
}

// ---------------------------------------------------------------------------
// MARK: - ChatView bias sync — mirrors LocationContext
// ---------------------------------------------------------------------------

/// Minimal replica of ChatView.syncBias() so we can test the logic without
/// spinning up a full SwiftUI view.  Must stay in sync with the real impl.
@MainActor
private func chatSyncBias(locationContext: LocationContext)
    -> (source: String?, label: String?, lat: Double?, lon: Double?) {

    if locationContext.isUsingDroppedPin,
       let pin = locationContext.droppedPin {
        return ("map_pin", "dropped pin", pin.latitude, pin.longitude)
    } else if let coord = locationContext.effectiveCoordinate {
        return ("gps", "current location", coord.latitude, coord.longitude)
    } else {
        return (nil, nil, nil, nil)
    }
}

@MainActor
@Suite("ChatView bias sync")
struct ChatBiasSyncTests {

    @Test("GPS → biasSource is 'gps', label is 'current location'")
    func gpsMode() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        let bias = chatSyncBias(locationContext: ctx)
        #expect(bias.source == "gps")
        #expect(bias.label == "current location")
        #expect(bias.lat == gpsCoord.latitude)
        #expect(bias.lon == gpsCoord.longitude)
    }

    @Test("Dropped pin → biasSource is 'map_pin', label is 'dropped pin'")
    func droppedPinMode() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        ctx.setDroppedPin(pinCoord)

        let bias = chatSyncBias(locationContext: ctx)
        #expect(bias.source == "map_pin")
        #expect(bias.label == "dropped pin")
        #expect(bias.lat == pinCoord.latitude)
        #expect(bias.lon == pinCoord.longitude)
    }

    @Test("Pin cleared → reverts to GPS source/label")
    func clearPinRevertsToGPS() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        ctx.setDroppedPin(pinCoord)
        ctx.clearDroppedPin()

        let bias = chatSyncBias(locationContext: ctx)
        #expect(bias.source == "gps")
        #expect(bias.label == "current location")
        #expect(bias.lat == gpsCoord.latitude)
    }

    @Test("No location and no pin → all nil (no chip shown)")
    func noLocationNoBias() {
        let ctx = LocationContext()
        let bias = chatSyncBias(locationContext: ctx)
        #expect(bias.source == nil)
        #expect(bias.label == nil)
        #expect(bias.lat == nil)
    }

    @Test("Spam: 50 rapid pin-drop / recenter cycles — always correct after each step")
    func spamToggleBiasConsistency() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        for i in 0..<50 {
            // Odd iterations → drop pin
            if i.isMultiple(of: 2) {
                ctx.setDroppedPin(pinCoord)
                let bias = chatSyncBias(locationContext: ctx)
                #expect(bias.source == "map_pin",
                        "Iteration \(i): expected map_pin, got \(bias.source ?? "nil")")
                #expect(bias.lat == pinCoord.latitude,
                        "Iteration \(i): expected pin lat, got \(bias.lat ?? 0)")
            } else {
                // Even iterations → recenter (clear pin)
                ctx.clearDroppedPin()
                let bias = chatSyncBias(locationContext: ctx)
                #expect(bias.source == "gps",
                        "Iteration \(i): expected gps, got \(bias.source ?? "nil")")
                #expect(bias.lat == gpsCoord.latitude,
                        "Iteration \(i): expected GPS lat, got \(bias.lat ?? 0)")
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - PlanViewModel origin label / API payload
// ---------------------------------------------------------------------------

@MainActor
/// Minimal replica of PlanViewModel's two LocationContext-dependent outputs.
private func planOriginLabel(locationContext: LocationContext) -> String {
    if locationContext.isUsingDroppedPin {
        let label = locationContext.source.displayLabel  // "dropped pin"
        return label.prefix(1).uppercased() + label.dropFirst()
    }
    return "My location"
}

@MainActor
private func planPayloadLabel(locationContext: LocationContext) -> String {
    locationContext.isUsingDroppedPin ? "Dropped pin" : "Current location"
}

@MainActor
@Suite("PlanViewModel origin display")
struct PlanViewModelOriginTests {

    @Test("GPS → origin label is 'My location'")
    func gpsOriginLabel() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        #expect(planOriginLabel(locationContext: ctx) == "My location")
    }

    @Test("Dropped pin → origin label is 'Dropped pin'")
    func pinOriginLabel() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        ctx.setDroppedPin(pinCoord)
        #expect(planOriginLabel(locationContext: ctx) == "Dropped pin")
    }

    @Test("GPS → API payload label is 'Current location'")
    func gpsPayloadLabel() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        #expect(planPayloadLabel(locationContext: ctx) == "Current location")
    }

    @Test("Dropped pin → API payload label is 'Dropped pin'")
    func pinPayloadLabel() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        ctx.setDroppedPin(pinCoord)
        #expect(planPayloadLabel(locationContext: ctx) == "Dropped pin")
    }

    @Test("Clearing pin → label reverts to 'My location'")
    func clearPinRevertsLabel() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        ctx.setDroppedPin(pinCoord)
        ctx.clearDroppedPin()
        #expect(planOriginLabel(locationContext: ctx) == "My location")
        #expect(planPayloadLabel(locationContext: ctx) == "Current location")
    }

    @Test("Spam: 50 rapid cycles — Chat and Plan always agree on source")
    func spamToggleChatAndPlanAgree() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        for i in 0..<50 {
            let dropPin = i.isMultiple(of: 2)
            if dropPin {
                ctx.setDroppedPin(pinCoord)
            } else {
                ctx.clearDroppedPin()
            }

            let chatBias = chatSyncBias(locationContext: ctx)
            let planLabel = planOriginLabel(locationContext: ctx)
            let apiLabel  = planPayloadLabel(locationContext: ctx)

            if dropPin {
                // All three must agree: pin is active
                #expect(chatBias.source == "map_pin",
                        "i=\(i): Chat source mismatch")
                #expect(planLabel == "Dropped pin",
                        "i=\(i): Plan label mismatch, got '\(planLabel)'")
                #expect(apiLabel == "Dropped pin",
                        "i=\(i): API label mismatch, got '\(apiLabel)'")
                // Coordinates must point to the pin, not GPS
                #expect(chatBias.lat != gpsCoord.latitude,
                        "i=\(i): Chat bias is using GPS lat instead of pin lat")
                #expect(chatBias.lat == pinCoord.latitude,
                        "i=\(i): Chat bias lat should equal pin lat")
            } else {
                // All three must agree: GPS is active
                #expect(chatBias.source == "gps",
                        "i=\(i): Chat source mismatch")
                #expect(planLabel == "My location",
                        "i=\(i): Plan label mismatch, got '\(planLabel)'")
                #expect(apiLabel == "Current location",
                        "i=\(i): API label mismatch, got '\(apiLabel)'")
                #expect(chatBias.lat == gpsCoord.latitude,
                        "i=\(i): Chat bias should be using GPS lat")
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - MainTabView mirror: chatBiasPin ↔ LocationContext
// ---------------------------------------------------------------------------

/// Tests the MainTabView onChange chain:
///   chatBiasPin set → locationContext.setDroppedPin()
///   chatBiasPin nil → locationContext.setDroppedPin(nil)
@MainActor
@Suite("MainTabView — chatBiasPin mirrors LocationContext")
struct MainTabViewMirrorTests {

    /// Simulate the MainTabView onChange logic (runs on pin lat change).
    private func applyBiasPin(_ pin: CLLocationCoordinate2D?, to ctx: LocationContext) {
        ctx.setDroppedPin(pin)
    }

    @Test("Setting chatBiasPin → context switches to droppedPin")
    func settingBiasPinSwitchesContext() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        applyBiasPin(pinCoord, to: ctx)

        #expect(ctx.isUsingDroppedPin)
        #expect(ctx.droppedPin?.latitude == pinCoord.latitude)
    }

    @Test("Clearing chatBiasPin (nil) → context reverts to GPS")
    func clearingBiasPinRevertsToGPS() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        applyBiasPin(pinCoord, to: ctx)
        applyBiasPin(nil, to: ctx)

        #expect(!ctx.isUsingDroppedPin)
        #expect(ctx.effectiveCoordinate?.latitude == gpsCoord.latitude)
    }

    @Test("Drag search spam: 100 set/clear cycles — final clear leaves GPS")
    func dragSearchSpam100Cycles() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        for _ in 0..<100 {
            applyBiasPin(pinCoord, to: ctx)
            applyBiasPin(nil, to: ctx)
        }

        #expect(!ctx.isUsingDroppedPin)
        #expect(ctx.source == .gps)
        #expect(ctx.effectiveCoordinate?.latitude == gpsCoord.latitude)
    }

    @Test("Drag search spam: 100 set/clear cycles — final set leaves pin")
    func dragSearchSpam100CyclesEndsOnPin() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        for _ in 0..<100 {
            applyBiasPin(nil, to: ctx)
            applyBiasPin(pinCoord, to: ctx)
        }

        #expect(ctx.isUsingDroppedPin)
        #expect(ctx.source == .droppedPin)
        #expect(ctx.effectiveCoordinate?.latitude == pinCoord.latitude)
    }

    @Test("All three consumers agree after 50 random-order transitions")
    func allConsumersAgreeAfterRandomTransitions() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)

        // Deterministic pseudo-random sequence using a simple LCG
        var seed: UInt64 = 42
        func next() -> Bool {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (seed >> 33) % 2 == 0
        }

        for i in 0..<50 {
            let dropPin = next()
            applyBiasPin(dropPin ? pinCoord : nil, to: ctx)

            let chatBias  = chatSyncBias(locationContext: ctx)
            let planLabel = planOriginLabel(locationContext: ctx)
            let apiLabel  = planPayloadLabel(locationContext: ctx)

            if dropPin {
                #expect(chatBias.source == "map_pin",  "i=\(i): Chat wrong")
                #expect(planLabel == "Dropped pin",    "i=\(i): Plan wrong")
                #expect(apiLabel  == "Dropped pin",    "i=\(i): API wrong")
                #expect(ctx.isUsingDroppedPin,         "i=\(i): Context wrong")
            } else {
                #expect(chatBias.source == "gps",      "i=\(i): Chat wrong")
                #expect(planLabel == "My location",    "i=\(i): Plan wrong")
                #expect(apiLabel  == "Current location", "i=\(i): API wrong")
                #expect(!ctx.isUsingDroppedPin,        "i=\(i): Context wrong")
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Edge Cases: concurrent GPS updates during pin session
// ---------------------------------------------------------------------------

@MainActor
@Suite("GPS updates during active pin session")
struct GPSUpdatesDuringPinTests {

    @Test("GPS update while pin is active does NOT change source")
    func gpsUpdateDuringPin() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        ctx.setDroppedPin(pinCoord)

        // GPS ticks arrive (simulate CoreLocation updates)
        for i in 0..<20 {
            let jitter = CLLocationCoordinate2D(
                latitude:  gpsCoord.latitude  + Double(i) * 0.0001,
                longitude: gpsCoord.longitude + Double(i) * 0.0001
            )
            ctx.setGPSCoordinate(jitter)

            // Pin must remain active
            #expect(ctx.isUsingDroppedPin,
                    "GPS tick \(i): pin should still be active")
            #expect(ctx.source == .droppedPin,
                    "GPS tick \(i): source should be droppedPin")
            #expect(ctx.effectiveCoordinate?.latitude == pinCoord.latitude,
                    "GPS tick \(i): effective coordinate should still be pin")
        }
    }

    @Test("ChatView bias unchanged by GPS tick while pin is active")
    func chatBiasUnchangedByGPSTick() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        ctx.setDroppedPin(pinCoord)

        for i in 0..<10 {
            ctx.setGPSCoordinate(CLLocationCoordinate2D(
                latitude: gpsCoord.latitude + Double(i) * 0.001,
                longitude: gpsCoord.longitude
            ))
            let bias = chatSyncBias(locationContext: ctx)
            #expect(bias.source == "map_pin",
                    "GPS tick \(i): Chat should still show map_pin")
            #expect(bias.lat == pinCoord.latitude,
                    "GPS tick \(i): Chat bias lat should be pin, got \(bias.lat ?? 0)")
        }
    }

    @Test("Recenter after GPS ticks: clearing pin uses latest GPS fix")
    func recenterAfterGPSTicksUsesLatestFix() {
        let ctx = LocationContext()
        ctx.setGPSCoordinate(gpsCoord)
        ctx.setDroppedPin(pinCoord)

        // Simulate 5 GPS ticks with drift
        let finalGPS = CLLocationCoordinate2D(
            latitude: gpsCoord.latitude + 0.005,
            longitude: gpsCoord.longitude + 0.003
        )
        for _ in 0..<4 {
            ctx.setGPSCoordinate(gpsCoord)
        }
        ctx.setGPSCoordinate(finalGPS)

        // User taps recenter
        ctx.clearDroppedPin()

        // Should be on latest GPS, not original or pin
        #expect(!ctx.isUsingDroppedPin)
        #expect(abs((ctx.effectiveCoordinate?.latitude ?? 0) - finalGPS.latitude) < 0.001)
    }
}
