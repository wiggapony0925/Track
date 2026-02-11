//
//  TransitRepository.swift
//  Track
//
//  Handles fetching transit data. Abstracts GTFS-Realtime feed complexity
//  away from ViewModels. Uses async/await for network calls.
//

import Foundation

/// Represents a single upcoming train arrival at a station.
struct TrainArrival: Identifiable {
    let id = UUID()
    let routeID: String
    let stationID: String
    let direction: String
    let scheduledTime: Date
    let estimatedTime: Date
    let minutesAway: Int
}

/// Represents a transit alert or service change.
struct TransitAlert: Identifiable {
    let id = UUID()
    let routeID: String?
    let title: String
    let message: String
    let severity: AlertSeverity

    enum AlertSeverity: String {
        case info
        case warning
        case severe
    }
}

/// Error types for transit data fetching.
enum TransitError: Error, CustomStringConvertible {
    case networkUnavailable
    case feedParsingFailed
    case signalLost
    case unknown(Error)

    var description: String {
        switch self {
        case .networkUnavailable:
            return "No network connection available"
        case .feedParsingFailed:
            return "Unable to read transit data"
        case .signalLost:
            return "Signal Lost in Tunnel"
        case .unknown(let error):
            return error.localizedDescription
        }
    }
}

/// Repository for fetching NYC transit data from GTFS-Realtime feeds.
/// Currently provides stub data; integrate SwiftProtobuf for live MTA feeds.
final class TransitRepository {
    /// Fetches upcoming arrivals for a given station.
    ///
    /// - Parameter stationID: The station identifier
    /// - Returns: Array of upcoming TrainArrivals
    /// - Throws: TransitError on failure
    func fetchArrivals(for stationID: String) async throws -> [TrainArrival] {
        // Stub implementation — replace with actual GTFS-RT protobuf decoding
        let now = Date()
        return [
            TrainArrival(
                routeID: "L",
                stationID: stationID,
                direction: "Manhattan",
                scheduledTime: now.addingTimeInterval(300),
                estimatedTime: now.addingTimeInterval(360),
                minutesAway: 5
            ),
            TrainArrival(
                routeID: "L",
                stationID: stationID,
                direction: "Canarsie",
                scheduledTime: now.addingTimeInterval(600),
                estimatedTime: now.addingTimeInterval(660),
                minutesAway: 10
            ),
            TrainArrival(
                routeID: "G",
                stationID: stationID,
                direction: "Church Av",
                scheduledTime: now.addingTimeInterval(480),
                estimatedTime: now.addingTimeInterval(480),
                minutesAway: 8
            ),
        ]
    }

    /// Fetches active alerts for a given route.
    ///
    /// - Parameter routeID: The route identifier (optional, nil fetches all)
    /// - Returns: Array of TransitAlerts
    func fetchAlerts(for routeID: String? = nil) async throws -> [TransitAlert] {
        // Stub implementation
        return []
    }

    /// Fetches nearby stations based on coordinates.
    ///
    /// - Parameters:
    ///   - latitude: User's latitude
    ///   - longitude: User's longitude
    ///   - radius: Search radius in meters
    /// - Returns: Array of Station-like data with distance info
    func fetchNearbyStations(
        latitude: Double,
        longitude: Double,
        radius: Double = 500
    ) async throws -> [(stationID: String, name: String, distance: Double, routeIDs: [String])] {
        // Stub implementation with sample NYC stations
        return [
            (stationID: "L01", name: "1st Avenue", distance: 120, routeIDs: ["L"]),
            (stationID: "L03", name: "Bedford Avenue", distance: 250, routeIDs: ["L"]),
            (stationID: "G29", name: "Metropolitan Av", distance: 400, routeIDs: ["G"]),
        ]
    }
}
