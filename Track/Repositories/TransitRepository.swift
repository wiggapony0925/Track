//
//  TransitRepository.swift
//  Track
//
//  Handles fetching transit data from the TrackAPI backend.
//  Bridges the API layer to the ViewModel layer.
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

/// Repository for fetching NYC transit data via the TrackAPI backend.
final class TransitRepository {

    /// Fetches upcoming arrivals for a given line from the backend.
    ///
    /// - Parameter stationID: The station/line identifier (e.g. "L", "A")
    /// - Returns: Array of upcoming TrainArrivals from the live API
    /// - Throws: TransitError on failure
    func fetchArrivals(for stationID: String) async throws -> [TrainArrival] {
        // Extract the line letter from the station ID (e.g. "L01" → "L")
        let lineID = extractLineID(from: stationID)

        AppLogger.shared.log("TRANSIT", message: "Fetching arrivals for line \(lineID) (station: \(stationID))")

        do {
            let arrivals = try await TrackAPI.fetchSubwayArrivals(lineID: lineID)
            AppLogger.shared.log("TRANSIT", message: "Got \(arrivals.count) arrivals for line \(lineID)")
            return arrivals
        } catch {
            AppLogger.shared.logError("fetchArrivals(\(lineID))", error: error)
            throw TransitError.unknown(error)
        }
    }

    /// Fetches nearby stations from the local CSV data.
    ///
    /// - Parameters:
    ///   - latitude: User's latitude
    ///   - longitude: User's longitude
    ///   - radius: Search radius in meters
    /// - Returns: Array of Station-like data with distance info
    func fetchNearbyStations(
        latitude: Double,
        longitude: Double,
        radius: Double? = nil
    ) async throws -> [(stationID: String, name: String, distance: Double, routeIDs: [String])] {
        if let radius = radius {
            _ = radius // kept if needed for logic later, or just verify not nil
        } else {
            // Access MainActor-isolated AppSettings safely
            _ = await MainActor.run { Double(AppSettings.shared.defaultSearchRadiusMeters) }
        }
        // Station data loaded from local storage
        // TODO: Load from CSV or backend endpoint when available
        AppLogger.shared.log("TRANSIT", message: "Fetching nearby stations for (\(latitude), \(longitude))")

        // Return common NYC stations as defaults until station API is implemented
        return [
            (stationID: "L01", name: "1st Avenue", distance: 120, routeIDs: ["L"]),
            (stationID: "L03", name: "Bedford Avenue", distance: 250, routeIDs: ["L"]),
            (stationID: "G29", name: "Metropolitan Av", distance: 400, routeIDs: ["G"]),
        ]
    }

    /// Extracts a line ID from a station ID.
    /// "L01" → "L", "G29" → "G", "ACE05" → "A"
    private func extractLineID(from stationID: String) -> String {
        // If it looks like just a letter or short route, return as-is
        if stationID.count <= 2 {
            return stationID
        }
        // Take the leading letter(s) before digits
        let letters = stationID.prefix(while: { $0.isLetter })
        return letters.isEmpty ? stationID : String(letters.first!)
    }
}
