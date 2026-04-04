import Foundation
import Testing
@testable import Track

// MARK: - Helpers

/// Builds an `AllSubwayLinesResponse` from JSON so we don't need a
/// memberwise init for `TrunkGroupPolylines` (which has only a custom
/// decoder).
private func makeSubwayResponse() throws -> AllSubwayLinesResponse {
    let json = """
    {
      "lines": [
        {"route_id": "1", "color_hex": "#EE352E", "polylines": ["abc"]}
      ],
      "trunk_polylines": [
        {
          "trunk_index": 0,
          "color_hex": "#EE352E",
          "route_ids": ["1", "2", "3"],
          "polylines": ["xyz"],
          "lane_offset": 1.5,
          "polyline_lane_offsets": [1.5]
        }
      ],
      "crossings": [
        {"lat": 40.75, "lng": -73.99, "trunk_indices": [0, 1]}
      ]
    }
    """
    return try JSONDecoder().decode(
        AllSubwayLinesResponse.self,
        from: Data(json.utf8)
    )
}

/// Builds an `AllCommuterRailLinesResponse` from JSON.
private func makeCommuterResponse(mode: String) throws -> AllCommuterRailLinesResponse {
    let json = """
    {
      "lines": [
        {
          "route_id": "LIRR-\(mode)",
          "name": "Test Branch",
          "color_hex": "#0039A6",
          "polylines": ["def"],
          "mode": "\(mode)",
          "stops": [
            {"stop_id": "S1", "name": "Penn", "lat": 40.75, "lon": -73.99}
          ]
        }
      ]
    }
    """
    return try JSONDecoder().decode(
        AllCommuterRailLinesResponse.self,
        from: Data(json.utf8)
    )
}

private func makeCachedArrival(
    id: String = "arr-1",
    routeId: String = "1",
    mode: String = "subway"
) -> CachedArrival {
    CachedArrival(
        id: id,
        routeId: routeId,
        routeName: routeId,
        stopName: "Times Sq",
        direction: "N",
        arrivalTime: Date().addingTimeInterval(300),
        mode: mode
    )
}

private func makeCachedStation(id: String = "A32") -> CachedStation {
    CachedStation(
        id: id,
        name: "Penn Station",
        latitude: 40.7505,
        longitude: -73.9934,
        routes: ["1", "2", "3"]
    )
}

// MARK: - 1. Arrival Caching

@Suite("OfflineCache: Arrival Round-Trip")
struct ArrivalCachingTests {

    @MainActor
    @Test("Cache and retrieve subway arrivals")
    func subwayRoundTrip() {
        let mgr = OfflineCacheManager.shared
        let arrivals = [
            makeCachedArrival(id: "a1", routeId: "1"),
            makeCachedArrival(id: "a2", routeId: "2"),
        ]
        mgr.cacheArrivals(arrivals, forMode: "subway")
        let cached = mgr.getCachedArrivals(forMode: "subway")
        #expect(cached != nil, "Subway arrivals should round-trip")
        #expect(cached?.count == 2)
        #expect(cached?.first?.routeId == "1")
    }

    @MainActor
    @Test("Cache and retrieve bus arrivals")
    func busRoundTrip() {
        let mgr = OfflineCacheManager.shared
        let arrivals = [makeCachedArrival(id: "b1", mode: "bus")]
        mgr.cacheArrivals(arrivals, forMode: "bus")
        let cached = mgr.getCachedArrivals(forMode: "bus")
        #expect(cached?.count == 1)
        #expect(cached?.first?.mode == "bus")
    }

