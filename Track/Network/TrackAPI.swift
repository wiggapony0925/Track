//
//  TrackAPI.swift
//  Track
//
//  Unified network client that communicates with the TrackBackend proxy API.
//  All MTA data flows through the backend — the iOS app never calls MTA directly.
//

import Foundation
import CoreLocation

/// Centralized API client for the Track backend.
struct TrackAPI {

    // MARK: - Environment Configuration

    /// The active backend URL, determined by the Developer Settings in SettingsView.
    /// On a physical device, localhost is never used (it would point to the phone itself).
    static var baseURL: String {
        let settings = AppSettings.shared
        let useLocalhost = UserDefaults.standard.bool(forKey: "dev_use_localhost")

        #if targetEnvironment(simulator)
        // Simulator runs on the Mac — localhost works fine
        if useLocalhost {
            let url = settings.localBaseURL
            print("🌐 TrackAPI baseURL (simulator/localhost): \(url)")
            return url
        }
        #endif

        // Physical device (or simulator with localhost off) — always use the WiFi IP
        let storedIP = UserDefaults.standard.string(forKey: "dev_custom_ip")
        let ip = (storedIP?.isEmpty == false) ? storedIP! : settings.defaultDeviceIP
        let url = "http://\(ip):\(settings.localPort)"
        #if DEBUG
        print("🌐 TrackAPI baseURL: \(url)  (ip=\(ip), stored=\(storedIP ?? "nil"), default=\(settings.defaultDeviceIP))")
        #endif
        return url
    }

    // MARK: - Config

