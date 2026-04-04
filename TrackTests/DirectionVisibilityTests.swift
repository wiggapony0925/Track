//
//  DirectionVisibilityTests.swift
//  TrackTests
//
//  Exhaustive tests that NO real direction is ever hidden from the
//  home row swipe view.  Tests every scenario that has caused missing
//  direction tabs in the past (expired arrivals, "Outbound" treated as
//  fallback, compass-code placeholders, etc.).
//
//  Rule:  If the MTA sends 2 directions, the user MUST see 2 tabs.
//         The ONLY exception is a backend backfill placeholder
//         ("Opposite", "SW", "N", etc.) with zero real arrivals.
//

import Foundation
import Testing
@testable import Track

@Suite("Direction Visibility — no real direction ever hidden")
@MainActor
struct DirectionVisibilityTests {

    // MARK: - Helpers

    /// Build a live arrival with a future arrivalTs.
    private func liveArrival(
        routeId: String = "Q80",
        stopName: String = "LEFFERTS BLVD/LINDEN BLVD",
        direction: String = "Inbound",
        minutesAway: Int = 15,
        mode: String = "bus"
    ) -> NearbyTransitResponse {
        NearbyTransitResponse(
            routeId: routeId,
            stopName: stopName,
            direction: direction,
            destination: nil,
            minutesAway: minutesAway,
            status: "OK",
            mode: mode,
            stopLat: 40.6750,
            stopLon: -73.8126,
            arrivalTs: Int(Date.now.timeIntervalSince1970) + (minutesAway * 60),
            vehicleId: "V-\(routeId)-\(minutesAway)",
            tripId: "T-\(routeId)-\(minutesAway)",
            stopId: "MTA_\(routeId)_001",
            isRealTime: true
        )
    }

    /// Build an expired arrival (arrivalTs > 90 s in the past).
    private func expiredArrival(
        routeId: String = "Q80",
        stopName: String = "LEFFERTS BLVD/LINDEN BLVD",
        direction: String = "Inbound",
        mode: String = "bus"
    ) -> NearbyTransitResponse {
        NearbyTransitResponse(
            routeId: routeId,
            stopName: stopName,
            direction: direction,
            destination: nil,
            minutesAway: 0,
            status: "OK",
            mode: mode,
            stopLat: 40.6750,
            stopLon: -73.8126,
            arrivalTs: Int(Date.now.timeIntervalSince1970) - 300, // 5 min ago
            vehicleId: "V-\(routeId)-expired",
            tripId: "T-\(routeId)-expired",
            stopId: "MTA_\(routeId)_001",
            isRealTime: true
        )
    }

    /// Build a placeholder arrival (minutesAway >= 99, no arrivalTs/vehicleId).
    private func placeholderArrival(
        routeId: String = "Q80",
        direction: String = "Outbound"
    ) -> NearbyTransitResponse {
        NearbyTransitResponse(
            routeId: routeId,
            stopName: "PLACEHOLDER",
            direction: direction,
            destination: nil,
            minutesAway: 99,
            status: "Scheduled",
            mode: "bus",
            stopLat: nil,
            stopLon: nil,
            arrivalTs: nil,
            vehicleId: nil,
            tripId: nil,
            stopId: nil
        )
    }

    /// Build a direction with the given arrivals.
    private func dir(
        _ name: String,
        label: String? = nil,
        arrivals: [NearbyTransitResponse]
    ) -> DirectionArrivalsResponse {
        DirectionArrivalsResponse(
            direction: name,
            directionLabel: label,
            arrivals: arrivals
        )
    }

    // MARK: - Core Rule: Every real direction must be visible

