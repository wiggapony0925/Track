//
//  FavoritesManager.swift
//  Track
//
//  Manages the user's favorite routes/stops.
//  Keeps an in-memory cache synced with Supabase and persists
//  locally in UserDefaults so favorites are available offline.
//

import Foundation
import Combine

/// Singleton that owns the user's favorites list.
/// Views observe `@Published favorites` for real-time UI updates.
@MainActor
class FavoritesManager: ObservableObject {
    static let shared = FavoritesManager()
    
    // MARK: - Published State
    
    @Published private(set) var favorites: [CloudFavorite] = []
    @Published var isLoading = false
    
    // MARK: - Private
    
    private let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? .standard
    private let cacheKey = "cached_favorites"
    private var refreshTask: Task<Void, Never>?
    private var lastRefreshDate: Date?
    
    private init() {
        // Load cached favorites from disk on launch for instant offline display.
        // The live refresh is driven by SyncManager.performFullSync() so we
        // don't fire an extra Supabase request here at cold launch.
        loadFromCache()
    }
    
    // MARK: - Public API
    
    /// Check whether a route+mode combo is favorited.
    /// Stop ID and direction are intentionally ignored so heart state remains
    /// stable when nearest-stop or selected-direction context changes.
    func isFavorite(routeId: String, direction: String?, mode: String) -> Bool {
        _ = direction
        return favorites.contains { fav in
            matchesFavoriteIdentity(
                favorite: fav,
                routeId: routeId,
                mode: mode
            )
        }
    }

    /// Route-level check used by route detail and list badges.
    func isFavorite(routeId: String, mode: String) -> Bool {
        return favorites.contains { fav in
            matchesFavoriteIdentity(
                favorite: fav,
                routeId: routeId,
                mode: mode
            )
        }
    }

    /// Backward-compatible overload.
    /// Kept for existing call sites; uses route-only identity.
    func isFavorite(routeId: String, stopId: String, direction: String?) -> Bool {
        _ = stopId
        _ = direction
        return favorites.contains { fav in
            normalized(fav.routeId) == normalized(routeId)
        }
    }
    
    /// Toggle favorite status for a route/stop.
    /// Returns `true` if the item is now favorited.
    @discardableResult
    func toggleFavorite(
        routeId: String,
        routeDisplayName: String,
        stopId: String,
        stopName: String,
        direction: String?,
        destination: String?,
        mode: String,
        stopLat: Double?,
        stopLon: Double?
    ) async -> Bool {
        // If already favorited (same route+mode), remove all duplicates.
        let existing = favorites.filter {
            matchesFavoriteIdentity(
                favorite: $0,
                routeId: routeId,
                mode: mode
            )
        }
        if !existing.isEmpty {
            await removeFavorites(existing)
            return false
        }
        
        // Otherwise add it
        await addFavorite(
            routeId: routeId,
            routeDisplayName: routeDisplayName,
            stopId: stopId,
            stopName: stopName,
            direction: direction,
            destination: destination,
            mode: mode,
            stopLat: stopLat,
            stopLon: stopLon
        )
        return true
    }
    
    /// Pull the latest favorites from Supabase
    func refresh() async {
        guard SupabaseManager.shared.isAuthenticated else { return }

        if let task = refreshTask {
            await task.value
            return
        }

        if let lastRefreshDate,
           Date().timeIntervalSince(lastRefreshDate) < 5
        {
            return
        }

        let task = Task { @MainActor in
            isLoading = true
            defer {
                isLoading = false
                refreshTask = nil
            }

            do {
                let remote = try await SupabaseManager.shared.fetchFavorites()
                favorites = deduplicated(remote)
                saveToCache()
                lastRefreshDate = Date()
                #if DEBUG
                print("[FavoritesManager] Refreshed \(favorites.count) favorites from cloud")
                #endif
            } catch SupabaseError.unauthorized {
                // Session may be in-flight during startup token refresh.
                // Keep cached favorites and avoid noisy decode/error churn.
            } catch {
                #if DEBUG
                print("[FavoritesManager] Failed to refresh: \(error)")
                #endif
            }
        }

        refreshTask = task
        await task.value
    }
    
