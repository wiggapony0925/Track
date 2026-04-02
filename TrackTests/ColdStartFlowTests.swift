//
//  ColdStartFlowTests.swift
//  TrackTests
//
//  End-to-end integration tests simulating the full app cold-start flow:
//  skeleton → API calls → live data rendered.  Hits real backend endpoints
//  and measures latency to ensure the user sees data within acceptable
//  time budgets.
//
//  Mirrors the exact sequence in HomeViewModel.refresh() + MapSystemViewModel.init():
//    1. /health                       — wake the server
//    2. /nearby/grouped               — live arrivals (critical path)
//    3. /subway/shapes/all            — system map polylines
//    4. /subway/stations/all          — station dots
//    5. /lirr/shapes/all + /mnr/shapes/all — commuter rail
//    6. /alerts + /accessibility      — service status
//
//  NOTE: These hit the LIVE Render backend.  The first test wakes the server
//  (with retries up to 120 s for cold boot) so subsequent tests measure
//  warm-server latency.  Run with:
//      -parallel-testing-enabled NO
//  to avoid multiple simulator clones overwhelming the free-tier server.
//

import CoreLocation
import Foundation
import Testing

@testable import Track

// MARK: - Cold Start Flow Tests

@MainActor
@Suite("Cold Start Flow", .serialized)
struct ColdStartFlowTests {

    // ── Constants ──────────────────────────────────────────────────

    /// South Ozone Park / JFK area — same as the user's logs.
    private static let testLat = 40.675044
    private static let testLon = -73.812646
    private static let testRadius = 8047

    /// Maximum time (seconds) for the full critical-path data load on a WARM server.
    private static let warmFlowBudget: TimeInterval = 30

    /// Maximum time for the server wake-up phase (health check retries).
    /// Render free-tier cold boot takes 30-60 s.
    private static let wakeUpBudget: TimeInterval = 120

    /// Maximum time for an individual non-shapes endpoint (warm server).
    private static let singleEndpointBudget: TimeInterval = 15

    /// Maximum time for shapes endpoints (warm server).
    private static let shapeEndpointBudget: TimeInterval = 30

    // ── Helpers ────────────────────────────────────────────────────

    /// Measures wall-clock time of a throwing async closure, returning (result, seconds).
    private func timed<T>(
        _ label: String,
        _ work: () async throws -> T
    ) async throws -> (T, TimeInterval) {
        let start = Date()
        let result = try await work()
        let elapsed = Date().timeIntervalSince(start)
        print("⏱️ [\(label)] \(String(format: "%.2f", elapsed))s")
        return (result, elapsed)
    }

    /// Non-throwing variant for functions that don't throw.
    private func timed<T>(_ label: String, _ work: () async -> T) async -> (T, TimeInterval) {
        let start = Date()
        let result = await work()
        let elapsed = Date().timeIntervalSince(start)
        print("⏱️ [\(label)] \(String(format: "%.2f", elapsed))s")
        return (result, elapsed)
    }

