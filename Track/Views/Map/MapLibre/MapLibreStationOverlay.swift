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
    let visibleCount: Int = max(1, min(routeCount, 4))
    let bulletW: Int = visibleCount * 12
    let gapW: Int = max(0, visibleCount - 1)
    let bulletRowWidth: CGFloat = CGFloat(bulletW + gapW)
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
///
/// Performance: Uses a spatial grid to reduce pairwise collision checks
/// from O(n²) to ~O(n). Each kept label is inserted into grid cells it
/// overlaps; candidates only check labels in neighboring cells.
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

    // Spatial grid — cell size chosen to be the max collision radius so
    // we only need to check the 3×3 neighborhood of each candidate.
    let cellSize: CGFloat = max(140.0 * spacingScale, 60.0)
    let cols = max(1, Int(viewportSize.width / cellSize) + 2)
    var grid: [Int: [Int]] = [:]  // cellKey → [index in `kept`]

    func cellKey(col: Int, row: Int) -> Int { row &* cols &+ col }
    func cellCoord(_ pt: CGPoint) -> (col: Int, row: Int) {
        (Int(pt.x / cellSize), Int(pt.y / cellSize))
    }

    var kept: [ProjectedRouteLabelPlacement] = []
    kept.reserveCapacity(min(prioritized.count, budget))

    for candidate in prioritized {
        if kept.count >= budget { break }

        let candidateSize: CGSize = routeLabelVisualSize(routeCount: candidate.routeIds.count)
        let (cc, cr) = cellCoord(candidate.point)
        var collides: Bool = false

        // Only check labels in the 3×3 neighborhood
        outerLoop: for dr in -1...1 {
            for dc in -1...1 {
                let key: Int = cellKey(col: cc + dc, row: cr + dr)
                guard let indices = grid[key] else { continue }
                for idx in indices {
                    let existing: ProjectedRouteLabelPlacement = kept[idx]
                    let existingSize: CGSize = routeLabelVisualSize(routeCount: existing.routeIds.count)
                    let dx: CGFloat = abs(candidate.point.x - existing.point.x)
                    let dy: CGFloat = abs(candidate.point.y - existing.point.y)
                    let sameSignature: Bool = candidate.routeSignature == existing.routeSignature

                    let sameExtra: CGFloat = sameSignature ? 18.0 : 8.0
                    let minX: CGFloat = (candidateSize.width + existingSize.width) / 2.0
                        + sameExtra * spacingScale
                    let sameExtraY: CGFloat = sameSignature ? 12.0 : 6.0
                    let minY: CGFloat = (candidateSize.height + existingSize.height) / 2.0
                        + sameExtraY * spacingScale

                    if dx < minX && dy < minY {
                        collides = true
                        break outerLoop
                    }

                    if sameSignature {
                        let minSpacing: CGFloat = max(candidateSize.width * 2.2, 120.0) * spacingScale
                        let dist: CGFloat = hypot(dx, dy)
                        if dist < minSpacing {
                            collides = true
                            break outerLoop
                        }
                    }
                }
            }
        }

        if !collides {
            let idx: Int = kept.count
            kept.append(candidate)
            // Insert into all cells this label's bounding box overlaps
            let halfW: CGFloat = candidateSize.width / 2.0 + 10.0 * spacingScale
            let halfH: CGFloat = candidateSize.height / 2.0 + 10.0 * spacingScale
            let minCol: Int = Int((candidate.point.x - halfW) / cellSize)
            let maxCol: Int = Int((candidate.point.x + halfW) / cellSize)
            let minRow: Int = Int((candidate.point.y - halfH) / cellSize)
            let maxRow: Int = Int((candidate.point.y + halfH) / cellSize)
            for r in minRow...maxRow {
                for c in minCol...maxCol {
                    grid[cellKey(col: c, row: r), default: []].append(idx)
                }
            }
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
