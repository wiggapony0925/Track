//
//  RouteAnalyticsManager.swift
//  Track
//
//  Tracks user interactions with transit routes to surface frequently used
//  lines in the widget and smart suggestions.
//  Uses App Group UserDefaults to share data with the Widget.
//  Also syncs to Supabase for global popularity rankings.
//

import Foundation
import CoreLocation

class RouteAnalyticsManager {
    static let shared = RouteAnalyticsManager()
    
    private let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? UserDefaults.standard
    private let key = "route_interaction_stats"
    
    // In-memory cache
    private var stats: [String: Int] = [:]
    
    // Debounce queue for cloud sync to avoid excessive network requests
    private var pendingCloudSync: [(routeId: String, displayName: String?, mode: String, type: String, latitude: Double?, longitude: Double?)] = []
    private var syncTask: Task<Void, Never>?
    private let syncDebounceInterval: TimeInterval = 2.0
    
    private init() {
        self.stats = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
    }
    
    /// Increments the interaction count for a given route.
    /// Call this when the user taps on a route or views its details.
    /// - Parameters:
    ///   - routeId: The route identifier (e.g., "MTA NYCT_L", "B63")
    ///   - displayName: Optional display name for the route
    ///   - mode: Transit mode ("bus", "subway", "lirr")
    ///   - type: Interaction type ("click", "track", "favorite")
    ///   - location: Optional user location for regional analytics
    func logInteraction(
        routeId: String,
        displayName: String? = nil,
        mode: String = "subway",
        type: String = "click",
        location: CLLocation? = nil
    ) {
        // Update local stats immediately
        let currentCount = stats[routeId] ?? 0
        stats[routeId] = currentCount + 1
        save()
        
        // Queue for debounced cloud sync
        pendingCloudSync.append((
            routeId: routeId,
            displayName: displayName,
            mode: mode,
            type: type,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude
        ))
        
        // Cancel existing sync task and schedule new one
        syncTask?.cancel()
        syncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(syncDebounceInterval * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            
            // Batch upload all pending interactions
            let itemsToSync = pendingCloudSync
            pendingCloudSync.removeAll()
            
            for item in itemsToSync {
                await SupabaseManager.shared.logRouteInteraction(
                    routeId: item.routeId,
                    displayName: item.displayName,
                    mode: item.mode,
                    type: item.type,
                    latitude: item.latitude,
                    longitude: item.longitude
                )
            }
        }
    }
    
    /// Legacy method for backward compatibility
    func logInteraction(routeId: String) {
        logInteraction(routeId: routeId, mode: "subway", type: "click")
    }
    
    /// Returns the interaction count for a given route.
    func getCount(for routeId: String) -> Int {
        return stats[routeId] ?? 0
    }
    
    /// Returns all stats.
    func getAllStats() -> [String: Int] {
        return stats
    }
    
    /// Returns the top N most interacted routes
    func getTopRoutes(limit: Int = 5) -> [(routeId: String, count: Int)] {
        return stats
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }
    
    private func save() {
        defaults.set(stats, forKey: key)
    }
}
