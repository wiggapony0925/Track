//
//  SubwayRoutesData.swift
//  Track
//
//  Bundled offline subway route data for NYC.
//  This data is used when the app has no network connectivity
//  to still display subway routes on the map.
//
//  Data sources:
//  - Bundled subway_bundle.json (generated from MTA GTFS)
//  - Backend /static/bundle endpoint for updates
//

import Foundation
import CoreLocation
import SwiftUI

/// Static subway route data bundled with the app for offline use
struct SubwayRoutesData {
    
    // MARK: - Cached Bundle Data
    
    private static var cachedBundle: StaticBundle?
    
    /// Load the static bundle (from cache, then bundle, then API)
    static func loadBundle() -> StaticBundle {
        // Return cached if available
        if let cached = cachedBundle {
            return cached
        }
        
        // Try loading from UserDefaults (updated bundle)
        if let data = UserDefaults(suiteName: kAppGroupIdentifier)?.data(forKey: "subway_bundle"),
           let bundle = try? JSONDecoder().decode(StaticBundle.self, from: data) {
            cachedBundle = bundle
            return bundle
        }
        
        // Try loading from app bundle
        if let url = Bundle.main.url(forResource: "subway_bundle", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let bundle = try? JSONDecoder().decode(StaticBundle.self, from: data) {
            cachedBundle = bundle
            return bundle
        }
        
        // Return empty bundle as fallback
        return StaticBundle(version: "0", routes: .v2([:]), stops: [], colors: [:])
    }
    
    // MARK: - Route Colors (Official MTA Colors)
    
    /// Dynamic route colors from bundle
    static var routeColors: [String: Color] {
        let bundle = loadBundle()
        var colors: [String: Color] = [:]
        
        for (routeId, hexColor) in bundle.colors {
            colors[routeId] = Color(hex: hexColor)
        }
        
        // Merge with hardcoded fallbacks
        return colors.merging(hardcodedColors) { bundled, _ in bundled }
    }
    
    /// Hardcoded fallback colors
    private static let hardcodedColors: [String: Color] = [
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
    
    /// Get color for a route ID (supports LIRR_*, MNR_* prefixes)
    static func color(for routeId: String) -> Color {
        let upper = routeId.uppercased()
        
        // Check exact match first
        if let color = routeColors[upper] {
            return color
        }
        
        // Check LIRR prefix - use AppTheme for consistency
        if upper.hasPrefix("LIRR") {
            return AppTheme.CommuterRailColors.lirrBlue
        }
        
        // Check MNR prefix - use AppTheme for consistency
        if upper.hasPrefix("MNR") {
            return AppTheme.CommuterRailColors.mnrBlue
        }
        
        return .gray
    }
    
    // MARK: - Major Stations (From Bundle or Fallback)
    
    /// All stations from bundle or fallback to hardcoded
    static var allStations: [OfflineStation] {
        let bundle = loadBundle()
        
        // If bundle has stops, convert them
        if !bundle.stops.isEmpty {
            return bundle.stops.map { stop in
                OfflineStation(
                    id: stop.id,
                    name: stop.name,
                    lat: stop.lat,
                    lng: stop.lon,
                    routes: stop.routes ?? [],
                    borough: "",  // Not in bundle
                    isAccessible: false  // Not in bundle
                )
            }
        }
        
        // Fallback to hardcoded stations
        return majorStations
    }
    
    /// Key subway stations with coordinates for offline map display (hardcoded fallback)
    static let majorStations: [OfflineStation] = [
        // Manhattan - Midtown
        OfflineStation(id: "127", name: "Times Sq-42 St", lat: 40.7559, lng: -73.9871, routes: ["1","2","3","7","N","Q","R","W","S"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "631", name: "Grand Central-42 St", lat: 40.7527, lng: -73.9772, routes: ["4","5","6","7","S"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "A27", name: "42 St-Port Authority", lat: 40.7575, lng: -73.9898, routes: ["A","C","E"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "D17", name: "Herald Sq-34 St", lat: 40.7496, lng: -73.9879, routes: ["B","D","F","M","N","Q","R","W"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "128", name: "Penn Station-34 St", lat: 40.7506, lng: -73.9910, routes: ["1","2","3","A","C","E"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "R17", name: "Union Sq-14 St", lat: 40.7359, lng: -73.9906, routes: ["4","5","6","L","N","Q","R","W"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "A32", name: "14 St-8 Av", lat: 40.7401, lng: -73.9981, routes: ["A","C","E","L"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "R20", name: "Canal St", lat: 40.7193, lng: -74.0007, routes: ["A","C","E","N","Q","R","W","J","Z","6"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "R23", name: "City Hall", lat: 40.7127, lng: -74.0066, routes: ["R","W"], borough: "Manhattan", isAccessible: false),
        OfflineStation(id: "A36", name: "Chambers St", lat: 40.7141, lng: -74.0087, routes: ["A","C","1","2","3"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "R27", name: "Whitehall St", lat: 40.7031, lng: -74.0129, routes: ["R","W","1"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "A40", name: "Fulton St", lat: 40.7102, lng: -74.0079, routes: ["A","C","J","Z","2","3","4","5"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "635", name: "Wall St", lat: 40.7074, lng: -74.0118, routes: ["4","5"], borough: "Manhattan", isAccessible: false),
        
        // Manhattan - Uptown
        OfflineStation(id: "120", name: "72 St", lat: 40.7786, lng: -73.9819, routes: ["1","2","3"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "Q04", name: "72 St (2nd Ave)", lat: 40.7688, lng: -73.9584, routes: ["Q"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "A17", name: "81 St-Museum", lat: 40.7818, lng: -73.9728, routes: ["A","B","C"], borough: "Manhattan", isAccessible: false),
        OfflineStation(id: "Q03", name: "86 St (2nd Ave)", lat: 40.7776, lng: -73.9517, routes: ["Q"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "Q01", name: "96 St (2nd Ave)", lat: 40.7846, lng: -73.9474, routes: ["Q"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "116", name: "96 St", lat: 40.7937, lng: -73.9723, routes: ["1","2","3"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "112", name: "116 St-Columbia", lat: 40.8077, lng: -73.9642, routes: ["1"], borough: "Manhattan", isAccessible: false),
        OfflineStation(id: "A11", name: "125 St", lat: 40.8111, lng: -73.9522, routes: ["A","B","C","D"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "621", name: "125 St (Lex)", lat: 40.8044, lng: -73.9375, routes: ["4","5","6"], borough: "Manhattan", isAccessible: true),
        OfflineStation(id: "301", name: "Harlem-148 St", lat: 40.8241, lng: -73.9363, routes: ["3"], borough: "Manhattan", isAccessible: false),
        OfflineStation(id: "A02", name: "Inwood-207 St", lat: 40.8680, lng: -73.9199, routes: ["A"], borough: "Manhattan", isAccessible: true),
        
        // Brooklyn
        OfflineStation(id: "R30", name: "Jay St-MetroTech", lat: 40.6923, lng: -73.9872, routes: ["A","C","F","R"], borough: "Brooklyn", isAccessible: true),
        OfflineStation(id: "235", name: "Atlantic Av-Barclays", lat: 40.6843, lng: -73.9779, routes: ["2","3","4","5","B","D","N","Q","R"], borough: "Brooklyn", isAccessible: true),
        OfflineStation(id: "G29", name: "Bergen St", lat: 40.6862, lng: -73.9750, routes: ["F","G"], borough: "Brooklyn", isAccessible: false),
        OfflineStation(id: "D24", name: "Grand Army Plaza", lat: 40.6752, lng: -73.9711, routes: ["2","3"], borough: "Brooklyn", isAccessible: false),
        OfflineStation(id: "R36", name: "36 St", lat: 40.6551, lng: -74.0034, routes: ["D","N","R"], borough: "Brooklyn", isAccessible: false),
        OfflineStation(id: "F27", name: "Church Av", lat: 40.6449, lng: -73.9797, routes: ["B","Q"], borough: "Brooklyn", isAccessible: true),
        OfflineStation(id: "L17", name: "Bedford Av", lat: 40.7172, lng: -73.9567, routes: ["L"], borough: "Brooklyn", isAccessible: true),
        OfflineStation(id: "G22", name: "Greenpoint Av", lat: 40.7313, lng: -73.9546, routes: ["G"], borough: "Brooklyn", isAccessible: true),
        OfflineStation(id: "A51", name: "Euclid Av", lat: 40.6756, lng: -73.8720, routes: ["A","C"], borough: "Brooklyn", isAccessible: true),
        OfflineStation(id: "L29", name: "Canarsie-Rockaway", lat: 40.6469, lng: -73.9020, routes: ["L"], borough: "Brooklyn", isAccessible: true),
        OfflineStation(id: "D43", name: "Coney Island-Stillwell Av", lat: 40.5755, lng: -73.9814, routes: ["D","F","N","Q"], borough: "Brooklyn", isAccessible: true),
        OfflineStation(id: "A42", name: "Broadway Junction", lat: 40.6791, lng: -73.9048, routes: ["A","C","J","Z","L"], borough: "Brooklyn", isAccessible: false),
        OfflineStation(id: "239", name: "Franklin Av-Medgar Evers College", lat: 40.6671, lng: -73.9583, routes: ["2","3","4","5","S"], borough: "Brooklyn", isAccessible: true),
        
        // Queens
        OfflineStation(id: "G14", name: "Court Sq", lat: 40.7473, lng: -73.9456, routes: ["E","G","M","7"], borough: "Queens", isAccessible: true),
        OfflineStation(id: "G08", name: "Queens Plaza", lat: 40.7490, lng: -73.9373, routes: ["E","M","R"], borough: "Queens", isAccessible: true),
        OfflineStation(id: "F09", name: "Jackson Hts-Roosevelt Av", lat: 40.7547, lng: -73.8916, routes: ["E","F","M","R","7"], borough: "Queens", isAccessible: true),
        OfflineStation(id: "701", name: "Flushing-Main St", lat: 40.7596, lng: -73.8300, routes: ["7"], borough: "Queens", isAccessible: true),
        OfflineStation(id: "G06", name: "Forest Hills-71 Av", lat: 40.7216, lng: -73.8445, routes: ["E","F","M","R"], borough: "Queens", isAccessible: true),
        OfflineStation(id: "A65", name: "Jamaica-179 St", lat: 40.7126, lng: -73.7837, routes: ["F"], borough: "Queens", isAccessible: true),
        OfflineStation(id: "H11", name: "Howard Beach-JFK Airport", lat: 40.6602, lng: -73.8303, routes: ["A"], borough: "Queens", isAccessible: true),
        OfflineStation(id: "H01", name: "Far Rockaway-Mott Av", lat: 40.6003, lng: -73.7550, routes: ["A"], borough: "Queens", isAccessible: true),
        OfflineStation(id: "718", name: "Woodside-61 St", lat: 40.7456, lng: -73.9029, routes: ["7"], borough: "Queens", isAccessible: true),
        
        // Bronx
        OfflineStation(id: "601", name: "Pelham Bay Park", lat: 40.8522, lng: -73.8283, routes: ["6"], borough: "Bronx", isAccessible: true),
        OfflineStation(id: "401", name: "Woodlawn", lat: 40.8863, lng: -73.8788, routes: ["4"], borough: "Bronx", isAccessible: false),
        OfflineStation(id: "213", name: "E 180 St", lat: 40.8418, lng: -73.8737, routes: ["2","5"], borough: "Bronx", isAccessible: true),
        OfflineStation(id: "D01", name: "Norwood-205 St", lat: 40.8750, lng: -73.8904, routes: ["D"], borough: "Bronx", isAccessible: false),
        OfflineStation(id: "501", name: "Eastchester-Dyre Av", lat: 40.8887, lng: -73.8308, routes: ["5"], borough: "Bronx", isAccessible: false),
        OfflineStation(id: "201", name: "Wakefield-241 St", lat: 40.9033, lng: -73.8506, routes: ["2"], borough: "Bronx", isAccessible: false),
        OfflineStation(id: "D11", name: "161 St-Yankee Stadium", lat: 40.8279, lng: -73.9257, routes: ["4","B","D"], borough: "Bronx", isAccessible: true),
    ]
    
    // MARK: - Route Paths (From Bundle or GeoJSON)
    
    /// Cached route paths - now supports multiple branches per route
    private static var offlinePaths: [String: [[CLLocationCoordinate2D]]] = loadRoutePaths()
    
    /// Get ALL branch coordinates for a route line (for routes like A train with Lefferts/Far Rockaway branches)
    static func routeBranches(for routeId: String) -> [[CLLocationCoordinate2D]] {
        let key = routeId.uppercased()
        return offlinePaths[key] ?? []
    }
    
    /// Get the primary (longest) route path for a route - for backwards compatibility
    static func routePath(for routeId: String) -> [CLLocationCoordinate2D] {
        let key = routeId.uppercased()
        
        if let branches = offlinePaths[key], !branches.isEmpty {
            // Return the longest branch (typically the main line)
            return branches.max(by: { $0.count < $1.count }) ?? []
        }
        
        // Fallback for missing data
        switch key {
        case "1", "2", "3": return redLinePath
        case "4", "5", "6": return greenLinePath
        default: return []
        }
    }
    
    /// Load route paths from bundle (priority) or legacy GeoJSON
    private static func loadRoutePaths() -> [String: [[CLLocationCoordinate2D]]] {
        // First try the new bundle format
        let bundle = loadBundle()
        if !bundle.routes.isEmpty {
            var paths: [String: [[CLLocationCoordinate2D]]] = [:]
            
            for routeId in bundle.routes.routeIds {
                let branches = bundle.routes.branches(for: routeId)
                paths[routeId.uppercased()] = branches.map { branch in
                    branch.map { coord in
                        CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lon)
                    }
                }
            }
            return paths
        }
        
        // Fallback to legacy GeoJSON file (single polyline per route)
        let legacyPaths = loadGeoJSONPaths()
        var converted: [String: [[CLLocationCoordinate2D]]] = [:]
        for (routeId, coords) in legacyPaths {
            converted[routeId] = [coords]  // Wrap in array for branch compatibility
        }
        return converted
    }
    
    /// Legacy: Load from GeoJSON file
    private static func loadGeoJSONPaths() -> [String: [CLLocationCoordinate2D]] {
        guard let url = Bundle.main.url(forResource: "subway_routes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return [:]
        }
        
        do {
            let collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
            var paths: [String: [CLLocationCoordinate2D]] = [:]
            
            for feature in collection.features {
                if let routeId = feature.properties["route_id"] {
                    let coordinates = feature.geometry.coordinates.map { 
                        CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) 
                    }
                    paths[routeId.uppercased()] = coordinates
                }
            }
            return paths
        } catch {
            #if DEBUG
            print("[SubwayRoutesData] Error decoding GeoJSON: \(error)")
            #endif
            return [:]
        }
    }
    
    // Simplified route paths (key waypoints only) - used as fallbacks
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
        CLLocationCoordinate2D(latitude: 40.8418, longitude: -73.8737),  // E 180 St
        CLLocationCoordinate2D(latitude: 40.8044, longitude: -73.9375),  // 125 St
        CLLocationCoordinate2D(latitude: 40.7527, longitude: -73.9772),  // Grand Central
        CLLocationCoordinate2D(latitude: 40.7359, longitude: -73.9906),  // Union Sq
        CLLocationCoordinate2D(latitude: 40.7127, longitude: -74.0066),  // City Hall
        CLLocationCoordinate2D(latitude: 40.6843, longitude: -73.9779),  // Atlantic
    ]
    
    // MARK: - All Route IDs
    
    static let allRouteIds: [String] = [
        "1", "2", "3",
        "4", "5", "6", "6X",
        "7", "7X",
        "A", "C", "E",
        "B", "D", "F", "FX", "M",
        "N", "Q", "R", "W",
        "G",
        "J", "Z",
        "L",
        "S", "SI"
    ]
}
struct OfflineStation: Identifiable, Codable {
    let id: String
    let name: String
    let lat: Double
    let lng: Double
    let routes: [String]
    let borough: String
    let isAccessible: Bool
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

// MARK: - GeoJSON Models

struct GeoJSONFeatureCollection: Codable {
    let features: [GeoJSONFeature]
}

struct GeoJSONFeature: Codable {
    let properties: [String: String]
    let geometry: GeoJSONGeometry
}

struct GeoJSONGeometry: Codable {
    let type: String
    let coordinates: [[Double]]
}

// MARK: - Static Bundle Models (From Backend API)

/// Static data bundle from backend /static/bundle endpoint
/// Version 2.x: routes is a dict mapping route_id to list of branches (each branch is a list of coordinates)
/// Version 1.x: routes is a dict mapping route_id to a single list of coordinates
struct StaticBundle: Codable {
    let version: String
    let routes: RouteData
    let stops: [BundleStop]
    let colors: [String: String]
    
    /// Supports both v1 (single polyline) and v2 (multi-branch) formats
    enum RouteData: Codable {
        case v1([String: [BundleCoordinate]])          // Single polyline per route
        case v2([String: [[BundleCoordinate]]])        // Multiple branches per route
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            
            // Try v2 format first (multi-branch)
            if let v2 = try? container.decode([String: [[BundleCoordinate]]].self) {
                self = .v2(v2)
                return
            }
            
            // Fall back to v1 format (single polyline)
            if let v1 = try? container.decode([String: [BundleCoordinate]].self) {
                self = .v1(v1)
                return
            }
            
            // Empty fallback
            self = .v2([:])
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .v1(let data):
                try container.encode(data)
            case .v2(let data):
                try container.encode(data)
            }
        }
        
        /// Check if empty
        var isEmpty: Bool {
            switch self {
            case .v1(let data): return data.isEmpty
            case .v2(let data): return data.isEmpty
            }
        }
        
        /// Get all route IDs
        var routeIds: [String] {
            switch self {
            case .v1(let data): return Array(data.keys)
            case .v2(let data): return Array(data.keys)
            }
        }
        
        /// Get count
        var count: Int {
            switch self {
            case .v1(let data): return data.count
            case .v2(let data): return data.count
            }
        }
        
        /// Get all branches for a route (returns single-element array for v1)
        func branches(for routeId: String) -> [[BundleCoordinate]] {
            switch self {
            case .v1(let data):
                if let coords = data[routeId] {
                    return [coords]
                }
                return []
            case .v2(let data):
                return data[routeId] ?? []
            }
        }
    }
}

/// Coordinate in bundle format
struct BundleCoordinate: Codable {
    let lat: Double
    let lon: Double
}

/// Stop in bundle format
struct BundleStop: Codable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let routes: [String]?  // Optional, may not be in all bundles
}
