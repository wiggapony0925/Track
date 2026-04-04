// Manages offline caching and network reachability for subway underground scenarios.
// Caches arrivals, routes, and provides fallback data when no WiFi is available.

import Foundation
import Network
import Combine

/// Manages offline caching and network connectivity monitoring
@MainActor
final class OfflineCacheManager: ObservableObject {
    static let shared = OfflineCacheManager()
    
    // MARK: - Published Properties
    
    /// Whether the device currently has network connectivity
    @Published private(set) var isOnline: Bool = true
    
    /// Whether we're currently using cached data (vs live data)
    @Published var isUsingCachedData: Bool = false
    
    /// Timestamp of last successful data fetch
    @Published private(set) var lastFetchTime: Date?
    
    // MARK: - Private Properties
    
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.track.networkmonitor")
    private let userDefaults: UserDefaults
    
    // Cache keys
    private enum CacheKey {
        static let nearbyArrivals = "cached_nearby_arrivals"
        static let subwayArrivals = "cached_subway_arrivals"
        static let busArrivals = "cached_bus_arrivals"
        static let lirrArrivals = "cached_lirr_arrivals"
        static let mnrArrivals = "cached_mnr_arrivals"
        static let lastFetchTime = "cached_last_fetch_time"
        static let cachedStations = "cached_stations"
        static let stationCacheVersion = "cached_stations_version"
        static let lirrShapes = "cached_lirr_shapes"
        static let mnrShapes = "cached_mnr_shapes"
        static let subwayShapes = "cached_subway_shapes_v4"
        static let subwayShapesCachedAt = "cached_subway_shapes_timestamp_v4"
        static let flattenedPolylines = "cached_flattened_polylines"
        static let flattenedPolylinesCachedAt = "cached_flattened_polylines_timestamp"
        static let flattenedPipelineHash = "cached_flattened_pipeline_hash"
    }

    /// Bump this whenever the station consolidation logic or hash
    /// algorithm changes.  On mismatch the stale cache is discarded
    /// so users never see leftover wrong-coordinate centroids.
    private static let currentStationCacheVersion = 3

    /// Auto-computed fingerprint of every algorithm constant that
    /// affects flattened polyline geometry.  When any constant changes
    /// the hash changes automatically — no manual version bumps needed.
    /// See `PipelineFingerprint` for the full parameter registry.
    private static let pipelineHash: String = PipelineFingerprint.shortHash
    
    // MARK: - Initialization
    
    private init() {
        // Use App Group for widget access
        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            self.userDefaults = groupDefaults
        } else {
            self.userDefaults = .standard
        }
        
        // Load last fetch time
        if let timestamp = userDefaults.object(forKey: CacheKey.lastFetchTime) as? Date {
            self.lastFetchTime = timestamp
        }

        // Remove legacy cache keys from previous versions
        let legacyKeys = [
            "cached_subway_shapes",
            "cached_subway_shapes_timestamp",
            "cached_subway_shapes_v2",
            "cached_subway_shapes_timestamp_v2",
            "cached_subway_shapes_v3",
            "cached_subway_shapes_timestamp_v3",
        ]
        // Legacy per-version timestamp keys (v10–v14)
        let legacyTimestamps = (10...14).map {
            "cached_flattened_polylines_timestamp_v\($0)"
        }
        for key in legacyKeys + legacyTimestamps {
            userDefaults.removeObject(forKey: key)
        }
        
