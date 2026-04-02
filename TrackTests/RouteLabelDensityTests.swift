//
//  RouteLabelDensityTests.swift
//  TrackTests
//
//  Verifies that screen-space route-label culling keeps trunk labels
//  readable in dense downtown corridors.
//

import CoreGraphics
import SwiftUI
import Testing
@testable import Track

struct RouteLabelDensityTests {

    @Test("Repeated identical route tags collapse to one in a dense cluster")
    func repeatedSignatureClusterIsThinned() {
        let placements: [ProjectedRouteLabelPlacement] = [
            .init(
                id: "center",
                point: CGPoint(x: 200, y: 400),
                routeIds: ["N", "Q", "R", "W"],
                color: .yellow
            ),
            .init(
                id: "nearby-1",
                point: CGPoint(x: 250, y: 402),
                routeIds: ["N", "Q", "R", "W"],
                color: .yellow
            ),
            .init(
                id: "nearby-2",
                point: CGPoint(x: 305, y: 399),
                routeIds: ["N", "Q", "R", "W"],
                color: .yellow
            ),
        ]

        let kept = cullRouteLabelPlacements(
            placements,
            viewportSize: CGSize(width: 400, height: 800),
            distance: 3_000
        )

        #expect(kept.count == 1)
        #expect(kept.first?.id == "center")
    }

    @Test("Far-apart identical route tags remain visible")
    func farApartRepeatedSignatureSurvives() {
        let placements: [ProjectedRouteLabelPlacement] = [
            .init(id: "north", point: CGPoint(x: 120, y: 180), routeIds: ["A", "C"], color: .blue),
            .init(id: "south", point: CGPoint(x: 300, y: 620), routeIds: ["A", "C"], color: .blue),
        ]

        let kept = cullRouteLabelPlacements(
            placements,
            viewportSize: CGSize(width: 400, height: 800),
            distance: 2_000
        )

        #expect(kept.count == 2)
        #expect(Set(kept.map(\.id)) == Set(["north", "south"]))
    }

    @Test("Overlapping mixed route tags choose the center-priority candidate")
    func overlappingMixedTagsPreferViewportCenter() {
        let placements: [ProjectedRouteLabelPlacement] = [
            .init(
                id: "center",
                point: CGPoint(x: 200, y: 400),
                routeIds: ["B", "D"],
                color: .orange
            ),
            .init(
                id: "offcenter",
                point: CGPoint(x: 214, y: 407),
                routeIds: ["N", "Q", "R", "W"],
                color: .yellow
            ),
        ]

        let kept = cullRouteLabelPlacements(
            placements,
            viewportSize: CGSize(width: 400, height: 800),
            distance: 3_000
        )

        #expect(kept.count == 1)
        #expect(kept.first?.id == "center")
    }
}
