// CameraHoverEngine.swift
// AutomaticHover — single resolution point for all camera hover intents.
//
// Architecture:
//   HoverTarget (intent)
//       ↓  CameraHoverEngine.resolve(_:is3D:)
//   TrackCameraPosition (bounds-validated)
//       ↓  MapLibreCameraState (zoom math)
//   MapLibre GL renderer
//
// CameraHoverEngine delegates geometry computation to MapCameraPresets
// (the existing, tested math layer) and applies HoverBounds clamping on top.
// This means:
//   • Zero duplication of bounding-box / padding arithmetic.
//   • Every camera change in the app enforces NYC metro bounds automatically.
//   • Callers express semantic intent — not raw TrackCamera construction.
//
// Usage:
//   let pos = CameraHoverEngine.resolve(.vehicle(at: coord), is3D: false)
//   withAnimation(HoverAnimations.fly) { cameraPosition = pos }

import CoreLocation
import Foundation
import SwiftUI

// MARK: - CameraHoverEngine

/// Resolves a `HoverTarget` to a bounds-validated `TrackCameraPosition`.
///
/// All public methods are O(1) pure functions — safe to call on the main thread
/// during layout or from within `withAnimation` blocks.
enum CameraHoverEngine {

    // MARK: - Primary Resolution

    /// Resolves a hover target to a bounds-validated camera position.
    ///
    /// - Parameters:
    ///   - target: Semantic description of where the camera should go.
    ///   - is3D: Pass `true` to apply a 60° pitch (3D perspective mode).
    /// - Returns: A `TrackCameraPosition` whose center and altitude are
    ///   guaranteed to be within `HoverBounds`.
    static func resolve(_ target: HoverTarget, is3D: Bool = false) -> TrackCameraPosition {
        let raw = rawPosition(for: target, is3D: is3D)
        return validated(raw)
    }

    /// Shorthand: resolve and immediately animate into a binding.
    ///
    /// Combines the common `withAnimation { cameraPosition = ... }` pattern
    /// into a single call, ensuring bounds validation is never skipped.
    ///
    /// - Parameters:
    ///   - target: Where the camera should go.
    ///   - is3D: 3D perspective flag.
    ///   - animation: SwiftUI animation to apply. Defaults to `HoverAnimations.fly`.
    ///   - binding: The `cameraPosition` binding to update.
    static func hover(
        to target: HoverTarget,
        is3D: Bool = false,
        animation: Animation = HoverAnimations.fly,
        updating binding: Binding<TrackCameraPosition>
    ) {
        let position = resolve(target, is3D: is3D)
        commit(position, animation: animation, to: binding)
    }

    // MARK: - Coalesced commit (THE single write point)

    /// Priority of an incoming commit.  User-initiated taps always win,
    /// system writes (sheet/onChange handlers) coalesce.
    enum CommitSource {
        /// Explicit user action — always applied (recenter button, chip tap).
        case user
        /// Background reaction (sheet detent change, onChange handler).
        case system
    }

    /// Time of the most recent successful commit (CFAbsoluteTime).
    /// Read/written from the main thread only — SwiftUI bindings are
    /// inherently main-actor isolated.
    private static var lastCommitAt: CFAbsoluteTime = 0
    /// Time of the most recent `.user`-sourced commit.  System writes
    /// are suppressed for `userCommitProtectionWindow` after this so that
    /// GPS-jitter ticks from `handleLocationUpdate` cannot fight an
    /// in-flight recenter animation (bounce) and the first-tap recenter
    /// always produces a visible camera change.
    private static var lastUserCommitAt: CFAbsoluteTime = 0
    /// Last camera position the engine wrote.  Used for dedupe + the
    /// `cameraWriteWillCommit` notification payload below.
    private static var lastCommittedPosition: TrackCameraPosition?
    /// Coalesce window: a `.system` commit landing within this many
    /// seconds of another commit that targets approximately the same
    /// camera is dropped — this is the bounce-killer.  Tuned to be
    /// shorter than `HoverAnimations.fly` (0.6s) so a genuine new
    /// destination during an in-flight animation still re-targets,
    /// but two onChange handlers firing in the same run loop don't
    /// both write.
    private static let coalesceWindow: CFAbsoluteTime = 0.18
    /// System writes are silenced for this many seconds after any
    /// `.user` commit.  1.5 s covers the longest camera spring animation
    /// (~0.9 s) plus GPS polling jitter so no background location tick
    /// can interrupt or undo a user-initiated recenter.
    private static let userCommitProtectionWindow: CFAbsoluteTime = 1.5

