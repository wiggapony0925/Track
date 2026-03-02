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
    /// Overridable via remote /config so the backend can throttle clients.
    private let _refreshIntervalSeconds: Int
    var refreshIntervalSeconds: Int {
        UserDefaults.standard.object(forKey: "rc_refresh_interval_seconds") as? Int ?? _refreshIntervalSeconds
    }
    /// Minimum seconds before a background-return triggers a new fetch.
    /// If the user comes back within this window, the previous data is reused.
    let refreshCooldownSeconds: Int
    /// Minimum distance (meters) the user must move before nearby-route
    /// discovery is re-triggered on a background return.
    let significantMovementMeters: Double
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
    /// Map zoom level (distance) at which station markers become visible.
    let stationVisibilityZoomMeters: Double
    /// How long before a Live Activity is considered stale (seconds).
    let liveActivityStaleDateSeconds: Double
    /// How long a completed Live Activity remains on the lock screen (seconds).
    let liveActivityDismissalSeconds: Double
    /// Default radius in meters for "Near You" transit section (from settings.json).
    private let _nearYouRadiusMeters: Double
    /// Default radius in meters for "A Little Farther Away" transit section (from settings.json).
    private let _fartherAwayRadiusMeters: Double
    /// Default radius in meters for "Much Farther Away" transit section (from settings.json).
    private let _muchFartherAwayRadiusMeters: Double
    
    /// Radius in meters for "Near You" transit section (user-configurable via Settings).
    var nearYouRadiusMeters: Double {
        UserDefaults.standard.object(forKey: "near_you_radius_meters") as? Double ?? _nearYouRadiusMeters
    }
    
    /// Radius in meters for "A Little Farther Away" transit section (user-configurable via Settings).
    var fartherAwayRadiusMeters: Double {
        UserDefaults.standard.object(forKey: "farther_away_radius_meters") as? Double ?? _fartherAwayRadiusMeters
    }
    
    /// Radius in meters for "Much Farther Away" transit section (user-configurable via Settings).
    var muchFartherAwayRadiusMeters: Double {
        UserDefaults.standard.object(forKey: "much_farther_away_radius_meters") as? Double ?? _muchFartherAwayRadiusMeters
    }

    /// The effective API search radius — always at least as large as the user's
    /// widest display tier so the backend returns exactly the data that fits
    /// the 3 display rings.
    var effectiveAPISearchRadius: Int {
        max(1, Int(muchFartherAwayRadiusMeters))
    }
    
    /// Default values from settings.json (used for "Reset to Defaults").
    var defaultNearYouRadiusMeters: Double { _nearYouRadiusMeters }
    var defaultFartherAwayRadiusMeters: Double { _fartherAwayRadiusMeters }
    var defaultMuchFartherAwayRadiusMeters: Double { _muchFartherAwayRadiusMeters }


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
    /// Whether to show LIRR routes on the system map by default.
    let showLIRRByDefault: Bool
    /// Whether to show Metro-North routes on the system map by default.
    let showMNRByDefault: Bool
    /// Perpendicular offset in meters between subway lines sharing the same tunnel.
    /// Higher values spread overlapping lines further apart; lower values keep them tighter.
    private let _subwayLineOffsetMeters: Double
    
    /// Subway line offset (user-configurable via Settings, falls back to settings.json value).
    var subwayLineOffsetMeters: Double {
        UserDefaults.standard.object(forKey: "subway_line_offset_meters") as? Double ?? _subwayLineOffsetMeters
    }
    
    /// Tolerance in degrees for polyline simplification (Ramer-Douglas-Peucker algorithm).
    /// Higher values = fewer points = better performance but less detail.
    /// ~0.0001° = ~11m, ~0.00015° = ~17m at NYC latitude.
    let polylineSimplificationTolerance: Double

    // MARK: - Camera Preset Settings (used by MapCameraPresets)

    /// Camera altitude for focusing on a vehicle marker.
    let vehicleFocusDistance: Double
    /// Multiplier applied to `userZoomDistance` for the "Explore NYC" overview.
    let explorerDistanceMultiplier: Double
    /// Minimum camera altitude when fitting user → nearest stop (walking path).
    let walkingZoomMinAltitude: Double
    /// Maximum camera altitude for walking path zoom.
    let walkingZoomMaxAltitude: Double
    /// Padding multiplier for very close stops (< walkingCloseThresholdMeters).
    let walkingClosePadding: Double
    /// Padding multiplier for medium-distance stops.
    let walkingMediumPadding: Double
    /// Padding multiplier for farther stops (> walkingMediumThresholdMeters).
    let walkingFarPadding: Double
    /// Distance threshold (meters) below which "close" padding applies.
    let walkingCloseThresholdMeters: Double
    /// Distance threshold (meters) above which "far" padding applies.
    let walkingMediumThresholdMeters: Double
    /// How much to bias the camera center toward the stop (0 = midpoint, 1 = stop).
    let walkingCenterBias: Double

    // MARK: - Init

    private init() {
        guard let url = Bundle.main.url(forResource: "settings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fall back to hardcoded defaults if settings.json is missing
            print("[AppSettings] WARNING: settings.json not found in bundle — using hardcoded defaults")
            self.defaultSearchRadiusMeters = 8047
            self.nearestMetroFallbackRadiusMeters = 8047
            self._refreshIntervalSeconds = 30
            self.refreshCooldownSeconds = 30
            self.significantMovementMeters = 150
            self.prodBaseURL = "https://track-vkrr.onrender.com"
            self.localBaseURL = "http://127.0.0.1:8000"
            self.defaultDeviceIP = "169.254.175.168"
            self.localPort = 8000
            self.maxServiceAlerts = 3
            self.maxElevatorOutages = 5
            self.maxLirrArrivals = 15
            self.stationVisibilityZoomMeters = 3500
            self.liveActivityStaleDateSeconds = 3600
            self.liveActivityDismissalSeconds = 120
            self._nearYouRadiusMeters = 2414
            self._fartherAwayRadiusMeters = 4023
            self._muchFartherAwayRadiusMeters = 8047
            self.distanceFilterMeters = 50
            self.commutePatternMatchRadiusMeters = 200
            self.stopPassedThresholdMeters = 100
            self.userZoomDistance = 3000
            self.minCameraDistance = 300
            self.maxCameraDistance = 600_000
            self.smartZoomMinAltitude = 2400
            self.smartZoomMaxAltitude = 20000
            self.smartZoomPaddingMultiplier = 4.5
            self.nycCenterLat = 40.7580
            self.nycCenterLon = -73.9855
            self.boundsCenterLat = 41.10
            self.boundsCenterLon = -73.20
            self.boundsLatDelta = 2.40
            self.boundsLonDelta = 4.00
            self.serviceAreaMinLat = 40.40
            self.serviceAreaMaxLat = 42.20
            self.serviceAreaMinLon = -74.35
            self.serviceAreaMaxLon = -71.70
            self.simulationEasingEnabled = true
            self.showLIRRByDefault = true
            self.showMNRByDefault = true
            self._subwayLineOffsetMeters = 12.0
            self.polylineSimplificationTolerance = 0.00006
            self.vehicleFocusDistance = 1500
            self.explorerDistanceMultiplier = 1.5
            self.walkingZoomMinAltitude = 600
            self.walkingZoomMaxAltitude = 6000
            self.walkingClosePadding = 3.5
            self.walkingMediumPadding = 2.8
            self.walkingFarPadding = 2.2
            self.walkingCloseThresholdMeters = 200
            self.walkingMediumThresholdMeters = 800
            self.walkingCenterBias = 0.15
            return
        }

        let api = json["api"] as? [String: Any] ?? [:]
        let display = json["display"] as? [String: Any] ?? [:]
        let location = json["location"] as? [String: Any] ?? [:]
        let map = json["map"] as? [String: Any] ?? [:]

        self.defaultSearchRadiusMeters = api["default_search_radius_meters"] as? Int ?? 8047
        self.nearestMetroFallbackRadiusMeters = api["nearest_metro_fallback_radius_meters"] as? Int ?? 8047
        self._refreshIntervalSeconds = api["refresh_interval_seconds"] as? Int ?? 30
        self.refreshCooldownSeconds = api["refresh_cooldown_seconds"] as? Int ?? 30
        self.significantMovementMeters = api["significant_movement_meters"] as? Double ?? 150
        self.prodBaseURL = api["prod_base_url"] as? String ?? "https://track-vkrr.onrender.com"
        self.localBaseURL = api["local_base_url"] as? String ?? "http://127.0.0.1:8000"
        self.defaultDeviceIP = api["default_device_ip"] as? String ?? "169.254.175.168"
        self.localPort = api["local_port"] as? Int ?? 8000

        self.maxServiceAlerts = display["max_service_alerts"] as? Int ?? 3
        self.maxElevatorOutages = display["max_elevator_outages"] as? Int ?? 5
        self.maxLirrArrivals = display["max_lirr_arrivals"] as? Int ?? 15
        self.stationVisibilityZoomMeters = display["station_visibility_zoom_meters"] as? Double ?? 3500
        self.liveActivityStaleDateSeconds = display["live_activity_stale_date_seconds"] as? Double ?? 3600
        self.liveActivityDismissalSeconds = display["live_activity_dismissal_seconds"] as? Double ?? 120
        self._nearYouRadiusMeters = display["near_you_radius_meters"] as? Double ?? 2414
        self._fartherAwayRadiusMeters = display["farther_away_radius_meters"] as? Double ?? 4023
        self._muchFartherAwayRadiusMeters = display["much_farther_away_radius_meters"] as? Double ?? 8047


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
        self.showLIRRByDefault = map["show_lirr_by_default"] as? Bool ?? true
        self.showMNRByDefault = map["show_mnr_by_default"] as? Bool ?? true
        self._subwayLineOffsetMeters = map["subway_line_offset_meters"] as? Double ?? 12.0
        self.polylineSimplificationTolerance = map["polyline_simplification_tolerance"] as? Double ?? 0.00006
        self.vehicleFocusDistance = map["vehicle_focus_distance"] as? Double ?? 1500
        self.explorerDistanceMultiplier = map["explorer_distance_multiplier"] as? Double ?? 1.5
        self.walkingZoomMinAltitude = map["walking_zoom_min_altitude"] as? Double ?? 600
        self.walkingZoomMaxAltitude = map["walking_zoom_max_altitude"] as? Double ?? 6000
        self.walkingClosePadding = map["walking_close_padding"] as? Double ?? 3.5
        self.walkingMediumPadding = map["walking_medium_padding"] as? Double ?? 2.8
        self.walkingFarPadding = map["walking_far_padding"] as? Double ?? 2.2
        self.walkingCloseThresholdMeters = map["walking_close_threshold_meters"] as? Double ?? 200
        self.walkingMediumThresholdMeters = map["walking_medium_threshold_meters"] as? Double ?? 800
        self.walkingCenterBias = map["walking_center_bias"] as? Double ?? 0.15
    }
}

// MARK: - Remote Config Overrides

extension AppSettings {
    /// Applies server-side overrides from the `/config` endpoint.
    /// Only a curated set of safe-to-override keys are accepted.
    /// Values persist in UserDefaults until the next `/config` fetch.
    static func applyRemoteOverrides(_ config: [String: Any]) {
        let store = UserDefaults.standard
        if let interval = config["refresh_interval_seconds"] as? Int, interval >= 10 {
            store.set(interval, forKey: "rc_refresh_interval_seconds")
        }
        if let showGhosts = config["show_ghost_trains"] as? Bool {
            store.set(showGhosts, forKey: "rc_show_ghost_trains")
        }
    }

    /// Whether "ghost" (scheduled-only) trains should appear in the UI.
    /// Controlled remotely via `/config → show_ghost_trains`.
    var showGhostTrains: Bool {
        UserDefaults.standard.object(forKey: "rc_show_ghost_trains") as? Bool ?? false
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by SettingsContentView after applying radius changes so other
    /// parts of the app can re-fetch transit data with the updated radius.
    static let radiusSettingsChanged = Notification.Name("radiusSettingsChanged")
}
