//
//  SubwayRoutesData.swift
//  Track
//
//  Bundled offline subway route data for NYC.
//  This data is used when the app has no network connectivity
//  to still display subway routes on the map.
//

import Foundation
import CoreLocation
import SwiftUI

/// Static subway route data bundled with the app for offline use
struct SubwayRoutesData {
    
    // MARK: - Route Colors (Official MTA Colors)
    
    static let routeColors: [String: Color] = [
        // IRT Lines
        "1": Color(hex: "EE352E"),  // Red
        "2": Color(hex: "EE352E"),
        "3": Color(hex: "EE352E"),
        "4": Color(hex: "00933C"),  // Green
        "5": Color(hex: "00933C"),
        "6": Color(hex: "00933C"),
        "6X": Color(hex: "00933C"),
        "7": Color(hex: "B933AD"),  // Purple
        "7X": Color(hex: "B933AD"),
        
        // IND Lines
        "A": Color(hex: "0039A6"),  // Blue
        "C": Color(hex: "0039A6"),
        "E": Color(hex: "0039A6"),
        "B": Color(hex: "FF6319"),  // Orange
        "D": Color(hex: "FF6319"),
        "F": Color(hex: "FF6319"),
        "FX": Color(hex: "FF6319"),
        "M": Color(hex: "FF6319"),
        "G": Color(hex: "6CBE45"),  // Lime Green
        
        // BMT Lines
        "J": Color(hex: "996633"),  // Brown
        "Z": Color(hex: "996633"),
        "L": Color(hex: "A7A9AC"),  // Gray
        "N": Color(hex: "FCCC0A"),  // Yellow
        "Q": Color(hex: "FCCC0A"),
        "R": Color(hex: "FCCC0A"),
        "W": Color(hex: "FCCC0A"),
        
        // Shuttles
        "S": Color(hex: "808183"),  // Shuttle Gray
        "SI": Color(hex: "0039A6"), // Staten Island Railway
    ]
    
    /// Get color for a route ID
    static func color(for routeId: String) -> Color {
        routeColors[routeId.uppercased()] ?? .gray
    }
    
    // MARK: - Major Stations (Simplified for Offline)
    
