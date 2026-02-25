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
        guard let url = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String, !url.isEmpty else {
            #if DEBUG
            // Development fallback — NEVER ships in release builds
            return "https://octpebjxadbufiplgjqg.supabase.co"
            #else
            fatalError("SUPABASE_URL missing from Info.plist. Add it via build configuration.")
            #endif
        }
        return url
    }

    static var anonKey: String {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String, !key.isEmpty else {
            #if DEBUG
            // Development fallback — NEVER ships in release builds
            return "sb_publishable_lAEZ_x8O4vjdGaw-I-QUMg_oS5iWKIn"
            #else
            fatalError("SUPABASE_ANON_KEY missing from Info.plist. Add it via build configuration.")
            #endif
        }
        return key
    }
}

// MARK: - Supabase Manager

/// Singleton manager for all Supabase operations
@MainActor
class SupabaseManager: ObservableObject {
    static let shared = SupabaseManager()
    
    // MARK: - Published State
    
    @Published var currentUser: UserProfile? {
        didSet { TrackAPI.setCachedEmail(currentUser?.email) }
    }
    @Published var isAuthenticated = false
    @Published var isAuthResolved = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // MARK: - Private Properties
    
    private let baseURL: URL
    private let apiKey: String
    private var accessToken: String?
    
    // Keychain keys for sensitive tokens
    private let accessTokenKey = "supabase_access_token"
    private let refreshTokenKey = "supabase_refresh_token"
    // UserDefaults key for non-sensitive user ID
    private let userIdKey = "supabase_user_id"
    
    private var defaults: UserDefaults {
        UserDefaults(suiteName: kAppGroupIdentifier) ?? .standard
    }
    
    // MARK: - URL Helpers
    
