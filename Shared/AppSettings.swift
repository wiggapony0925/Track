//
//  AppSettings.swift
//  Shared
//
//  Loads settings.json from the app bundle and exposes typed,
//  centralized configuration values. Change a single value in
//  settings.json to adjust behavior across the entire app —
//  search radius, refresh interval, map bounds, etc.
//

import Foundation

// MARK: - App Group Constant

/// Shared App Group identifier used across main app and widgets
let kAppGroupIdentifier = "group.JFMCAPITALGROUP.Track"

struct AppSettings {
    static let shared = AppSettings()

    // MARK: - API Settings

    /// Default search radius in meters for nearby transit.
    let defaultSearchRadiusMeters: Int
    /// Expanded radius to find the nearest subway station if none are found nearby.
    let nearestMetroFallbackRadiusMeters: Int
    /// How often the app polls for new data (in seconds).
    let refreshIntervalSeconds: Int
    /// Base URL for the production backend.
    let prodBaseURL: String
    /// Base URL for the local backend (simulator).
    let localBaseURL: String
    /// IP address of the backend for physical device testing.
    let defaultDeviceIP: String
    /// Port number for local development.
    let localPort: Int

    // MARK: - Display Settings

    /// Maximum number of service alerts to show in the UI.
    let maxServiceAlerts: Int
    /// Maximum number of broken elevators to display.
    let maxElevatorOutages: Int
    /// How many LIRR arrivals to list.
    let maxLirrArrivals: Int
    /// Number of upcoming arrivals to show in the Route Detail sheet.
    let maxRouteDetailArrivals: Int
    /// Map zoom level (distance) at which station markers become visible.
    let stationVisibilityZoomMeters: Double
    /// How long before a Live Activity is considered stale (seconds).
    let liveActivityStaleDateSeconds: Double
    /// How long a completed Live Activity remains on the lock screen (seconds).
    let liveActivityDismissalSeconds: Double


    // MARK: - Location Settings

    /// Minimum distance change (meters) to trigger a location update.
    let distanceFilterMeters: Double
    /// Radius to matching the user's location to a "commute pattern".
    let commutePatternMatchRadiusMeters: Double
    /// Distance threshold to consider a stop "passed".
    let stopPassedThresholdMeters: Double

    // MARK: - Map Settings

    /// Default camera altitude for "User Tracking" mode.
    let userZoomDistance: Double
    /// Minimum allowed camera altitude (closest zoom).
    let minCameraDistance: Double
    /// Maximum allowed camera altitude (furthest zoom).
    let maxCameraDistance: Double
    /// Minimum altitude for the smart "Fit Bounds" logic.
    let smartZoomMinAltitude: Double
    /// Maximum altitude for the smart "Fit Bounds" logic.
    let smartZoomMaxAltitude: Double
    /// Padding multiplier for fitting route shapes on screen.
    let smartZoomPaddingMultiplier: Double
    /// Default center latitude for NYC.
    let nycCenterLat: Double
    /// Default center longitude for NYC.
    let nycCenterLon: Double
    /// Center latitude for the camera bounds constraint.
    let boundsCenterLat: Double
    /// Center longitude for the camera bounds constraint.
    let boundsCenterLon: Double
    /// Latitude delta (height) for the camera bounds constraint.
    let boundsLatDelta: Double
    /// Longitude delta (width) for the camera bounds constraint.
    let boundsLonDelta: Double
    /// Minimum latitude for the supported service area.
    let serviceAreaMinLat: Double
    /// Maximum latitude for the supported service area.
    let serviceAreaMaxLat: Double
    /// Minimum longitude for the supported service area.
    let serviceAreaMinLon: Double
    /// Maximum longitude for the supported service area.
    let serviceAreaMaxLon: Double
    /// Toggles the "Ease-In-Out" physics for train animation (vs Linear).
    let simulationEasingEnabled: Bool

    // MARK: - Init