    /// Key subway stations with coordinates for offline map display
    static let majorStations: [OfflineStation] = [
        // Manhattan - Midtown
        OfflineStation(id: "127", name: "Times Sq-42 St", lat: 40.7559, lng: -73.9871, routes: ["1","2","3","7","N","Q","R","W","S"]),
        OfflineStation(id: "631", name: "Grand Central-42 St", lat: 40.7527, lng: -73.9772, routes: ["4","5","6","7","S"]),
        OfflineStation(id: "A27", name: "42 St-Port Authority", lat: 40.7575, lng: -73.9898, routes: ["A","C","E"]),
        OfflineStation(id: "D17", name: "Herald Sq-34 St", lat: 40.7496, lng: -73.9879, routes: ["B","D","F","M","N","Q","R","W"]),
        OfflineStation(id: "128", name: "Penn Station-34 St", lat: 40.7506, lng: -73.9910, routes: ["1","2","3","A","C","E"]),
        OfflineStation(id: "R17", name: "Union Sq-14 St", lat: 40.7359, lng: -73.9906, routes: ["4","5","6","L","N","Q","R","W"]),
        OfflineStation(id: "A32", name: "14 St-8 Av", lat: 40.7401, lng: -73.9981, routes: ["A","C","E","L"]),
        OfflineStation(id: "R20", name: "Canal St", lat: 40.7193, lng: -74.0007, routes: ["A","C","E","N","Q","R","W","J","Z","6"]),
        OfflineStation(id: "R23", name: "City Hall", lat: 40.7127, lng: -74.0066, routes: ["R","W"]),
        OfflineStation(id: "A36", name: "Chambers St", lat: 40.7141, lng: -74.0087, routes: ["A","C","1","2","3"]),
        OfflineStation(id: "R27", name: "Whitehall St", lat: 40.7031, lng: -74.0129, routes: ["R","W","1"]),
        OfflineStation(id: "A40", name: "Fulton St", lat: 40.7102, lng: -74.0079, routes: ["A","C","J","Z","2","3","4","5"]),
        OfflineStation(id: "635", name: "Wall St", lat: 40.7074, lng: -74.0118, routes: ["4","5"]),
        
        // Manhattan - Uptown
        OfflineStation(id: "120", name: "72 St", lat: 40.7786, lng: -73.9819, routes: ["1","2","3"]),
        OfflineStation(id: "Q04", name: "72 St (2nd Ave)", lat: 40.7688, lng: -73.9584, routes: ["Q"]),
        OfflineStation(id: "A17", name: "81 St-Museum", lat: 40.7818, lng: -73.9728, routes: ["A","B","C"]),
        OfflineStation(id: "Q03", name: "86 St (2nd Ave)", lat: 40.7776, lng: -73.9517, routes: ["Q"]),
        OfflineStation(id: "Q01", name: "96 St (2nd Ave)", lat: 40.7846, lng: -73.9474, routes: ["Q"]),
        OfflineStation(id: "116", name: "96 St", lat: 40.7937, lng: -73.9723, routes: ["1","2","3"]),
        OfflineStation(id: "112", name: "116 St-Columbia", lat: 40.8077, lng: -73.9642, routes: ["1"]),
        OfflineStation(id: "A11", name: "125 St", lat: 40.8111, lng: -73.9522, routes: ["A","B","C","D"]),
        OfflineStation(id: "621", name: "125 St (Lex)", lat: 40.8044, lng: -73.9375, routes: ["4","5","6"]),
        OfflineStation(id: "301", name: "Harlem-148 St", lat: 40.8241, lng: -73.9363, routes: ["3"]),
        OfflineStation(id: "A02", name: "Inwood-207 St", lat: 40.8680, lng: -73.9199, routes: ["A"]),
        
        // Brooklyn
        OfflineStation(id: "R30", name: "Jay St-MetroTech", lat: 40.6923, lng: -73.9872, routes: ["A","C","F","R"]),
        OfflineStation(id: "235", name: "Atlantic Av-Barclays", lat: 40.6843, lng: -73.9779, routes: ["2","3","4","5","B","D","N","Q","R"]),
        OfflineStation(id: "G29", name: "Bergen St", lat: 40.6862, lng: -73.9750, routes: ["F","G"]),
        OfflineStation(id: "D24", name: "Grand Army Plaza", lat: 40.6752, lng: -73.9711, routes: ["2","3"]),
        OfflineStation(id: "R36", name: "36 St", lat: 40.6551, lng: -74.0034, routes: ["D","N","R"]),
        OfflineStation(id: "F27", name: "Church Av", lat: 40.6449, lng: -73.9797, routes: ["B","Q"]),
        OfflineStation(id: "L17", name: "Bedford Av", lat: 40.7172, lng: -73.9567, routes: ["L"]),
        OfflineStation(id: "G22", name: "Greenpoint Av", lat: 40.7313, lng: -73.9546, routes: ["G"]),
        OfflineStation(id: "A51", name: "Euclid Av", lat: 40.6756, lng: -73.8720, routes: ["A","C"]),
        OfflineStation(id: "L29", name: "Canarsie-Rockaway", lat: 40.6469, lng: -73.9020, routes: ["L"]),
        OfflineStation(id: "D43", name: "Coney Island", lat: 40.5755, lng: -73.9814, routes: ["D","F","N","Q"]),
        
        // Queens
        OfflineStation(id: "G14", name: "Court Sq", lat: 40.7473, lng: -73.9456, routes: ["E","G","M","7"]),
        OfflineStation(id: "G08", name: "Queens Plaza", lat: 40.7490, lng: -73.9373, routes: ["E","M","R"]),
        OfflineStation(id: "F09", name: "Jackson Hts", lat: 40.7547, lng: -73.8916, routes: ["E","F","M","R","7"]),
        OfflineStation(id: "701", name: "Flushing-Main St", lat: 40.7596, lng: -73.8300, routes: ["7"]),
        OfflineStation(id: "G06", name: "Forest Hills-71 Av", lat: 40.7216, lng: -73.8445, routes: ["E","F","M","R"]),
        OfflineStation(id: "A65", name: "Jamaica-179 St", lat: 40.7126, lng: -73.7837, routes: ["F"]),
        OfflineStation(id: "H11", name: "JFK Airport", lat: 40.6602, lng: -73.8303, routes: ["A"]),
        OfflineStation(id: "H01", name: "Far Rockaway", lat: 40.6003, lng: -73.7550, routes: ["A"]),
        
        // Bronx
        OfflineStation(id: "601", name: "Pelham Bay Park", lat: 40.8522, lng: -73.8283, routes: ["6"]),
        OfflineStation(id: "401", name: "Woodlawn", lat: 40.8863, lng: -73.8788, routes: ["4"]),
        OfflineStation(id: "213", name: "E 180 St", lat: 40.8418, lng: -73.8737, routes: ["2","5"]),
        OfflineStation(id: "D01", name: "Norwood-205 St", lat: 40.8750, lng: -73.8904, routes: ["D"]),
        OfflineStation(id: "501", name: "Eastchester-Dyre", lat: 40.8887, lng: -73.8308, routes: ["5"]),
        OfflineStation(id: "201", name: "Wakefield-241 St", lat: 40.9033, lng: -73.8506, routes: ["2"]),
    ]
    
