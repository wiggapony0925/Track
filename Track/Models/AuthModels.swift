//
//  AuthModels.swift
//  Track
//
//  Codable model types for Supabase authentication responses.
//  These structs map to the JSON returned by the Supabase Auth API.
//

import Foundation

// MARK: - Auth Response

/// Top-level response from Supabase `auth/v1/token` endpoint
struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String?
    let expiresIn: Int?
    let expiresAt: Int?
    let user: AuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user
    }
}

// MARK: - Auth User

/// User object returned inside `AuthResponse` and from `auth/v1/user`
struct AuthUser: Codable {
    let id: String
    let email: String?
    let phone: String?
    let role: String?
    let aud: String?
    let confirmedAt: String?
    let lastSignInAt: String?
    let createdAt: String?
    let updatedAt: String?
    let userMetadata: AuthUserMetadata?
    let appMetadata: AuthAppMetadata?
    let identities: [AuthIdentity]?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case phone
        case role
        case aud
        case confirmedAt = "confirmed_at"
        case lastSignInAt = "last_sign_in_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case userMetadata = "user_metadata"
        case appMetadata = "app_metadata"
        case identities
    }
}

// MARK: - Auth User Metadata

/// Metadata provided by the identity provider (Apple Sign-In)
struct AuthUserMetadata: Codable {
    let sub: String?
    let email: String?
    let fullName: String?
    let givenName: String?
    let familyName: String?
    let emailVerified: Bool?
    let phoneVerified: Bool?
    let issuer: String?
    let providerID: String?

    enum CodingKeys: String, CodingKey {
        case sub
        case email
        case fullName = "full_name"
        case givenName = "given_name"
        case familyName = "family_name"
        case emailVerified = "email_verified"
        case phoneVerified = "phone_verified"
        case issuer = "iss"
        case providerID = "provider_id"
    }
}

// MARK: - Auth App Metadata

/// App-level metadata managed by Supabase
struct AuthAppMetadata: Codable {
    let provider: String?
    let providers: [String]?

    enum CodingKeys: String, CodingKey {
        case provider
        case providers
    }
}

// MARK: - Auth Identity

/// A linked identity (e.g., Apple) on the auth user
struct AuthIdentity: Codable {
    let id: String?
    let identityID: String?
    let userID: String?
    let provider: String?
    let lastSignInAt: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case identityID = "identity_id"
        case userID = "user_id"
        case provider
        case lastSignInAt = "last_sign_in_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
