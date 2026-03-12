//
//  OfflineCacheManager.swift
//  Track
//
//  Manages offline caching and network reachability for subway underground scenarios.
//  Caches arrivals, routes, and provides fallback data when no WiFi is available.
//

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
        static let lastFetchTime = "cached_last_fetch_time"
        static let cachedStations = "cached_stations"
        static let lirrShapes = "cached_lirr_shapes"
        static let mnrShapes = "cached_mnr_shapes"
        static let subwayShapes = "cached_subway_shapes"
        static let subwayShapesCachedAt = "cached_subway_shapes_timestamp"
    }
    
    // MARK: - Initialization
    
    private init() {
        // Use App Group for widget access
        if let groupDefaults = UserDefaults(suiteName: kAppGroupIdentifier) {
            self.userDefaults = groupDefaults
        } else {
            self.userDefaults = .standard
        }
        
        // Load last fetch time
        if let timestamp = userDefaults.object(forKey: CacheKey.lastFetchTime) as? Date {
            self.lastFetchTime = timestamp
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
    }
    
    /// Get cached stations
    func getCachedStations() -> [CachedStation]? {
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

    /// Whether the subway shapes disk cache is stale (> 24 hours old) or missing.
    var isSubwayShapesCacheStale: Bool {
        guard let ts = userDefaults.object(forKey: CacheKey.subwayShapesCachedAt) as? Date else { return true }
        return Date().timeIntervalSince(ts) > 86_400  // 24 hours
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
        userDefaults.removeObject(forKey: CacheKey.lastFetchTime)
        userDefaults.removeObject(forKey: CacheKey.cachedStations)
        userDefaults.removeObject(forKey: CacheKey.lirrShapes)
        userDefaults.removeObject(forKey: CacheKey.mnrShapes)
        userDefaults.removeObject(forKey: CacheKey.subwayShapes)
        userDefaults.removeObject(forKey: CacheKey.subwayShapesCachedAt)
        lastFetchTime = nil
    }
}
