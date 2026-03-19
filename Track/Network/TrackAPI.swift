//
//  TrackAPI.swift
//  Track
//
//  Unified network client that communicates with the TrackBackend proxy API.
//  All MTA data flows through the backend — the iOS app never calls MTA directly.
//

import CoreLocation
import Foundation

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
                .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupIdentifier)?
                .appendingPathComponent("URLCache")
        )
        // Use the protocol's cache policy (honors Cache-Control headers).
        // This is the default, but explicit is better than implicit.
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    // MARK: - Cold-Start State

    /// Whether at least one backend response has succeeded this session.
    /// Before this becomes `true`, HTTP timeouts are extended to 25 s to
    /// survive Render's container cold-start (warmup now takes ~5 s with
    /// concurrent feed priming instead of the old ~25 s sequential warmup).
    /// Reset automatically on each app launch (static var, not persisted).
    nonisolated(unsafe) private(set) static var serverWarmedUp = false

    // MARK: - Connection Warm-Up

    /// Fires a lightweight TCP/TLS warm-up to the backend host as early as
    /// possible in the app lifecycle (called from TrackApp.init).
    ///
    /// On cellular, establishing a TLS connection cold takes 1–3 seconds.
    /// By the time HomeView.onAppear fires the real /nearby/grouped request,
    /// the connection is already open → that latency cost is paid in parallel
    /// with splash / auth checks rather than on the critical path.
    static func warmConnection() {
        // .userInitiated guarantees the TLS handshake completes before
        // HomeView fires its first /nearby/grouped request. The former
        // .utility priority let iOS defer this, leaving TLS on the
        // critical path and adding ~1-2s on cellular cold launches.
        let resolvedBase = baseURL          // read on @MainActor
        Task.detached(priority: .userInitiated) {
            guard let url = URL(string: resolvedBase + "/health") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            _ = try? await session.data(for: request)
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
        UserDefaults.standard.removeObject(forKey: "dev_use_localhost")
        invalidateBaseURL()

        // Read MainActor-isolated values before entering the detached task.
        let storedIP = UserDefaults.standard.string(forKey: "dev_custom_ip")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedIP = (storedIP?.isEmpty == false) ? storedIP! : AppSettings.shared.defaultDeviceIP
        let port = AppSettings.shared.localPort
        let localURL = "http://\(resolvedIP):\(port)/health"
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
                    UserDefaults.standard.set(true, forKey: "dev_use_localhost")
                    invalidateBaseURL()
                }
            } catch {
                // Server unreachable — flag already cleared, nothing to do
                logger.log("API_CONFIG", message: "Local server unreachable (\(error.localizedDescription)) — staying on production")
            }
        }
        #endif
    }

    // MARK: - Cached User Email (avoids MainActor hop on every request)

    /// Set by SupabaseManager after login/profile load to avoid hopping
    /// to @MainActor on every API call.
    /// nonisolated(unsafe) is safe here: written only from @MainActor
    /// (SupabaseManager.currentUser didSet) and read from async contexts
    /// where a stale/nil value is harmless (just omits the header).
    nonisolated(unsafe) private(set) static var cachedUserEmail: String?

    static func setCachedEmail(_ email: String?) {
        cachedUserEmail = email
    }

    // MARK: - Environment Configuration

    /// The active backend URL, determined by the Developer Settings in SettingsView.
    /// On a physical device, localhost is never used (it would point to the phone itself).
    /// Cached to avoid re-computing (and logging) on every API call.
    /// nonisolated(unsafe): written from @MainActor, read from async contexts.
    nonisolated(unsafe) private static var _cachedBaseURL: String?
    
    /// Invalidate the cached URL when developer settings change.
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
            let storedIP = UserDefaults.standard.string(forKey: "dev_custom_ip")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedIP = (storedIP?.isEmpty == false) ? storedIP! : settings.defaultDeviceIP
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

        if let email = cachedUserEmail, !email.isEmpty {
            request.setValue(email, forHTTPHeaderField: "x-user-email")
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
    /// - Returns: Array of `GroupedNearbyTransitResponse`.
    static func fetchNearbyGrouped(
        lat: Double, lon: Double, radius: Int? = nil, mode: String? = nil
    ) async throws -> [GroupedNearbyTransitResponse] {
        let effectiveRadius = radius ?? AppSettings.shared.effectiveAPISearchRadius
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
        components.queryItems = queryItems
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        let data = try await get(url: url)
        return try decoder.decode([GroupedNearbyTransitResponse].self, from: data)
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
        let data = try await get(url: url)
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
            if let email = cachedUserEmail, !email.isEmpty {
                request.setValue(email, forHTTPHeaderField: "x-user-email")
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
            if let email = cachedUserEmail, !email.isEmpty {
                request.setValue(email, forHTTPHeaderField: "x-user-email")
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

    // MARK: - Private

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

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
    private static let extendedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = URLCache(
            memoryCapacity: 10 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024,
            directory: FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupIdentifier)?
                .appendingPathComponent("URLCache")
        )
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    private static func getWithExtendedTimeout(path: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw TrackAPIError.invalidURL
        }
        AppLogger.shared.logRequest(method: "GET", url: url.absoluteString)
        return try await getWithExtendedTimeout(url: url)
    }

    private static func getWithExtendedTimeout(url: URL) async throws -> Data {
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
            // Extended timeout: 1 attempt with 45 s timeout (cold-start),
            // then 1 retry with 45 s if it's a transient 5xx.
            let maxAttempts = 2
            for attempt in 0..<maxAttempts {
                if attempt > 0 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 s backoff
                }
                do {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 45
                    if let email = cachedUserEmail, !email.isEmpty {
                        request.setValue(email, forHTTPHeaderField: "x-user-email")
                    }
                    let (data, response) = try await extendedSession.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        lastError = TrackAPIError.networkError
                        continue
                    }
                    guard (200...299).contains(http.statusCode) else {
                        let serverErr = TrackAPIError.serverError(statusCode: http.statusCode)
                        if http.statusCode < 500 { throw serverErr }
                        lastError = serverErr
                        continue
                    }
                    serverWarmedUp = true
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

    private static func get(url: URL) async throws -> Data {
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
            let maxAttempts = serverWarmedUp ? 3 : 2
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
                    if !serverWarmedUp {
                        request.timeoutInterval = 25
                    }
                    if let email = cachedUserEmail, !email.isEmpty {
                        request.setValue(email, forHTTPHeaderField: "x-user-email")
                    }

                    let (data, response) = try await session.data(for: request)
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