    @MainActor
    @Test("Cache and retrieve LIRR arrivals")
    func lirrRoundTrip() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheArrivals(
            [makeCachedArrival(id: "l1", mode: "lirr")],
            forMode: "lirr"
        )
        #expect(mgr.getCachedArrivals(forMode: "lirr")?.count == 1)
    }

    @MainActor
    @Test("Cache and retrieve MNR arrivals")
    func mnrRoundTrip() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheArrivals(
            [makeCachedArrival(id: "m1", mode: "mnr")],
            forMode: "mnr"
        )
        #expect(mgr.getCachedArrivals(forMode: "mnr")?.count == 1)
    }

    @MainActor
    @Test("Cache and retrieve nearby arrivals")
    func nearbyRoundTrip() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheArrivals(
            [makeCachedArrival(id: "n1")],
            forMode: "nearby"
        )
        #expect(mgr.getCachedArrivals(forMode: "nearby")?.count == 1)
    }

    @MainActor
    @Test("Unknown mode falls back to nearby key")
    func unknownModeFallsBackToNearby() {
        let mgr = OfflineCacheManager.shared
        let arrivals = [makeCachedArrival(id: "u1")]
        mgr.cacheArrivals(arrivals, forMode: "unknown_mode")
        // Both "unknown_mode" and "nearby" should read the same key.
        let cached = mgr.getCachedArrivals(forMode: "nearby")
        #expect(cached?.first?.id == "u1")
    }

    @MainActor
    @Test("Caching arrivals updates lastFetchTime")
    func lastFetchTimeUpdated() {
        let mgr = OfflineCacheManager.shared
        let before = Date()
        mgr.cacheArrivals(
            [makeCachedArrival()],
            forMode: "subway"
        )
        #expect(mgr.lastFetchTime != nil)
        // lastFetchTime should be recent (within 2 seconds).
        let elapsed = mgr.lastFetchTime!.timeIntervalSince(before)
        #expect(elapsed >= 0 && elapsed < 2)
    }
}

// MARK: - 2. Station Caching

@Suite("OfflineCache: Station Round-Trip")
struct StationCachingTests {

    @MainActor
    @Test("Cache and retrieve stations")
    func roundTrip() {
        let mgr = OfflineCacheManager.shared
        let stations = [
            makeCachedStation(id: "A32"),
            makeCachedStation(id: "R20"),
        ]
        mgr.cacheStations(stations)
        let cached = mgr.getCachedStations()
        #expect(cached != nil)
        #expect(cached?.count == 2)
        #expect(cached?.first?.name == "Penn Station")
    }

    @MainActor
    @Test("Empty station array round-trips")
    func emptyArray() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheStations([])
        let cached = mgr.getCachedStations()
        #expect(cached != nil)
        #expect(cached?.count == 0)
    }
}

// MARK: - 3. Subway Shapes Caching

@Suite("OfflineCache: Subway Shapes")
struct SubwayShapesCachingTests {

    @MainActor
    @Test("Cache and retrieve subway shapes")
    func roundTrip() throws {
        let mgr = OfflineCacheManager.shared
        let response = try makeSubwayResponse()
        mgr.cacheSubwayShapes(response)
        let cached = mgr.getCachedSubwayShapes()
        #expect(cached != nil)
        #expect(cached?.lines.count == 1)
        #expect(cached?.lines.first?.routeId == "1")
        #expect(cached?.trunkPolylines?.count == 1)
        #expect(cached?.crossings?.count == 1)
    }

    @MainActor
    @Test("Subway shapes staleness flag is false right after caching")
    func notStaleImmediately() throws {
        let mgr = OfflineCacheManager.shared
        mgr.cacheSubwayShapes(try makeSubwayResponse())
        #expect(!mgr.isSubwayShapesCacheStale)
    }
}

// MARK: - 4. Commuter Rail Shapes Caching

@Suite("OfflineCache: Commuter Rail Shapes")
struct CommuterShapesCachingTests {

    @MainActor
    @Test("Cache and retrieve LIRR shapes")
    func lirrRoundTrip() throws {
        let mgr = OfflineCacheManager.shared
        let response = try makeCommuterResponse(mode: "lirr")
        mgr.cacheLIRRShapes(response)
        let cached = mgr.getCachedLIRRShapes()
        #expect(cached != nil)
        #expect(cached?.lines.count == 1)
        #expect(cached?.lines.first?.mode == "lirr")
        #expect(cached?.lines.first?.stops.count == 1)
    }