    // MARK: - Private Helpers
    
    private func addFavorite(
        routeId: String,
        routeDisplayName: String,
        stopId: String,
        stopName: String,
        direction: String?,
        destination: String?,
        mode: String,
        stopLat: Double?,
        stopLon: Double?
    ) async {
        // Use currentUser if loaded, otherwise fall back to the stored UUID in UserDefaults
        let userId: UUID? = SupabaseManager.shared.currentUser?.id ?? {
            let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? .standard
            if let str = defaults.string(forKey: "supabase_user_id") {
                return UUID(uuidString: str)
            }
            return nil
        }()
        
        guard let userId else {
            #if DEBUG
            print("[FavoritesManager] Cannot add favorite - no user ID available")
            #endif
            return
        }

        // Guard against duplicate inserts for the same route identity.
        if favorites.contains(where: {
            matchesFavoriteIdentity(
                favorite: $0,
                routeId: routeId,
                mode: mode
            )
        }) {
            return
        }
        
        let favorite = CloudFavorite(
            userId: userId,
            routeId: routeId,
            routeDisplayName: routeDisplayName,
            stopId: stopId,
            stopName: stopName,
            direction: direction,
            destination: destination,
            mode: mode,
            stopLat: stopLat,
            stopLon: stopLon,
            displayOrder: favorites.count
        )
        
        // Optimistic local insert
        favorites.append(favorite)
        saveToCache()
        
        do {
            try await SupabaseManager.shared.addFavorite(favorite)
            // Re-fetch to get the server-assigned ID
            await refresh()
        } catch {
            // Roll back optimistic insert
            favorites.removeAll {
                matchesFavoriteIdentity(
                    favorite: $0,
                    routeId: routeId,
                    mode: mode
                )
            }
            saveToCache()
            #if DEBUG
            print("[FavoritesManager] Failed to add: \(error)")
            #endif
        }
    }

    func removeFavorites(_ items: [CloudFavorite]) async {
        // Optimistic local remove (including records with nil id from cache)
        let ids = Set(items.compactMap(\ .id))
        favorites.removeAll { favorite in
            if let id = favorite.id {
                return ids.contains(id)
            }
            return items.contains(where: {
                normalized($0.routeId) == normalized(favorite.routeId)
                    && normalized($0.mode) == normalized(favorite.mode)
            })
        }
        saveToCache()

        for favorite in items {
            guard let id = favorite.id else { continue }
            do {
                try await SupabaseManager.shared.removeFavorite(id: id)
            } catch {
                await refresh()
                #if DEBUG
                print("[FavoritesManager] Failed to remove: \(error)")
                #endif
                return
            }
        }
    }
    
    private func removeFavorite(_ favorite: CloudFavorite) async {
        guard let id = favorite.id else { return }
        
        // Optimistic local remove
        favorites.removeAll { $0.id == id }
        saveToCache()
        
        do {
            try await SupabaseManager.shared.removeFavorite(id: id)
        } catch {
            // Re-fetch to restore
            await refresh()
            #if DEBUG
            print("[FavoritesManager] Failed to remove: \(error)")
            #endif
        }
    }

    private func matchesFavoriteIdentity(
        favorite: CloudFavorite,
        routeId: String,
        mode: String
    ) -> Bool {
        normalized(favorite.routeId) == normalized(routeId)
            && normalized(favorite.mode) == normalized(mode)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedDirection(_ value: String?) -> String {
        guard let value else { return "" }
        return normalized(value)
    }
    
    // MARK: - Local Cache
    
    private func saveToCache() {
        if let data = try? JSONEncoder().encode(favorites) {
            defaults.set(data, forKey: cacheKey)
        }
    }
    
    private func loadFromCache() {
        guard let data = defaults.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode([CloudFavorite].self, from: data) else {
            return
        }
        favorites = deduplicated(cached)
    }

    private func deduplicated(_ items: [CloudFavorite]) -> [CloudFavorite] {
        var seen = Set<String>()
        var result: [CloudFavorite] = []
        for item in items {
            let key = "\(normalized(item.routeId))|\(normalized(item.mode))"
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }
}