        startNetworkMonitoring()
    }
    
    deinit {
        monitor.cancel()
    }
    
    // MARK: - Network Monitoring
    
    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isOnline = isSatisfied
                
                // If we just came online, clear the cached data flag
                if isSatisfied {
                    self.isUsingCachedData = false
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }
    
    // MARK: - Cache Arrivals
    
    /// Cache arrival data for a specific mode
    func cacheArrivals(_ arrivals: [CachedArrival], forMode mode: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        guard let data = try? encoder.encode(arrivals) else { return }
        
        let key = cacheKey(forMode: mode)
        userDefaults.set(data, forKey: key)
        
        // Update last fetch time
        lastFetchTime = Date()
        userDefaults.set(lastFetchTime, forKey: CacheKey.lastFetchTime)
    }
    
    /// Retrieve cached arrivals for a specific mode
    func getCachedArrivals(forMode mode: String) -> [CachedArrival]? {
        let key = cacheKey(forMode: mode)
        guard let data = userDefaults.data(forKey: key) else { return nil }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        return try? decoder.decode([CachedArrival].self, from: data)
    }
    
    /// Get the age of cached data in human-readable format
    func getCacheAge() -> String? {
        guard let fetchTime = lastFetchTime else { return nil }
        
        let elapsed = Date().timeIntervalSince(fetchTime)
        
        if elapsed < 60 {
            return "< 1 min ago"
        } else if elapsed < 3600 {
            let minutes = Int(elapsed / 60)
            return "\(minutes) min ago"
        } else {
            let hours = Int(elapsed / 3600)
            return "\(hours) hr ago"
        }
    }
    
    /// Check if cache is still valid (less than 30 minutes old)
    func isCacheValid(forMode mode: String) -> Bool {
        guard let fetchTime = lastFetchTime else { return false }
        let elapsed = Date().timeIntervalSince(fetchTime)
        return elapsed < 1800 // 30 minutes
    }
    
    // MARK: - Cache Stations
    
    /// Cache station data for offline display
    func cacheStations(_ stations: [CachedStation]) {
        guard let data = try? JSONEncoder().encode(stations) else { return }
        userDefaults.set(data, forKey: CacheKey.cachedStations)
        userDefaults.set(Self.currentStationCacheVersion, forKey: CacheKey.stationCacheVersion)
    }
    
    /// Get cached stations — returns nil when the cache was written by
    /// an older version (different hash / consolidation logic) so that
    /// stale wrong-coordinate centroids are never shown.
    func getCachedStations() -> [CachedStation]? {
        let stored = userDefaults.integer(forKey: CacheKey.stationCacheVersion)
        guard stored == Self.currentStationCacheVersion else {
            // Wipe stale cache so it's never read again
            userDefaults.removeObject(forKey: CacheKey.cachedStations)
            userDefaults.removeObject(forKey: CacheKey.stationCacheVersion)
            return nil
        }
        guard let data = userDefaults.data(forKey: CacheKey.cachedStations) else { return nil }
        return try? JSONDecoder().decode([CachedStation].self, from: data)
    }
    
    // MARK: - Cache Subway Shapes

    /// Cache subway line shapes for instant system map on next launch.
    /// Written to UserDefaults after a successful /subway/shapes/all fetch.
    func cacheSubwayShapes(_ response: AllSubwayLinesResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        userDefaults.set(data, forKey: CacheKey.subwayShapes)
        userDefaults.set(Date(), forKey: CacheKey.subwayShapesCachedAt)
    }

    /// Get disk-cached subway shapes (nil if never cached).
    func getCachedSubwayShapes() -> AllSubwayLinesResponse? {
        guard let data = userDefaults.data(forKey: CacheKey.subwayShapes) else { return nil }
        return try? JSONDecoder().decode(AllSubwayLinesResponse.self, from: data)
    }

    /// Whether the subway shapes disk cache is stale (> 7 days old) or missing.
    /// Subway shapes change extremely rarely (MTA service changes happen
    /// a few times per year).  The previous 24-hour TTL forced a full
    /// re-download every day, adding 60-90 s to cold starts when the
    /// backend was also cold.  7 days matches Transit app's approach:
    /// cache shapes semi-permanently, refresh opportunistically.
    var isSubwayShapesCacheStale: Bool {
        guard let ts = userDefaults.object(
            forKey: CacheKey.subwayShapesCachedAt
        ) as? Date else { return true }
        return Date().timeIntervalSince(ts) > 604_800  // 7 days
    }

    // MARK: - Cache Commuter Rail Shapes
    
    /// Cache LIRR line shapes for offline map display
    func cacheLIRRShapes(_ response: AllCommuterRailLinesResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        userDefaults.set(data, forKey: CacheKey.lirrShapes)
    }
    
    /// Cache Metro-North line shapes for offline map display
    func cacheMNRShapes(_ response: AllCommuterRailLinesResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        userDefaults.set(data, forKey: CacheKey.mnrShapes)
    }
    
    /// Get cached LIRR shapes
    func getCachedLIRRShapes() -> AllCommuterRailLinesResponse? {
        guard let data = userDefaults.data(forKey: CacheKey.lirrShapes) else { return nil }
        return try? JSONDecoder().decode(AllCommuterRailLinesResponse.self, from: data)
    }
    
    /// Get cached Metro-North shapes
    func getCachedMNRShapes() -> AllCommuterRailLinesResponse? {
        guard let data = userDefaults.data(forKey: CacheKey.mnrShapes) else { return nil }
        return try? JSONDecoder().decode(AllCommuterRailLinesResponse.self, from: data)
    }

    // MARK: - Cache Flattened Polylines (Pre-computed for instant cold start)

    /// Serializable representation of a flattened polyline for disk caching.
    /// Avoids re-running the full simplification + unification pipeline on every launch.
    struct CachedFlattenedPolyline: Codable {
        let id: String
        let coordinates: [[Double]]  // [[lat, lon], ...]
        let colorHex: String
        let lineWidth: Double
        let routeIds: [String]
        let isElevated: Bool
        let trunkIndex: Int
        let laneOffset: Double
    }

    struct CachedFlattenedBundle: Codable {
        let subway: [CachedFlattenedPolyline]
        let commuter: [CachedFlattenedPolyline]
    }

    /// Cache pre-computed flattened polylines to disk so cold starts
    /// can skip the entire simplification/unification pipeline.
    func cacheFlattenedPolylines(_ bundle: CachedFlattenedBundle) {
        guard let data = try? JSONEncoder().encode(bundle) else { return }
        // Use file-based cache for large data instead of UserDefaults
        guard let dir = flattenedCacheDirectory() else { return }
        let currentFile = flattenedPolylineCacheFileName()
        let fileURL = dir.appendingPathComponent(currentFile)
        try? data.write(to: fileURL, options: .atomic)
        userDefaults.set(Date(), forKey: CacheKey.flattenedPolylinesCachedAt)
        userDefaults.set(Self.pipelineHash, forKey: CacheKey.flattenedPipelineHash)
        // Remove stale files from previous pipeline hashes / versions
        cleanStalePolylineFiles(in: dir, keeping: currentFile)
    }

    /// Get pre-computed flattened polylines (nil if never cached or
    /// if the pipeline hash has changed since the cache was written).
    func getCachedFlattenedPolylines() -> CachedFlattenedBundle? {
        // Fast-reject: if the stored pipeline hash doesn't match the
        // current one, the geometry was built by outdated code.
        let storedHash = userDefaults.string(
            forKey: CacheKey.flattenedPipelineHash
        ) ?? ""
        guard storedHash == Self.pipelineHash else {
            // Wipe stale files eagerly so disk doesn't accumulate.
            if let dir = flattenedCacheDirectory() {
                cleanStalePolylineFiles(in: dir, keeping: nil)
            }
            userDefaults.removeObject(forKey: CacheKey.flattenedPipelineHash)
            userDefaults.removeObject(forKey: CacheKey.flattenedPolylinesCachedAt)
            return nil
        }
        guard let dir = flattenedCacheDirectory() else { return nil }
        let fileURL = dir.appendingPathComponent(flattenedPolylineCacheFileName())
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CachedFlattenedBundle.self, from: data)
    }

    /// Whether the flattened polyline cache is stale (> 7 days) or missing.
    /// Flattened polylines are derived from subway shapes — same logic
    /// applies: shapes barely change, so 7 days is safe.  The previous
    /// 24-hour TTL meant the expensive decode → unify → simplify → fillet
    /// pipeline ran on every launch after a day of not using the app.
    var isFlattenedPolylinesCacheStale: Bool {
        guard let ts = userDefaults.object(
            forKey: CacheKey.flattenedPolylinesCachedAt
        ) as? Date else { return true }
        return Date().timeIntervalSince(ts) > 604_800  // 7 days
    }

    private func flattenedCacheDirectory() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        let dir = container.appendingPathComponent("FlattenedPolylineCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func flattenedPolylineCacheFileName() -> String {
        "flattened_polylines_\(Self.pipelineHash).json"
    }

    /// Removes all `flattened_polylines_*.json` files except the
    /// one matching `keeping`.  Pass `nil` to remove everything.
    private func cleanStalePolylineFiles(
        in dir: URL,
        keeping currentFile: String?
    ) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: dir.path
        ) else { return }
        for file in contents where file.hasPrefix("flattened_polylines") {
            if file == currentFile { continue }
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(file)
            )
        }
    }

    // MARK: - Baked GeoJSON Tile Cache

    /// Directory for baked GeoJSON vector tile files.
    /// These are pre-built FeatureCollection files that MapLibre loads
    /// directly via its C++ parser, bypassing all Swift feature-building.
    func bakedTilesDirectory() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        let dir = container.appendingPathComponent("BakedTransitTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns a previously baked tile set (nil if files are missing).
    func getCachedBakedTiles() -> TransitTileBaker.BakedTileSet? {
        guard let dir = bakedTilesDirectory() else { return nil }
        return TransitTileBaker.loadExisting(from: dir)
    }

    /// Removes all baked tile files (called from clearCache).
    func clearBakedTiles() {
        guard let dir = bakedTilesDirectory() else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers
    
    private func cacheKey(forMode mode: String) -> String {
        switch mode.lowercased() {
        case "nearby":
            return CacheKey.nearbyArrivals
        case "subway":
            return CacheKey.subwayArrivals
        case "bus":
            return CacheKey.busArrivals
        case "lirr":
            return CacheKey.lirrArrivals
        case "mnr":
            return CacheKey.mnrArrivals
        default:
            return CacheKey.nearbyArrivals
        }
    }
    
    /// Clear all cached data
    func clearCache() {
        userDefaults.removeObject(forKey: CacheKey.nearbyArrivals)
        userDefaults.removeObject(forKey: CacheKey.subwayArrivals)
        userDefaults.removeObject(forKey: CacheKey.busArrivals)
        userDefaults.removeObject(forKey: CacheKey.lirrArrivals)
        userDefaults.removeObject(forKey: CacheKey.mnrArrivals)
        userDefaults.removeObject(forKey: CacheKey.lastFetchTime)
        userDefaults.removeObject(forKey: CacheKey.cachedStations)
        userDefaults.removeObject(forKey: CacheKey.stationCacheVersion)
        userDefaults.removeObject(forKey: CacheKey.lirrShapes)
        userDefaults.removeObject(forKey: CacheKey.mnrShapes)
        userDefaults.removeObject(forKey: CacheKey.subwayShapes)
        userDefaults.removeObject(forKey: CacheKey.subwayShapesCachedAt)
        userDefaults.removeObject(forKey: CacheKey.flattenedPolylinesCachedAt)
        userDefaults.removeObject(forKey: CacheKey.flattenedPipelineHash)
        if let dir = flattenedCacheDirectory() {
            try? FileManager.default.removeItem(at: dir)
        }
        clearBakedTiles()
        lastFetchTime = nil
    }
}