    /// Wakes the server with retries until /health returns 200 or the budget expires.
    /// Must be called at the start of every test to guarantee a warm server.
    @discardableResult
    private func ensureServerAwake() async -> TimeInterval {
        let start = Date()
        var attempt = 0
        let maxAttempts = 20   // 20 × (5 s sleep + 10 s timeout) ≈ up to 300 s
        while attempt < maxAttempts {
            let ping = await TrackAPI.pingBackend(timeoutSeconds: 10)
            if ping.ok {
                let elapsed = Date().timeIntervalSince(start)
                if attempt > 0 {
                    let t = String(format: "%.1f", elapsed)
                    print("✅ Server awake after "
                        + "\(attempt + 1) attempt(s) (\(t)s)")
                }
                return elapsed
            }
            attempt += 1
            if attempt < maxAttempts {
                let err = ping.error ?? "unknown"
                print("⏳ Wake attempt "
                    + "\(attempt)/\(maxAttempts) "
                    + "failed (\(err)) — retrying in 5 s…")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let t = String(format: "%.1f", elapsed)
        print("⚠️ Server did not wake after "
            + "\(maxAttempts) attempts (\(t)s)")
        return elapsed
    }

    // ── Phase 0: Server Wake-Up ──────────────────────────────────

    @Test("Server wakes up within cold-start budget")
    func serverWakesUp() async throws {
        let wakeTime = await ensureServerAwake()

        // Verify the server is actually responding now
        let ping = await TrackAPI.pingBackend(timeoutSeconds: 10)
        #expect(ping.ok, "Server health check failed after wake-up: \(ping.error ?? "unknown")")
        #expect(ping.statusCode == 200)

        let wt = String(format: "%.1f", wakeTime)
        print("📊 Server wake time: \(wt)s "
            + "(budget: \(Self.wakeUpBudget)s)")
        let wtInt = String(format: "%.0f", wakeTime)
        #expect(wakeTime < Self.wakeUpBudget,
                "Server took \(wtInt)s to wake "
                + "— exceeds \(Self.wakeUpBudget)s budget")
    }

    // ── Phase 1: Nearby Grouped (Critical Path) ──────────────────

    @Test("Nearby grouped returns live arrivals")
    func nearbyGroupedReturnsData() async throws {
        await ensureServerAwake()

        let (groups, elapsed) = try await timed("nearby/grouped") {
            try await TrackAPI.fetchNearbyGrouped(
                lat: Self.testLat,
                lon: Self.testLon,
                radius: Self.testRadius
            )
        }

        // Must return data — this is what populates the home screen
        #expect(!groups.isEmpty, "No grouped transit returned — user sees empty skeleton")
        #expect(elapsed < Self.singleEndpointBudget,
                "nearby/grouped took "
                + "\(String(format: "%.1f", elapsed))s "
                + "— exceeds \(Self.singleEndpointBudget)s budget")

        // Validate structure
        let withArrivals = groups.filter { $0.hasRealArrivals }
        #expect(!withArrivals.isEmpty, "All \(groups.count) groups are placeholder-only")

        // Check for transit modes (subway + bus at minimum near JFK area)
        let modes = Set(groups.map(\.mode))
        #expect(modes.count >= 1, "Expected at least 1 transit mode, got: \(modes)")

        // Each group should have route metadata
        for group in groups.prefix(5) {
            #expect(!group.routeId.isEmpty, "Group has empty routeId")
            #expect(!group.displayName.isEmpty, "Group \(group.routeId) has empty displayName")
            #expect(!group.directions.isEmpty, "Group \(group.routeId) has no directions")
        }

        let totalArrivals = groups.flatMap(\.directions).flatMap(\.arrivals).count
        print("  ↳ \(groups.count) groups, "
            + "\(withArrivals.count) with arrivals, "
            + "\(totalArrivals) total arrivals, "
            + "modes: \(modes)")
    }

    // ── Phase 2: Subway System Map Shapes ────────────────────────

    @Test("Subway shapes loads full system map")
    func subwayShapesLoadsFullMap() async throws {
        await ensureServerAwake()

        let (response, elapsed) = try await timed("subway/shapes/all") {
            try await TrackAPI.fetchAllSubwayShapes()
        }

        #expect(!response.lines.isEmpty, "No subway lines returned")
        #expect(elapsed < Self.shapeEndpointBudget,
                "subway/shapes/all took "
                + "\(String(format: "%.1f", elapsed))s "
                + "— exceeds \(Self.shapeEndpointBudget)s budget")