    /// Safely builds URLComponents for a Supabase REST endpoint.
    /// Throws `SupabaseError.networkError` instead of force-unwrapping.
    private func components(for path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let url = baseURL.appendingPathComponent(path)
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SupabaseError.networkError
        }
        if !queryItems.isEmpty { comps.queryItems = queryItems }
        guard let final = comps.url else { throw SupabaseError.networkError }
        return final
    }
    
    // MARK: - Initialization
    
    /// Thread-safe ISO 8601 date parsing for Supabase timestamps.
    private static func parseISO8601Date(_ string: String) -> Date? {
        // ISO8601DateFormatter is not thread-safe, so create per-call.
        // These are only used during JSON decoding which is infrequent.
        let primary = ISO8601DateFormatter()
        primary.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = primary.date(from: string) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }

    /// Shared decoder that handles Supabase ISO 8601 timestamps with fractional seconds.
    private let supabaseDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = SupabaseManager.parseISO8601Date(string) { return date }
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
        guard let url = URL(string: SupabaseConfig.url) else {
            fatalError("[SupabaseManager] Invalid SUPABASE_URL: '\(SupabaseConfig.url)'. Check Info.plist configuration.")
        }
        self.baseURL = url
        self.apiKey = SupabaseConfig.anonKey

        migrateTokensToKeychainIfNeeded()
        restoreSessionFromStorage()
    }

    /// One-time migration: move tokens from UserDefaults to Keychain.
    private func migrateTokensToKeychainIfNeeded() {
        // Check if tokens are still in UserDefaults (legacy storage)
        if let legacyAccess = defaults.string(forKey: accessTokenKey), !legacyAccess.isEmpty {
            KeychainHelper.set(legacyAccess, forKey: accessTokenKey)
            defaults.removeObject(forKey: accessTokenKey)
        }
        if let legacyRefresh = defaults.string(forKey: refreshTokenKey), !legacyRefresh.isEmpty {
            KeychainHelper.set(legacyRefresh, forKey: refreshTokenKey)
            defaults.removeObject(forKey: refreshTokenKey)
        }
    }

    private func restoreSessionFromStorage() {
        guard let token = KeychainHelper.get(accessTokenKey), !token.isEmpty else {
            accessToken = nil
            currentUser = nil
            isAuthenticated = false
            isAuthResolved = true
            return
        }

        accessToken = token
        isAuthenticated = true
        // Unblock the UI immediately — the token's presence is enough
        // to show HomeView.  Profile validation runs in the background.
        isAuthResolved = true

        Task {
            await loadCurrentUser()
            // If the profile load fails and the token is invalid,
            // loadCurrentUser() will call signOut() which resets state.
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
        let tokenURL = try components(
            for: "auth/v1/token",
            queryItems: [URLQueryItem(name: "grant_type", value: "id_token")]
        )
        
        var request = URLRequest(url: tokenURL)
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
            
            // Store tokens securely in Keychain
            accessToken = authResponse.accessToken
            KeychainHelper.set(authResponse.accessToken, forKey: accessTokenKey)
            KeychainHelper.set(authResponse.refreshToken, forKey: refreshTokenKey)
            defaults.set(authResponse.user.id, forKey: userIdKey)

            do {
                // Ensure profile exists and is readable before finalizing auth state.
                AppLogger.shared.log("AUTH", message: "Auth succeeded for userId: \(userId). Updating profile...")
                try await updateProfileWithAppleData(
                    credentials: credentials,
                    tokenClaims: tokenClaims,
                    authUser: authResponse.user,
                    userId: userId
                )
                AppLogger.shared.log("AUTH", message: "Profile updated. Fetching profile...")

                let profile = try await fetchProfile(userId: userId)
                AppLogger.shared.log("AUTH", message: "Profile fetched: \(profile.email ?? "no email")")
                currentUser = profile
                isAuthenticated = true
            } catch {
                AppLogger.shared.logError("Post-auth profile setup", error: error)
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
        
        KeychainHelper.delete(accessTokenKey)
        KeychainHelper.delete(refreshTokenKey)
        defaults.removeObject(forKey: userIdKey)
    }
    
    /// Load current user profile
    /// - Parameter retryCount: Internal counter to prevent infinite recursion
    ///   when token refresh succeeds but re-fetch is immediately rejected.
    func loadCurrentUser(retryCount: Int = 0) async {
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
                    AppLogger.shared.logError("Profile missing and bootstrap failed", error: error)
                    errorMessage = "Your session is no longer valid. Please sign in again."
                    signOut()
                }
            case .unauthorized:
                // Try refreshing the token before giving up — but only once
                guard retryCount == 0, await refreshAccessToken() else {
                    AppLogger.shared.log("AUTH", message: "Unauthorized and refresh failed. Signing out.")
                    errorMessage = "Your session is no longer valid. Please sign in again."
                    signOut()
                    return
                }
                AppLogger.shared.log("AUTH", message: "Token refreshed successfully, retrying profile fetch")
                await loadCurrentUser(retryCount: retryCount + 1)
            default:
                AppLogger.shared.logError("Failed to load user profile", error: supabaseError)
            }
        } catch {
            AppLogger.shared.logError("Failed to load user profile", error: error)
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

    // MARK: - Token Refresh

    /// Attempts to refresh the access token using the stored refresh token.
    /// Returns `true` if the token was successfully refreshed.
    private func refreshAccessToken() async -> Bool {
        guard let refreshToken = KeychainHelper.get(refreshTokenKey), !refreshToken.isEmpty else {
            AppLogger.shared.log("AUTH", message: "No refresh token available")
            return false
        }

        let url = baseURL.appendingPathComponent("auth/v1/token")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]

        guard let requestURL = components.url else { return false }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")

        let body: [String: String] = ["refresh_token": refreshToken]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                AppLogger.shared.log("AUTH", message: "Token refresh returned non-200")
                return false
            }

            let authResponse = try supabaseDecoder.decode(AuthResponse.self, from: data)
            accessToken = authResponse.accessToken
            KeychainHelper.set(authResponse.accessToken, forKey: accessTokenKey)
            KeychainHelper.set(authResponse.refreshToken, forKey: refreshTokenKey)
            AppLogger.shared.log("AUTH", message: "Access token refreshed successfully")
            return true
        } catch {
            AppLogger.shared.logError("Token refresh", error: error)
            return false
        }
    }

    // MARK: - Profile Operations
    
    /// Fetch user profile from Supabase
    func fetchProfile(userId: UUID) async throws -> UserProfile {
        let profileURL = try components(
            for: "rest/v1/profiles",
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(userId.uuidString)"),
                URLQueryItem(name: "select", value: "*")
            ]
        )
        
        var request = URLRequest(url: profileURL)
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
        
        AppLogger.shared.log("SUPABASE", message: "Upsert profile for \(profile.id.uuidString)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            AppLogger.shared.log("SUPABASE", message: "Upsert: no HTTP response")
            throw SupabaseError.upsertFailed
        }
        
        let responseBody = String(data: data, encoding: .utf8) ?? "nil"
        AppLogger.shared.log("SUPABASE", message: "Upsert response: \(httpResponse.statusCode) — \(responseBody)")
        
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
        let finalURL = try components(for: "rest/v1/profiles", queryItems: [
            URLQueryItem(name: "id", value: "eq.\(profile.id.uuidString)")
        ])
        
        var request = URLRequest(url: finalURL)
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
            AppLogger.shared.log("ANALYTICS", message: "Skipping route interaction insert: missing authenticated user_id")
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
            AppLogger.shared.logError("Route interaction logging", error: error)
        }
    }
    
    // MARK: - Favorites
    
    /// Fetch all favorites for current user
    func fetchFavorites() async throws -> [CloudFavorite] {
        guard let userId = defaults.string(forKey: userIdKey) else {
            return []
        }
        
        let finalURL = try components(for: "rest/v1/favorites", queryItems: [
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "display_order.asc")
        ])
        
        var request = URLRequest(url: finalURL)
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
            AppLogger.shared.log("SUPABASE", message: "addFavorite failed: \(body)")
            throw SupabaseError.insertFailed
        }
    }
    
    /// Remove a favorite
    func removeFavorite(id: Int64) async throws {
        let finalURL = try components(for: "rest/v1/favorites", queryItems: [
            URLQueryItem(name: "id", value: "eq.\(id)")
        ])
        
        var request = URLRequest(url: finalURL)
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
        
        let finalURL = try components(for: "rest/v1/schedules", queryItems: [
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "*")
        ])
        
        var request = URLRequest(url: finalURL)
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
        let finalURL = try components(for: "rest/v1/schedules", queryItems: [
            URLQueryItem(name: "id", value: "eq.\(id.uuidString)")
        ])
        
        var request = URLRequest(url: finalURL)
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
        
        let finalURL = try components(for: "rest/v1/user_settings", queryItems: [
            URLQueryItem(name: "user_id", value: "eq.\(userId.uuidString)"),
            URLQueryItem(name: "select", value: "*")
        ])
        
        var request = URLRequest(url: finalURL)
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
        
        let finalURL = try components(for: "rest/v1/commute_patterns", queryItems: [
            URLQueryItem(name: "user_id", value: "eq.\(userId.uuidString)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "frequency.desc")
        ])
        
        var request = URLRequest(url: finalURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        return try supabaseDecoder.decode([CloudCommutePattern].self, from: data)
    }
}
