// Unified network client that communicates with the TrackBackend proxy API.
// All MTA data flows through the backend — the iOS app never calls MTA directly.

import CoreLocation
import Foundation
import os

private actor APIRequestMemoizer {
    private var inflight: [String: Task<Data, Error>] = [:]
    private var cache: [String: (timestamp: Date, data: Data)] = [:]

    func getCached(for key: String, ttl: TimeInterval) -> Data? {
        guard let cached = cache[key] else { return nil }
        guard Date().timeIntervalSince(cached.timestamp) <= ttl else {
            cache.removeValue(forKey: key)
            return nil
        }
        return cached.data
    }

    func setCached(_ data: Data, for key: String) {
        cache[key] = (Date(), data)
    }

    func getInflight(for key: String) -> Task<Data, Error>? {
        inflight[key]
    }

    func setInflight(_ task: Task<Data, Error>, for key: String) {
        inflight[key] = task
    }

    func clearInflight(for key: String) {
        inflight.removeValue(forKey: key)
    }

    /// Removes a cached entry so the next request hits the network.
    /// Use when a successful 200 response decoded to empty data (backend
    /// was mid-cold-start) so retries don't serve the stale empty result.
    func invalidateCached(for key: String) {
        cache.removeValue(forKey: key)
    }
}

/// Centralized API client for the Track backend.
struct TrackAPI {

    // MARK: - Dedicated URLSession

    /// Custom session used for all Track API calls.
    /// - `waitsForConnectivity = true`  → queues the request until the network is
    ///   available instead of failing immediately. Eliminates retry-backoff waste
    ///   (~1.5 s) when the radio hasn't finished waking on app cold-start.
    /// - 15 s request timeout → fail faster than the URLSession.shared default (60 s)
    ///   so the user sees an error sooner when the server is actually unreachable.
    /// - 10 MB URLCache → enables automatic HTTP-level caching driven by
    ///   Cache-Control headers from the backend.  Static geometry endpoints
    ///   (shapes, stations) send `max-age=3600` so subsequent fetches within
    ///   the hour resolve from disk in <1 ms.  Real-time endpoints send
    ///   `stale-while-revalidate` so URLSession can serve a cached copy
    ///   while revalidating in the background.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 6
        // 10 MB memory / 50 MB disk cache for HTTP responses.
        // Keyed by full URL (including query params like lat/lon) so
        // each unique location/endpoint combo is cached independently.
        config.urlCache = URLCache(
            memoryCapacity: 10 * 1024 * 1024,   // 10 MB RAM
            diskCapacity:   50 * 1024 * 1024,    // 50 MB disk
            directory: FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
                .appendingPathComponent("URLCache")
        )
        // Use the protocol's cache policy (honors Cache-Control headers).
        // This is the default, but explicit is better than implicit.
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    /// Standard-timeout session for supplementary calls that should fail
    /// immediately when offline instead of waiting for connectivity.
    private static let failFastSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - Cold-Start State

    /// Thread-safe lock protecting `serverWarmedUp`.
    /// Replaces `nonisolated(unsafe)` to eliminate data races between
    /// the health probe (Task.detached), retry loops, and MainActor reads.
    nonisolated private static let _warmLock = OSAllocatedUnfairLock(initialState: false)

    /// Whether at least one backend response has succeeded this session.
    /// Before this becomes `true`, HTTP timeouts are extended to 25 s to
    /// survive Render's container cold-start.
    /// Thread-safe: reads/writes go through `_warmLock`.
    nonisolated(unsafe) static var serverWarmedUp: Bool {
        get { _warmLock.withLock { $0 } }
        set { _warmLock.withLock { $0 = newValue } }
    }

    // MARK: - Connection Warm-Up

    /// Thread-safe lock protecting `_healthGateTask`.
    nonisolated private static let _healthGateLock =
        OSAllocatedUnfairLock<Task<Bool, Never>?>(
            initialState: nil
        )

    /// In-flight health-gate task so multiple callers coalesce onto one probe.
    /// Thread-safe: reads/writes go through `_healthGateLock`.
    nonisolated(unsafe) private static var _healthGateTask: Task<Bool, Never>? {
        get { _healthGateLock.withLock { $0 } }
        set { _healthGateLock.withLock { $0 = newValue } }
    }

    nonisolated private static let _localhostSuppressedLock =
        OSAllocatedUnfairLock(initialState: false)
    nonisolated(unsafe) private static var _localhostSuppressedThisLaunch: Bool {
        get { _localhostSuppressedLock.withLock { $0 } }
        set { _localhostSuppressedLock.withLock { $0 = newValue } }
    }

    /// Fires a lightweight TCP/TLS warm-up to the backend host as early as
    /// possible in the app lifecycle (called from TrackApp.init).
    ///
    /// On cellular, establishing a TLS connection cold takes 1–3 seconds.
    /// By the time HomeView.onAppear fires the real /nearby/grouped request,
    /// the connection is already open → that latency cost is paid in parallel
    /// with splash / auth checks rather than on the critical path.
    static func warmConnection() {
        // Kick off the health gate probe immediately.  If the backend is
        // warm (normal case) this resolves in <500 ms and `waitForBackendReady`
        // returns instantly.  If the backend is cold-starting on Render,
        // the probe keeps retrying with exponential backoff for up to 90 s
        // — preventing the app from wasting its first refresh on requests
        // that will all 502.
        let resolvedBase = baseURL          // read on @MainActor
        _healthGateTask = Task.detached(priority: .userInitiated) {
            let maxAttempts = 12  // ~90s total with backoff
            for attempt in 0..<maxAttempts {
                guard let url = URL(string: resolvedBase + "/health") else { return false }
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                do {
                    let (_, response) = try await session.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        serverWarmedUp = true
                        await MainActor.run {
                            let ts = AppLogger.shared
                                .timeSinceLaunchFormatted
                            let msg = "Backend healthy "
                                + "(attempt \(attempt + 1), "
                                + "T+\(ts))"
                            AppLogger.shared.log(
                                "API_HEALTH",
                                message: msg
                            )
                        }
                        return true
                    }
                } catch {}
                // Exponential backoff: 1s, 2s, 4s, 8s, 8s, 8s, ...
                let delay = min(pow(2.0, Double(attempt)), 8.0)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await MainActor.run {
                let msg = "⚠️ Backend not healthy "
                    + "after 90s — proceeding anyway"
                AppLogger.shared.log(
                    "API_HEALTH", message: msg
                )
            }
            return false
        }
    }