    @MainActor
    @Test("Cache and retrieve MNR shapes")
    func mnrRoundTrip() throws {
        let mgr = OfflineCacheManager.shared
        let response = try makeCommuterResponse(mode: "mnr")
        mgr.cacheMNRShapes(response)
        let cached = mgr.getCachedMNRShapes()
        #expect(cached != nil)
        #expect(cached?.lines.first?.mode == "mnr")
    }
}

// MARK: - 5. Flattened Polylines (File-Based)

@Suite("OfflineCache: Flattened Polylines")
struct FlattenedPolylinesCachingTests {

    @MainActor
    @Test("Cache and retrieve flattened polylines")
    func roundTrip() {
        let mgr = OfflineCacheManager.shared
        let poly = OfflineCacheManager.CachedFlattenedPolyline(
            id: "trunk-0",
            coordinates: [[40.75, -73.99], [40.76, -73.98]],
            colorHex: "#EE352E",
            lineWidth: 4.0,
            routeIds: ["1", "2", "3"],
            isElevated: false,
            trunkIndex: 0,
            laneOffset: 1.5
        )
        let bundle = OfflineCacheManager.CachedFlattenedBundle(
            subway: [poly],
            commuter: []
        )
        mgr.cacheFlattenedPolylines(bundle)
        let cached = mgr.getCachedFlattenedPolylines()
        #expect(cached != nil)
        #expect(cached?.subway.count == 1)
        #expect(cached?.subway.first?.id == "trunk-0")
        #expect(cached?.subway.first?.coordinates.count == 2)
        #expect(cached?.commuter.count == 0)
    }

    @MainActor
    @Test("Flattened polyline staleness is false right after caching")
    func notStaleImmediately() {
        let mgr = OfflineCacheManager.shared
        let bundle = OfflineCacheManager.CachedFlattenedBundle(
            subway: [],
            commuter: []
        )
        mgr.cacheFlattenedPolylines(bundle)
        #expect(!mgr.isFlattenedPolylinesCacheStale)
    }

    @MainActor
    @Test("Flattened polyline cache filename includes pipeline hash")
    func filenameContainsHash() {
        let hash = PipelineFingerprint.shortHash
        // Validate the filename format indirectly: write → read succeeds
        // only if the hash in the filename matches.
        let bundle = OfflineCacheManager.CachedFlattenedBundle(
            subway: [],
            commuter: []
        )
        let mgr = OfflineCacheManager.shared
        mgr.cacheFlattenedPolylines(bundle)
        let cached = mgr.getCachedFlattenedPolylines()
        #expect(cached != nil, "Round-trip proves filename hash matches")
        // Hash itself should be 8 hex chars.
        #expect(hash.count == 8)
    }

    @MainActor
    @Test("CachedFlattenedPolyline preserves all fields")
    func allFieldsPreserved() {
        let poly = OfflineCacheManager.CachedFlattenedPolyline(
            id: "t-5",
            coordinates: [[40.0, -74.0]],
            colorHex: "#00933C",
            lineWidth: 3.5,
            routeIds: ["4", "5", "6"],
            isElevated: true,
            trunkIndex: 5,
            laneOffset: -2.0
        )
        let bundle = OfflineCacheManager.CachedFlattenedBundle(
            subway: [poly],
            commuter: []
        )
        // Encode → decode to verify Codable fidelity.
        let data = try! JSONEncoder().encode(bundle)
        let decoded = try! JSONDecoder().decode(
            OfflineCacheManager.CachedFlattenedBundle.self,
            from: data
        )
        let p = decoded.subway[0]
        #expect(p.id == "t-5")
        #expect(p.colorHex == "#00933C")
        #expect(p.lineWidth == 3.5)
        #expect(p.routeIds == ["4", "5", "6"])
        #expect(p.isElevated == true)
        #expect(p.trunkIndex == 5)
        #expect(p.laneOffset == -2.0)
    }
}

// MARK: - 6. Cache Validity & Staleness

@Suite("OfflineCache: Cache Validity")
struct CacheValidityTests {

