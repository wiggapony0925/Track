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
        withAnimation(animation) {
            binding.wrappedValue = position
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