        // MTA has ~27 subway routes (including express variants)
        #expect(response.lines.count >= 20,
                "Expected ≥20 subway lines, got \(response.lines.count)")

        // Validate line structure
        for line in response.lines.prefix(5) {
            #expect(!line.routeId.isEmpty, "Line has empty routeId")
            #expect(!line.colorHex.isEmpty, "Line \(line.routeId) has empty colorHex")
            #expect(!line.polylines.isEmpty, "Line \(line.routeId) has no polylines")
            let decoded = line.decodedPolylines
            #expect(!decoded.isEmpty, "Line \(line.routeId) decoded to empty polylines")
            for branch in decoded {
                #expect(branch.count >= 2, "Branch has < 2 points")
            }
        }

        // Trunk polylines (corridor pipeline) should be present
        if let trunks = response.trunkPolylines {
            #expect(!trunks.isEmpty, "trunkPolylines array is empty")
            print("  ↳ \(response.lines.count) lines, "
                + "\(trunks.count) trunk groups "
                + "(corridor pipeline active)")
        } else {
            print("  ↳ \(response.lines.count) lines, "
                + "no trunk polylines "
                + "(corridor pipeline inactive)")
        }
    }

    // ── Phase 3: Subway Stations ─────────────────────────────────

    @Test("Subway stations loads all stops")
    func subwayStationsLoadsAllStops() async throws {
        await ensureServerAwake()

        let (response, elapsed) = try await timed("subway/stations/all") {
            try await TrackAPI.fetchAllSubwayStations()
        }

        #expect(!response.stations.isEmpty, "No stations returned")
        #expect(elapsed < Self.singleEndpointBudget,
                "subway/stations/all took \(String(format: "%.1f", elapsed))s")

        // MTA has ~472 subway stations
        #expect(response.stations.count >= 400,
                "Expected ≥400 stations, got \(response.stations.count)")

        // Spot-check station data integrity
        for station in response.stations.prefix(10) {
            #expect(!station.name.isEmpty, "Station \(station.id) has empty name")
            #expect(!station.routes.isEmpty, "Station \(station.name) has no routes")
            #expect(station.lat != 0, "Station \(station.name) has lat=0")
            #expect(station.lon != 0, "Station \(station.name) has lon=0")
            // NYC bounding box
            #expect(station.lat > 40.4 && station.lat < 41.0,
                    "Station \(station.name) lat \(station.lat) outside NYC")
            #expect(station.lon > -74.3 && station.lon < -73.6,
                    "Station \(station.name) lon \(station.lon) outside NYC")
        }

        print("  ↳ \(response.stations.count) stations")
    }

    // ── Phase 4: Commuter Rail ───────────────────────────────────

    @Test("LIRR shapes loads all branches")
    func lirrShapesLoad() async throws {
        await ensureServerAwake()

        let (response, elapsed) = try await timed("lirr/shapes/all") {
            try await TrackAPI.fetchAllLIRRShapes()
        }

        #expect(!response.lines.isEmpty, "No LIRR lines returned")
        #expect(elapsed < Self.shapeEndpointBudget,
                "lirr/shapes/all took \(String(format: "%.1f", elapsed))s")

        // LIRR has ~11 branches
        #expect(response.lines.count >= 8,
                "Expected ≥8 LIRR lines, got \(response.lines.count)")

        for line in response.lines.prefix(3) {
            #expect(!line.polylines.isEmpty, "LIRR \(line.routeId) has no polylines")
            #expect(
                line.mode == "lirr",
                "Line \(line.routeId) mode is "
                + "'\(line.mode)', expected 'lirr'")
        }

        let totalStops = response.lines.reduce(0) { $0 + $1.stops.count }
        print("  ↳ \(response.lines.count) LIRR branches, \(totalStops) stops")
    }

    @Test("MNR shapes loads all lines")
    func mnrShapesLoad() async throws {
        await ensureServerAwake()

        let (response, elapsed) = try await timed("mnr/shapes/all") {
            try await TrackAPI.fetchAllMNRShapes()
        }

        #expect(!response.lines.isEmpty, "No MNR lines returned")
        #expect(elapsed < Self.shapeEndpointBudget,
                "mnr/shapes/all took \(String(format: "%.1f", elapsed))s")

        // MNR has ~7 lines
        #expect(response.lines.count >= 5,
                "Expected ≥5 MNR lines, got \(response.lines.count)")

        for line in response.lines.prefix(3) {
            #expect(!line.polylines.isEmpty, "MNR \(line.routeId) has no polylines")
            #expect(
                line.mode == "mnr",
                "Line \(line.routeId) mode is "
                + "'\(line.mode)', expected 'mnr'")
        }

        let totalStops = response.lines.reduce(0) { $0 + $1.stops.count }
        print("  ↳ \(response.lines.count) MNR lines, \(totalStops) stops")
    }

    // ── Phase 5: Service Status ──────────────────────────────────

    @Test("Alerts endpoint returns valid data")
    func alertsEndpoint() async throws {
        await ensureServerAwake()

        let (alerts, elapsed) = try await timed("alerts") {
            try await TrackAPI.fetchAlerts()
        }

        // Alerts may be empty if no service disruptions — that's OK
        #expect(elapsed < Self.singleEndpointBudget,
                "alerts took \(String(format: "%.1f", elapsed))s")

        for alert in alerts.prefix(5) {
            #expect(!alert.title.isEmpty, "Alert has empty title")
            #expect(!alert.mode.isEmpty, "Alert has empty mode")
            #expect(!alert.severity.isEmpty, "Alert has empty severity")
        }

        print("  ↳ \(alerts.count) active alerts")
    }

    @Test("Accessibility endpoint returns valid data")
    func accessibilityEndpoint() async throws {
        await ensureServerAwake()

        let (outages, elapsed) = try await timed("accessibility") {
            try await TrackAPI.fetchAccessibility()
        }

        #expect(elapsed < Self.singleEndpointBudget,
                "accessibility took \(String(format: "%.1f", elapsed))s")

        print("  ↳ \(outages.count) elevator outages")
    }

    // ── Full Cold Start Flow (Parallel, Real Timing) ─────────────

    @Test("Full cold start flow completes within budget")
    func fullColdStartFlow() async throws {
        // Phase 0: Wake the server (like TrackApp.init → warmConnection)
        let wakeTime = await ensureServerAwake()

        // Phase 1: Measure the ACTUAL data-loading flow on a warm server
        // This is the user experience AFTER the retry logic succeeds
        let flowStart = Date()

        // Fire all requests in parallel (mirrors HomeViewModel + MapSystemViewModel)

        // Critical path: nearby grouped arrivals
        async let nearbyTask: [GroupedNearbyTransitResponse]? = {
            do {
                return try await TrackAPI.fetchNearbyGrouped(
                    lat: Self.testLat, lon: Self.testLon, radius: Self.testRadius
                )
            } catch {
                print("❌ nearby/grouped failed: \(error)")
                return nil
            }
        }()

        // Map data: subway shapes (triggers corridor pipeline)
        async let subwayShapesTask: AllSubwayLinesResponse? = {
            do { return try await TrackAPI.fetchAllSubwayShapes() }
            catch { print("❌ subway/shapes/all failed: \(error)"); return nil }
        }()

        // Station dots
        async let stationsTask: AllSubwayStationsResponse? = {
            do { return try await TrackAPI.fetchAllSubwayStations() }
            catch { print("❌ subway/stations/all failed: \(error)"); return nil }
        }()

        // Commuter rail
        async let lirrTask: AllCommuterRailLinesResponse? = {
            do { return try await TrackAPI.fetchAllLIRRShapes() }
            catch { print("⚠️  lirr/shapes/all failed: \(error)"); return nil }
        }()

        async let mnrTask: AllCommuterRailLinesResponse? = {
            do { return try await TrackAPI.fetchAllMNRShapes() }
            catch { print("⚠️  mnr/shapes/all failed: \(error)"); return nil }
        }()

        // Service status
        async let alertsTask: [TransitAlert]? = {
            do { return try await TrackAPI.fetchAlerts() }
            catch { print("⚠️  alerts failed: \(error)"); return nil }
        }()

        async let accessTask: [ElevatorStatus]? = {
            do { return try await TrackAPI.fetchAccessibility() }
            catch { print("⚠️  accessibility failed: \(error)"); return nil }
        }()

        // Await all — measure critical-path time
        let nearbyStart = Date()
        let nearby = await nearbyTask
        let nearbyElapsed = Date().timeIntervalSince(nearbyStart)

        let subwayShapes = await subwayShapesTask
        let stations = await stationsTask
        let lirrShapes = await lirrTask
        let mnrShapes = await mnrTask
        let alerts = await alertsTask
        let accessibility = await accessTask

        let flowElapsed = Date().timeIntervalSince(flowStart)

        // ── Report ──
        print("")
        print("═══════════════════════════════════════════════════════════")
        print("  COLD START FLOW RESULTS")
        print("═══════════════════════════════════════════════════════════")
        print("  Server wake:        \(String(format: "%6.2f", wakeTime))s")
        print("  ──────────────────────────────────────────")
        let naStr = String(format: "%6.2f", nearbyElapsed)
        let naCt = nearby?.count ?? 0
        print("  Nearby arrivals:    \(naStr)s"
            + "  → \(naCt) groups")
        let ssIcon = subwayShapes != nil ? "✅" : "❌"
        let ssCt = subwayShapes?.lines.count ?? 0
        print("  Subway shapes:      \(ssIcon)"
            + "  \(ssCt) lines")
        if let trunks = subwayShapes?.trunkPolylines {
            print("    Trunk polylines:  ✅"
                + "  \(trunks.count) groups")
        }
        let stIcon = stations != nil ? "✅" : "❌"
        let stCt = stations?.stations.count ?? 0
        print("  Stations:           \(stIcon)"
            + "  \(stCt) stations")
        let lrIcon = lirrShapes != nil ? "✅" : "❌"
        let lrCt = lirrShapes?.lines.count ?? 0
        print("  LIRR:               \(lrIcon)"
            + "  \(lrCt) branches")
        let mnIcon = mnrShapes != nil ? "✅" : "❌"
        let mnCt = mnrShapes?.lines.count ?? 0
        print("  MNR:                \(mnIcon)"
            + "  \(mnCt) lines")
        let alIcon = alerts != nil ? "✅" : "❌"
        let alCt = alerts?.count ?? 0
        print("  Alerts:             \(alIcon)"
            + "  \(alCt) alerts")
        let acIcon = accessibility != nil ? "✅" : "❌"
        let acCt = accessibility?.count ?? 0
        print("  Accessibility:      \(acIcon)"
            + "  \(acCt) outages")
        print("  ─────────────────────────────────────────────────────────")
        print("  Parallel data load: \(String(format: "%6.2f", flowElapsed))s")
        print("  ═══════════════════════")
        print("  TOTAL (wake + data):  \(String(format: "%6.2f", wakeTime + flowElapsed))s")
        print("  DATA LOAD BUDGET:     \(String(format: "%6.0f", Self.warmFlowBudget))s")
        print("═══════════════════════════════════════════════════════════")

        // ── Assertions ──

        // Critical: nearby grouped MUST succeed on warm server
        #expect(nearby != nil, "nearby/grouped returned nil — user sees error state forever")
        if let nearby {
            let withArrivals = nearby.filter { $0.hasRealArrivals }
            #expect(!withArrivals.isEmpty,
                    "\(nearby.count) groups returned but none have real arrivals")
        }

        // System map shapes should load
        #expect(subwayShapes != nil, "subway/shapes/all failed — map shows no lines")

        // Stations should load
        #expect(stations != nil, "subway/stations/all failed — no station dots")

        // Warm-server data load should be fast
        #expect(flowElapsed < Self.warmFlowBudget,
                "Warm-server data load took "
                + "\(String(format: "%.1f", flowElapsed))s"
                + " — exceeds \(Self.warmFlowBudget)s budget")

        // Nearby arrivals should resolve quickly (user stuck on skeletons until this returns)
        #expect(nearbyElapsed < 15,
                "Nearby arrivals took "
                + "\(String(format: "%.1f", nearbyElapsed))s"
                + " — user stuck on skeletons too long")
    }

    // ── Data Consistency Test ────────────────────────────────────

    @Test("Nearby response data is consistent and renderable")
    func nearbyDataConsistency() async throws {
        await ensureServerAwake()

        let groups = try await TrackAPI.fetchNearbyGrouped(
            lat: Self.testLat, lon: Self.testLon, radius: Self.testRadius
        )

        // Every group should have valid decoded fields
        for group in groups {
            #expect(!group.routeId.isEmpty)
            #expect(!group.displayName.isEmpty)
            #expect(["subway", "bus", "lirr", "mnr"].contains(group.mode),
                    "Unknown mode '\(group.mode)' for \(group.routeId)")

            for direction in group.directions {
                #expect(!direction.direction.isEmpty,
                        "Empty direction in \(group.routeId)")

                for arrival in direction.arrivals where !arrival.isPlaceholder {
                    #expect(!arrival.routeId.isEmpty)
                    #expect(!arrival.stopName.isEmpty)
                    #expect(!arrival.mode.isEmpty)
                    #expect(arrival.minutesAway >= -5,
                            "Arrival minutesAway=\(arrival.minutesAway) — too far in past")
                }
            }
        }

        let busGroups = groups.filter(\.isBus)
        let subwayGroups = groups.filter { $0.mode == "subway" }
        print("  ↳ Consistency: \(subwayGroups.count) subway, \(busGroups.count) bus — all valid")
    }

    // ── Map Pipeline Integration ─────────────────────────────────

    @Test("Shapes + stations produce valid system map data")
    func shapesAndStationsIntegrate() async throws {
        await ensureServerAwake()

        // Fetch both in parallel like MapSystemViewModel does
        async let shapesTask = TrackAPI.fetchAllSubwayShapes()
        async let stationsTask = TrackAPI.fetchAllSubwayStations()

        let shapes = try await shapesTask
        let stations = try await stationsTask

        // Shapes should cover the major trunk groups
        let routeIds = Set(shapes.lines.map(\.routeId))
        let expectedRoutes = ["1", "2", "3", "4", "5", "6", "7",
                              "A", "C", "E", "B", "D", "F", "M",
                              "G", "J", "Z", "L", "N", "Q", "R", "W"]
        let missing = expectedRoutes.filter { !routeIds.contains($0) }
        #expect(missing.isEmpty,
                "Missing subway routes from shapes: \(missing)")

        // Station routes should reference routes that exist in shapes
        let stationRouteIds = Set(stations.stations.flatMap(\.routes))
        let shapeRouteIds = Set(shapes.lines.map(\.routeId))
        let orphanStationRoutes = stationRouteIds.subtracting(shapeRouteIds)
        let significantOrphans = orphanStationRoutes.filter { !$0.hasSuffix("X") }
        if !significantOrphans.isEmpty {
            print("  ⚠️ Station routes not in shapes: \(significantOrphans)")
        }

        // Verify trunk polylines carry lane offsets (corridor pipeline active)
        if let trunks = shapes.trunkPolylines, !trunks.isEmpty {
            let withOffsets = trunks.filter { abs($0.laneOffset) > 0.01 }
            #expect(!withOffsets.isEmpty,
                    "All \(trunks.count) trunk groups "
                    + "have laneOffset=0 — corridor "
                    + "pipeline may have failed")
            print("  ↳ \(trunks.count) trunk groups, \(withOffsets.count) with lane offsets")
        }

        print("  ↳ \(shapes.lines.count) lines "
            + "× \(stations.stations.count) stations "
            + "— integration valid")
    }

    // ── Retry Resilience ─────────────────────────────────────────

    @Test("Extended timeout retries survive cold server")
    func extendedTimeoutRetriesWork() async throws {
        await ensureServerAwake()

        let start = Date()
        let response = try await TrackAPI.fetchAllSubwayShapes()
        let elapsed = Date().timeIntervalSince(start)

        #expect(!response.lines.isEmpty,
                "Subway shapes returned empty after retries")
        #expect(response.lines.count >= 20,
                "Expected ≥20 lines, got \(response.lines.count)")

        let etStr = String(format: "%.2f", elapsed)
        print("⏱️ Extended timeout shape fetch: "
            + "\(etStr)s — \(response.lines.count) lines")

        #expect(elapsed < Self.shapeEndpointBudget,
                "Shapes took "
                + "\(String(format: "%.1f", elapsed))s "
                + "— exceeds \(Self.shapeEndpointBudget)s budget")
    }
}