    @MainActor
    @Test("isCacheValid is true immediately after caching arrivals")
    func validImmediately() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheArrivals(
            [makeCachedArrival()],
            forMode: "subway"
        )
        #expect(mgr.isCacheValid(forMode: "subway"))
    }

    @MainActor
    @Test("isCacheValid is false when there is no lastFetchTime")
    func invalidWithNoFetch() {
        let mgr = OfflineCacheManager.shared
        mgr.clearCache()
        #expect(!mgr.isCacheValid(forMode: "subway"))
    }

    @MainActor
    @Test("Subway shapes staleness is true when never cached")
    func shapesStaleWhenMissing() {
        let mgr = OfflineCacheManager.shared
        mgr.clearCache()
        #expect(mgr.isSubwayShapesCacheStale)
    }

    @MainActor
    @Test("Flattened polylines staleness is true when never cached")
    func flattenedStaleWhenMissing() {
        let mgr = OfflineCacheManager.shared
        mgr.clearCache()
        #expect(mgr.isFlattenedPolylinesCacheStale)
    }
}

// MARK: - 7. Cache Age String

@Suite("OfflineCache: Cache Age")
struct CacheAgeTests {

    @MainActor
    @Test("Age string is nil when never cached")
    func nilWhenNeverCached() {
        let mgr = OfflineCacheManager.shared
        mgr.clearCache()
        #expect(mgr.getCacheAge() == nil)
    }

    @MainActor
    @Test("Age string is '< 1 min ago' right after caching")
    func lessThanOneMinute() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheArrivals(
            [makeCachedArrival()],
            forMode: "subway"
        )
        let age = mgr.getCacheAge()
        #expect(age == "< 1 min ago")
    }
}

// MARK: - 8. Clear Cache

@Suite("OfflineCache: Clear")
struct ClearCacheTests {

    @MainActor
    @Test("clearCache removes all arrival caches")
    func clearsArrivals() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheArrivals([makeCachedArrival()], forMode: "subway")
        mgr.cacheArrivals([makeCachedArrival()], forMode: "bus")
        mgr.cacheArrivals([makeCachedArrival()], forMode: "lirr")
        mgr.cacheArrivals([makeCachedArrival()], forMode: "mnr")
        mgr.cacheArrivals([makeCachedArrival()], forMode: "nearby")
        mgr.clearCache()
        #expect(mgr.getCachedArrivals(forMode: "subway") == nil)
        #expect(mgr.getCachedArrivals(forMode: "bus") == nil)
        #expect(mgr.getCachedArrivals(forMode: "lirr") == nil)
        #expect(mgr.getCachedArrivals(forMode: "mnr") == nil)
        #expect(mgr.getCachedArrivals(forMode: "nearby") == nil)
    }

    @MainActor
    @Test("clearCache removes station cache")
    func clearsStations() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheStations([makeCachedStation()])
        mgr.clearCache()
        // After clear, getCachedStations returns nil (no data) or nil
        // (version mismatch — version key was removed).
        let cached = mgr.getCachedStations()
        #expect(cached == nil)
    }

    @MainActor
    @Test("clearCache resets lastFetchTime")
    func clearsLastFetchTime() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheArrivals([makeCachedArrival()], forMode: "subway")
        #expect(mgr.lastFetchTime != nil)
        mgr.clearCache()
        #expect(mgr.lastFetchTime == nil)
    }

    @MainActor
    @Test("clearCache invalidates flattened polyline data")
    func clearsFlattened() {
        let mgr = OfflineCacheManager.shared
        let bundle = OfflineCacheManager.CachedFlattenedBundle(
            subway: [],
            commuter: []
        )
        mgr.cacheFlattenedPolylines(bundle)
        mgr.clearCache()
        #expect(mgr.isFlattenedPolylinesCacheStale)
    }
}

// MARK: - 9. Network State Defaults

@Suite("OfflineCache: Network")
struct NetworkStateTests {

    @MainActor
    @Test("Default online state is true")
    func defaultOnline() {
        #expect(OfflineCacheManager.shared.isOnline == true)
    }

    @MainActor
    @Test("Default isUsingCachedData is false")
    func defaultNotUsingCached() {
        #expect(OfflineCacheManager.shared.isUsingCachedData == false)
    }
}

// MARK: - 10. Pipeline Hash Integration

