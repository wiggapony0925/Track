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
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    // MARK: - Connection Warm-Up

    /// Fires a lightweight TCP/TLS warm-up to the backend host as early as
    /// possible in the app lifecycle (called from TrackApp.init).
    ///
    /// On cellular, establishing a TLS connection cold takes 1–3 seconds.
    /// By the time HomeView.onAppear fires the real /nearby/grouped request,
    /// the connection is already open → that latency cost is paid in parallel
    /// with splash / auth checks rather than on the critical path.
    static func warmConnection() {
        Task.detached(priority: .utility) {
            guard let url = URL(string: baseURL + "/health") else { return }
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
    /// Called from `TrackApp.init()` at `.userInitiated` priority so it
    /// resolves before HomeView.onAppear fires its first real request.
    static func validateLocalServer() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "dev_use_localhost") else { return }
        Task.detached(priority: .userInitiated) {
            // Use a plain URLSession — no waitsForConnectivity — so a TCP
            // refused / host-unreachable error comes back in milliseconds.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 1.5
            config.timeoutIntervalForResource = 1.5
            let probe = URLSession(configuration: config)
            let storedIP = UserDefaults.standard.string(forKey: "dev_custom_ip")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedIP = (storedIP?.isEmpty == false) ? storedIP! : AppSettings.shared.defaultDeviceIP
            let localURL = "http://\(resolvedIP):\(AppSettings.shared.localPort)/health"
            guard let url = URL(string: localURL) else { return }
            do {
                _ = try await probe.data(from: url)
                // Server responded — keep the flag as-is
                AppLogger.shared.log("API_CONFIG", message: "Local server reachable at \(localURL) ✓")
            } catch {
                // Server unreachable — clear the flag and force prod
                AppLogger.shared.log("API_CONFIG", message: "Local server unreachable (\(error.localizedDescription)) — falling back to production")
                await MainActor.run {
                    UserDefaults.standard.removeObject(forKey: "dev_use_localhost")
                }
                invalidateBaseURL()
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
        return try decoder.decode([SubwayArrivalResponse].self, from: data).map {
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
    /// - Returns: An `AllSubwayLinesResponse` with lightweight overlay data per line.
    static func fetchAllSubwayShapes() async throws -> AllSubwayLinesResponse {
        let data = try await get(path: "/subway/shapes/all")
        return try decoder.decode(AllSubwayLinesResponse.self, from: data)
    }

    /// Fetches polylines + colors for ALL LIRR branches.
    /// - Returns: An `AllCommuterRailLinesResponse` with overlay data per branch.
    static func fetchAllLIRRShapes() async throws -> AllCommuterRailLinesResponse {
        let data = try await get(path: "/lirr/shapes/all")
        return try decoder.decode(AllCommuterRailLinesResponse.self, from: data)
    }

    /// Fetches polylines + colors for ALL Metro-North branches.
    /// - Returns: An `AllCommuterRailLinesResponse` with overlay data per branch.
    static func fetchAllMNRShapes() async throws -> AllCommuterRailLinesResponse {
        let data = try await get(path: "/mnr/shapes/all")
        return try decoder.decode(AllCommuterRailLinesResponse.self, from: data)
    }

    /// Fetches all subway stations for map markers.
    /// - Returns: An `AllSubwayStationsResponse` with all stations and their routes.
    static func fetchAllSubwayStations() async throws -> AllSubwayStationsResponse {
        let data = try await get(path: "/subway/stations/all")
        return try decoder.decode(AllSubwayStationsResponse.self, from: data)
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
        return try decoder.decode([SubwayArrivalResponse].self, from: data).map {
            $0.toTrainArrival()
        }
    }

    // MARK: - Metro-North

    /// Fetches upcoming Metro-North arrivals from the GTFS-Realtime feed.
    ///
    /// - Returns: Array of decoded `TrainArrival` objects.
    static func fetchMNRArrivals() async throws -> [TrainArrival] {
        let data = try await get(path: "/mnr")
        return try decoder.decode([SubwayArrivalResponse].self, from: data).map {
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
        case "/subway/shapes/all", "/lirr/shapes/all", "/mnr/shapes/all", "/subway/stations/all", "/alerts", "/accessibility":
            return true
        default:
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
            for attempt in 0..<3 {
                if attempt > 0 {
                    // Exponential backoff: 0.5 s, 1.0 s
                    let delay = UInt64(0.5 * Double(attempt) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                }
                do {
                    var request = URLRequest(url: url)
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
                    return data
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

enum TrackAPIError: Error, CustomStringConvertible {
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
}

// MARK: - Backend Response Types

// Models have been moved to:
// - Models/TransitResponseModels.swift
// - Models/BusModels.swift
// - Models/SubwayModels.swift
