// HoverAnimations.swift
// AutomaticHover — canonical animation presets for camera transitions.
//
// This is the single source of truth for every Spring/easeInOut timing
// value used when the camera moves.  MapCameraPresets.flyAnimation etc.
// are now deprecated aliases that forward here, so no call site in the
// existing codebase needs to change immediately.
//
// Naming convention:
//   .fly    — long arcing animation (route open, vehicle focus, direction change)
//   .snap   — short snappy animation (recenter button, sheet-driven recenters)
//   .smooth — long easeInOut (3D toggle, Explore NYC button)
//   .gentle — slow spring for passive tracking (transit-speed follow)

import SwiftUI

// MARK: - HoverAnimations

/// Canonical camera transition animations for the AutomaticHover system.
///
/// All values are tuned to match the inertia of MapLibre's native momentum
/// scrolling so programmatic moves feel continuous with gesture-driven ones.
enum HoverAnimations {

    // MARK: - Presets

    /// Standard fly animation for significant camera changes.
    ///
    /// Used for: route open, vehicle focus, direction change, drag-search reset.
    /// Spring: response 0.6 s, damping 0.85 (gentle overshoot, settles fast).
    static let fly: Animation = .spring(response: 0.6, dampingFraction: 0.85)

    /// Snappy animation for lightweight recenters.
    ///
    /// Used for: recenter button tap, sheet-collapse-triggered camera snap.
    /// Spring: response 0.4 s, damping 0.8 (minimal overshoot).
    static let snap: Animation = .spring(response: 0.4, dampingFraction: 0.8)

    /// Long smooth animation for mode transitions.
    ///
    /// Used for: 3D toggle, Explore NYC overview, initial app load.
    /// easeInOut: 0.8 s — feels cinematic, not mechanical.
    static let smooth: Animation = .easeInOut(duration: 0.8)

    /// Gentle passive-tracking animation for transit-speed GPS follow.
    ///
    /// Used for: `recenterOnUser()` while aboard a vehicle.
    /// Spring: response 0.6 s, damping 0.85 — same curve as fly but
    /// semantically distinct so it can be tuned independently.
    static let gentle: Animation = .spring(response: 0.6, dampingFraction: 0.85)

    /// Route-fitting animation — fly from current position to show route + user.
    ///
    /// Used for: initial route open, `onRecenter` inside route detail sheet.
    static let routeFit: Animation = .spring(response: 0.55, dampingFraction: 0.85)
}
