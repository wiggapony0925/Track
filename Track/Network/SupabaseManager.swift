// Manages all Supabase interactions including authentication,
// database operations, and data synchronization.
// Setup:
// 1. Add Supabase SDK: File > Add Packages > https://github.com/supabase-community/supabase-swift
// 2. Configure credentials below or in environment

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
        guard let url = Bundle.main.object(
            forInfoDictionaryKey: "SUPABASE_URL"
        ) as? String, !url.isEmpty else {
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
        guard let key = Bundle.main.object(
            forInfoDictionaryKey: "SUPABASE_ANON_KEY"
        ) as? String, !key.isEmpty else {
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
    private var accessToken: String? {
        didSet { TrackAPI.setCachedAccessToken(accessToken) }
    }

    /// Dedicated session with a 15-second timeout (vs URLSession.shared's 60s default).
    /// Prevents Supabase calls from hanging the UI when the server is slow or unreachable.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()
    
    // Keychain keys for sensitive tokens
    private let accessTokenKey = "supabase_access_token"
    private let refreshTokenKey = "supabase_refresh_token"
    // UserDefaults key for non-sensitive user ID
    private let userIdKey = "supabase_user_id"

    /// Coalesces concurrent token-refresh attempts into a single network call.
    /// When multiple callers `await` this while a refresh is already in flight,
    /// they all share the same result instead of each firing their own request.
    private var activeRefreshTask: Task<Bool, Never>?
    
    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
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
    nonisolated private static func parseISO8601Date(_ string: String) -> Date? {
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
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(string)"
            )
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
        // Gracefully handle invalid URLs instead of crashing in release.
        // If the URL is malformed the app will show network errors rather
        // than terminating with a fatalError — much better UX for users.
        let urlString = SupabaseConfig.url
        guard let url = URL(string: urlString) else {
            #if DEBUG
            fatalError(
                "[SupabaseManager] Invalid SUPABASE_URL: " +
                "'\(urlString)'. Check Info.plist configuration."
            )
            #else
            AppLogger.shared.logError("SupabaseManager.init", error: NSError(
                domain: "SupabaseManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid SUPABASE_URL: '\(urlString)'"]
            ))
            // Fall back to the production URL so the app doesn't crash.
            self.baseURL = URL(string: "https://octpebjxadbufiplgjqg.supabase.co")!
            self.apiKey = SupabaseConfig.anonKey
            migrateTokensToKeychainIfNeeded()
            restoreSessionFromStorage()
            return
            #endif
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
        
        let (data, response) = try await session.data(for: request)
        
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
                AppLogger.shared.log(
                    "AUTH",
                    message: "Auth succeeded for userId: \(userId). Updating profile..."
                )
                try await updateProfileWithAppleData(
                    credentials: credentials,
                    tokenClaims: tokenClaims,
                    authUser: authResponse.user,
                    userId: userId
                )
                AppLogger.shared.log("AUTH", message: "Profile updated. Fetching profile...")

                let profile = try await fetchProfile(userId: userId)
                AppLogger.shared.log(
                    "AUTH",
                    message: "Profile fetched: \(profile.email ?? "no email")"
                )
                currentUser = profile
                isAuthenticated = true
            } catch {
                AppLogger.shared.logError("Post-auth profile setup", error: error)
                signOut()
                throw SupabaseError.authFailed(
                    "Unable to complete account setup: \(error.localizedDescription)"
                )
            }
        } else {
            throw authError(from: data, statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Email / Password

    /// Sign in with email + password against Supabase Auth.
    func signInWithEmail(email: String, password: String) async throws {
        try await performEmailAuth(
            path: "auth/v1/token",
            queryItems: [URLQueryItem(name: "grant_type", value: "password")],
            body: ["email": email.lowercased(), "password": password],
            failurePrefix: "Sign-in failed"
        )
    }

    /// Create a new account with email + password and sign in immediately.
    /// Supabase returns a session if email confirmation is disabled; if it
    /// requires confirmation we surface a friendly message instead.
    func signUpWithEmail(
        email: String,
        password: String,
        fullName: String?
    ) async throws {
        var body: [String: Any] = [
            "email": email.lowercased(),
            "password": password,
        ]
        if let fullName = fullName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fullName.isEmpty {
            body["data"] = ["full_name": fullName]
        }

        try await performEmailAuth(
            path: "auth/v1/signup",
            queryItems: [],
            body: body,
            failurePrefix: "Sign-up failed",
            displayName: fullName
        )
    }

    /// Shared transport + session-finalisation logic for the email
    /// sign-in and sign-up endpoints. Both return the same
    /// `AuthResponse` shape on success.
    private func performEmailAuth(
        path: String,
        queryItems: [URLQueryItem],
        body: [String: Any],
        failurePrefix: String,
        displayName: String? = nil
    ) async throws {
        isLoading = true
        isAuthResolved = false
        errorMessage = nil

        defer {
            isLoading = false
            isAuthResolved = true
        }

        let url = try components(for: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }

        guard httpResponse.statusCode == 200 else {
            // Surface the Supabase-provided message when present.
            if let decoded = try? JSONDecoder()
                .decode(SupabaseAuthErrorResponse.self, from: data) {
                let message = decoded.errorDescription ?? decoded.msg ?? decoded.error
                if let message, !message.isEmpty {
                    throw SupabaseError.authFailed("\(failurePrefix): \(message)")
                }
            }
            throw SupabaseError.authFailed(
                "\(failurePrefix) (status \(httpResponse.statusCode))"
            )
        }

        // Sign-up with email-confirmation enabled returns a 200 with no
        // session and a `user` payload only. Detect that shape and
        // bubble it back so the UI can show a "check your inbox" state.
        let decoded: AuthResponse
        do {
            decoded = try supabaseDecoder.decode(AuthResponse.self, from: data)
        } catch {
            // Likely the no-session sign-up confirmation flow.
            throw SupabaseError.authFailed(
                "Check your inbox to confirm your email, then sign in."
            )
        }

        guard let userId = UUID(uuidString: decoded.user.id) else {
            throw SupabaseError.invalidCredentials
        }

        accessToken = decoded.accessToken
        KeychainHelper.set(decoded.accessToken, forKey: accessTokenKey)
        KeychainHelper.set(decoded.refreshToken, forKey: refreshTokenKey)
        defaults.set(decoded.user.id, forKey: userIdKey)

        do {
            // Best-effort profile bootstrap — for sign-in we usually have
            // a row already; for sign-up we seed name + email.
            try await ensureEmailProfile(
                userId: userId,
                authUser: decoded.user,
                displayName: displayName
            )
            let profile = try await fetchProfile(userId: userId)
            currentUser = profile
            isAuthenticated = true
        } catch {
            AppLogger.shared.logError("Post-auth profile setup", error: error)
            signOut()
            throw SupabaseError.authFailed(
                "Unable to complete account setup: \(error.localizedDescription)"
            )
        }
    }

    /// Best-effort profile upsert for the email auth path. Mirrors what
    /// `updateProfileWithAppleData` does, but with only the email + an
    /// optional display name available.
    private func ensureEmailProfile(
        userId: UUID,
        authUser: AuthUser,
        displayName: String?
    ) async throws {
        let existing = await resolveExistingProfile(userId: userId)

        let cleanedName: String? = {
            let trimmed = displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed
        }()
        let parts = cleanedName?.split(separator: " ", maxSplits: 1).map(String.init) ?? []
        let given = parts.first ?? existing?.givenName
        let family = parts.count > 1 ? parts.last : existing?.familyName

        let profile = UserProfile(
            id: userId,
            appleUserId: existing?.appleUserId,
            email: (authUser.email ?? existing?.email)?.lowercased(),
            fullName: cleanedName ?? existing?.fullName,
            givenName: given,
            familyName: family,
            username: existing?.username,
            avatarUrl: existing?.avatarUrl,
            preferredTheme: existing?.preferredTheme,
            notificationsEnabled: existing?.notificationsEnabled,
            createdAt: existing?.createdAt,
            updatedAt: existing?.updatedAt,
            lastLoginAt: Date()
        )

        try await upsertProfile(profile)
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
                    AppLogger.shared.log(
                        "AUTH",
                        message: "Unauthorized and refresh failed. Signing out."
                    )
                    errorMessage = "Your session is no longer valid. Please sign in again."
                    signOut()
                    return
                }
                AppLogger.shared.log(
                    "AUTH",
                    message: "Token refreshed successfully, retrying profile fetch"
                )
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
    ///
    /// Concurrent callers are coalesced: if a refresh is already in flight,
    /// subsequent callers await the same result instead of firing duplicate
    /// network requests (which would consume the single-use refresh token).
    private func refreshAccessToken() async -> Bool {
        // If a refresh is already in flight, piggy-back on it.
        if let existing = activeRefreshTask {
            AppLogger.shared.log("AUTH", message: "Token refresh already in flight — coalescing")
            return await existing.value
        }

        let task = Task<Bool, Never> {
            defer { activeRefreshTask = nil }
            return await performTokenRefresh()
        }
        activeRefreshTask = task
        return await task.value
    }

    /// The actual network call for token refresh, separated so the
    /// coalescing wrapper in `refreshAccessToken()` stays clean.
    private func performTokenRefresh() async -> Bool {
        guard let refreshToken = KeychainHelper.get(refreshTokenKey), !refreshToken.isEmpty else {
            AppLogger.shared.log("AUTH", message: "No refresh token available")
            return false
        }

        let url = baseURL.appendingPathComponent("auth/v1/token")
        guard var components = URLComponents(
            url: url, resolvingAgainstBaseURL: false
        ) else { return false }
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
            let (data, response) = try await session.data(for: request)
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
        
        let (data, response) = try await session.data(for: request)
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

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            AppLogger.shared.log("SUPABASE", message: "Upsert: no HTTP response")
            throw SupabaseError.upsertFailed
        }
        
        let responseBody = String(data: data, encoding: .utf8) ?? "nil"
        AppLogger.shared.log(
            "SUPABASE",
            message: "Upsert response: \(httpResponse.statusCode) — \(responseBody)"
        )
        
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

        let (data, response) = try await session.data(for: request)
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

        let fullName = authUser.userMetadata?.fullName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let givenName = authUser.userMetadata?.givenName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let familyName = authUser.userMetadata?.familyName?
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
        
        let (_, response) = try await session.data(for: request)
        
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
        let existingProfile: UserProfile? = await resolveExistingProfile(userId: userId)
        let resolved: ResolvedAppleProfile = resolveAppleFields(
            credentials: credentials,
            tokenClaims: tokenClaims,
            authUser: authUser,
            existingProfile: existingProfile
        )

        let profile = UserProfile(
            id: userId,
            appleUserId: resolved.appleUserId,
            email: resolved.email,
            fullName: resolved.fullName,
            givenName: resolved.givenName,
            familyName: resolved.familyName,
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

    private func resolveExistingProfile(userId: UUID) async -> UserProfile? {
        if let currentUser, currentUser.id == userId {
            return currentUser
        }
        return try? await fetchProfile(userId: userId)
    }

    /// Pure resolution of Apple Sign-In fields with nil-coalescing fallback chains.
    /// Extracted to reduce type-checker pressure on `updateProfileWithAppleData`.
    private struct ResolvedAppleProfile {
        let email: String?
        let givenName: String?
        let familyName: String?
        let fullName: String?
        let appleUserId: String?
    }

    private func resolveAppleFields(
        credentials: AppleSignInCredentials,
        tokenClaims: AppleIDTokenClaims?,
        authUser: AuthUser,
        existingProfile: UserProfile?
    ) -> ResolvedAppleProfile {
        let appleFullName: String? = credentials.fullName?
            .formatted()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFullName: String? = (appleFullName?.isEmpty == false ? appleFullName : nil)

        // Break email chain into explicit steps to reduce type-checker load
        let credEmail: String? = credentials.email
        let claimEmail: String? = tokenClaims?.email
        let authEmail: String? = authUser.email
        let profileEmail: String? = existingProfile?.email
        let email: String? = (credEmail ?? claimEmail ?? authEmail ?? profileEmail)?.lowercased()

        // Break givenName chain
        let credGiven: String? = credentials.fullName?.givenName
        let claimGiven: String? = tokenClaims?.givenName
        let metaGiven: String? = authUser.userMetadata?.givenName
        let profileGiven: String? = existingProfile?.givenName
        let givenName: String? = credGiven ?? claimGiven ?? metaGiven ?? profileGiven

        // Break familyName chain
        let credFamily: String? = credentials.fullName?.familyName
        let claimFamily: String? = tokenClaims?.familyName
        let metaFamily: String? = authUser.userMetadata?.familyName
        let profileFamily: String? = existingProfile?.familyName
        let familyName: String? = credFamily ?? claimFamily ?? metaFamily ?? profileFamily

        let combinedNameFromParts: String? = {
            let parts: [String] = [givenName, familyName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: " ")
        }()

        let appleUserId: String? = credentials.userId.isEmpty
            ? (tokenClaims?.sub ?? existingProfile?.appleUserId)
            : credentials.userId

        // Break fullName chain
        let claimName: String? = tokenClaims?.name
        let metaName: String? = authUser.userMetadata?.fullName
        let profileName: String? = existingProfile?.fullName
        let finalFullName: String? =
            resolvedFullName ?? claimName ?? metaName
            ?? combinedNameFromParts ?? profileName

        return ResolvedAppleProfile(
            email: email,
            givenName: givenName,
            familyName: familyName,
            fullName: finalFullName,
            appleUserId: appleUserId
        )
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
            AppLogger.shared.log(
                "ANALYTICS",
                message: "Skipping route interaction insert: missing authenticated user_id"
            )
            return
        }
        body["user_id"] = userId
        
        if let lat = latitude, let lon = longitude {
            body["latitude"] = lat
            body["longitude"] = lon
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, _) = try await session.data(for: request)
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
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw SupabaseError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.networkError
        }
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
        
        let (data, response) = try await session.data(for: request)
        
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
        
        let (_, response) = try await session.data(for: request)
        
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
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw SupabaseError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.networkError
        }
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
        
        let (_, response) = try await session.data(for: request)
        
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
        
        let (_, response) = try await session.data(for: request)
        
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
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw SupabaseError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.networkError
        }
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
        request.setValue(
            "return=representation,resolution=merge-duplicates",
            forHTTPHeaderField: "Prefer"
        )
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = try supabaseEncoder.encode(settings)
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
            AppLogger.shared.log(
                "SUPABASE",
                message: "saveUserSettings failed — HTTP \(statusCode): \(body)"
            )
            throw SupabaseError.upsertFailed
        }
    }

    // MARK: - Trip Configurations

    /// Fetch the user's trip configuration from Supabase.
    func fetchTripConfiguration() async throws -> CloudTripConfiguration? {
        guard let userId = currentUser?.id else { return nil }

        let finalURL = try components(for: "rest/v1/trip_configurations", queryItems: [
            URLQueryItem(name: "user_id", value: "eq.\(userId.uuidString)"),
            URLQueryItem(name: "select", value: "user_id,priority,mode_subway,mode_bus,mode_lirr,mode_mnr,accessibility_priority,walk_preference")
        ])

        var request = URLRequest(url: finalURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw SupabaseError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.networkError
        }
        let results = try supabaseDecoder.decode([CloudTripConfiguration].self, from: data)
        return results.first
    }

    /// Save (upsert) the user's trip configuration to Supabase.
    func saveTripConfiguration(_ config: CloudTripConfiguration) async throws {
        guard currentUser != nil else { throw SupabaseError.unauthorized }

        let url = baseURL.appendingPathComponent("rest/v1/trip_configurations")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue(
            "return=representation,resolution=merge-duplicates",
            forHTTPHeaderField: "Prefer"
        )
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try supabaseEncoder.encode(config)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
            AppLogger.shared.log(
                "SUPABASE",
                message: "saveTripConfiguration failed — HTTP \(statusCode): \(body)"
            )
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
        request.setValue(
            "return=representation,resolution=merge-duplicates",
            forHTTPHeaderField: "Prefer"
        )
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
        
        let (_, response) = try await session.data(for: request)
        
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
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw SupabaseError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseError.networkError
        }
        
        return try supabaseDecoder.decode([CloudCommutePattern].self, from: data)
    }
}
