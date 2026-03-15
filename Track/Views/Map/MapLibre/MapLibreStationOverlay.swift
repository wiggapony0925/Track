//
//  MapLibreStationOverlay.swift
//  Track
//
//  SwiftUI overlay rendering route label bubbles on top of the
//  MapLibre GL map. Uses coordinate-to-screen-point projection.
//

import CoreLocation
import MapLibre
import SwiftUI

// MARK: - Route Labels Overlay

/// Screen-space placement for a projected trunk route label bubble.
///
/// Stored separately from the geographic label model so we can run
/// collision/density filtering using only pixel coordinates.
struct ProjectedRouteLabelPlacement: Identifiable {
    let id: String
    let point: CGPoint
    let routeIds: [String]
    let color: Color

    var routeSignature: String {
        routeIds
            .prefix(4)
            .map { $0.uppercased() }
            .joined(separator: "|")
    }
}

/// Approximate rendered size of a route label capsule in screen points.
/// This mirrors `TrunkRouteLabelView` closely enough for collision culling.
func routeLabelVisualSize(routeCount: Int) -> CGSize {
    let visibleCount = max(1, min(routeCount, 4))
    let bulletRowWidth = CGFloat(visibleCount * 12 + max(0, visibleCount - 1))
    return CGSize(width: bulletRowWidth + 3.0, height: 15.0)
}

private func routeLabelSpacingScale(for distance: Double?) -> CGFloat {
    switch ZoomTier.tier(for: distance) {
    case .veryClose: return 0.95
    case .close: return 1.05
    case .medium: return 1.15
    case .far: return 1.25
    case .distant: return 1.35
    }
}

private func routeLabelDensityBudget(for distance: Double?) -> Int {
    switch ZoomTier.tier(for: distance) {
    case .veryClose: return 18
    case .close: return 14
    case .medium: return 10
    case .far: return 8
    case .distant: return 6
    }
}

/// Cull projected route labels so dense trunks don't turn into a wall of tags.
///
/// Strategy:
/// - prefer labels nearer the viewport center
/// - keep repeated identical signatures farther apart than different ones
/// - reject any labels whose capsules would visually collide on screen
func cullRouteLabelPlacements(
    _ placements: [ProjectedRouteLabelPlacement],
    viewportSize: CGSize,
    distance: Double?
) -> [ProjectedRouteLabelPlacement] {
    guard placements.count > 1 else { return placements }

    let spacingScale = routeLabelSpacingScale(for: distance)
    let budget = routeLabelDensityBudget(for: distance)
    let viewportCenter = CGPoint(x: viewportSize.width / 2.0, y: viewportSize.height / 2.0)

    let prioritized = placements.sorted { lhs, rhs in
        let lhsDist = hypot(lhs.point.x - viewportCenter.x, lhs.point.y - viewportCenter.y)
        let rhsDist = hypot(rhs.point.x - viewportCenter.x, rhs.point.y - viewportCenter.y)
        if abs(lhsDist - rhsDist) > 1.0 {
            return lhsDist < rhsDist
        }
        if lhs.routeIds.count != rhs.routeIds.count {
            return lhs.routeIds.count > rhs.routeIds.count
        }
        return lhs.id < rhs.id
    }

    var kept: [ProjectedRouteLabelPlacement] = []
    kept.reserveCapacity(min(prioritized.count, budget))

    for candidate in prioritized {
        if kept.count >= budget { break }

        let candidateSize = routeLabelVisualSize(routeCount: candidate.routeIds.count)
        var collides = false

        for existing in kept {
            let existingSize = routeLabelVisualSize(routeCount: existing.routeIds.count)
            let dx = abs(candidate.point.x - existing.point.x)
            let dy = abs(candidate.point.y - existing.point.y)
            let sameSignature = candidate.routeSignature == existing.routeSignature

            let minX = (candidateSize.width + existingSize.width) / 2.0
                + (sameSignature ? 18.0 : 8.0) * spacingScale
            let minY = (candidateSize.height + existingSize.height) / 2.0
                + (sameSignature ? 12.0 : 6.0) * spacingScale

            if dx < minX && dy < minY {
                collides = true
                break
            }

            if sameSignature {
                let minSpacing = max(candidateSize.width * 2.2, 120.0) * spacingScale
                if hypot(dx, dy) < minSpacing {
                    collides = true
                    break
                }
            }
        }

        if !collides {
            kept.append(candidate)
        }
    }

    return kept.sorted { lhs, rhs in
        if abs(lhs.point.y - rhs.point.y) > 1.0 {
            return lhs.point.y < rhs.point.y
        }
        if abs(lhs.point.x - rhs.point.x) > 1.0 {
            return lhs.point.x < rhs.point.x
        }
        return lhs.id < rhs.id
    }
}

/// Renders trunk route label bubbles (e.g., "A C E" circles) on the
/// MapLibre map at close zoom levels.
struct MapLibreRouteLabelOverlay: View {
    let mapView: MLNMapView?
    let labels: [HomeViewModel.TrunkRouteLabel]
    let currentDistance: Double?
    let hasActiveRoute: Bool

    /// Bumped every camera frame to force SwiftUI re-projection during gestures.
    let cameraChangeToken: UInt64

    @ViewBuilder
    var body: some View {
        if !hasActiveRoute,
           let distance = currentDistance,
           distance < AppSettings.shared.stationMaxZoomOutMeters * 0.16
        {
            GeometryReader { geometry in
                let placements = projectedPlacements(in: geometry.size)
                ZStack {
                    ForEach(placements) { placement in
                        TrunkRouteLabelView(
                            routeIds: placement.routeIds,
                            color: placement.color
                        )
                        .position(placement.point)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func projectedPlacements(in viewportSize: CGSize) -> [ProjectedRouteLabelPlacement] {
        let projected = labels.compactMap { label -> ProjectedRouteLabelPlacement? in
            guard let point = projectToScreen(label.coordinate, mapView: mapView) else {
                return nil
            }
            return ProjectedRouteLabelPlacement(
                id: label.id,
                point: point,
                routeIds: label.routeIds,
                color: label.color
            )
        }

        return cullRouteLabelPlacements(
            projected,
            viewportSize: viewportSize,
            distance: currentDistance
        )
    }
}