    /// Posted on `NotificationCenter.default` immediately before the
    /// engine writes a new camera into the binding.  The MapLibre
    /// renderer observes this so its `programmaticCameraInFlight`
    /// flag also covers SwiftUI-driven writes (not just renderer
    /// `setCenter` calls), preventing the gesture-throttled
    /// `syncCameraToBinding` work item from echoing a stale value
    /// back during the SwiftUI animation window.
    static let cameraWriteWillCommit = Notification.Name("TrackCameraHoverEngine.willCommit")

    /// Single coalesced write into a `cameraPosition` binding.
    ///
    /// All call sites that previously did
    /// ```swift
    /// withAnimation(...) { cameraPosition = MapCameraPresets... }
    /// ```
    /// should call this instead.  The engine:
    ///   1. Bounds-validates the position via `HoverBounds`.
    ///   2. Skips the write if the binding already holds an equivalent value.
    ///   3. Drops `.system` writes that land inside `coalesceWindow` of
    ///      the previous commit when both target the same camera —
    ///      this prevents the "two onChange handlers fight each other
    ///      with overlapping springs" bounce.
    ///   3b. Additionally drops ANY `.system` write within
    ///       `userCommitProtectionWindow` of the last `.user` commit —
    ///       prevents GPS jitter from fighting an in-flight recenter.
    ///   4. Posts `cameraWriteWillCommit` so the renderer can mute
    ///      its echo path.
    ///   5. Wraps the assignment in the requested SwiftUI animation.
    static func commit(
        _ position: TrackCameraPosition,
        animation: Animation = HoverAnimations.fly,
        to binding: Binding<TrackCameraPosition>,
        source: CommitSource = .system
    ) {
        let validated = validated(position)

        // (2) No-op write — binding already at target.
        if validated == binding.wrappedValue {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()

        if source == .system {
            // (3b) Hard silence after any user tap — covers the full animation
            //      window so GPS jitter ticks can't fight an in-flight recenter.
            if now - lastUserCommitAt < userCommitProtectionWindow {
                return
            }
            // (3) Same-target coalesce for rapid-fire system writes.
            if let last = lastCommittedPosition,
               now - lastCommitAt < coalesceWindow,
               validated == last {
                return
            }
        }

        lastCommitAt = now
        if source == .user {
            lastUserCommitAt = now
        }
        lastCommittedPosition = validated

        // (4) Tell the renderer a SwiftUI-side write is starting.
        NotificationCenter.default.post(name: cameraWriteWillCommit, object: nil)

        // (5) Apply.
        withAnimation(animation) {
            binding.wrappedValue = validated
        }
    }

    // MARK: - Private: Raw Position (delegates to MapCameraPresets)

    /// Computes the raw (un-validated) position by routing to the correct
    /// geometry strategy in `MapCameraPresets`.
    private static func rawPosition(
        for target: HoverTarget,
        is3D: Bool
    ) -> TrackCameraPosition {
        switch target {

        case let .coordinate(coord, distanceOverride):
            if let d = distanceOverride {
                return MapCameraPresets.center(on: coord, distance: d, is3D: is3D)
            } else {
                return MapCameraPresets.center(on: coord, is3D: is3D)
            }

        case let .vehicle(coord):
            return MapCameraPresets.focusVehicle(at: coord, is3D: is3D)

        case let .walkingPath(user, stop):
            return MapCameraPresets.fitWalkingPath(
                user: user, stop: stop, is3D: is3D)

        case let .walkingRoute(latSpan, lonSpan, center):
            return MapCameraPresets.fitWalkingRoute(
                latSpanMeters: latSpan,
                lonSpanMeters: lonSpan,
                center: center,
                is3D: is3D)

        case let .fitTwo(from, to):
            return MapCameraPresets.fitTwoPoints(from: from, to: to, is3D: is3D)

        case .userLocation:
            return .userLocation

        case .nyc:
            return MapCameraPresets.explorer(is3D: is3D)
        }
    }

    // MARK: - Private: Bounds Validation

    /// Applies coordinate and distance clamping from `HoverBounds`.
    ///
    /// `.userLocation` and `.automatic` are pass-through (no clamp needed —
    /// the renderer owns those positions).
    private static func validated(_ position: TrackCameraPosition) -> TrackCameraPosition {
        guard let camera = position.camera else {
            // .userLocation / .automatic — renderer-managed, no clamp.
            return position
        }

        let clampedCenter = HoverBounds.clamp(camera.centerCoordinate)
        let clampedDistance = HoverBounds.clamp(distance: camera.distance)

        // Return unchanged if nothing needed clamping (avoids object churn).
        if clampedCenter.latitude == camera.centerCoordinate.latitude,
           clampedCenter.longitude == camera.centerCoordinate.longitude,
           clampedDistance == camera.distance {
            return position
        }

        return .camera(TrackCamera(
            centerCoordinate: clampedCenter,
            distance: clampedDistance,
            heading: camera.heading,
            pitch: camera.pitch
        ))
    }
}