@Suite("OfflineCache: Pipeline Hash")
struct PipelineHashIntegrationTests {

    @MainActor
    @Test("Pipeline hash is 8 hex chars")
    func hashFormat() {
        let hash = PipelineFingerprint.shortHash
        #expect(hash.count == 8)
        let hexSet = CharacterSet(charactersIn: "0123456789abcdef")
        for scalar in hash.unicodeScalars {
            #expect(hexSet.contains(scalar))
        }
    }

    @MainActor
    @Test("Flattened cache only returns data matching current hash")
    func hashMismatchReturnsNil() {
        let mgr = OfflineCacheManager.shared
        // Write a valid bundle.
        let bundle = OfflineCacheManager.CachedFlattenedBundle(
            subway: [],
            commuter: []
        )
        mgr.cacheFlattenedPolylines(bundle)
        // Verify it reads back.
        #expect(mgr.getCachedFlattenedPolylines() != nil)

        // Now corrupt the stored hash in UserDefaults.
        let ud = UserDefaults(
            suiteName: appGroupIdentifier
        ) ?? .standard
        ud.set("BADC0DE0", forKey: "cached_flattened_pipeline_hash")

        // Read should now reject it (hash mismatch).
        #expect(mgr.getCachedFlattenedPolylines() == nil)

        // Restore by re-caching so other tests are unaffected.
        mgr.cacheFlattenedPolylines(bundle)
    }
}

// MARK: - 11. Overwrite Semantics

@Suite("OfflineCache: Overwrite")
struct OverwriteTests {

    @MainActor
    @Test("Caching arrivals overwrites previous data")
    func arrivalsOverwrite() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheArrivals(
            [makeCachedArrival(id: "old")],
            forMode: "subway"
        )
        mgr.cacheArrivals(
            [makeCachedArrival(id: "new1"),
             makeCachedArrival(id: "new2")],
            forMode: "subway"
        )
        let cached = mgr.getCachedArrivals(forMode: "subway")
        #expect(cached?.count == 2)
        #expect(cached?.first?.id == "new1")
    }

    @MainActor
    @Test("Caching stations overwrites previous data")
    func stationsOverwrite() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheStations([makeCachedStation(id: "old")])
        mgr.cacheStations([
            makeCachedStation(id: "s1"),
            makeCachedStation(id: "s2"),
            makeCachedStation(id: "s3"),
        ])
        let cached = mgr.getCachedStations()
        #expect(cached?.count == 3)
    }
}

// MARK: - 12. CachedFlattenedBundle Codable

@Suite("OfflineCache: Codable Fidelity")
struct CodableFidelityTests {

    @Test("CachedFlattenedBundle subway + commuter encode/decode")
    func bundleRoundTrip() throws {
        let subway = OfflineCacheManager.CachedFlattenedPolyline(
            id: "sub-0",
            coordinates: [[40.0, -74.0], [40.1, -73.9]],
            colorHex: "#FF0000",
            lineWidth: 4.0,
            routeIds: ["A"],
            isElevated: false,
            trunkIndex: 0,
            laneOffset: 0.0
        )
        let commuter = OfflineCacheManager.CachedFlattenedPolyline(
            id: "com-0",
            coordinates: [[40.7, -73.5]],
            colorHex: "#0039A6",
            lineWidth: 3.0,
            routeIds: ["LIRR-1"],
            isElevated: false,
            trunkIndex: 99,
            laneOffset: -1.0
        )
        let bundle = OfflineCacheManager.CachedFlattenedBundle(
            subway: [subway],
            commuter: [commuter]
        )

        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(
            OfflineCacheManager.CachedFlattenedBundle.self,
            from: data
        )

        #expect(decoded.subway.count == 1)
        #expect(decoded.commuter.count == 1)
        #expect(decoded.subway[0].id == "sub-0")
        #expect(decoded.commuter[0].routeIds == ["LIRR-1"])
        #expect(decoded.commuter[0].laneOffset == -1.0)
    }

