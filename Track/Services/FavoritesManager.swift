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
    
    private init() {
        // Load cached favorites from disk on launch
        loadFromCache()

        // In ChallengeMode, seed a few favorites so judges see a populated screen
        if ChallengeMode.isEnabled && favorites.isEmpty {
            favorites = MockDataProvider.defaultFavorites()
        }
    }
    
    // MARK: - Public API
    
    /// Check whether a route+stop+direction combo is favorited
    func isFavorite(routeId: String, stopId: String, direction: String?) -> Bool {
        favorites.contains { fav in
            fav.routeId == routeId &&
            fav.stopId == stopId &&
            fav.direction == direction
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
        // If already favorited, remove it
        if let existing = favorites.first(where: {
            $0.routeId == routeId &&
            $0.stopId == stopId &&
            $0.direction == direction
        }) {
            await removeFavorite(existing)
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
        if ChallengeMode.isEnabled { return }
        guard SupabaseManager.shared.isAuthenticated else { return }
        isLoading = true
        defer { isLoading = false }
        
        do {
            let remote = try await SupabaseManager.shared.fetchFavorites()
            favorites = remote
            saveToCache()
            print("[FavoritesManager] Refreshed \(remote.count) favorites from cloud")
        } catch {
            print("[FavoritesManager] Failed to refresh: \(error)")
        }
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
        guard let userId = SupabaseManager.shared.currentUser?.id else {
            print("[FavoritesManager] Cannot add favorite - not signed in")
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
                $0.routeId == routeId && $0.stopId == stopId && $0.direction == direction
            }
            saveToCache()
            print("[FavoritesManager] Failed to add: \(error)")
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
            print("[FavoritesManager] Failed to remove: \(error)")
        }
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
        favorites = cached
    }
}
