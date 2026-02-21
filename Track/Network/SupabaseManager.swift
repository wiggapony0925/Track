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
import Combine

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
        
        // In challenge mode, mark as authenticated without network
        if ChallengeMode.isEnabled {
            self.isAuthenticated = true
            self.currentUser = UserProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                appleUserId: "challenge_mode_user",
                email: "student@example.com",
                fullName: "Challenge User",
                givenName: "Challenge",
                familyName: "User"
            )
            return
        }
        
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
    
    /// Sign up with Apple (creates new account using native Apple ID token)
    /// Uses Supabase's native OAuth flow with Apple identity token
    private func signUpWithApple(credentials: AppleSignInCredentials) async throws {
        guard let idToken = credentials.identityTokenString else {
            throw SupabaseError.invalidCredentials
        }
        
        // Use Supabase's token-based sign in for Apple
        // This will create a new account if one doesn't exist
        let url = baseURL.appendingPathComponent("auth/v1/token", isDirectory: false)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        
        // Use id_token grant type for native Apple Sign-In
        let body: [String: Any] = [
            "grant_type": "id_token",
            "provider": "apple",
            "id_token": idToken
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
        let profile = UserProfile(
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
        if ChallengeMode.isEnabled { return }
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
        if ChallengeMode.isEnabled { return [] }
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
        if ChallengeMode.isEnabled { return }
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
        if ChallengeMode.isEnabled { return }
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
        if ChallengeMode.isEnabled { return [] }
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
        if ChallengeMode.isEnabled { return }
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
        if ChallengeMode.isEnabled { return }
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
    
    // MARK: - User Settings
    
    /// Fetch user settings from Supabase
    func fetchUserSettings() async throws -> CloudUserSettings? {
        if ChallengeMode.isEnabled { return nil }
        guard let userId = currentUser?.id else { return nil }
        
        let url = baseURL.appendingPathComponent("rest/v1/user_settings")
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userId.uuidString)"),
            URLQueryItem(name: "select", value: "*")
        ]
        
        var request = URLRequest(url: url)
        request.url = urlComponents.url
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let results = try decoder.decode([CloudUserSettings].self, from: data)
        return results.first
    }
    
    /// Save user settings to Supabase (upsert)
    func saveUserSettings(_ settings: CloudUserSettings) async throws {
        if ChallengeMode.isEnabled { return }
        guard currentUser != nil else { throw SupabaseError.unauthorized }
        
        let url = baseURL.appendingPathComponent("rest/v1/user_settings")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("return=representation,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(settings)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.upsertFailed
        }
    }
    
    // MARK: - Commute Patterns
    
    /// Sync a commute pattern to cloud (upsert)
    func syncCommutePattern(
        routeId: String,
        direction: String,
        startLatitude: Double,
        startLongitude: Double,
        destinationStationId: String,
        destinationName: String,
        timeOfDay: Int,
        dayOfWeek: Int,
        frequency: Int
    ) async throws {
        if ChallengeMode.isEnabled { return }
        guard let userId = currentUser?.id else {
            throw SupabaseError.unauthorized
        }
        
        let url = baseURL.appendingPathComponent("rest/v1/commute_patterns", isDirectory: false)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("return=representation,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let pattern = CloudCommutePattern(
            id: nil,
            userId: userId,
            routeId: routeId,
            direction: direction,
            startLatitude: startLatitude,
            startLongitude: startLongitude,
            destinationStationId: destinationStationId,
            destinationName: destinationName,
            timeOfDay: timeOfDay,
            dayOfWeek: dayOfWeek,
            frequency: frequency,
            lastUsed: Date()
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(pattern)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.upsertFailed
        }
    }
    
    /// Fetch commute patterns from cloud
    func fetchCommutePatterns() async throws -> [CloudCommutePattern] {
        if ChallengeMode.isEnabled { return [] }
        guard let userId = currentUser?.id else {
            return []
        }
        
        let url = baseURL.appendingPathComponent("rest/v1/commute_patterns", isDirectory: false)
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userId.uuidString)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "frequency.desc")
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CloudCommutePattern].self, from: data)
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