    // MARK: - Route Paths (Simplified)
    
    /// Get coordinates for a route line (simplified for offline display)
    static func routePath(for routeId: String) -> [CLLocationCoordinate2D] {
        switch routeId {
        case "1", "2", "3":
            return redLinePath
        case "4", "5", "6":
            return greenLinePath
        case "7":
            return purpleLinePath
        case "A", "C", "E":
            return blueLinePath
        case "B", "D", "F", "M":
            return orangeLinePath
        case "N", "Q", "R", "W":
            return yellowLinePath
        case "L":
            return grayLinePath
        case "G":
            return limeLinePath
        case "J", "Z":
            return brownLinePath
        default:
            return []
        }
    }
    
    // Simplified route paths (key waypoints only)
    private static let redLinePath: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.9033, longitude: -73.8506),  // 241 St
        CLLocationCoordinate2D(latitude: 40.8241, longitude: -73.9363),  // 148 St
        CLLocationCoordinate2D(latitude: 40.8077, longitude: -73.9642),  // 116 St
        CLLocationCoordinate2D(latitude: 40.7937, longitude: -73.9723),  // 96 St
        CLLocationCoordinate2D(latitude: 40.7786, longitude: -73.9819),  // 72 St
        CLLocationCoordinate2D(latitude: 40.7559, longitude: -73.9871),  // Times Sq
        CLLocationCoordinate2D(latitude: 40.7506, longitude: -73.9910),  // 34 St
        CLLocationCoordinate2D(latitude: 40.7141, longitude: -74.0087),  // Chambers
        CLLocationCoordinate2D(latitude: 40.7031, longitude: -74.0129),  // South Ferry
    ]
    
    private static let greenLinePath: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.8863, longitude: -73.8788),  // Woodlawn
        CLLocationCoordinate2D(latitude: 40.8418, longitude: -73.8737),  // 180 St
        CLLocationCoordinate2D(latitude: 40.8044, longitude: -73.9375),  // 125 St
        CLLocationCoordinate2D(latitude: 40.7527, longitude: -73.9772),  // Grand Central
        CLLocationCoordinate2D(latitude: 40.7359, longitude: -73.9906),  // Union Sq
        CLLocationCoordinate2D(latitude: 40.7127, longitude: -74.0066),  // City Hall
        CLLocationCoordinate2D(latitude: 40.6843, longitude: -73.9779),  // Atlantic
        CLLocationCoordinate2D(latitude: 40.5755, longitude: -73.9814),  // Coney Island
    ]
    
    private static let purpleLinePath: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7596, longitude: -73.8300),  // Flushing
        CLLocationCoordinate2D(latitude: 40.7547, longitude: -73.8916),  // Jackson Hts
        CLLocationCoordinate2D(latitude: 40.7473, longitude: -73.9456),  // Court Sq
        CLLocationCoordinate2D(latitude: 40.7559, longitude: -73.9871),  // Times Sq
        CLLocationCoordinate2D(latitude: 40.7428, longitude: -74.0061),  // Hudson Yards
    ]
    
    private static let blueLinePath: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.8680, longitude: -73.9199),  // Inwood
        CLLocationCoordinate2D(latitude: 40.8111, longitude: -73.9522),  // 125 St
        CLLocationCoordinate2D(latitude: 40.7818, longitude: -73.9728),  // 81 St
        CLLocationCoordinate2D(latitude: 40.7575, longitude: -73.9898),  // Port Authority
        CLLocationCoordinate2D(latitude: 40.7401, longitude: -73.9981),  // 14 St
        CLLocationCoordinate2D(latitude: 40.7193, longitude: -74.0007),  // Canal
        CLLocationCoordinate2D(latitude: 40.7102, longitude: -74.0079),  // Fulton
        CLLocationCoordinate2D(latitude: 40.6923, longitude: -73.9872),  // Jay St
        CLLocationCoordinate2D(latitude: 40.6756, longitude: -73.8720),  // Euclid
        CLLocationCoordinate2D(latitude: 40.6003, longitude: -73.7550),  // Far Rockaway
    ]
    
    private static let orangeLinePath: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.8750, longitude: -73.8904),  // Norwood
        CLLocationCoordinate2D(latitude: 40.8111, longitude: -73.9522),  // 125 St
        CLLocationCoordinate2D(latitude: 40.7818, longitude: -73.9728),  // 81 St
        CLLocationCoordinate2D(latitude: 40.7496, longitude: -73.9879),  // Herald Sq
        CLLocationCoordinate2D(latitude: 40.7359, longitude: -73.9906),  // Union Sq
        CLLocationCoordinate2D(latitude: 40.7193, longitude: -74.0007),  // Canal
        CLLocationCoordinate2D(latitude: 40.6923, longitude: -73.9872),  // Jay St
        CLLocationCoordinate2D(latitude: 40.6449, longitude: -73.9797),  // Church Av
        CLLocationCoordinate2D(latitude: 40.5755, longitude: -73.9814),  // Coney Island
    ]
    
    private static let yellowLinePath: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7846, longitude: -73.9474),  // 96 St (Q)
        CLLocationCoordinate2D(latitude: 40.7688, longitude: -73.9584),  // 72 St (Q)
        CLLocationCoordinate2D(latitude: 40.7559, longitude: -73.9871),  // Times Sq
        CLLocationCoordinate2D(latitude: 40.7496, longitude: -73.9879),  // Herald Sq
        CLLocationCoordinate2D(latitude: 40.7359, longitude: -73.9906),  // Union Sq
        CLLocationCoordinate2D(latitude: 40.7193, longitude: -74.0007),  // Canal
        CLLocationCoordinate2D(latitude: 40.6923, longitude: -73.9872),  // Jay St
        CLLocationCoordinate2D(latitude: 40.6843, longitude: -73.9779),  // Atlantic
        CLLocationCoordinate2D(latitude: 40.5755, longitude: -73.9814),  // Coney Island
    ]
    
    private static let grayLinePath: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7401, longitude: -73.9981),  // 14 St
        CLLocationCoordinate2D(latitude: 40.7359, longitude: -73.9906),  // Union Sq
        CLLocationCoordinate2D(latitude: 40.7172, longitude: -73.9567),  // Bedford Av
        CLLocationCoordinate2D(latitude: 40.6469, longitude: -73.9020),  // Canarsie
    ]
    
    private static let limeLinePath: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7473, longitude: -73.9456),  // Court Sq
        CLLocationCoordinate2D(latitude: 40.7313, longitude: -73.9546),  // Greenpoint
        CLLocationCoordinate2D(latitude: 40.6862, longitude: -73.9750),  // Bergen St
        CLLocationCoordinate2D(latitude: 40.6449, longitude: -73.9797),  // Church Av
    ]
    
    private static let brownLinePath: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7193, longitude: -74.0007),  // Canal
        CLLocationCoordinate2D(latitude: 40.7102, longitude: -74.0079),  // Fulton
        CLLocationCoordinate2D(latitude: 40.6923, longitude: -73.9872),  // Jay St
        CLLocationCoordinate2D(latitude: 40.6831, longitude: -73.9035),  // Broadway Jct
        CLLocationCoordinate2D(latitude: 40.7126, longitude: -73.7837),  // Jamaica
    ]
    
    // MARK: - All Route IDs
    
    static let allRouteIds: [String] = [
        "1", "2", "3",
        "4", "5", "6",
        "7",
        "A", "C", "E",
        "B", "D", "F", "M",
        "N", "Q", "R", "W",
        "G",
        "J", "Z",
        "L",
        "S"
    ]
}

// MARK: - Offline Station Model

struct OfflineStation: Identifiable, Codable {
    let id: String
    let name: String
    let lat: Double
    let lng: Double
    let routes: [String]
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

// MARK: - Color Extension for Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
