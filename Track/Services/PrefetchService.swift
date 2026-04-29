// Background prefetch for the Plan tab's planner data.
//
// Called from ContentView as soon as auth resolves and again whenever
// the app returns to the foreground. Refreshes only stale buckets
// (using PlannerDataCache.TTL values) so we don't burn battery or
// hammer the engine on every scenePhase change.
//
// Result: by the time the user taps the "Trips" tab, PlannerDataCache
// already holds fresh data — PlanViewModel.configure() reads it
// synchronously and renders the page with zero perceived latency.

import Foundation

@MainActor
final class PrefetchService {
    static let shared = PrefetchService()

    /// Minimum interval between full prefetch cycles to avoid thrashing
    /// when scenePhase fires repeatedly (e.g. app switcher swipes).
    private static let minimumInterval: TimeInterval = 30  // 30 seconds

    private var lastRunAt: Date = .distantPast
    private var inflightTask: Task<Void, Never>?

    private init() {}

    /// Kick off a background prefetch of all planner data buckets.
    ///
    /// - Coalesces concurrent calls (a single in-flight task at a time).
    /// - Skips buckets that are still within their TTL.
    /// - Throttled by `minimumInterval` to ignore rapid-fire scenePhase events.
    /// - Silent on failure — this is best-effort warming.
    func prefetchPlannerData(force: Bool = false) {
        // Coalesce: if a prefetch is already running, let it finish.
        if let existing = inflightTask, !existing.isCancelled {
            return
        }

        // Throttle.
        if !force, Date().timeIntervalSince(lastRunAt) < Self.minimumInterval {
            return
        }

        inflightTask = Task(priority: .utility) { [weak self] in
            await self?.runPrefetch(force: force)
            self?.inflightTask = nil
        }
    }

    /// Cancel any running prefetch (e.g. on sign-out).
    func cancel() {
        inflightTask?.cancel()
        inflightTask = nil
    }

    // MARK: - Private

    private func runPrefetch(force: Bool) async {
        guard let userID = SupabaseManager.shared.currentUser?.id.uuidString.lowercased()
            ?? SupabaseManager.shared.storedUserIdString?.lowercased() else {
            return
        }
        guard OfflineCacheManager.shared.isOnline else {
            return
        }

        lastRunAt = Date()
        let cache = PlannerDataCache.shared
        let snapshot = cache.snapshot(for: userID)
        if !snapshot.savedPlaces.isEmpty, SavedPlacesCache.shared.allPlaces.isEmpty {
            SavedPlacesCache.shared.update(all: Self.savedLocations(from: snapshot.savedPlaces))
        }

        // Decide which buckets to refresh based on per-bucket TTL.
        let needsSavedPlaces = force || cache.isStale(
            \.savedPlacesAt, ttl: PlannerDataCache.TTL.savedPlaces, for: userID)
        let needsRecentTrips = force || cache.isStale(
            \.recentTripsAt, ttl: PlannerDataCache.TTL.recentTrips, for: userID)
        let needsTemplates = force || cache.isStale(
            \.savedTripTemplatesAt, ttl: PlannerDataCache.TTL.savedTripTemplates, for: userID)
        let needsRecommendations = force || cache.isStale(
            \.recommendationsAt, ttl: PlannerDataCache.TTL.recommendations, for: userID)

        // Fire the needed fetches in parallel. Each writes to the cache
        // independently on success — no single failure blocks the others.
        await withTaskGroup(of: Void.self) { group in
            if needsSavedPlaces {
                group.addTask {
                    do {
                        let places = try await TrackAPI.fetchEngineSavedPlaces(userID: userID)
                        await cache.updateSavedPlaces(places, for: userID)
                        await MainActor.run {
                            SavedPlacesCache.shared.update(all: Self.savedLocations(from: places))
                        }
                    } catch {
                        // Silent — cached data remains usable.
                    }
                }
            }
            if needsRecentTrips {
                group.addTask {
                    do {
                        let trips = try await TrackAPI.fetchEngineRecentTrips(
                            userID: userID, limit: 12)
                        await cache.updateRecentTrips(trips, for: userID)
                    } catch {
                    }
                }
            }
            if needsTemplates {
                group.addTask {
                    do {
                        let templates = try await TrackAPI.fetchEngineSavedTrips(userID: userID)
                        await cache.updateSavedTripTemplates(templates, for: userID)
                    } catch {
                    }
                }
            }
            if needsRecommendations {
                group.addTask {
                    do {
                        // Recommendations depend on origin coordinate. The
                        // prefetch runs without an origin context; the
                        // backend returns generic recommendations in that
                        // case (saved places + frequent destinations),
                        // which is exactly what PlanView shows on first
                        // open before the user sets an origin.
                        let recs = try await TrackAPI.fetchEngineRecommendations(
                            userID: userID,
                            latitude: nil,
                            longitude: nil,
                            limit: 6
                        )
                        await cache.updateRecommendations(recs, for: userID)
                    } catch {
                    }
                }
            }
            await group.waitForAll()
        }
    }

    private static func savedLocations(
        from records: [PlannerSavedPlaceRecord]
    ) -> [SavedLocation] {
        records.map { record in
            let category = SavedLocationCategory(engineKind: record.kind)
            return SavedLocation(
                enginePlaceID: record.placeID,
                name: record.label,
                
                
                address: record.address ?? "",
                latitude: record.lat,
                longitude: record.lon,
                category: category,
                iconName: record.icon ?? category.defaultIcon,
                visibleOnMap: record.visibleOnMap,
                createdAt: Date(timeIntervalSince1970: TimeInterval(record.createdAt)),
                lastUsedAt: record.lastUsedAt.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
            )
        }
    }
}
