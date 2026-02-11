//
//  TrackAPI.swift
//  Track
//
//  Unified network client that communicates with the TrackBackend proxy API.
//  All MTA data flows through the backend — the iOS app never calls MTA directly.
//

import Foundation

/// Centralized API client for the Track backend.
struct TrackAPI {

    /// Base URL for the backend API. Change this when deploying to a real server.
    static var baseURL = "http://127.0.0.1:8000"

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
    static func fetchNearbyBusStops(lat: Double, lon: Double) async throws -> [BusStop] {
        let data = try await get(path: "/bus/nearby?lat=\(lat)&lon=\(lon)")
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
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw TrackAPIError.networkError
        }
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
