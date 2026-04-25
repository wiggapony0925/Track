// Codable model types for Supabase cloud data.
// These structs map directly to Supabase database tables.

import Foundation
import AuthenticationServices

// MARK: - User Profile

/// User profile stored in Supabase
struct UserProfile: Codable, Identifiable {
    let id: UUID
    var appleUserId: String?
    var email: String?
    var fullName: String?
    var givenName: String?
    var familyName: String?
    var username: String?
    var avatarUrl: String?
    var preferredTheme: String?
    var notificationsEnabled: Bool?
    var createdAt: Date?
    var updatedAt: Date?
    var lastLoginAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id
        case appleUserId = "apple_user_id"
        case email
        case fullName = "full_name"
        case givenName = "given_name"
        case familyName = "family_name"
        case username
        case avatarUrl = "avatar_url"
        case preferredTheme = "preferred_theme"
        case notificationsEnabled = "notifications_enabled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastLoginAt = "last_login_at"
    }
}

// MARK: - Cloud Favorite

/// Favorite route/stop stored in Supabase
struct CloudFavorite: Codable, Identifiable, Equatable {
    var id: Int64?
    let userId: UUID
    let routeId: String
    let routeDisplayName: String
    let stopId: String
    let stopName: String
    var direction: String?
    var destination: String?
    let mode: String
    var stopLat: Double?
    var stopLon: Double?
    var displayOrder: Int?
    var createdAt: Date?
    var updatedAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case routeId = "route_id"
        case routeDisplayName = "route_display_name"
        case stopId = "stop_id"
        case stopName = "stop_name"
        case direction
        case destination
        case mode
        case stopLat = "stop_lat"
        case stopLon = "stop_lon"
        case displayOrder = "display_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Route Interaction

/// Route interaction for analytics
struct RouteInteraction: Codable {
    var id: Int64?
    var userId: UUID?
    let routeId: String
    var routeDisplayName: String?
    let mode: String
    var interactionType: String?
    var latitude: Double?
    var longitude: Double?
    var createdAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case routeId = "route_id"
        case routeDisplayName = "route_display_name"
        case mode
        case interactionType = "interaction_type"
        case latitude
        case longitude
        case createdAt = "created_at"
    }
}

// MARK: - Cloud Schedule

/// Cloud schedule for widget activation
struct CloudSchedule: Codable, Identifiable {
    var id: UUID?
    let userId: UUID
    let daysOfWeek: [Int]
    let startTime: String  // "HH:mm:ss" format
    var durationMinutes: Int?
    var routeId: String?
    var direction: String?
    var isEnabled: Bool?
    var createdAt: Date?
    var updatedAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case daysOfWeek = "days_of_week"
        case startTime = "start_time"
        case durationMinutes = "duration_minutes"
        case routeId = "route_id"
        case direction
        case isEnabled = "is_enabled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Cloud User Settings

/// Synced user settings stored in Supabase
struct CloudUserSettings: Codable {
    let userId: UUID
    var preferredTheme: String?
    var distanceUnit: String?
    var nearYouRadiusMeters: Double?
    var fartherAwayRadiusMeters: Double?
    var muchFartherAwayRadiusMeters: Double?
    var showSystemMap: Bool?
    var subwayLineOffsetMeters: Double?
    var hapticsEnabled: Bool?
    var autoRefreshEnabled: Bool?
    var notificationsEnabled: Bool?
    var dragToSearch: Bool?
    var devUseLocalhost: Bool?
    var devCustomIp: String?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case preferredTheme = "preferred_theme"
        case distanceUnit = "distance_unit"
        case nearYouRadiusMeters = "near_you_radius_meters"
        case fartherAwayRadiusMeters = "farther_away_radius_meters"
        case muchFartherAwayRadiusMeters = "much_farther_away_radius_meters"
        case showSystemMap = "show_system_map"
        case subwayLineOffsetMeters = "subway_line_offset_meters"
        case hapticsEnabled = "haptics_enabled"
        case autoRefreshEnabled = "auto_refresh_enabled"
        case notificationsEnabled = "notifications_enabled"
        case dragToSearch = "drag_to_search"
        case devUseLocalhost = "dev_use_localhost"
        case devCustomIp = "dev_custom_ip"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Trip Configuration

/// Routing priority for trip planning.
enum TripPriority: String, Codable, CaseIterable, Identifiable {
    case quick = "quick"
    case fewerTransfers = "fewer_transfers"
    case lessWalking = "less_walking"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quick: return "Quick"
        case .fewerTransfers: return "Fewer transfers"
        case .lessWalking: return "Less walking"
        }
    }

    var icon: String {
        switch self {
        case .quick: return "bolt.fill"
        case .fewerTransfers: return "arrow.triangle.swap"
        case .lessWalking: return "figure.stand"
        }
    }
}

