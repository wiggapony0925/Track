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
    @Published var isAuthResolved = false
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
    
    /// Shared decoder that handles Supabase ISO 8601 timestamps with fractional seconds.
    private let supabaseDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        nonisolated(unsafe) let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        nonisolated(unsafe) let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = formatter.date(from: string) { return date }
            if let date = fallback.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(string)")
        }
        return decoder
    }()

    /// Shared encoder that writes ISO 8601 timestamps for Supabase.
    private let supabaseEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private init() {
        self.baseURL = URL(string: SupabaseConfig.url)!
        self.apiKey = SupabaseConfig.anonKey

        restoreSessionFromStorage()
    }

    private func restoreSessionFromStorage() {
        guard let token = defaults.string(forKey: accessTokenKey), !token.isEmpty else {
            accessToken = nil
            currentUser = nil
            isAuthenticated = false
            isAuthResolved = true
            return
        }

        accessToken = token
        isAuthenticated = true
        isAuthResolved = false

        Task {
            await loadCurrentUser()
            isAuthResolved = true
        }
    }
    
    // MARK: - Authentication

    private struct SupabaseAuthErrorResponse: Decodable {
        let error: String?
        let errorDescription: String?
        let msg: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
            case msg
        }
    }

    private struct AppleIDTokenClaims: Decodable {
        let sub: String?
        let email: String?
        let name: String?
        let givenName: String?
        let familyName: String?

        enum CodingKeys: String, CodingKey {
            case sub
            case email
            case name
            case givenName = "given_name"
            case familyName = "family_name"
        }
    }

    private func decodeAppleIDTokenClaims(from idToken: String) -> AppleIDTokenClaims? {
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = 4 - (payload.count % 4)
        if padding < 4 {
            payload += String(repeating: "=", count: padding)
        }

        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONDecoder().decode(AppleIDTokenClaims.self, from: data)
    }

    private func authError(from data: Data, statusCode: Int) -> SupabaseError {
        if let decoded = try? JSONDecoder().decode(SupabaseAuthErrorResponse.self, from: data) {
            let message = decoded.errorDescription ?? decoded.msg ?? decoded.error
            if let message, !message.isEmpty {
                return .authFailed("Apple sign-in failed: \(message)")
            }
        }
        return .authFailed("Apple sign-in failed with status \(statusCode)")
    }
    
    /// Sign in with Apple credentials
    func signInWithApple(credentials: AppleSignInCredentials) async throws {
        isLoading = true
        isAuthResolved = false
        errorMessage = nil
        
        defer {
            isLoading = false
            isAuthResolved = true
        }
        
        guard let idToken = credentials.identityTokenString else {
            throw SupabaseError.invalidCredentials
        }
        let tokenClaims = decodeAppleIDTokenClaims(from: idToken)
        
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
            let authResponse = try supabaseDecoder.decode(AuthResponse.self, from: data)
            guard let userId = UUID(uuidString: authResponse.user.id) else {
                throw SupabaseError.invalidCredentials
            }
            
            // Store tokens
            accessToken = authResponse.accessToken
            defaults.set(authResponse.accessToken, forKey: accessTokenKey)
            defaults.set(authResponse.refreshToken, forKey: refreshTokenKey)
            defaults.set(authResponse.user.id, forKey: userIdKey)

            do {
                // Ensure profile exists and is readable before finalizing auth state.
                print("[SupabaseManager] Auth succeeded for userId: \(userId). Updating profile...")
                try await updateProfileWithAppleData(
                    credentials: credentials,
                    tokenClaims: tokenClaims,
                    authUser: authResponse.user,
                    userId: userId
                )
                print("[SupabaseManager] Profile updated. Fetching profile...")

                let profile = try await fetchProfile(userId: userId)
                print("[SupabaseManager] Profile fetched: \(profile.email ?? "no email")")
                currentUser = profile
                isAuthenticated = true
            } catch {
                print("[SupabaseManager] Post-auth profile setup FAILED: \(error)")
                signOut()
                throw SupabaseError.authFailed("Unable to complete account setup: \(error.localizedDescription)")
            }
        } else {
            throw authError(from: data, statusCode: httpResponse.statusCode)
        }
    }
    
    /// Sign out current user
    func signOut() {
        accessToken = nil
        currentUser = nil
        isAuthenticated = false
        isAuthResolved = true
        
        defaults.removeObject(forKey: accessTokenKey)
        defaults.removeObject(forKey: refreshTokenKey)
        defaults.removeObject(forKey: userIdKey)
    }
    
    /// Load current user profile
    func loadCurrentUser() async {
        guard let userId = defaults.string(forKey: userIdKey),
              let uuid = UUID(uuidString: userId) else {
            signOut()
            return
        }
        
        do {
            let profile = try await fetchProfile(userId: uuid)
            currentUser = profile
        } catch let supabaseError as SupabaseError {
            switch supabaseError {
            case .notFound:
                do {
                    let profile = try await bootstrapProfileFromSession(userId: uuid)
                    currentUser = profile
                    isAuthenticated = true
                } catch {
                    print("Profile missing and bootstrap failed: \(error)")
                    errorMessage = "Your session is no longer valid. Please sign in again."
                    signOut()
                }
            case .unauthorized:
                print("Profile missing or unauthorized. Signing out local session.")
                errorMessage = "Your session is no longer valid. Please sign in again."
                signOut()
            default:
                print("Failed to load user profile: \(supabaseError)")
            }
        } catch {
            print("Failed to load user profile: \(error)")
        }
    }

    /// Revalidates profile/session state while app is running.
    ///
    /// **Important:** This must NOT toggle `isAuthResolved` to `false`.
    /// Doing so causes ContentView to momentarily swap HomeView for
    /// SplashLoadingView, destroying all @State in HomeView (cached
    /// data, cooldown timestamps, hasLoadedOnce). When the session
    /// check finishes, a brand-new HomeView is created — forcing a
    /// full skeleton reload every time the user returns from background.
    func refreshSessionIfNeeded() async {
        // Don't interfere with an active sign-in flow.
        guard !isLoading else { return }

        guard accessToken != nil else {
            signOut()
            return
        }

        // Silently re-validate — keep isAuthResolved=true so the
        // existing HomeView stays mounted and preserves its state.
        await loadCurrentUser()
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
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw SupabaseError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.networkError
        }

        let profiles = try supabaseDecoder.decode([UserProfile].self, from: data)
        
        guard let profile = profiles.first else {
            throw SupabaseError.notFound
        }
        
        return profile
    }

    /// Insert or update a profile row by primary key
    private func upsertProfile(_ profile: UserProfile) async throws {
        let url = baseURL.appendingPathComponent("rest/v1/profiles")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body = try supabaseEncoder.encode(profile)
        request.httpBody = body
        
        print("[SupabaseManager] Upsert profile body: \(String(data: body, encoding: .utf8) ?? "nil")")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            print("[SupabaseManager] Upsert: no HTTP response")
            throw SupabaseError.upsertFailed
        }
        
        let responseBody = String(data: data, encoding: .utf8) ?? "nil"
        print("[SupabaseManager] Upsert response: \(httpResponse.statusCode) — \(responseBody)")
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.upsertFailed
        }

        currentUser = profile
    }

    /// Fetch authenticated user identity from Supabase Auth API.
    private func fetchAuthenticatedUserIdentity() async throws -> AuthUser {
        guard let accessToken else { throw SupabaseError.unauthorized }

        let url = baseURL.appendingPathComponent("auth/v1/user")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw SupabaseError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.networkError
        }

        return try supabaseDecoder.decode(AuthUser.self, from: data)
    }

    /// Rebuild a missing profile row from authenticated user identity data.
    private func bootstrapProfileFromSession(userId: UUID) async throws -> UserProfile {
        let authUser = try await fetchAuthenticatedUserIdentity()

        let fullName = authUser.userMetadata?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let givenName = authUser.userMetadata?.givenName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let familyName = authUser.userMetadata?.familyName?.trimmingCharacters(in: .whitespacesAndNewlines)

        let profile = UserProfile(
            id: userId,
            appleUserId: authUser.userMetadata?.sub,
            email: authUser.email?.lowercased(),
            fullName: (fullName?.isEmpty == false ? fullName : nil),
            givenName: (givenName?.isEmpty == false ? givenName : nil),
            familyName: (familyName?.isEmpty == false ? familyName : nil),
            username: nil,
            avatarUrl: nil,
            preferredTheme: nil,
            notificationsEnabled: nil,
            createdAt: nil,
            updatedAt: nil,
            lastLoginAt: Date()
        )

        try await upsertProfile(profile)
        return try await fetchProfile(userId: userId)
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
        
        request.httpBody = try supabaseEncoder.encode(profile)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.updateFailed
        }
        
        currentUser = profile
    }
    
    /// Update profile with Apple Sign-In data
    private func updateProfileWithAppleData(
        credentials: AppleSignInCredentials,
        tokenClaims: AppleIDTokenClaims?,
        authUser: AuthUser,
        userId: UUID
    ) async throws {
        let existingProfile: UserProfile?
        if let currentUser, currentUser.id == userId {
            existingProfile = currentUser
        } else {
            existingProfile = try? await fetchProfile(userId: userId)
        }

        let appleFullName = credentials.fullName?.formatted().trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFullName = (appleFullName?.isEmpty == false ? appleFullName : nil)

        let resolvedEmail = (
            credentials.email
            ?? tokenClaims?.email
            ?? authUser.email
            ?? existingProfile?.email
        )?.lowercased()

        let resolvedGivenName = credentials.fullName?.givenName
            ?? tokenClaims?.givenName
            ?? authUser.userMetadata?.givenName
            ?? existingProfile?.givenName

        let resolvedFamilyName = credentials.fullName?.familyName
            ?? tokenClaims?.familyName
            ?? authUser.userMetadata?.familyName
            ?? existingProfile?.familyName

        let combinedNameFromParts: String? = {
            let parts = [resolvedGivenName, resolvedFamilyName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: " ")
        }()

        let resolvedAppleUserId = credentials.userId.isEmpty
            ? (tokenClaims?.sub ?? existingProfile?.appleUserId)
            : credentials.userId

        let profile = UserProfile(
            id: userId,
            appleUserId: resolvedAppleUserId,
            email: resolvedEmail,
            fullName: resolvedFullName
                ?? tokenClaims?.name
                ?? authUser.userMetadata?.fullName
                ?? combinedNameFromParts
                ?? existingProfile?.fullName,
            givenName: resolvedGivenName,
            familyName: resolvedFamilyName,
            username: existingProfile?.username,
            avatarUrl: existingProfile?.avatarUrl,
            preferredTheme: existingProfile?.preferredTheme,
            notificationsEnabled: existingProfile?.notificationsEnabled,
            createdAt: existingProfile?.createdAt,
            updatedAt: existingProfile?.updatedAt,
            lastLoginAt: Date()
        )
        
        try await upsertProfile(profile)
    }
    
    // MARK: - Analytics
    
    /// Log a route interaction for analytics
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
        
        guard let userId = defaults.string(forKey: userIdKey), !userId.isEmpty else {
            print("Skipping route interaction insert: missing authenticated user_id")
            return
        }
        body["user_id"] = userId
        
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
        return try supabaseDecoder.decode([CloudFavorite].self, from: data)
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
        
        // Build a minimal insert payload — omit server-generated fields
        // (id, created_at, updated_at) so Supabase uses its defaults
        var payload: [String: Any] = [
            "user_id": favorite.userId.uuidString,
            "route_id": favorite.routeId,
            "route_display_name": favorite.routeDisplayName,
            "stop_id": favorite.stopId,
            "stop_name": favorite.stopName,
            "mode": favorite.mode,
            "display_order": favorite.displayOrder ?? 0
        ]
        if let direction = favorite.direction { payload["direction"] = direction }
        if let destination = favorite.destination { payload["destination"] = destination }
        if let lat = favorite.stopLat { payload["stop_lat"] = lat }
        if let lon = favorite.stopLon { payload["stop_lon"] = lon }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            print("[SupabaseManager] addFavorite failed: \(body)")
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
        return try supabaseDecoder.decode([CloudSchedule].self, from: data)
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
        
        request.httpBody = try supabaseEncoder.encode(schedule)
        
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
    
    // MARK: - User Settings
    
    /// Fetch user settings from Supabase
    func fetchUserSettings() async throws -> CloudUserSettings? {
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
        let results = try supabaseDecoder.decode([CloudUserSettings].self, from: data)
        return results.first
    }
    
    /// Save user settings to Supabase (upsert)
    func saveUserSettings(_ settings: CloudUserSettings) async throws {
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
        
        request.httpBody = try supabaseEncoder.encode(settings)
        
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
        
        request.httpBody = try supabaseEncoder.encode(pattern)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.upsertFailed
        }
    }
    
    /// Fetch commute patterns from cloud
    func fetchCommutePatterns() async throws -> [CloudCommutePattern] {
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
        
        return try supabaseDecoder.decode([CloudCommutePattern].self, from: data)
    }
}
