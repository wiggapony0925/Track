//
//  SupabaseManager.swift
//  Track
//
//  Manages all Supabase interactions including authentication,
//  database operations, and data synchronization.
//
//  Setup:
//  1. Add Supabase SDK: File > Add Packages > https://github.com/supabase-community/supabase-swift
//  2. Configure credentials below or in environment
//

import Foundation
import AuthenticationServices

// MARK: - Supabase Configuration

/// Supabase project configuration
/// WARNING: In production, these should be loaded from:
/// - Info.plist with build configuration variables
/// - A Secrets.plist file excluded from version control
/// - Environment variables set in Xcode scheme
///
/// The anon key is publishable and safe for client-side use,
/// but should still not be committed to public repositories.
enum SupabaseConfig {
    static var url: String {
        // Try to load from Info.plist first
        if let url = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String, !url.isEmpty {
            return url
        }
        // Fallback to hardcoded (development only)
        return "https://octpebjxadbufiplgjqg.supabase.co"
    }
    
    static var anonKey: String {
        // Try to load from Info.plist first
        if let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String, !key.isEmpty {
            return key
        }
        // Fallback to hardcoded (development only)
        return "sb_publishable_lAEZ_x8O4vjdGaw-I-QUMg_oS5iWKIn"
    }
}

// MARK: - Supabase Models

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

/// Favorite route/stop stored in Supabase
struct CloudFavorite: Codable, Identifiable {
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

// MARK: - Apple Sign-In Credentials

/// Stores Apple Sign-In credentials for Supabase auth
struct AppleSignInCredentials {
    let userId: String
    let email: String?
    let fullName: PersonNameComponents?
    let identityToken: Data?
    let authorizationCode: Data?
    
    var identityTokenString: String? {
        guard let token = identityToken else { return nil }
        return String(data: token, encoding: .utf8)
    }
    
    var authorizationCodeString: String? {
        guard let code = authorizationCode else { return nil }
        return String(data: code, encoding: .utf8)
    }
}

// MARK: - Supabase Manager

/// Singleton manager for all Supabase operations
@MainActor
class SupabaseManager: ObservableObject {
    static let shared = SupabaseManager()
    
    // MARK: - Published State
    
    @Published var currentUser: UserProfile?
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // MARK: - Private Properties
    
    private let baseURL: URL
    private let apiKey: String
    private var accessToken: String?
    
    // UserDefaults keys
    private let accessTokenKey = "supabase_access_token"
    private let refreshTokenKey = "supabase_refresh_token"
    private let userIdKey = "supabase_user_id"
    
    private var defaults: UserDefaults {
        UserDefaults(suiteName: kAppGroupIdentifier) ?? .standard
    }
    
    // MARK: - Initialization
    
    private init() {
        self.baseURL = URL(string: SupabaseConfig.url)!
        self.apiKey = SupabaseConfig.anonKey
        
        // Restore session if available
        if let token = defaults.string(forKey: accessTokenKey) {
            self.accessToken = token
            self.isAuthenticated = true
            
            // Load user profile
            Task {
                await loadCurrentUser()
            }
        }
    }
    
    // MARK: - Authentication
    
    /// Sign in with Apple credentials
    func signInWithApple(credentials: AppleSignInCredentials) async throws {
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }
        
        guard let idToken = credentials.identityTokenString else {
            throw SupabaseError.invalidCredentials
        }
        
        // Build request to Supabase Auth
        let url = baseURL.appendingPathComponent("auth/v1/token")
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]
        
        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        
        let body: [String: Any] = [
            "provider": "apple",
            "id_token": idToken
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }
        