    /// Fetches app settings from the backend on launch.
    static func fetchConfig() async throws -> [String: Any] {
        let data = try await get(path: "/config")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrackAPIError.decodingFailed
        }
        return json
    }

    // MARK: - Subway

    /// Fetches upcoming subway arrivals for a line from the backend.
    ///
    /// - Parameter lineID: A subway line identifier (e.g. "L", "A", "1").
    /// - Returns: Array of decoded `TrainArrival` objects.
    static func fetchSubwayArrivals(lineID: String) async throws -> [TrainArrival] {
        let data = try await get(path: "/subway/\(lineID)")
        return try decoder.decode([SubwayArrivalResponse].self, from: data).map { $0.toTrainArrival() }
    }

    // MARK: - Bus

    /// Fetches nearby bus stops based on coordinates.
    ///
    /// - Parameters:
    ///   - lat: User's latitude.
    ///   - lon: User's longitude.
    /// - Returns: Array of `BusStop`.
    static func fetchNearbyBusStops(lat: Double, lon: Double, radius: Int? = nil) async throws -> [BusStop] {
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

    /// Fetches stops for a specific bus route.
    ///
    /// - Parameter routeID: Fully-qualified route ID (e.g. "MTA NYCT_B63").
    /// - Returns: Array of `BusStop` along the route.
    static func fetchBusStopsForRoute(routeID: String) async throws -> [BusStop] {
        let encoded = routeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? routeID
        let data = try await get(path: "/bus/stops/\(encoded)")
        return try decoder.decode([BusStop].self, from: data)
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
    static func fetchNearbyTransit(lat: Double, lon: Double, radius: Int? = nil) async throws -> [NearbyTransitResponse] {
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
    static func fetchNearbyGrouped(lat: Double, lon: Double, radius: Int? = nil, mode: String? = nil) async throws -> [GroupedNearbyTransitResponse] {
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
        let encoded = routeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? routeID
        let data = try await get(path: "/bus/vehicles/\(encoded)")
        return try decoder.decode([BusVehicleResponse].self, from: data)
    }

    /// Fetches the route shape (polylines + stops) for a bus route.
    ///
    /// - Parameter routeID: Fully-qualified route ID (e.g. "MTA NYCT_B63").
    /// - Returns: A `RouteShapeResponse` with encoded polylines and stops.
    static func fetchRouteShape(routeID: String) async throws -> RouteShapeResponse {
        let encoded = routeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? routeID
        let data = try await get(path: "/bus/route-shape/\(encoded)")
        return try decoder.decode(RouteShapeResponse.self, from: data)
    }

    /// Fetches the full route geometry for a subway line (e.g. the entire C train).
    ///
    /// - Parameter routeID: Subway line letter/number (e.g. "C", "L", "1").
    /// - Returns: A `RouteShapeResponse` with the complete polyline and all stations.
    static func fetchSubwayShape(routeID: String) async throws -> RouteShapeResponse {
        let encoded = routeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? routeID
        let data = try await get(path: "/subway/shape/\(encoded)")
        return try decoder.decode(RouteShapeResponse.self, from: data)
    }

    /// Fetches the full route geometry for a single LIRR branch.
    ///
    /// - Parameter routeID: LIRR branch ID (e.g. "LIRR_9" or "9").
    /// - Returns: A `RouteShapeResponse` with the branch polyline.
    static func fetchLIRRShape(routeID: String) async throws -> RouteShapeResponse {
        let encoded = routeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? routeID
        let data = try await get(path: "/lirr/shape/\(encoded)")
        return try decoder.decode(RouteShapeResponse.self, from: data)
    }

    /// Fetches the full route geometry for a single Metro-North line.
    ///
    /// - Parameter routeID: MNR line ID (e.g. "MNR_1" or "1").
    /// - Returns: A `RouteShapeResponse` with the line polyline.
    static func fetchMNRShape(routeID: String) async throws -> RouteShapeResponse {
        let encoded = routeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? routeID
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
    static func fetchNearbySubwayStations(lat: Double, lon: Double, radius: Int = 1600) async throws -> AllSubwayStationsResponse {
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
    /// Replaces the client-side `DelayCalculator` heuristic with a server-side model
    /// that can be upgraded (e.g. to ML) without an app update.
    ///
    /// - Parameters:
    ///   - minutesAway: MTA-predicted minutes until arrival
    ///   - routeId: The transit route identifier
    ///   - hour: Current hour (0-23)
    ///   - dayOfWeek: Day of week (1=Sun, 7=Sat)
    ///   - weather: Current weather: "clear", "rain", or "snow"
    /// - Returns: A `DelayPredictionResponse` with adjusted time.
    static func fetchDelayPrediction(
        minutesAway: Int,
        routeId: String,
        hour: Int,
        dayOfWeek: Int,
        weather: String = "clear"
    ) async throws -> DelayPredictionResponse {
        guard var components = URLComponents(string: baseURL + "/predict/delay") else {
            throw TrackAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "minutes_away", value: String(minutesAway)),
            URLQueryItem(name: "route_id", value: routeId),
            URLQueryItem(name: "hour", value: String(hour)),
            URLQueryItem(name: "day_of_week", value: String(dayOfWeek)),
            URLQueryItem(name: "weather", value: weather),
        ]
        guard let url = components.url else {
            throw TrackAPIError.invalidURL
        }
        let data = try await get(url: url)
        return try decoder.decode(DelayPredictionResponse.self, from: data)
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
        return try decoder.decode([SubwayArrivalResponse].self, from: data).map { $0.toTrainArrival() }
    }

    // MARK: - Metro-North

    /// Fetches upcoming Metro-North arrivals from the GTFS-Realtime feed.
    ///
    /// - Returns: Array of decoded `TrainArrival` objects.
    static func fetchMNRArrivals() async throws -> [TrainArrival] {
        let data = try await get(path: "/mnr")
        return try decoder.decode([SubwayArrivalResponse].self, from: data).map { $0.toTrainArrival() }
    }

    // MARK: - Private

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func get(path: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw TrackAPIError.invalidURL
        }
        AppLogger.shared.logRequest(method: "GET", url: url.absoluteString)
        return try await get(url: url)
    }

    private static func get(url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw TrackAPIError.networkError
        }

        // Log the response JSON
        let jsonString = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.shared.logResponse(
            url: url.absoluteString,
            statusCode: http.statusCode,
            json: jsonString
        )

        guard (200...299).contains(http.statusCode) else {
            throw TrackAPIError.serverError(statusCode: http.statusCode)
        }
        return data
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