    private init() {
        guard let url = Bundle.main.url(forResource: "settings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fall back to hardcoded defaults if settings.json is missing
            print("[AppSettings] WARNING: settings.json not found in bundle — using hardcoded defaults")
            self.defaultSearchRadiusMeters = 800
            self.nearestMetroFallbackRadiusMeters = 5000
            self.refreshIntervalSeconds = 30
            self.prodBaseURL = "https://track-api.onrender.com"
            self.localBaseURL = "http://127.0.0.1:8000"
            self.defaultDeviceIP = "192.168.12.101"
            self.localPort = 8000
            self.maxServiceAlerts = 3
            self.maxElevatorOutages = 5
            self.maxLirrArrivals = 15
            self.maxRouteDetailArrivals = 4
            self.stationVisibilityZoomMeters = 3500
            self.liveActivityStaleDateSeconds = 3600
            self.liveActivityDismissalSeconds = 120
            self.distanceFilterMeters = 50
            self.commutePatternMatchRadiusMeters = 200
            self.stopPassedThresholdMeters = 100
            self.userZoomDistance = 3000
            self.minCameraDistance = 300
            self.maxCameraDistance = 80_000
            self.smartZoomMinAltitude = 2400
            self.smartZoomMaxAltitude = 20000
            self.smartZoomPaddingMultiplier = 4.5
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
            self.simulationEasingEnabled = true
            return
        }

        let api = json["api"] as? [String: Any] ?? [:]
        let display = json["display"] as? [String: Any] ?? [:]
        let location = json["location"] as? [String: Any] ?? [:]
        let map = json["map"] as? [String: Any] ?? [:]

        self.defaultSearchRadiusMeters = api["default_search_radius_meters"] as? Int ?? 800
        self.nearestMetroFallbackRadiusMeters = api["nearest_metro_fallback_radius_meters"] as? Int ?? 5000
        self.refreshIntervalSeconds = api["refresh_interval_seconds"] as? Int ?? 30
        self.prodBaseURL = api["prod_base_url"] as? String ?? "https://track-api.onrender.com"
        self.localBaseURL = api["local_base_url"] as? String ?? "http://127.0.0.1:8000"
        self.defaultDeviceIP = api["default_device_ip"] as? String ?? "192.168.12.101"
        self.localPort = api["local_port"] as? Int ?? 8000

        self.maxServiceAlerts = display["max_service_alerts"] as? Int ?? 3
        self.maxElevatorOutages = display["max_elevator_outages"] as? Int ?? 5
        self.maxLirrArrivals = display["max_lirr_arrivals"] as? Int ?? 15
        self.maxRouteDetailArrivals = display["max_route_detail_arrivals"] as? Int ?? 4
        self.stationVisibilityZoomMeters = display["station_visibility_zoom_meters"] as? Double ?? 3500
        self.liveActivityStaleDateSeconds = display["live_activity_stale_date_seconds"] as? Double ?? 3600
        self.liveActivityDismissalSeconds = display["live_activity_dismissal_seconds"] as? Double ?? 120


        self.distanceFilterMeters = location["distance_filter_meters"] as? Double ?? 50
        self.commutePatternMatchRadiusMeters = location["commute_pattern_match_radius_meters"] as? Double ?? 200
        self.stopPassedThresholdMeters = location["stop_passed_threshold_meters"] as? Double ?? 100

        self.userZoomDistance = map["user_zoom_distance"] as? Double ?? 3000
        self.minCameraDistance = map["min_camera_distance"] as? Double ?? 300
        self.maxCameraDistance = map["max_camera_distance"] as? Double ?? 80_000
        self.smartZoomMinAltitude = map["smart_zoom_min_altitude"] as? Double ?? 2400
        self.smartZoomMaxAltitude = map["smart_zoom_max_altitude"] as? Double ?? 20000
        self.smartZoomPaddingMultiplier = map["smart_zoom_padding_multiplier"] as? Double ?? 4.5
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
        self.simulationEasingEnabled = map["simulation_easing_enabled"] as? Bool ?? true
    }
}
