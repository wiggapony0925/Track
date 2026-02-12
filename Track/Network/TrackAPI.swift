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
    static var baseURL: String {
        let settings = AppSettings.shared
        let useLocalhost = UserDefaults.standard.bool(forKey: "dev_use_localhost")
        if useLocalhost {
            return settings.localBaseURL
        } else {
            let storedIP = UserDefaults.standard.string(forKey: "dev_custom_ip") ?? settings.defaultDeviceIP
            return "http://\(storedIP):\(settings.localPort)"
        }
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
        let effectiveRadius = radius ?? AppSettings.shared.defaultSearchRadiusMeters
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
        let effectiveRadius = radius ?? AppSettings.shared.defaultSearchRadiusMeters
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
    /// - Returns: Array of `GroupedNearbyTransitResponse`.
    static func fetchNearbyGrouped(lat: Double, lon: Double, radius: Int? = nil) async throws -> [GroupedNearbyTransitResponse] {
        let effectiveRadius = radius ?? AppSettings.shared.defaultSearchRadiusMeters
        guard var components = URLComponents(string: baseURL + "/nearby/grouped") else {
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

    /// Fetches polylines + colors for ALL subway lines (the full system map).
    ///
    /// Called once on app launch to draw every line on the map.
    /// - Returns: An `AllSubwayLinesResponse` with lightweight overlay data per line.
    static func fetchAllSubwayShapes() async throws -> AllSubwayLinesResponse {
        let data = try await get(path: "/subway/shapes/all")
        return try decoder.decode(AllSubwayLinesResponse.self, from: data)
    }

    /// Fetches all subway stations for map markers.
    /// - Returns: An `AllSubwayStationsResponse` with all stations and their routes.
    static func fetchAllSubwayStations() async throws -> AllSubwayStationsResponse {
        let data = try await get(path: "/subway/stations/all")
        return try decoder.decode(AllSubwayStationsResponse.self, from: data)
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

    // MARK: - LIRR

    /// Fetches upcoming LIRR arrivals from the GTFS-Realtime feed.
    ///
    /// - Returns: Array of decoded `TrainArrival` objects.
    static func fetchLIRRArrivals() async throws -> [TrainArrival] {
        let data = try await get(path: "/lirr")
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

/// Matches the backend's `TrackArrival` JSON schema (snake_case).
private struct SubwayArrivalResponse: Codable {
    let station: String
    let direction: String
    let minutesAway: Int
    let status: String

    enum CodingKeys: String, CodingKey {
        case station
        case direction
        case minutesAway = "minutes_away"
        case status
    }

    func toTrainArrival() -> TrainArrival {
        let now = Date()
        return TrainArrival(
            routeID: station,
            stationID: station,
            direction: direction,
            scheduledTime: now.addingTimeInterval(Double(minutesAway) * 60),
            estimatedTime: now.addingTimeInterval(Double(minutesAway) * 60),
            minutesAway: minutesAway
        )
    }
}

/// Matches the backend's `NearbyTransitArrival` JSON schema.
struct NearbyTransitResponse: Codable, Identifiable {
    var id: String { "\(routeId)-\(stopName)-\(minutesAway)" }

    let routeId: String
    let stopName: String
    let direction: String
    let destination: String?
    let minutesAway: Int
    let status: String
    let mode: String
    let stopLat: Double?
    let stopLon: Double?

    var isBus: Bool { mode == "bus" }

    /// Strips "MTA NYCT_" prefix for display.
    var displayName: String {
        stripMTAPrefix(routeId)
    }

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case stopName = "stop_name"
        case direction
        case destination
        case minutesAway = "minutes_away"
        case status
        case mode
        case stopLat = "stop_lat"
        case stopLon = "stop_lon"
    }
}

/// Arrivals for a single direction within a grouped route.
struct DirectionArrivalsResponse: Codable, Identifiable {
    var id: String { direction }

    let direction: String
    let arrivals: [NearbyTransitResponse]
}

/// Matches the backend's `GroupedNearbyTransit` JSON schema.
/// One entry per route; directions are swipeable sub-groups.
struct GroupedNearbyTransitResponse: Codable, Identifiable {
    var id: String { routeId }

    let routeId: String
    let displayName: String
    let mode: String
    let colorHex: String?
    let directions: [DirectionArrivalsResponse]

    var isBus: Bool { mode == "bus" }

    /// The soonest arrival across all directions.
    var soonestMinutes: Int {
        directions.flatMap(\.arrivals).map(\.minutesAway).min() ?? 99
    }

    /// The name of the direction (destination) for the soonest arrival.
    var soonestDirectionName: String? {
        let all = directions.flatMap { dir in 
            dir.arrivals.map { (dir.direction, $0.minutesAway) }
        }
        return all.min(by: { $0.1 < $1.1 })?.0
    }

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case displayName = "display_name"
        case mode
        case colorHex = "color_hex"
        case directions
    }
}

/// Matches the backend's `BusVehicle` JSON schema.
struct BusVehicleResponse: Codable, Identifiable {
    var id: String { vehicleId }

    let vehicleId: String
    let routeId: String
    let lat: Double
    let lon: Double
    let bearing: Double?
    let nextStop: String?
    let statusText: String?

    /// Strips "MTA NYCT_" prefix for display.
    var displayRouteName: String {
        stripMTAPrefix(routeId)
    }

    enum CodingKeys: String, CodingKey {
        case vehicleId = "vehicle_id"
        case routeId = "route_id"
        case lat, lon, bearing
        case nextStop = "next_stop"
        case statusText = "status_text"
    }
}

/// Lightweight overlay for drawing a single subway line on the full map.
struct SubwayLineOverlay: Codable, Identifiable {
    var id: String { routeId }
    let routeId: String
    let colorHex: String
    let polylines: [String]

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case colorHex = "color_hex"
        case polylines
    }

    /// Decodes polylines on demand.
    var decodedPolylines: [[CLLocationCoordinate2D]] {
        polylines.map { decodePolyline($0) }
    }
}

/// Response containing all subway lines for the system map.
struct AllSubwayLinesResponse: Codable {
    let lines: [SubwayLineOverlay]
}

struct SubwayStation: Codable, Identifiable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let routes: [String]
}

struct AllSubwayStationsResponse: Codable {
    let stations: [SubwayStation]
}

/// Matches the backend's `RouteShape` JSON schema.
struct RouteShapeResponse: Codable {
    let routeId: String
    let polylines: [String]
    let stops: [BusStop]

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case polylines, stops
    }

    /// Decodes all Google-encoded polylines into coordinate arrays.
    var decodedPolylines: [[CLLocationCoordinate2D]] {
        polylines.map { decodePolyline($0) }
    }
}