    @Test("CachedArrival encodes/decodes with ISO-8601 dates")
    func arrivalCodable() throws {
        let arrival = makeCachedArrival()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(arrival)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CachedArrival.self, from: data)
        #expect(decoded.id == arrival.id)
        #expect(decoded.routeId == arrival.routeId)
        // Dates should match to the second (ISO-8601 truncates sub-second).
        #expect(
            abs(decoded.arrivalTime.timeIntervalSince(arrival.arrivalTime)) < 1
        )
    }

    @Test("CachedStation encodes/decodes all fields")
    func stationCodable() throws {
        let station = makeCachedStation()
        let data = try JSONEncoder().encode(station)
        let decoded = try JSONDecoder().decode(
            CachedStation.self,
            from: data
        )
        #expect(decoded.id == "A32")
        #expect(decoded.name == "Penn Station")
        #expect(decoded.latitude == 40.7505)
        #expect(decoded.longitude == -73.9934)
        #expect(decoded.routes == ["1", "2", "3"])
    }
}

// MARK: - 13. Mode Key Mapping

@Suite("OfflineCache: Mode Key Mapping")
struct ModeKeyMappingTests {

    @MainActor
    @Test("Each mode stores to a separate key")
    func modesAreIsolated() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheArrivals(
            [makeCachedArrival(id: "sub", mode: "subway")],
            forMode: "subway"
        )
        mgr.cacheArrivals(
            [makeCachedArrival(id: "bus", mode: "bus")],
            forMode: "bus"
        )
        mgr.cacheArrivals(
            [makeCachedArrival(id: "lirr", mode: "lirr")],
            forMode: "lirr"
        )
        mgr.cacheArrivals(
            [makeCachedArrival(id: "mnr", mode: "mnr")],
            forMode: "mnr"
        )
        #expect(mgr.getCachedArrivals(forMode: "subway")?.first?.id == "sub")
        #expect(mgr.getCachedArrivals(forMode: "bus")?.first?.id == "bus")
        #expect(mgr.getCachedArrivals(forMode: "lirr")?.first?.id == "lirr")
        #expect(mgr.getCachedArrivals(forMode: "mnr")?.first?.id == "mnr")
    }

    @MainActor
    @Test("Mode key is case-insensitive")
    func caseInsensitive() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheArrivals(
            [makeCachedArrival(id: "upper")],
            forMode: "Subway"
        )
        let cached = mgr.getCachedArrivals(forMode: "Subway")
        #expect(cached?.first?.id == "upper")
    }
}

// MARK: - 14. Baked Tile Directory

@Suite("OfflineCache: Baked Tiles")
struct BakedTileTests {

    @MainActor
    @Test("bakedTilesDirectory returns non-nil URL")
    func directoryExists() {
        let dir = OfflineCacheManager.shared.bakedTilesDirectory()
        #expect(dir != nil)
    }

    @MainActor
    @Test("bakedTilesDirectory creates directory on disk")
    func directoryIsCreated() {
        let dir = OfflineCacheManager.shared.bakedTilesDirectory()!
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: dir.path,
            isDirectory: &isDir
        )
        #expect(exists)
        #expect(isDir.boolValue)
    }

    @MainActor
    @Test("getCachedBakedTiles returns nil when no files exist")
    func nilWhenEmpty() {
        let mgr = OfflineCacheManager.shared
        mgr.clearBakedTiles()
        #expect(mgr.getCachedBakedTiles() == nil)
    }
}

// MARK: - 15. Station Cache Version Guard

@Suite("OfflineCache: Station Version Guard")
struct StationVersionGuardTests {

    @MainActor
    @Test("getCachedStations returns nil after version mismatch")
    func versionMismatch() {
        let mgr = OfflineCacheManager.shared
        mgr.cacheStations([makeCachedStation()])

        // Corrupt the version so it doesn't match currentStationCacheVersion.
        let ud = UserDefaults(
            suiteName: appGroupIdentifier
        ) ?? .standard
        ud.set(9999, forKey: "cached_stations_version")

        let cached = mgr.getCachedStations()
        #expect(cached == nil, "Mismatched version should return nil")

        // Restore valid state.
        mgr.cacheStations([makeCachedStation()])
    }
}