    @Test func twoLiveDirections_bothVisible() {
        let directions = [
            dir("JFK AIRPORT via LEFFERTS BL", arrivals: [
                liveArrival(minutesAway: 13),
                liveArrival(minutesAway: 28),
            ]),
            dir("KEW GARDENS via LEFFERTS BL", arrivals: [
                liveArrival(direction: "Outbound", minutesAway: 20),
            ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2, "Both live directions must be visible")
    }

    @Test func directionWithExpiredArrivals_stillVisible() {
        // Q80 scenario: one direction has live arrivals, other had real
        // arrivals that all expired (>90s ago). Both must remain visible.
        let directions = [
            dir("JFK AIRPORT via LEFFERTS BL", arrivals: [
                liveArrival(minutesAway: 13),
            ]),
            dir("SOUTH OZONE PARK", arrivals: [
                expiredArrival(direction: "Outbound"),
            ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "Direction with expired real arrivals must stay visible (show '--' times)")
    }

    // MARK: - "Outbound" / "Inbound" must NEVER be treated as fallback

    @Test func outboundDirection_withPlaceholder_visible() {
        // Q80, Q37, Q9, Q51, Q115 etc. — "Outbound" with only a placeholder
        let directions = [
            dir("JFK AIRPORT via LEFFERTS BL", arrivals: [
                liveArrival(minutesAway: 13),
            ]),
            dir("Outbound", arrivals: [
                placeholderArrival(direction: "Outbound"),
            ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "Outbound with placeholder must be visible — it's a real MTA direction")
    }

    @Test func inboundDirection_withPlaceholder_visible() {
        let directions = [
            dir("SOUTH OZONE PARK", arrivals: [
                liveArrival(minutesAway: 10),
            ]),
            dir("Inbound", arrivals: [
                placeholderArrival(direction: "Inbound"),
            ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "Inbound with placeholder must be visible — it's a real MTA direction")
    }

    @Test func outbound_notInFallbackDirections() {
        #expect(!DirectionConstants.isFallbackDirection("Outbound"),
                "Outbound must NOT be classified as a fallback direction")
        #expect(!DirectionConstants.isFallbackDirection("OUTBOUND"),
                "OUTBOUND must NOT be classified as a fallback direction")
        #expect(!DirectionConstants.isFallbackDirection("outbound"),
                "outbound must NOT be classified as a fallback direction")
    }

    @Test func inbound_notInFallbackDirections() {
        #expect(!DirectionConstants.isFallbackDirection("Inbound"),
                "Inbound must NOT be classified as a fallback direction")
        #expect(!DirectionConstants.isFallbackDirection("INBOUND"),
                "INBOUND must NOT be classified as a fallback direction")
        #expect(!DirectionConstants.isFallbackDirection("inbound"),
                "inbound must NOT be classified as a fallback direction")
    }

    // MARK: - Compass-code placeholders are correctly dropped

    @Test func compassCodePlaceholder_SW_dropped() {
        let directions = [
            dir("EAST SIDE YORK AV CROSSTOWN", arrivals: [
                liveArrival(routeId: "M31", minutesAway: 8),
            ]),
            dir("SW", arrivals: [
                placeholderArrival(routeId: "M31", direction: "SW"),
            ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 1, "SW compass placeholder with no real arrivals should be dropped")
    }

    @Test func compassCodePlaceholders_allDropped() {
        // Verify *all* compass codes are treated as fallback
        let codes = ["N", "S", "E", "W", "NE", "NW", "SE", "SW"]
        for code in codes {
            #expect(DirectionConstants.isFallbackDirection(code),
                    "\(code) must be a fallback direction code")
        }
    }

    @Test func compassLongFormPlaceholders_allDropped() {
        let labels = ["Northbound", "Southbound", "Eastbound", "Westbound",
                       "Northeast", "Northwest", "Southeast", "Southwest"]
        for label in labels {
            #expect(DirectionConstants.isFallbackDirection(label),
                    "\(label) must be a fallback direction")
        }
    }

    @Test func oppositeDirection_dropped() {
        let directions = [
            dir("JAMAICA BUS TERMINAL", arrivals: [
                liveArrival(routeId: "Q6", minutesAway: 5),
            ]),
            dir("Opposite", arrivals: [
                placeholderArrival(routeId: "Q6", direction: "Opposite"),
            ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 1, "Opposite placeholder should be dropped")
    }

    @Test func oppositeDirection_caseInsensitive() {
        let directions = [
            dir("Uptown", arrivals: [liveArrival(routeId: "1", minutesAway: 3)]),
            dir("OPPOSITE", arrivals: [placeholderArrival(routeId: "1", direction: "OPPOSITE")]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 1, "OPPOSITE (uppercase) should also be dropped")
    }

    // MARK: - Fallback: don't drop everything

    @Test func allDirectionsPlaceholder_fallbackKeepsAll() {
        // If filtering would produce zero visible directions, keep all
        let directions = [
            dir("N", arrivals: [placeholderArrival(direction: "N")]),
            dir("S", arrivals: [placeholderArrival(direction: "S")]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "When all directions would be dropped, fallback must keep ALL")
    }

    @Test func emptyDirections_emptyResult() {
        let visible = ArrivalHelpers.visibleDirections(for: [])
        #expect(visible.isEmpty, "Empty input → empty output")
    }

    // MARK: - Real bus route scenarios from the MTA feed

    @Test func q80_jfkAirport_outbound_bothVisible() {
        // Real Q80 data: 2 directions, second is "Outbound" with 1 placeholder
        let directions = [
            dir("JFK AIRPORT via LEFFERTS BL",
                label: "JFK AIRPORT via LEFFERTS BL",
                arrivals: [
                    liveArrival(routeId: "Q80", minutesAway: 13),
                    liveArrival(routeId: "Q80", minutesAway: 28),
                    liveArrival(routeId: "Q80", minutesAway: 43),
                ]),
            dir("Outbound",
                label: nil,
                arrivals: [
                    placeholderArrival(routeId: "Q80", direction: "Outbound"),
                ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "Q80: both JFK AIRPORT and Outbound must appear in swipe tabs")
    }

    @Test func q37_southOzonePark_outbound_bothVisible() {
        let directions = [
            dir("SOUTH OZONE PARK via AQUEDUCT",
                arrivals: [
                    liveArrival(routeId: "Q37", minutesAway: 10),
                    liveArrival(routeId: "Q37", minutesAway: 25),
                ]),
            dir("Outbound",
                arrivals: [
                    placeholderArrival(routeId: "Q37", direction: "Outbound"),
                ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "Q37: both directions must be visible")
    }

    @Test func q9_rush_outbound_bothVisible() {
        let directions = [
            dir("RUSH SOUTH OZONE PARK",
                arrivals: [
                    liveArrival(routeId: "Q9", minutesAway: 8),
                ]),
            dir("Outbound",
                arrivals: [
                    placeholderArrival(routeId: "Q9", direction: "Outbound"),
                ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "Q9: both directions must be visible")
    }

    @Test func q51_limited_outbound_bothVisible() {
        let directions = [
            dir("LIMITED CAMBRIA HEIGHTS",
                arrivals: [
                    liveArrival(routeId: "Q51", minutesAway: 10),
                    liveArrival(routeId: "Q51", minutesAway: 30),
                ]),
            dir("Outbound",
                arrivals: [
                    placeholderArrival(routeId: "Q51", direction: "Outbound"),
                ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "Q51: both directions must be visible")
    }

    @Test func q115_springfield_outbound_bothVisible() {
        let directions = [
            dir("SPRINGFIELD GARDENS via BREWER BL",
                arrivals: [
                    liveArrival(routeId: "Q115", minutesAway: 12),
                ]),
            dir("Outbound",
                arrivals: [
                    placeholderArrival(routeId: "Q115", direction: "Outbound"),
                ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "Q115: both directions must be visible")
    }

    @Test func bm5_express_outbound_bothVisible() {
        let directions = [
            dir("SPRING CREEK SEAVIEW AV via LINDEN BL via PENN AV",
                arrivals: [
                    liveArrival(routeId: "BM5", minutesAway: 20),
                ]),
            dir("Outbound",
                arrivals: [
                    placeholderArrival(routeId: "BM5", direction: "Outbound"),
                ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "BM5: both directions must be visible")
    }

    @Test func qm15_midtown_outbound_bothVisible() {
        let directions = [
            dir("MIDTOWN 57 ST via 6 AV",
                arrivals: [
                    liveArrival(routeId: "QM15", minutesAway: 15),
                ]),
            dir("Outbound",
                arrivals: [
                    placeholderArrival(routeId: "QM15", direction: "Outbound"),
                ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "QM15: both directions must be visible")
    }

    @Test func q44sbs_select_outbound_bothVisible() {
        let directions = [
            dir("SELECT BUS JAMAICA via MAIN ST",
                arrivals: [
                    liveArrival(routeId: "Q44-SBS", minutesAway: 5),
                    liveArrival(routeId: "Q44-SBS", minutesAway: 12),
                ]),
            dir("Outbound",
                arrivals: [
                    placeholderArrival(routeId: "Q44-SBS", direction: "Outbound"),
                ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "Q44-SBS: both directions must be visible")
    }

    // MARK: - Subway direction scenarios

    @Test func subwayTwoDirections_bothVisible() {
        // Standard subway: two named terminal directions
        let directions = [
            dir("Far Rockaway-Mott Av",
                arrivals: [
                    liveArrival(routeId: "A", direction: "South", minutesAway: 5, mode: "subway"),
                    liveArrival(routeId: "A", direction: "South", minutesAway: 15, mode: "subway"),
                ]),
            dir("Inwood-207 St",
                arrivals: [
                    liveArrival(routeId: "A", direction: "North", minutesAway: 8, mode: "subway"),
                ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2, "Subway with 2 named directions → both visible")
    }

    @Test func subwayThreeDirections_allVisible() {
        // A train has 3 directions: Far Rockaway, Inwood, Ozone Park-Lefferts
        let directions = [
            dir("Far Rockaway-Mott Av", arrivals: [
                liveArrival(routeId: "A", minutesAway: 5, mode: "subway"),
            ]),
            dir("Inwood-207 St", arrivals: [
                liveArrival(routeId: "A", minutesAway: 8, mode: "subway"),
            ]),
            dir("Ozone Park-Lefferts Blvd", arrivals: [
                liveArrival(routeId: "A", minutesAway: 12, mode: "subway"),
            ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 3, "A train with 3 branches → all 3 visible")
    }

    @Test func subwayDirectionWithExpiredArrivals_stillVisible() {
        // Cached subway direction with all arrivals expired
        let directions = [
            dir("Far Rockaway-Mott Av", arrivals: [
                liveArrival(routeId: "A", minutesAway: 5, mode: "subway"),
            ]),
            dir("Inwood-207 St", arrivals: [
                expiredArrival(routeId: "A", direction: "North", mode: "subway"),
            ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 2,
                "Subway direction with expired arrivals must NOT disappear")
    }

    // MARK: - LIRR / MNR direction scenarios

    @Test func lirrFourDirections_allVisible() {
        let directions = [
            dir("Babylon", arrivals: [
                liveArrival(routeId: "LIRR_1", minutesAway: 20, mode: "lirr")
            ]),
            dir("Grand Central", arrivals: [
                liveArrival(routeId: "LIRR_1", minutesAway: 25, mode: "lirr")
            ]),
            dir("Massapequa", arrivals: [
                liveArrival(routeId: "LIRR_1", minutesAway: 40, mode: "lirr")
            ]),
            dir("Penn Station", arrivals: [
                liveArrival(routeId: "LIRR_1", minutesAway: 15, mode: "lirr")
            ]),
        ]
        let visible = ArrivalHelpers.visibleDirections(for: directions)
        #expect(visible.count == 4, "LIRR with 4 directions → all 4 visible")
    }

    // MARK: - Stress: live API integration test

    @Test(.timeLimit(.minutes(3)))
    func liveAPI_everyDirectionVisible() async throws {
        // Hit the live backend and verify that for EVERY route group,
        // visibleDirections count == group.directions count
        // (minus only Opposite/compass placeholders with no data).
        //
        // Note: first request may trigger Render cold-start (~30-90s).
        // We make a warm-up request first, then the real one.
        let baseURL = "https://track-vkrr.onrender.com"
            + "/nearby/grouped?lat=40.67504&lon=-73.81264&radius=8047"
        let url = URL(string: baseURL)!

        // Warm-up request (tolerates failure)
        _ = try? await URLSession.shared.data(from: url)

        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 200 else {
            // Server might be cold — skip rather than fail
            print("⚠️ Server returned \(http.statusCode) — skipping live API test")
            return
        }

        let groups = try JSONDecoder().decode([GroupedNearbyTransitResponse].self, from: data)
        #expect(!groups.isEmpty, "Should get at least some route groups")

        var failures: [String] = []

        for group in groups {
            let allDirs = group.directions
            let visible = ArrivalHelpers.visibleDirections(for: allDirs)

            // Count "real" directions: those that have at least one
            // non-placeholder arrival OR are named Inbound/Outbound.
            let realDirCount = allDirs.filter { dir in
                // Has real arrivals
                if dir.arrivals.contains(where: { !$0.isPlaceholder }) { return true }
                // Is Inbound/Outbound (real MTA direction)
                let upper = dir.direction.uppercased()
                if upper == "INBOUND" || upper == "OUTBOUND" { return true }
                // Named direction (not compass/opposite placeholder)
                if dir.direction.lowercased() == "opposite" { return false }
                if DirectionConstants.isFallbackDirection(dir.direction) { return false }
                return true
            }.count

            if visible.count < realDirCount {
                let allDirNames = Set(allDirs.map { $0.direction })
                let visibleDirNames = Set(visible.map { $0.direction })
                let missing = allDirNames.subtracting(visibleDirNames)
                failures.append(
                    "\(group.mode) \(group.routeId): "
                    + "visible=\(visible.count)/\(allDirs.count) "
                    + "expected≥\(realDirCount) "
                    + "MISSING: \(missing.sorted().joined(separator: ", "))"
                )
            }
        }

        if !failures.isEmpty {
            let msg = "MISSING DIRECTIONS:\n" + failures.joined(separator: "\n")
            #expect(Bool(false), "\(msg)")
        }
    }
}
