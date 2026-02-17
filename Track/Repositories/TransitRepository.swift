//
//  TransitRepository.swift
//  Track
//
//  Handles fetching transit data from the TrackAPI backend.
//  Bridges the API layer to the ViewModel layer.
//

import Foundation
import CoreLocation

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

    /// Fetches nearby stations using server-side proximity filtering.
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
        let effectiveRadius = radius ?? Double(AppSettings.shared.effectiveAPISearchRadius)
        
        AppLogger.shared.log("TRANSIT", message: "Fetching nearby stations for (\(latitude), \(longitude))")

        do {
            // Use server-side proximity filtering instead of downloading all stations
            let response = try await TrackAPI.fetchNearbySubwayStations(
                lat: latitude,
                lon: longitude,
                radius: Int(effectiveRadius)
            )
            let userLoc = CLLocation(latitude: latitude, longitude: longitude)
            
            let nearby = response.stations.map { station -> (stationID: String, name: String, distance: Double, routeIDs: [String]) in
                let stopLoc = CLLocation(latitude: station.lat, longitude: station.lon)
                let distance = userLoc.distance(from: stopLoc)
                return (stationID: station.id, name: station.name, distance: distance, routeIDs: station.routes)
            }.sorted { $0.distance < $1.distance }
            
            return nearby
        } catch {
            AppLogger.shared.logError("fetchNearbyStations", error: error)
            return []
        }
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
