//
//  Station.swift
//  Track
//
//  SwiftData model representing an NYC transit station.
//

import Foundation
import SwiftData

@Model
final class Station {
    var stationID: String
    var name: String
    var latitude: Double
    var longitude: Double
    var routeIDs: [String]

    init(stationID: String, name: String, latitude: Double, longitude: Double, routeIDs: [String] = []) {
        self.stationID = stationID
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.routeIDs = routeIDs
    }
}