/// User's trip planning preferences, synced to Supabase `trip_configurations`.
struct CloudTripConfiguration: Codable, Equatable {
    var userId: UUID
    var priority: String
    var modeSubway: Bool
    var modeBus: Bool
    var modeLirr: Bool
    var modeMnr: Bool
    var accessibilityPriority: Bool
    var walkPreference: Float

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case priority
        case modeSubway = "mode_subway"
        case modeBus = "mode_bus"
        case modeLirr = "mode_lirr"
        case modeMnr = "mode_mnr"
        case accessibilityPriority = "accessibility_priority"
        case walkPreference = "walk_preference"
    }

    /// Convenience: resolved priority enum.
    var resolvedPriority: TripPriority {
        TripPriority(rawValue: priority) ?? .quick
    }

    /// Build the `modes` array for the engine request.
    var enabledModes: [String] {
        var modes: [String] = []
        if modeSubway { modes.append("subway") }
        if modeBus { modes.append("bus") }
        if modeLirr { modes.append("lirr") }
        if modeMnr { modes.append("mnr") }
        return modes
    }

    /// Walking distance in meters mapped from the 0–1 slider.
    /// 0.0 → 400m, 0.5 → 1200m (default), 1.0 → 2400m
    var maxOriginWalkMeters: Int {
        let base: Float = 400
        let extra: Float = 2000
        return Int(base + walkPreference * extra)
    }

    var maxDestinationWalkMeters: Int {
        let base: Float = 300
        let extra: Float = 1700
        return Int(base + walkPreference * extra)
    }

    var maxTransferWalkMeters: Int {
        let base: Float = 150
        let extra: Float = 450
        return Int(base + walkPreference * extra)
    }

    /// Max transfers based on priority.
    var maxTransfers: Int {
        switch resolvedPriority {
        case .quick: return 2
        case .fewerTransfers: return 1
        case .lessWalking: return 2
        }
    }

    /// Factory default — subway + bus ON, commuter rail OFF.
    static func makeDefault(userId: UUID) -> CloudTripConfiguration {
        CloudTripConfiguration(
            userId: userId,
            priority: TripPriority.quick.rawValue,
            modeSubway: true,
            modeBus: true,
            modeLirr: false,
            modeMnr: false,
            accessibilityPriority: false,
            walkPreference: 0.5
        )
    }
}

// MARK: - Apple Sign-In Credentials

/// Stores Apple Sign-In credentials for Supabase auth
struct AppleSignInCredentials {
    let userId: String
    let email: String?
    let fullName: PersonNameComponents?
    let identityToken: Data?
    let authorizationCode: Data?
    /// The plaintext nonce that was hashed (SHA-256) and sent to Apple
    /// in the original `ASAuthorizationAppleIDRequest`. Supabase will
    /// verify the hash against the `nonce` claim inside `identityToken`
    /// to defeat token-replay attacks. `nil` only for legacy callers.
    let rawNonce: String?

    var identityTokenString: String? {
        guard let token = identityToken else { return nil }
        return String(data: token, encoding: .utf8)
    }
    
    var authorizationCodeString: String? {
        guard let code = authorizationCode else { return nil }
        return String(data: code, encoding: .utf8)
    }
}

// MARK: - Cloud Commute Pattern

/// Cloud commute pattern model for Supabase sync
struct CloudCommutePattern: Codable {
    let id: UUID?
    let userId: UUID
    let routeId: String
    let direction: String
    let startLatitude: Double
    let startLongitude: Double
    let destinationStationId: String
    let destinationName: String
    let timeOfDay: Int
    let dayOfWeek: Int
    let frequency: Int
    let lastUsed: Date
    var createdAt: Date?
    var updatedAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case routeId = "route_id"
        case direction
        case startLatitude = "start_latitude"
        case startLongitude = "start_longitude"
        case destinationStationId = "destination_station_id"
        case destinationName = "destination_name"
        case timeOfDay = "time_of_day"
        case dayOfWeek = "day_of_week"
        case frequency
        case lastUsed = "last_used"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Supabase Errors

enum SupabaseError: Error, LocalizedError {
    case invalidCredentials
    case networkError
    case authFailed(String)
    case notFound
    case updateFailed
    case insertFailed
    case deleteFailed
    case upsertFailed
    case unauthorized
    
    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid sign-in credentials"
        case .networkError:
            return "Network connection error"
        case .authFailed(let message):
            return message
        case .notFound:
            return "Resource not found"
        case .updateFailed:
            return "Failed to update data"
        case .insertFailed:
            return "Failed to save data"
        case .deleteFailed:
            return "Failed to delete data"
        case .upsertFailed:
            return "Failed to sync data"
        case .unauthorized:
            return "Not authorized"
        }
    }
}