    /// Waits for the backend to become healthy before allowing the first
    /// network refresh.  Returns immediately if the backend is already warm
    /// or if no health probe is in flight.
    ///
    /// Call this from `HomeViewModel.refresh()` before firing grouped/shapes
    /// requests.  When the backend is warm (99% of launches), this resolves
    /// in <1 ms.  When Render is cold-starting, this blocks only the first
    /// refresh — the UI still shows cached route cards and map polylines
    /// from the session/disk cache while waiting.
    static func waitForBackendReady() async {
        // Fast path: already warm from a previous session or health probe
        if serverWarmedUp { return }
        // Wait for the in-flight health probe (if any)
        if let task = _healthGateTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = await task.value
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                await group.next()
                group.cancelAll()
            }
        }
    }

    /// In DEBUG builds: if `dev_use_localhost` is set but the local server
    /// doesn't respond within 1.5 s, auto-clear the flag and fall back to
    /// production. Prevents a stale UserDefaults flag from bricking the app
    /// when the developer's Mac isn't on the same network.
    ///
    /// **Race-condition fix:** The flag is cleared *synchronously* before
    /// any async work begins so that `baseURL` (read by `warmConnection()`
    /// and HomeView's first refresh) resolves to production immediately.
    /// Only if the local server probe succeeds is the flag restored. This
    /// means worst-case the app uses production for the first request, then
    /// switches to local on the next refresh — far better than hanging
    /// forever on an unreachable localhost.
    ///
    /// Called from `TrackApp.init()` at `.userInitiated` priority.
    static func validateLocalServer() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "dev_use_localhost") else { return }

        // ── Synchronous: clear the flag NOW so baseURL resolves to prod ──
        // This prevents warmConnection() and the first API call from
        // caching a localhost URL that might be unreachable.
        _localhostSuppressedThisLaunch = true
        UserDefaults.standard.removeObject(forKey: "dev_use_localhost")
        invalidateBaseURL()

        // Read MainActor-isolated values before entering the detached task.
        let storedIP = UserDefaults.standard
            .string(forKey: "dev_custom_ip")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedIP = (storedIP?.isEmpty == false)
            ? storedIP!
            : AppSettings.shared.defaultDeviceIP
        let port = AppSettings.shared.localPort
        #if targetEnvironment(simulator)
        let localURL = AppSettings.shared.localBaseURL + "/health"
        #else
        let localURL = "http://\(resolvedIP):\(port)/health"
        #endif
        let logger = AppLogger.shared       // capture on caller's actor

        // ── Async: probe the local server and restore the flag if reachable ──
        Task.detached(priority: .userInitiated) {
            // Use a plain URLSession — no waitsForConnectivity — so a TCP
            // refused / host-unreachable error comes back in milliseconds.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 1.5
            config.timeoutIntervalForResource = 1.5
            let probe = URLSession(configuration: config)
            guard let url = URL(string: localURL) else { return }
            do {
                _ = try await probe.data(from: url)
                // Server responded — restore the flag and switch to local
                logger.log("API_CONFIG", message: "Local server reachable at \(localURL) ✓")
                await MainActor.run {
                    _localhostSuppressedThisLaunch = false
                    UserDefaults.standard.set(true, forKey: "dev_use_localhost")
                    invalidateBaseURL()
                }
            } catch {
                await MainActor.run {
                    _localhostSuppressedThisLaunch = true
                    UserDefaults.standard.removeObject(forKey: "dev_use_localhost")
                    invalidateBaseURL()
                    if !serverWarmedUp {
                        _healthGateTask = nil
                    }
                }
                let msg = "Local server unreachable "
                    + "(\(error.localizedDescription))"
                    + " — staying on production"
                logger.log("API_CONFIG", message: msg)
            }
        }
        #endif
    }

    // MARK: - Cached User Email (avoids MainActor hop on every request)

    /// Thread-safe lock protecting `cachedUserEmail`.
    nonisolated private static let _emailLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Set by SupabaseManager after login/profile load to avoid hopping
    /// to @MainActor on every API call.
    /// Thread-safe: reads/writes go through `_emailLock`.
    nonisolated(unsafe) static var cachedUserEmail: String? {
        get { _emailLock.withLock { $0 } }
        set { _emailLock.withLock { $0 = newValue } }
    }

    static func setCachedEmail(_ email: String?) {
        cachedUserEmail = email
    }

    // MARK: - Cached Access Token (Supabase JWT for backend auth)

    /// Thread-safe lock protecting `cachedAccessToken`.
    nonisolated private static let _tokenLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The Supabase access token forwarded by SupabaseManager after login.
    /// Sent as `Authorization: Bearer <token>` on every backend request.
    /// Thread-safe: reads/writes go through `_tokenLock`.
    nonisolated(unsafe) static var cachedAccessToken: String? {
        get { _tokenLock.withLock { $0 } }
        set { _tokenLock.withLock { $0 = newValue } }
    }

    static func setCachedAccessToken(_ token: String?) {
        cachedAccessToken = token
    }

    // MARK: - Environment Configuration

    /// The active backend URL, determined by the Developer Settings in SettingsView.
    /// On a physical device, localhost is never used (it would point to the phone itself).
    /// Cached to avoid re-computing (and logging) on every API call.
    /// Thread-safe: reads/writes go through `_baseURLLock`.
    nonisolated private static let _baseURLLock = OSAllocatedUnfairLock<String?>(initialState: nil)
    nonisolated(unsafe) private static var _cachedBaseURL: String? {
        get { _baseURLLock.withLock { $0 } }
        set { _baseURLLock.withLock { $0 = newValue } }
    }
    
    /// Invalidate the cached URL when developer settings change.
    /// Evicts a path from the in-memory memoizer so the next call for that
    /// path hits the network rather than returning stale cached data.
    ///
    /// Call this immediately after decoding a successful 200 response whose
    /// payload turned out to be empty (e.g. `lines: []`), so retries go live.
    static func invalidateCachedPath(_ path: String) async {
        await memoizer.invalidateCached(for: path)
    }

    static func invalidateBaseURL() {
        _cachedBaseURL = nil
    }
    
    static var baseURL: String {
        if let cached = _cachedBaseURL { return cached }
        
        let settings = AppSettings.shared

        #if DEBUG
        // --- Local-server logic is strictly debug-only ---
        // This prevents a leftover `dev_use_localhost` UserDefaults flag
        // from accidentally routing a release/TestFlight build to localhost.
        let useLocalhost = UserDefaults.standard.bool(forKey: "dev_use_localhost")
            && !_localhostSuppressedThisLaunch

        #if targetEnvironment(simulator)
            // Simulator runs on the Mac — localhost works fine
            if useLocalhost {
                let url = settings.localBaseURL
                AppLogger.shared.log("API_CONFIG", message: "baseURL (simulator/localhost): \(url)")
                _cachedBaseURL = url
                return url
            }
        #endif

        if useLocalhost {
            // Physical device local mode: use configured IP (or default fallback)
            let storedIP = UserDefaults.standard
                .string(forKey: "dev_custom_ip")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedIP = (storedIP?.isEmpty == false)
                ? storedIP!
                : settings.defaultDeviceIP
            let url = "http://\(resolvedIP):\(settings.localPort)"
            AppLogger.shared.log("API_CONFIG", message: "baseURL (dev): \(url)")
            _cachedBaseURL = url
            return url
        }
        #endif

        // Production (always used in release builds): deployed Render backend
        let url = settings.prodBaseURL
        AppLogger.shared.log("API_CONFIG", message: "baseURL (production): \(url)")
        _cachedBaseURL = url
        return url
    }

    // MARK: - Config

    /// Pings the active backend and returns status + latency for developer diagnostics.
    static func pingBackend(timeoutSeconds: TimeInterval = 5.0) async
        -> (ok: Bool, statusCode: Int?, latencyMs: Double?, error: String?)
    {
        guard let url = URL(string: baseURL + "/health") else {
            return (false, nil, nil, "Invalid backend URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeoutSeconds

        if let token = cachedAccessToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let latency = Date().timeIntervalSince(start) * 1000
            guard let http = response as? HTTPURLResponse else {
                return (false, nil, latency, "No HTTP response")
            }
            let ok = (200...299).contains(http.statusCode)
            return (ok, http.statusCode, latency, ok ? nil : "HTTP \(http.statusCode)")
        } catch {
            let latency = Date().timeIntervalSince(start) * 1000
            return (false, nil, latency, error.localizedDescription)
        }
    }

    // MARK: - Subway

    /// Fetches upcoming subway arrivals for a line from the backend.
    ///
    /// - Parameter lineID: A subway line identifier (e.g. "L", "A", "1").
    /// - Returns: Array of decoded `TrainArrival` objects.
    static func fetchSubwayArrivals(lineID: String) async throws -> [TrainArrival] {
        let data = try await get(path: "/subway/\(lineID)")
        return try decoder.decode([TransitArrivalResponse].self, from: data).map {
            $0.toTrainArrival()
        }
    }

    /// Fetches the predicted arrival time of a single GTFS trip at every
    /// stop on its path — used by the chip-tap flow so the Stops list can
    /// re-render ETAs from the selected vehicle's perspective.
    static func fetchSubwayTripStops(tripId: String) async throws -> [TransitArrivalResponse] {
        let encoded = tripId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tripId
        let data = try await get(path: "/subway/trip/\(encoded)/stops")
        return try decoder.decode([TransitArrivalResponse].self, from: data)
    }

    // MARK: - Bus

    /// Fetches nearby bus stops based on coordinates.
    ///
    /// - Parameters:
    ///   - lat: User's latitude.
    ///   - lon: User's longitude.
    /// - Returns: Array of `BusStop`.
    static func fetchNearbyBusStops(lat: Double, lon: Double, radius: Int? = nil) async throws
        -> [BusStop]
    {
        let effectiveRadius = radius ?? AppSettings.shared.effectiveAPISearchRadius
        guard var components = URLComponents(string: baseURL + "/bus/nearby") else {
            throw TrackAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "radius", value: String(effectiveRadius)),
        ]
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        let data = try await get(url: url)
        return try decoder.decode([BusStop].self, from: data)
    }

    /// Fetches live bus arrivals at a specific stop.
    ///
    /// - Parameter stopID: The bus stop identifier (e.g. "MTA_308214").
    /// - Returns: Array of `BusArrival`.
    static func fetchBusArrivals(stopID: String) async throws -> [BusArrival] {
        let encoded = stopID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stopID
        let data = try await get(path: "/bus/live/\(encoded)")
        return try decoder.decode([BusArrival].self, from: data)
    }

    /// Fetches all MTA bus routes.
    ///
    /// - Returns: Array of `BusRoute` with short name, long name, and color.
    static func fetchBusRoutes() async throws -> [BusRoute] {
        let data = try await get(path: "/bus/routes")
        return try decoder.decode([BusRoute].self, from: data)
    }

    // MARK: - Bus Schedule

    /// Fetches today's scheduled departures for a bus route.
    /// Used when no live buses are running to show upcoming scheduled times.
    static func fetchBusSchedule(routeID: String) async throws -> BusScheduleResponse {
        let stripped =
            routeID
            .replacingOccurrences(of: "MTA NYCT_", with: "")
            .replacingOccurrences(of: "MTABC_", with: "")
        let data = try await get(path: "/bus/schedule/\(stripped)")
        return try decoder.decode(BusScheduleResponse.self, from: data)
    }

    // MARK: - Nearby Transit

    /// Fetches the nearest buses and trains with live countdowns.
    /// Returns a unified list sorted by minutes away.
    ///
    /// - Parameters:
    ///   - lat: User's latitude.
    ///   - lon: User's longitude.
    ///   - radius: Search radius in meters (from settings.json by default).
    /// - Returns: Array of `NearbyTransitResponse`.
    static func fetchNearbyTransit(lat: Double, lon: Double, radius: Int? = nil) async throws
        -> [NearbyTransitResponse]
    {
        let effectiveRadius = radius ?? AppSettings.shared.effectiveAPISearchRadius
        guard var components = URLComponents(string: baseURL + "/nearby") else {
            throw TrackAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "radius", value: String(effectiveRadius)),
        ]
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        let data = try await get(url: url)
        return try decoder.decode([NearbyTransitResponse].self, from: data)
    }

    /// Fetches nearby transit grouped by route with direction sub-groups.
    /// Each route appears once; directions are swipeable in the detail sheet.
    ///
    /// - Parameters:
    ///   - lat: User's latitude.
    ///   - lon: User's longitude.
    ///   - radius: Search radius in meters (from settings.json by default).
    ///   - mode: Optional transit mode filter ("subway", "bus", "lirr", "mnr").
    ///   - quick: When `true`, the backend skips expensive bus backfill phases
    ///     and uses a coarser GPS grid for faster response during drag-to-search.
    /// - Returns: Array of `GroupedNearbyTransitResponse`.
    ///
    /// Uses extended timeouts because the backend's `/nearby/grouped`
    /// endpoint fans out to multiple MTA / OBA feeds in parallel and
    /// has a server-side compute timeout of 45 s.  The standard 15 s /
    /// 25 s client timeouts are too short — the request times out before
    /// the server finishes computing, especially on cold starts where
    /// Render boots the container AND primes feed caches concurrently.
    static func fetchNearbyGrouped(
        lat: Double, lon: Double, radius: Int? = nil, mode: String? = nil,
        quick: Bool = false
    ) async throws -> [GroupedNearbyTransitResponse] {
        let effectiveRadius = radius ?? AppSettings.shared.effectiveAPISearchRadius

        let knownOffline = await MainActor.run { !OfflineCacheManager.shared.isOnline }
        if knownOffline {
            AppLogger.shared.log(
                "OFFLINE",
                message: quick
                    ? "Reachability says offline; using local drag-search bundle"
                    : "Reachability says offline; probing /nearby/grouped before local fallback"
            )
            if quick,
               let synthesized = await synthesizeNearbyGroupedFallback(
                lat: lat,
                lon: lon,
                radius: effectiveRadius,
                mode: mode,
                reason: "drag-search offline"
               ) {
                return synthesized
            }
        }

        guard var components = URLComponents(string: baseURL + "/nearby/grouped") else {
            throw TrackAPIError.invalidURL
        }
        var queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "radius", value: String(effectiveRadius)),
        ]
        if let mode = mode {
            queryItems.append(URLQueryItem(name: "mode", value: mode))
        }
        if quick {
            queryItems.append(URLQueryItem(name: "quick", value: "true"))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        AppLogger.shared.logRequest(method: "GET", url: url.absoluteString)
        let data: Data
        do {
            data = try await getWithExtendedTimeout(url: url, waitsForConnectivity: false)
        } catch {
            if let synthesized = await synthesizeNearbyGroupedFallback(
                lat: lat,
                lon: lon,
                radius: effectiveRadius,
                mode: mode,
                reason: error.localizedDescription
            ) {
                return synthesized
            }
            throw error
        }
        do {
            let decoded = try decoder.decode([GroupedNearbyTransitResponse].self, from: data)
            if mode == nil {
                await MainActor.run {
                    OfflineCacheManager.shared.noteNetworkRequestSucceeded()
                }
            }
            return decoded
        } catch let decodingError as DecodingError {
            // Log detailed decode context so we can diagnose contract mismatches
            let detail: String
            switch decodingError {
            case .keyNotFound(let key, let ctx):
                let path = ctx.codingPath
                    .map(\.stringValue)
                    .joined(separator: ".")
                detail = "keyNotFound "
                    + "'\(key.stringValue)' at \(path)"
            case .typeMismatch(let type, let ctx):
                let path = ctx.codingPath
                    .map(\.stringValue)
                    .joined(separator: ".")
                detail = "typeMismatch \(type) at \(path)"
            case .valueNotFound(let type, let ctx):
                let path = ctx.codingPath
                    .map(\.stringValue)
                    .joined(separator: ".")
                detail = "valueNotFound \(type) at \(path)"
            case .dataCorrupted(let ctx):
                let path = ctx.codingPath
                    .map(\.stringValue)
                    .joined(separator: ".")
                detail = "dataCorrupted at \(path)"
            @unknown default:
                detail = decodingError.localizedDescription
            }
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            AppLogger.shared.logError("fetchNearbyGrouped DECODE", error: decodingError)
            AppLogger.shared.log(
                "DECODE",
                message: "Detail: \(detail)"
                    + " | Response preview: \(preview)"
            )
            throw decodingError
        }
    }

    static func fetchLocalNearbyGrouped(
        lat: Double,
        lon: Double,
        radius: Int? = nil,
        mode: String? = nil,
        reason: String
    ) async -> [GroupedNearbyTransitResponse]? {
        let effectiveRadius = radius ?? AppSettings.shared.effectiveAPISearchRadius
        return await synthesizeNearbyGroupedFallback(
            lat: lat,
            lon: lon,
            radius: effectiveRadius,
            mode: mode,
            reason: reason,
            markOffline: false
        )
    }

    private static func synthesizeNearbyGroupedFallback(
        lat: Double,
        lon: Double,
        radius: Int,
        mode: String?,
        reason: String,
        markOffline: Bool = true
    ) async -> [GroupedNearbyTransitResponse]? {
        let bundleRef = await MainActor.run {
            GTFSBundleManager.shared.current ?? GTFSBundleManager.shared.bootstrap()
        }
        guard let bundleRef else { return nil }

        let synthesized = await Task.detached(priority: .userInitiated) {
            OfflineNearbyFallback.synthesize(
                lat: lat,
                lon: lon,
                radiusMeters: Double(radius),
                mode: mode,
                bundle: bundleRef
            )
        }.value
        guard let synthesized else { return nil }

        if markOffline && mode == nil {
            await MainActor.run {
                OfflineCacheManager.shared.noteOfflineFallbackUsed()
            }
        }
        AppLogger.shared.log(
            "OFFLINE",
            message: "fetchNearbyGrouped fell back to local bundle "
                + "(\(synthesized.count) routes) — \(reason)"
        )
        return synthesized
    }

    /// Fetches inactive transit routes — routes serving the area but with no active service.
    ///
    /// - Parameters:
    ///   - lat: Latitude of the user's location.
    ///   - lon: Longitude of the user's location.
    ///   - radius: Search radius in meters.
    ///   - activeRoutes: Display names of currently active routes to exclude.
    /// - Returns: Array of `InactiveRouteResponse`.
    static func fetchInactiveRoutes(
        lat: Double, lon: Double, radius: Int? = nil,
        activeRoutes: [String] = []
    ) async throws -> [InactiveRouteResponse] {
        let effectiveRadius = radius ?? AppSettings.shared.effectiveAPISearchRadius
        guard var components = URLComponents(string: baseURL + "/nearby/inactive") else {
            throw TrackAPIError.invalidURL
        }
        var queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "radius", value: String(effectiveRadius)),
        ]
        if !activeRoutes.isEmpty {
            queryItems.append(
                URLQueryItem(name: "active_routes", value: activeRoutes.joined(separator: ","))
            )
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        AppLogger.shared.logRequest(method: "GET", url: url.absoluteString)
        let data = try await get(url: url)
        return try decoder.decode([InactiveRouteResponse].self, from: data)
    }

    // MARK: - Bus Vehicles & Route Shapes

    /// Fetches live vehicle positions for a bus route.
    ///
    /// - Parameter routeID: Fully-qualified route ID (e.g. "MTA NYCT_B63").
    /// - Returns: Array of `BusVehicleResponse` with GPS positions.
    static func fetchBusVehicles(routeID: String) async throws -> [BusVehicleResponse] {
        let encoded =
            routeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? routeID
        let data = try await get(path: "/bus/vehicles/\(encoded)")
        return try decoder.decode([BusVehicleResponse].self, from: data)
    }

    /// Fetches the route shape (polylines + stops) for a bus route.
    ///
    /// - Parameter routeID: Fully-qualified route ID (e.g. "MTA NYCT_B63").
    /// - Returns: A `RouteShapeResponse` with encoded polylines and stops.
    static func fetchRouteShape(routeID: String) async throws -> RouteShapeResponse {
        let encoded =
            routeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? routeID
        let data = try await get(path: "/bus/route-shape/\(encoded)")
        return try decoder.decode(RouteShapeResponse.self, from: data)
    }

    /// Fetches all bus route shapes and stops for map tile baking.
    ///
    /// Returns every NYC bus route polyline and every revenue stop in a
    /// single compact payload.  The iOS app downloads this once, bakes
    /// it into GeoJSON tile files, and renders as MapLibre GL layers
    /// for zero-lag bus mode rendering.
    ///
    /// - Returns: A `BusTileDataResponse` with all routes and stops.
    static func fetchBusTileData() async throws -> BusTileDataResponse {
        let data = try await get(path: "/bus/tile-data")
        return try decoder.decode(BusTileDataResponse.self, from: data)
    }

    /// Fetches the full route geometry for a subway line (e.g. the entire C train).
    ///
    /// - Parameter routeID: Subway line letter/number (e.g. "C", "L", "1").
    /// - Returns: A `RouteShapeResponse` with the complete polyline and all stations.
    static func fetchSubwayShape(routeID: String) async throws -> RouteShapeResponse {
        let encoded =
            routeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? routeID
        let data = try await get(path: "/subway/shape/\(encoded)")
        return try decoder.decode(RouteShapeResponse.self, from: data)
    }

    /// Fetches live GTFS-RT vehicle positions for a subway line.
    ///
    /// Backend: `GET /subway/vehicles/{line_id}` returns one entry per
    /// active train with real GPS lat/lon, bearing, speed, occupancy and
    /// VehicleStopStatus. Used by the map to overlay accurate live
    /// positions on top of (or in place of) the client's interpolated
    /// markers — see `HomeViewModel.updateTrainPositions`.
    ///
    /// Returns an empty array on transport / decode failure so callers
    /// can fall back to interpolation without throwing.
    ///
    /// - Parameter line: Subway line letter/number (e.g. "A", "7", "L").
    static func fetchSubwayVehicles(line: String) async -> [TrainVehicle] {
        let encoded =
            line.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? line
        do {
            let data = try await get(path: "/subway/vehicles/\(encoded)")
            return try decoder.decode([TrainVehicle].self, from: data)
        } catch {
            AppLogger.shared.logError(
                "fetchSubwayVehicles(\(line)) — falling back to interpolation",
                error: error
            )
            return []
        }
    }

    /// Fetches the full route geometry for a single LIRR branch.
    ///
    /// - Parameter routeID: LIRR branch ID (e.g. "LIRR_9" or "9").
    /// - Returns: A `RouteShapeResponse` with the branch polyline.
    static func fetchLIRRShape(routeID: String) async throws -> RouteShapeResponse {
        let encoded =
            routeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? routeID
        let data = try await get(path: "/lirr/shape/\(encoded)")
        return try decoder.decode(RouteShapeResponse.self, from: data)
    }

    /// Fetches the full route geometry for a single Metro-North line.
    ///
    /// - Parameter routeID: MNR line ID (e.g. "MNR_1" or "1").
    /// - Returns: A `RouteShapeResponse` with the line polyline.
    static func fetchMNRShape(routeID: String) async throws -> RouteShapeResponse {
        let encoded =
            routeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? routeID
        let data = try await get(path: "/mnr/shape/\(encoded)")
        return try decoder.decode(RouteShapeResponse.self, from: data)
    }

    /// Fetches polylines + colors for ALL subway lines (the full system map).
    ///
    /// Called once on app launch to draw every line on the map.
    /// Uses an extended timeout because this endpoint triggers the server's
    /// corridor pipeline on first call, which can take 45-90s on cold start.
    /// - Returns: An `AllSubwayLinesResponse` with lightweight overlay data per line.
    static func fetchAllSubwayShapes() async throws -> AllSubwayLinesResponse {
        let data = try await getWithExtendedTimeout(path: "/subway/shapes/all")
        return try decoder.decode(AllSubwayLinesResponse.self, from: data)
    }

    /// Fetches polylines + colors for ALL LIRR branches.
    /// - Returns: An `AllCommuterRailLinesResponse` with overlay data per branch.
    static func fetchAllLIRRShapes() async throws -> AllCommuterRailLinesResponse {
        let data = try await getWithExtendedTimeout(path: "/lirr/shapes/all")
        return try decoder.decode(AllCommuterRailLinesResponse.self, from: data)
    }

    /// Fetches polylines + colors for ALL Metro-North branches.
    /// - Returns: An `AllCommuterRailLinesResponse` with overlay data per branch.
    static func fetchAllMNRShapes() async throws -> AllCommuterRailLinesResponse {
        let data = try await getWithExtendedTimeout(path: "/mnr/shapes/all")
        return try decoder.decode(AllCommuterRailLinesResponse.self, from: data)
    }

    /// Fetches all subway stations for map markers.
    /// - Returns: An `AllSubwayStationsResponse` with all stations and their routes.
    static func fetchAllSubwayStations() async throws -> AllSubwayStationsResponse {
        let data = try await get(path: "/subway/stations/all")
        return try decoder.decode(AllSubwayStationsResponse.self, from: data)
    }

    /// Fetches processed stations with positions snapped onto offset polylines.
    /// Must be called after ``fetchAllSubwayShapes()`` so the pipeline cache is populated.
    /// - Returns: A `ProcessedStationsResponse` with `is_transfer` flags and per-route positions.
    static func fetchProcessedStations() async throws -> ProcessedStationsResponse {
        let data = try await get(path: "/subway/stations/processed")
        return try decoder.decode(ProcessedStationsResponse.self, from: data)
    }

    /// Fetches subway stations near the user's location.
    /// Uses server-side proximity filtering instead of downloading all stations.
    ///
    /// - Parameters:
    ///   - lat: User's latitude.
    ///   - lon: User's longitude.
    ///   - radius: Search radius in meters (defaults to ~1 mile).
    /// - Returns: An `AllSubwayStationsResponse` with nearby stations.
    static func fetchNearbySubwayStations(lat: Double, lon: Double, radius: Int = 1600) async throws
        -> AllSubwayStationsResponse
    {
        guard var components = URLComponents(string: baseURL + "/subway/stations/nearby") else {
            throw TrackAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "radius", value: String(radius)),
        ]
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        let data = try await get(url: url, waitsForConnectivity: false)
        return try decoder.decode(AllSubwayStationsResponse.self, from: data)
    }

    // MARK: - Delay Prediction

    /// Fetches a delay-adjusted arrival time from the backend prediction service.
    ///
    /// Safe to call on every arrival row — the backend responds in <1 ms when
    /// the result is cached.  Returns `nil` on any error so callers fall back
    /// to the un-adjusted ETA without disrupting the UI.
    ///
    /// - Parameters:
    ///   - minutesAway: MTA-predicted minutes until arrival.
    ///   - routeId: Transit route ID (e.g. "7", "L", "B63").
    ///   - mode: Transit mode: "subway", "bus", "lirr", "mnr".
    ///   - stopId: Optional GTFS stop_id for recency correction.
    /// - Returns: A `DelayPrediction`, or `nil` if the request fails.
    static func fetchDelayPrediction(
        minutesAway: Int,
        routeId: String,
        mode: String,
        stopId: String? = nil
    ) async -> DelayPrediction? {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        // Calendar weekday: 1 = Sunday … 7 = Saturday (matches backend expectation)
        let dayOfWeek = calendar.component(.weekday, from: now)

        guard var components = URLComponents(string: baseURL + "/predict/delay") else {
            return nil
        }
        var queryItems = [
            URLQueryItem(name: "minutes_away", value: String(minutesAway)),
            URLQueryItem(name: "route_id", value: routeId),
            URLQueryItem(name: "hour", value: String(hour)),
            URLQueryItem(name: "day_of_week", value: String(dayOfWeek)),
            URLQueryItem(name: "weather", value: "clear"),
            URLQueryItem(name: "mode", value: mode),
        ]
        if let stopId, !stopId.isEmpty {
            queryItems.append(URLQueryItem(name: "stop_id", value: stopId))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }
        // Use a lightweight one-shot request — no retries, 4s timeout.
        // The main `get(url:)` does 3 retries with exponential backoff
        // (designed for critical endpoints like /nearby/grouped).
        // Prediction is supplementary; burning 46s in retries when the
        // endpoint is cold would waste resources for no UX benefit.
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            if let token = cachedAccessToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }
            return try decoder.decode(DelayPrediction.self, from: data)
        } catch {
            // Non-fatal — caller falls back to un-adjusted ETA
            return nil
        }
    }

    // MARK: - Remote Config

    /// Fetches server-side configuration overrides from `/config`.
    /// Returns the raw JSON dictionary so AppSettings can merge selectively.
    /// Uses a single-shot request (no retries) with a short timeout —
    /// config is non-critical and the app runs fine on bundled defaults.
    static func fetchRemoteConfig() async -> [String: Any]? {
        guard let url = URL(string: baseURL + "/config") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            if let token = cachedAccessToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    // MARK: - Service Status

    /// Fetches critical MTA service alerts.
    ///
    /// - Returns: Array of `TransitAlert`.
    static func fetchAlerts() async throws -> [TransitAlert] {
        let data = try await get(path: "/alerts")
        return try decoder.decode([TransitAlert].self, from: data)
    }

    /// Fetches currently broken elevators and escalators.
    ///
    /// - Returns: Array of `ElevatorStatus`.
    static func fetchAccessibility() async throws -> [ElevatorStatus] {
        let data = try await get(path: "/accessibility")
        return try decoder.decode([ElevatorStatus].self, from: data)
    }

    /// Fetches the full accessibility profile for a station, including ADA
    /// status and all elevator/escalator equipment with live in-service status.
    ///
    /// - Parameters:
    ///   - stopIDs: GTFS stop IDs (e.g. ["127", "127N", "127S"]).
    ///   - name: Station display name for fallback matching.
    /// - Returns: Decoded `StationAccessibility`, or `nil` if station not found.
    static func fetchStationAccessibility(
        stopIDs: [String] = [],
        name: String? = nil
    ) async throws -> StationAccessibility? {
        var params: [(String, String)] = []
        if !stopIDs.isEmpty {
            params.append(("stop_ids", stopIDs.joined(separator: ",")))
        }
        if let name, !name.isEmpty {
            params.append(("name", name))
        }
        guard !params.isEmpty else { return nil }

        let query = params.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }.joined(separator: "&")
        do {
            let data = try await get(path: "/accessibility/station?\(query)")
            return try decoder.decode(StationAccessibility.self, from: data)
        } catch TrackAPIError.serverError(statusCode: 404) {
            return nil
        }
    }

    /// Fetches upcoming LIRR arrivals from the GTFS-Realtime feed.
    ///
    /// - Returns: Array of decoded `TrainArrival` objects.
    static func fetchLIRRArrivals() async throws -> [TrainArrival] {
        let data = try await get(path: "/lirr")
        return try decoder.decode([TransitArrivalResponse].self, from: data).map {
            $0.toTrainArrival()
        }
    }

    // MARK: - Metro-North

    /// Fetches upcoming Metro-North arrivals from the GTFS-Realtime feed.
    ///
    /// - Returns: Array of decoded `TrainArrival` objects.
    static func fetchMNRArrivals() async throws -> [TrainArrival] {
        let data = try await get(path: "/mnr")
        return try decoder.decode([TransitArrivalResponse].self, from: data).map {
            $0.toTrainArrival()
        }
    }

    // MARK: - Track Engine

    static func fetchEngineSearch(
        query: String,
        userID: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        limit: Int = 12
    ) async throws -> [PlannerSearchResult] {
        guard var components = URLComponents(string: baseURL + "/engine/search") else {
            throw TrackAPIError.invalidURL
        }
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let userID, !userID.isEmpty {
            queryItems.append(URLQueryItem(name: "user_id", value: userID))
        }
        if let latitude {
            queryItems.append(URLQueryItem(name: "lat", value: String(latitude)))
        }
        if let longitude {
            queryItems.append(URLQueryItem(name: "lon", value: String(longitude)))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        let data = try await get(url: url)
        return try decoder.decode([PlannerSearchResult].self, from: data)
    }

    static func fetchEngineSavedPlaces(userID: String) async throws -> [PlannerSavedPlaceRecord] {
        guard var components = URLComponents(string: baseURL + "/engine/places") else {
            throw TrackAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        let data = try await get(url: url)
        return try decoder.decode([PlannerSavedPlaceRecord].self, from: data)
    }

    static func upsertEngineSavedPlace(
        request payload: EngineSavedPlaceUpsertRequest
    ) async throws -> PlannerSavedPlaceRecord {
        let data = try await sendJSON(
            method: "POST",
            path: "/engine/places",
            body: payload,
            timeout: 20
        )
        return try decoder.decode(PlannerSavedPlaceRecord.self, from: data)
    }

    static func deleteEngineSavedPlace(
        placeID: Int,
        userID: String
    ) async throws {
        _ = try await sendJSON(
            method: "DELETE",
            path: "/engine/places/\(placeID)",
            queryItems: [URLQueryItem(name: "user_id", value: userID)],
            timeout: 20
        )
    }

    static func fetchEngineRecentTrips(
        userID: String,
        limit: Int = 12
    ) async throws -> [PlannerRecentTripRecord] {
        guard var components = URLComponents(string: baseURL + "/engine/trips/recent") else {
            throw TrackAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        let data = try await get(url: url)
        return try decoder.decode([PlannerRecentTripRecord].self, from: data)
    }

    static func fetchEngineRecommendations(
        userID: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        originLabel: String = "Current location",
        limit: Int = 6
    ) async throws -> [PlannerRecommendation] {
        guard var components = URLComponents(string: baseURL + "/engine/recommendations") else {
            throw TrackAPIError.invalidURL
        }
        var queryItems = [
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "origin_label", value: originLabel),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let latitude {
            queryItems.append(URLQueryItem(name: "origin_lat", value: String(latitude)))
        }
        if let longitude {
            queryItems.append(URLQueryItem(name: "origin_lon", value: String(longitude)))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        let data = try await get(url: url)
        return try decoder.decode([PlannerRecommendation].self, from: data)
    }

    // MARK: - Saved Trip Templates

    static func fetchEngineSavedTrips(
        userID: String
    ) async throws -> [PlannerSavedTripRecord] {
        guard var components = URLComponents(string: baseURL + "/engine/trips/saved") else {
            throw TrackAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        let data = try await get(url: url)
        return try decoder.decode([PlannerSavedTripRecord].self, from: data)
    }

    static func upsertEngineSavedTrip(
        request payload: EngineSavedTripUpsertRequest
    ) async throws -> PlannerSavedTripRecord {
        let data = try await sendJSON(
            method: "POST",
            path: "/engine/trips/saved",
            body: payload,
            timeout: 20
        )
        return try decoder.decode(PlannerSavedTripRecord.self, from: data)
    }

    static func deleteEngineSavedTrip(
        tripID: Int,
        userID: String
    ) async throws {
        _ = try await sendJSON(
            method: "DELETE",
            path: "/engine/trips/saved/\(tripID)",
            queryItems: [URLQueryItem(name: "user_id", value: userID)],
            timeout: 20
        )
    }

    // MARK: - Calendar Events

    static func replaceCalendarEvents(
        userID: String,
        events: [CalendarEventPayload]
    ) async throws {
        _ = try await sendJSON(
            method: "PUT",
            path: "/engine/calendar/events",
            queryItems: [URLQueryItem(name: "user_id", value: userID)],
            body: events,
            timeout: 20
        )
    }

    // MARK: - Go (Trip Planning)

    static func fetchEngineGo(
        request payload: EngineGoRequestPayload
    ) async throws -> EngineGoResponseDTO {
        let data = try await sendJSON(
            method: "POST",
            path: "/engine/go",
            body: payload,
            timeout: 40
        )
        return try decoder.decode(EngineGoResponseDTO.self, from: data)
    }

    // MARK: - Private

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Use a custom strategy that handles both standard ISO 8601
        // ("2026-03-31T12:00:00Z") and fractional-second variants
        // ("2026-03-31T12:00:00.123456+00:00") that MTA SIRI and
        // Python's datetime.isoformat() emit by default.
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBase = ISO8601DateFormatter()
        isoBase.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = isoFull.date(from: str) { return date }
            if let date = isoBase.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(str)"
            )
        }
        return d
    }()

    private static let encoder = JSONEncoder()

    private static let memoizer = APIRequestMemoizer()
    private static let staticEndpointTTL: TimeInterval = 30

    private static func isStaticCacheablePath(_ path: String) -> Bool {
        switch path {
        case "/subway/shapes/all", "/lirr/shapes/all", "/mnr/shapes/all",
             "/subway/stations/all", "/alerts", "/accessibility",
             "/bus/routes":
            return true
        default:
            // Schedule and shape endpoints change rarely — cache 30 s
            // so rapid re-opens and back-button don't re-fetch.
            if path.hasPrefix("/bus/schedule/") || path.hasPrefix("/bus/route-shape/") {
                return true
            }
            return false
        }
    }

    private static func cacheablePath(from url: URL) -> String? {
        let path = url.path
        return isStaticCacheablePath(path) ? path : nil
    }

    private static func get(path: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw TrackAPIError.invalidURL
        }
        AppLogger.shared.logRequest(method: "GET", url: url.absoluteString)
        return try await get(url: url)
    }

    /// Extended-timeout variant for heavy endpoints (shapes/all) that trigger
    /// the server's corridor pipeline on cold start.  Uses a dedicated
    /// URLSession with a 90 s resource timeout so the request survives
    /// Render.com's free-tier cold boot (30-60 s) + pipeline execution.
    ///
    /// Uses `.reloadIgnoringLocalCacheData` so URLSession never serves a
    /// stale HTTP-cached response — the app-level memoizer (30 s TTL) and
    /// `OfflineCacheManager` provide all the caching we need.  This prevents
    /// the poisoned-empty-shapes bug where `Cache-Control: max-age=3600` causes
    /// URLSession to return a cached empty 200 for up to 1 hour after a bad
    /// cold-start response.
    private static let extendedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil  // app-level memoizer + OfflineCache handle caching
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Same retry/timeout profile as `extendedSession`, but does not wait
    /// indefinitely for connectivity. Offline-capable endpoints use this so
    /// they can fall through to local GTFS instead of parking on URLSession's
    /// connectivity queue.
    private static let extendedFailFastSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private static func getWithExtendedTimeout(path: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw TrackAPIError.invalidURL
        }
        AppLogger.shared.logRequest(method: "GET", url: url.absoluteString)
        return try await getWithExtendedTimeout(url: url)
    }

    private static func getWithExtendedTimeout(
        url: URL,
        waitsForConnectivity: Bool = true
    ) async throws -> Data {
        let cacheKey = url.absoluteString
        let cacheablePath = cacheablePath(from: url)

        // Re-use the same memo/cache layer as the standard get() method
        if let cacheablePath,
           let cached = await memoizer.getCached(for: cacheablePath, ttl: staticEndpointTTL)
        {
            AppLogger.shared.log("API_CACHE", message: "HIT \(cacheablePath)")
            return cached
        }

        if let inflight = await memoizer.getInflight(for: cacheKey) {
            AppLogger.shared.log("API_CACHE", message: "COALESCE \(url.path)")
            return try await inflight.value
        }

        let task = Task<Data, Error> {
            var lastError: Error = TrackAPIError.networkError
            // Extended timeout with aggressive cold-start retries.
            // During cold start, the server's corridor pipeline can take
            // 60-90s and returns 503 + Retry-After:15.  6 attempts × 15s
            // = 90s coverage, enough for worst-case pipeline builds.
            let wasColdStart = !serverWarmedUp
            let maxAttempts = wasColdStart ? 6 : 3
            let endpointPath = url.path
            let retryStart = Date()
            for attempt in 0..<maxAttempts {
                if attempt > 0 {
                    // Escalating backoff: 5s, 10s, 15s during cold start;
                    // 3s for warm-server transient retries.
                    // Note: 503 responses with Retry-After already sleep
                    // before reaching this point, so we skip the extra delay.
                    let delay: UInt64 = wasColdStart
                        ? UInt64(min(5 + (attempt - 1) * 5, 15)) * 1_000_000_000
                        : 3_000_000_000
                    let delaySec = Double(delay) / 1_000_000_000
                    let waitSec = String(format: "%.0f", delaySec)
                    let tPlus = AppLogger.formatDuration(
                        AppLogger.shared.timeSinceLaunch
                    )
                    let msg = "\(endpointPath) "
                        + "attempt \(attempt + 1)/\(maxAttempts) "
                        + "— waiting \(waitSec)s (T+\(tPlus))"
                    AppLogger.shared.log("API_RETRY", message: msg)
                    try await Task.sleep(nanoseconds: delay)
                }
                do {
                    let attemptStart = Date()
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 45
                    if let token = cachedAccessToken, !token.isEmpty {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    let session = waitsForConnectivity
                        ? extendedSession
                        : extendedFailFastSession
                    let (data, response) = try await session.data(for: request)
                    let attemptElapsed = Date().timeIntervalSince(attemptStart)
                    guard let http = response as? HTTPURLResponse else {
                        let dur = AppLogger.formatDuration(attemptElapsed)
                        let msg = "\(endpointPath) "
                            + "attempt \(attempt + 1) "
                            + "→ no HTTP response (\(dur))"
                        AppLogger.shared.log("API_RETRY", message: msg)
                        lastError = TrackAPIError.networkError
                        continue
                    }
                    guard (200...299).contains(http.statusCode) else {
                        let dur = AppLogger.formatDuration(attemptElapsed)
                        let msg = "\(endpointPath) "
                            + "attempt \(attempt + 1) "
                            + "→ HTTP \(http.statusCode) (\(dur))"
                        AppLogger.shared.log("API_RETRY", message: msg)
                        let serverErr = TrackAPIError.serverError(statusCode: http.statusCode)
                        if http.statusCode < 500 { throw serverErr }
                        // Respect Retry-After header from 503 (shapes building)
                        if http.statusCode == 503,
                           let retryAfterStr = http.value(forHTTPHeaderField: "Retry-After"),
                           let retryAfterSec = Double(retryAfterStr),
                           retryAfterSec > 0, retryAfterSec <= 30
                        {
                            let retryMsg = "\(endpointPath) "
                                + "server said Retry-After: "
                                + "\(retryAfterStr)s"
                            AppLogger.shared.log(
                                "API_RETRY",
                                message: retryMsg
                            )
                            try await Task.sleep(nanoseconds: UInt64(retryAfterSec * 1_000_000_000))
                        }
                        lastError = serverErr
                        continue
                    }
                    let totalRetryElapsed = Date().timeIntervalSince(retryStart)
                    let dur = AppLogger.formatDuration(attemptElapsed)
                    let total = AppLogger.formatDuration(
                        totalRetryElapsed
                    )
                    let msg = "\(endpointPath) "
                        + "attempt \(attempt + 1) "
                        + "→ ✅ \(http.statusCode) "
                        + "(\(dur), total \(total))"
                    AppLogger.shared.log("API_RETRY", message: msg)
                    serverWarmedUp = true
                    return data
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as TrackAPIError {
                    throw error
                } catch {
                    let msg = "\(endpointPath) "
                        + "attempt \(attempt + 1) "
                        + "→ \(error.localizedDescription)"
                    AppLogger.shared.log("API_RETRY", message: msg)
                    lastError = error
                }
            }
            let totalRetryElapsed = Date().timeIntervalSince(retryStart)
            let failDur = AppLogger.formatDuration(
                totalRetryElapsed
            )
            let tPlus = AppLogger.formatDuration(
                AppLogger.shared.timeSinceLaunch
            )
            let msg = "\(endpointPath) ALL "
                + "\(maxAttempts) attempts FAILED "
                + "after \(failDur) (T+\(tPlus))"
            AppLogger.shared.log("API_RETRY", message: msg)
            throw lastError
        }

        await memoizer.setInflight(task, for: cacheKey)

        do {
            let data = try await task.value
            if let cacheablePath {
                await memoizer.setCached(data, for: cacheablePath)
                AppLogger.shared.log("API_CACHE", message: "STORE \(cacheablePath)")
            }
            await memoizer.clearInflight(for: cacheKey)
            return data
        } catch {
            await memoizer.clearInflight(for: cacheKey)
            throw error
        }
    }

    private static func get(
        url: URL,
        waitsForConnectivity: Bool = true
    ) async throws -> Data {
        let cacheKey = url.absoluteString
        let cacheablePath = cacheablePath(from: url)

        if let cacheablePath,
           let cached = await memoizer.getCached(for: cacheablePath, ttl: staticEndpointTTL)
        {
            AppLogger.shared.log("API_CACHE", message: "HIT \(cacheablePath)")
            return cached
        }

        if let inflight = await memoizer.getInflight(for: cacheKey) {
            AppLogger.shared.log("API_CACHE", message: "COALESCE \(url.path)")
            return try await inflight.value
        }

        let task = Task<Data, Error> {
            var lastError: Error = TrackAPIError.networkError
            // During cold-start use fewer retries with a longer timeout
            // so a single attempt can survive Render's boot time.
            // 25 s per request × 2 attempts fits within the 30 s resource
            // timeout budget while giving the server time to warm up.
            //
            // Capture cold-start state ONCE at the start of the retry loop.
            // A concurrent request (e.g. /subway/stations/all) may flip
            // serverWarmedUp mid-loop, which previously caused the timeout
            // to drop from 25 s → 15 s between attempts — cutting the 2nd
            // attempt short before the server could respond.
            let wasColdStart = !serverWarmedUp
            let maxAttempts = wasColdStart ? 2 : 3
            for attempt in 0..<maxAttempts {
                if attempt > 0 {
                    // Exponential backoff: 0.5 s, 1.0 s
                    let delay = UInt64(0.5 * Double(attempt) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                }
                do {
                    var request = URLRequest(url: url)
                    // Extend per-request timeout during cold-start so the
                    // retry doesn't burn all attempts before the server boots.
                    // Use the captured flag so the timeout stays consistent
                    // across ALL attempts in this retry loop.
                    if wasColdStart {
                        request.timeoutInterval = 25
                    }
                    if let token = cachedAccessToken, !token.isEmpty {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }

                    let requestSession = waitsForConnectivity ? session : failFastSession
                    let (data, response) = try await requestSession.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        lastError = TrackAPIError.networkError
                        continue
                    }

                    guard (200...299).contains(http.statusCode) else {
                        let serverErr = TrackAPIError.serverError(statusCode: http.statusCode)
                        // Do not retry 4xx client errors — they won't change
                        if http.statusCode < 500 { throw serverErr }
                        lastError = serverErr
                        continue
                    }
                    serverWarmedUp = true
                    return data
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as TrackAPIError {
                    // Propagate non-retriable API errors immediately
                    throw error
                } catch {
                    // URLError and other transient network errors → retry
                    lastError = error
                }
            }
            throw lastError
        }

        await memoizer.setInflight(task, for: cacheKey)

        do {
            let data = try await task.value
            if let cacheablePath {
                await memoizer.setCached(data, for: cacheablePath)
                AppLogger.shared.log("API_CACHE", message: "STORE \(cacheablePath)")
            }
            await memoizer.clearInflight(for: cacheKey)
            return data
        } catch {
            await memoizer.clearInflight(for: cacheKey)
            throw error
        }
    }

    private static func sendJSON<Body: Encodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        guard var components = URLComponents(string: baseURL + path) else {
            throw TrackAPIError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }

        AppLogger.shared.logRequest(method: method, url: url.absoluteString)

        var lastError: Error = TrackAPIError.networkError
        let wasColdStart = !serverWarmedUp
        let attempts = wasColdStart ? 3 : 2

        for attempt in 0..<attempts {
            if attempt > 0 {
                // Reduced delays: cold-start 2s→4s, warm 1s→2s
                let delay: UInt64 = wasColdStart
                    ? UInt64(min(2 + attempt * 2, 6)) * 1_000_000_000
                    : UInt64(attempt) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            }

            do {
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.timeoutInterval = wasColdStart ? max(timeout, 20) : timeout
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                if let token = cachedAccessToken, !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }

                if let body {
                    request.httpBody = try encoder.encode(body)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }

                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = TrackAPIError.networkError
                    continue
                }
                guard (200...299).contains(http.statusCode) else {
                    let serverErr = TrackAPIError.serverError(statusCode: http.statusCode)
                    if http.statusCode < 500 {
                        throw serverErr
                    }
                    // Respect Retry-After from 503 (engine starting up)
                    if http.statusCode == 503,
                       let retryAfter = http.value(forHTTPHeaderField: "Retry-After"),
                       let retrySec = Double(retryAfter),
                       retrySec > 0, retrySec <= 15
                    {
                        try await Task.sleep(nanoseconds: UInt64(retrySec * 1_000_000_000))
                    }
                    lastError = serverErr
                    continue
                }

                serverWarmedUp = true

                // Log server timing when available
                #if DEBUG
                if let serverMs = http.value(forHTTPHeaderField: "X-Server-Time-Ms") {
                    let pathStr = url.path
                    print("[Network] \(pathStr) — server: \(serverMs)ms")
                }
                #endif

                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TrackAPIError {
                throw error
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private static func sendJSON(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval = 30
    ) async throws -> Data {
        try await sendJSON(
            method: method,
            path: path,
            queryItems: queryItems,
            body: Optional<String>.none,
            timeout: timeout
        )
    }
}

// MARK: - Errors

enum TrackAPIError: Error, LocalizedError, CustomStringConvertible {
    case invalidURL
    case networkError
    case decodingFailed
    case serverError(statusCode: Int)

    var description: String {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .networkError:
            return "Network connection failed"
        case .decodingFailed:
            return "Unable to read server response"
        case .serverError(let code):
            return "Server error (\(code))"
        }
    }

    var errorDescription: String? { description }
}

// MARK: - Backend Response Types

// Models have been moved to:
// - Models/TransitResponseModels.swift
// - Models/BusModels.swift
// - Models/SubwayModels.swift
