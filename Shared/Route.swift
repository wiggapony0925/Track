//
//  Route.swift
//  Shared
//
//  SwiftData model representing a transit route (e.g., "L", "4", "A").
//

import Foundation
import SwiftData

@Model
final class Route {
    var routeID: String
    var name: String
    var colorHex: String

    init(routeID: String, name: String, colorHex: String = "#0039A6") {
        self.routeID = routeID
        self.name = name
        self.colorHex = colorHex
    }
}
