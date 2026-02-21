//
//  ChallengeMode.swift
//  Shared
//
//  Swift Student Challenge 2026 offline mode.
//  When enabled, the app runs entirely without network access:
//  - Bypasses login/authentication
//  - Returns mock transit data from TrackAPI
//  - Disables Supabase cloud sync and analytics
//  - Activates all existing offline fallbacks
//
//  Set `isEnabled` to `true` before building for SSC submission.
//  Set it back to `false` for production App Store builds.
//

import Foundation

/// Controls whether the app runs in Swift Student Challenge mode.
/// When enabled, all network calls are replaced with local mock data
/// so the app works fully offline with zero Wi-Fi.
enum ChallengeMode {
    /// Set to `true` for Swift Student Challenge submission.
    /// Set to `false` for production builds.
    ///
    /// ⚠️ IMPORTANT: Remember to set this back to `false` before
    /// submitting to the App Store. When `true`, all live transit
    /// data is replaced with static mock data.
    static let isEnabled = true

    #if !DEBUG
    // Emit a compile-time warning when challenge mode is on in a Release build.
    // This prevents accidentally shipping mock data to the App Store.
    @available(*, deprecated, message: "ChallengeMode is ON — set isEnabled to false for App Store builds")
    private static let _releaseGuard: Void = ()
    #endif
}
