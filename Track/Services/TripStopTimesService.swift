// Fetches and caches per-trip GTFS-RT stop predictions from the
// backend.  When the user taps a chip in `ArrivalChipView`, the
// caller asks this service for the predicted arrival timestamp of
// that specific trip at every stop on its remaining path so the
// Stops list can re-render ETAs from that vehicle's perspective.
//
// Cache TTL is 25 s — slightly longer than the backend's 10 s
// `Cache-Control: public, max-age=10` so a re-tap of the same chip
// while the user pans/scrolls reuses the result instead of hitting
// the network.

import Foundation

@MainActor
final class TripStopTimesService {
    static let shared = TripStopTimesService()

    private struct CacheEntry {
        let fetchedAt: Date
        let stopETAs: [String: Int]  // stopId → arrival_ts
    }

    private let ttl: TimeInterval = 25
    private var cache: [String: CacheEntry] = [:]
    /// Inflight tasks keyed by tripId so concurrent taps coalesce.
    private var inflight: [String: Task<[String: Int], Error>] = [:]

    private init() {}

    /// Returns a `[stopId: arrival_ts]` mapping for *tripId*, or an
    /// empty dictionary when the trip is no longer in any active
    /// GTFS-RT feed.  Throws on transport / decode errors so the
    /// caller can decide whether to log or fall back silently.
    func stopETAs(for tripId: String) async throws -> [String: Int] {
        if let entry = cache[tripId],
           Date().timeIntervalSince(entry.fetchedAt) < ttl {
            return entry.stopETAs
        }
        if let existing = inflight[tripId] {
            return try await existing.value
        }
        let task = Task<[String: Int], Error> { [weak self] in
            defer { Task { @MainActor [weak self] in self?.inflight[tripId] = nil } }
            let rows = try await TrackAPI.fetchSubwayTripStops(tripId: tripId)
            var dict: [String: Int] = [:]
            for row in rows {
                guard let ts = row.arrivalTs, ts > 0 else { continue }
                dict[row.station] = ts
                // GTFS subway stop_ids include a trailing N/S direction
                // suffix.  The Stops list keys by the *base* parent stop
                // (no suffix), so write both forms so either lookup hits.
                if row.station.count > 1,
                   let last = row.station.last,
                   last == "N" || last == "S" {
                    dict[String(row.station.dropLast())] = ts
                }
            }
            await MainActor.run { [weak self] in
                self?.cache[tripId] = CacheEntry(
                    fetchedAt: Date(),
                    stopETAs: dict
                )
            }
            return dict
        }
        inflight[tripId] = task
        return try await task.value
    }

    /// Drops the cache for a trip — useful when the user picks a new
    /// chip and we want to free memory aggressively.
    func clear(tripId: String) {
        cache[tripId] = nil
    }

    /// Drops all cached entries.  Call on direction change or sheet
    /// dismiss so we don't hold stale data across contexts.
    func clearAll() {
        cache.removeAll()
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
    }
}
