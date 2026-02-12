//
//  AppSettings.swift
//  Track
//
//  Loads settings.json from the app bundle and exposes typed,
//  centralized configuration values. Change a single value in
//  settings.json to adjust behavior across the entire app —
//  search radius, refresh interval, map bounds, etc.
//

import Foundation

struct AppSettings {
    static let shared = AppSettings()

    // MARK: - API Settings

    let defaultSearchRadiusMeters: Int
    let nearestMetroFallbackRadiusMeters: Int
    let refreshIntervalSeconds: Int
    let prodBaseURL: String
    let localBaseURL: String
    let defaultDeviceIP: String
    let localPort: Int

    // MARK: - Location Settings

    let distanceFilterMeters: Double
    let commutePatternMatchRadiusMeters: Double
    let stopPassedThresholdMeters: Double

    // MARK: - Map Settings

    let userZoomDistance: Double
    let minCameraDistance: Double
    let maxCameraDistance: Double
    let nycCenterLat: Double
    let nycCenterLon: Double
    let boundsCenterLat: Double
    let boundsCenterLon: Double
    let boundsLatDelta: Double
    let boundsLonDelta: Double
    let serviceAreaMinLat: Double
    let serviceAreaMaxLat: Double
    let serviceAreaMinLon: Double
    let serviceAreaMaxLon: Double

    // MARK: - Init

    private init() {
        guard let url = Bundle.main.url(forResource: "settings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fall back to hardcoded defaults if settings.json is missing
            print("[AppSettings] WARNING: settings.json not found in bundle — using hardcoded defaults")
            self.defaultSearchRadiusMeters = 500
            self.nearestMetroFallbackRadiusMeters = 5000
            self.refreshIntervalSeconds = 30
            self.prodBaseURL = "https://track-api.onrender.com"
            self.localBaseURL = "http://127.0.0.1:8000"
            self.defaultDeviceIP = "192.168.12.101"
            self.localPort = 8000
            self.distanceFilterMeters = 50
            self.commutePatternMatchRadiusMeters = 200
            self.stopPassedThresholdMeters = 100
            self.userZoomDistance = 3000
            self.minCameraDistance = 300
            self.maxCameraDistance = 80_000
            self.nycCenterLat = 40.7580
            self.nycCenterLon = -73.9855
            self.boundsCenterLat = 40.71
            self.boundsCenterLon = -73.38
            self.boundsLatDelta = 0.60
            self.boundsLonDelta = 2.00
            self.serviceAreaMinLat = 40.40
            self.serviceAreaMaxLat = 41.10
            self.serviceAreaMinLon = -74.35
            self.serviceAreaMaxLon = -72.40
            return
        }

        let api = json["api"] as? [String: Any] ?? [:]
        let location = json["location"] as? [String: Any] ?? [:]
        let map = json["map"] as? [String: Any] ?? [:]

        self.defaultSearchRadiusMeters = api["default_search_radius_meters"] as? Int ?? 500
        self.nearestMetroFallbackRadiusMeters = api["nearest_metro_fallback_radius_meters"] as? Int ?? 5000
        self.refreshIntervalSeconds = api["refresh_interval_seconds"] as? Int ?? 30
        self.prodBaseURL = api["prod_base_url"] as? String ?? "https://track-api.onrender.com"
        self.localBaseURL = api["local_base_url"] as? String ?? "http://127.0.0.1:8000"
        self.defaultDeviceIP = api["default_device_ip"] as? String ?? "192.168.12.101"
        self.localPort = api["local_port"] as? Int ?? 8000

        self.distanceFilterMeters = location["distance_filter_meters"] as? Double ?? 50
        self.commutePatternMatchRadiusMeters = location["commute_pattern_match_radius_meters"] as? Double ?? 200
        self.stopPassedThresholdMeters = location["stop_passed_threshold_meters"] as? Double ?? 100

        self.userZoomDistance = map["user_zoom_distance"] as? Double ?? 3000
        self.minCameraDistance = map["min_camera_distance"] as? Double ?? 300
        self.maxCameraDistance = map["max_camera_distance"] as? Double ?? 80_000
        self.nycCenterLat = map["nyc_center_lat"] as? Double ?? 40.7580
        self.nycCenterLon = map["nyc_center_lon"] as? Double ?? -73.9855
        self.boundsCenterLat = map["bounds_center_lat"] as? Double ?? 40.71
        self.boundsCenterLon = map["bounds_center_lon"] as? Double ?? -73.38
        self.boundsLatDelta = map["bounds_lat_delta"] as? Double ?? 0.60
        self.boundsLonDelta = map["bounds_lon_delta"] as? Double ?? 2.00
        self.serviceAreaMinLat = map["service_area_min_lat"] as? Double ?? 40.40
        self.serviceAreaMaxLat = map["service_area_max_lat"] as? Double ?? 41.10
        self.serviceAreaMinLon = map["service_area_min_lon"] as? Double ?? -74.35
        self.serviceAreaMaxLon = map["service_area_max_lon"] as? Double ?? -72.40
    }
}