        if httpResponse.statusCode == 200 {
            // Parse auth response
            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            
            // Store tokens
            accessToken = authResponse.accessToken
            defaults.set(authResponse.accessToken, forKey: accessTokenKey)
            defaults.set(authResponse.refreshToken, forKey: refreshTokenKey)
            defaults.set(authResponse.user.id, forKey: userIdKey)
            
            isAuthenticated = true
            
            // Update profile with Apple data
            await updateProfileWithAppleData(credentials: credentials, userId: UUID(uuidString: authResponse.user.id)!)
            
            // Load full profile
            await loadCurrentUser()
        } else {
            // Try to create account if user doesn't exist
            try await signUpWithApple(credentials: credentials)
        }
    }
    
    /// Sign up with Apple (creates new account)
    private func signUpWithApple(credentials: AppleSignInCredentials) async throws {
        guard let idToken = credentials.identityTokenString else {
            throw SupabaseError.invalidCredentials
        }
        
        let url = baseURL.appendingPathComponent("auth/v1/signup")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        
        // Generate a unique email if Apple hides it
        // Use full UUID to guarantee uniqueness
        let email = credentials.email ?? "apple_\(UUID().uuidString.lowercased())@track.privaterelay"
        
        let body: [String: Any] = [
            "email": email,
            "password": UUID().uuidString, // Random password (user will use Apple Sign-In)
            "data": [
                "apple_user_id": credentials.userId,
                "full_name": credentials.fullName?.formatted() ?? ""
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SupabaseError.signUpFailed
        }
        
        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        
        // Store tokens
        accessToken = authResponse.accessToken
        defaults.set(authResponse.accessToken, forKey: accessTokenKey)
        defaults.set(authResponse.refreshToken, forKey: refreshTokenKey)
        defaults.set(authResponse.user.id, forKey: userIdKey)
        
        isAuthenticated = true
        
        // Update profile with Apple data
        await updateProfileWithAppleData(credentials: credentials, userId: UUID(uuidString: authResponse.user.id)!)
        
        await loadCurrentUser()
    }
    
    /// Anonymous sign in (for users who skip login)
    func signInAnonymously() async throws {
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }
        
        let url = baseURL.appendingPathComponent("auth/v1/signup")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        
        // Generate anonymous user with full UUID for uniqueness
        let anonymousEmail = "anon_\(UUID().uuidString.lowercased())@track.app"
        let body: [String: Any] = [
            "email": anonymousEmail,
            "password": UUID().uuidString
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SupabaseError.signUpFailed
        }
        
        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        
        accessToken = authResponse.accessToken
        defaults.set(authResponse.accessToken, forKey: accessTokenKey)
        defaults.set(authResponse.refreshToken, forKey: refreshTokenKey)
        defaults.set(authResponse.user.id, forKey: userIdKey)
        
        isAuthenticated = true
    }
    
    /// Sign out current user
    func signOut() {
        accessToken = nil
        currentUser = nil
        isAuthenticated = false
        
        defaults.removeObject(forKey: accessTokenKey)
        defaults.removeObject(forKey: refreshTokenKey)
        defaults.removeObject(forKey: userIdKey)
    }
    
    /// Load current user profile
    func loadCurrentUser() async {
        guard let userId = defaults.string(forKey: userIdKey),
              let uuid = UUID(uuidString: userId) else { return }
        
        do {
            let profile = try await fetchProfile(userId: uuid)
            currentUser = profile
        } catch {
            print("Failed to load user profile: \(error)")
        }
    }
    
    // MARK: - Profile Operations
    
    /// Fetch user profile from Supabase
    func fetchProfile(userId: UUID) async throws -> UserProfile {
        let url = baseURL.appendingPathComponent("rest/v1/profiles")
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(userId.uuidString)"),
            URLQueryItem(name: "select", value: "*")
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let profiles = try JSONDecoder().decode([UserProfile].self, from: data)
        
        guard let profile = profiles.first else {
            throw SupabaseError.notFound
        }
        
        return profile
    }
    
    /// Update user profile
    func updateProfile(_ profile: UserProfile) async throws {
        let url = baseURL.appendingPathComponent("rest/v1/profiles")
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "id", value: "eq.\(profile.id.uuidString)")]
        
        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(profile)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.updateFailed
        }
        
        currentUser = profile
    }
    
    /// Update profile with Apple Sign-In data
    private func updateProfileWithAppleData(credentials: AppleSignInCredentials, userId: UUID) async {
        var profile = UserProfile(
            id: userId,
            appleUserId: credentials.userId,
            email: credentials.email,
            fullName: credentials.fullName?.formatted(),
            givenName: credentials.fullName?.givenName,
            familyName: credentials.fullName?.familyName
        )
        
        do {
            try await updateProfile(profile)
        } catch {
            print("Failed to update profile with Apple data: \(error)")
        }
    }
    
    // MARK: - Analytics
    
    /// Log a route interaction for analytics (works for anonymous users too)
    func logRouteInteraction(
        routeId: String,
        displayName: String? = nil,
        mode: String,
        type: String = "click",
        latitude: Double? = nil,
        longitude: Double? = nil
    ) async {
        let url = baseURL.appendingPathComponent("rest/v1/route_interactions")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        var body: [String: Any] = [
            "route_id": routeId,
            "mode": mode,
            "interaction_type": type
        ]
        
        if let displayName = displayName {
            body["route_display_name"] = displayName
        }
        
        if let userId = defaults.string(forKey: userIdKey) {
            body["user_id"] = userId
        }
        
        if let lat = latitude, let lon = longitude {
            body["latitude"] = lat
            body["longitude"] = lon
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, _) = try await URLSession.shared.data(for: request)
        } catch {
            print("Failed to log route interaction: \(error)")
        }
    }
    
    // MARK: - Favorites
    
    /// Fetch all favorites for current user
    func fetchFavorites() async throws -> [CloudFavorite] {
        guard let userId = defaults.string(forKey: userIdKey) else {
            return []
        }
        
        let url = baseURL.appendingPathComponent("rest/v1/favorites")
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "display_order.asc")
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([CloudFavorite].self, from: data)
    }
    
    /// Add a favorite
    func addFavorite(_ favorite: CloudFavorite) async throws {
        let url = baseURL.appendingPathComponent("rest/v1/favorites")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(favorite)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.insertFailed
        }
    }
    
    /// Remove a favorite
    func removeFavorite(id: Int64) async throws {
        let url = baseURL.appendingPathComponent("rest/v1/favorites")
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "id", value: "eq.\(id)")]
        
        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.deleteFailed
        }
    }
    
    // MARK: - Schedules
    
    /// Fetch all schedules for current user
    func fetchSchedules() async throws -> [CloudSchedule] {
        guard let userId = defaults.string(forKey: userIdKey) else {
            return []
        }
        
        let url = baseURL.appendingPathComponent("rest/v1/schedules")
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "*")
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([CloudSchedule].self, from: data)
    }
    
    /// Upsert a schedule
    func upsertSchedule(_ schedule: CloudSchedule) async throws {
        let url = baseURL.appendingPathComponent("rest/v1/schedules")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(schedule)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.upsertFailed
        }
    }
    
    /// Delete a schedule
    func deleteSchedule(id: UUID) async throws {
        let url = baseURL.appendingPathComponent("rest/v1/schedules")
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")]
        
        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.deleteFailed
        }
    }
}

// MARK: - Auth Response

private struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let user: AuthUser
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

private struct AuthUser: Codable {
    let id: String
    let email: String?
}

// MARK: - Supabase Errors

enum SupabaseError: Error, LocalizedError {
    case invalidCredentials
    case networkError
    case signUpFailed
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
        case .signUpFailed:
            return "Failed to create account"
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
