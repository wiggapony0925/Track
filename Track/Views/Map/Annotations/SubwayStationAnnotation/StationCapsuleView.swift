import SwiftUI

/// A track-aligned marker for consolidated subway stations.
///
/// **Shape is a visual flag for physical structure:**
///   - **Subway / open-cut** → white-filled **capsule** (pill) with dark stroke.
///     Width stretches with the number of trunk-color groups.
///   - **Elevated / viaduct** → white-filled **circle** with lighter stroke
///     and a drop shadow to visually "float" above the map surface.
///   - **At-grade (SIR)** → small circle, no shadow.
///
/// **Rotation** matches the average bearing of nearby polylines.
/// **Size** scales with the current discrete zoom tier.
///
/// **Pulse** — when a train is ≤1 minute away, a concentric ring
/// expands outward in the approaching train's route color, then fades.
/// The pulse is driven by `imminentRouteId` (set from live arrivals).
///
/// Performance: conforms to `Equatable` so MapKit only diffs when the
/// station data or zoom tier actually changes.
struct StationCapsuleView: View, Equatable {
    let station: MapSystemViewModel.ConsolidatedStation

    /// Discrete zoom tier — only changes when crossing a zoom boundary.
    var zoomTier: TrackMapView.ZoomTier = .medium

    /// Route ID of the train arriving within 1 minute, or `nil`.
    /// Drives the pulse ring color + animation toggle.
    var imminentRouteId: String? = nil

    static func == (lhs: StationCapsuleView, rhs: StationCapsuleView) -> Bool {
        lhs.station == rhs.station
            && lhs.zoomTier == rhs.zoomTier
            && lhs.imminentRouteId == rhs.imminentRouteId
    }

    private var zoomScale: CGFloat { zoomTier.rawValue }

    /// Whether this station is on an elevated / viaduct structure.
    private var isElevated: Bool {
        station.structure == .elevated || station.structure == .viaduct
    }

    /// Whether this station is at street level (SIR).
    private var isAtGrade: Bool {
        station.structure == .atGrade
    }

    var body: some View {
        let scale = zoomScale

        if isElevated || isAtGrade {
            // ── Elevated / at-grade: circle marker ──
            let diameter: CGFloat = (isAtGrade ? 4.5 : 5.5) * scale
            let strokeWidth = max(0.5, 0.75 * scale)

            Circle()
                .fill(Color.white)
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle()
                        .stroke(
                            isElevated ? Color(.systemGray3) : Color(.systemGray5),
                            lineWidth: strokeWidth
                        )
                )
                .shadow(
                    color: isElevated ? Color.black.opacity(0.3) : .clear,
                    radius: isElevated ? 2.0 * scale : 0,
                    x: 0,
                    y: isElevated ? 1.2 * scale : 0
                )
                .modifier(PulseRingModifier(
                    routeId: imminentRouteId,
                    diameter: diameter
                ))
                .accessibilityLabel("Station: \\(station.name)")
        } else {
            // ── Subway / open-cut: capsule (pill) marker ──
            let groups = station.colorGroupCount
            let lineCount = CGFloat(station.routes.count)
            let baseHeight: CGFloat = min(5 + lineCount * 0.35, 8)
            let baseWidth: CGFloat = groups <= 1 ? 5 : min(5 + CGFloat(groups) * 3.5, 16)
            let width = baseWidth * scale
            let height = baseHeight * scale
            let strokeWidth = max(0.5, 0.75 * scale)

            Capsule()
                .fill(Color.white)
                .frame(width: width, height: height)
                .overlay(
                    Capsule()
                        .stroke(
                            station.structure == .openCut
                                ? Color(.systemGray4)
                                : Color(.darkGray),
                            lineWidth: strokeWidth
                        )
                )
                .rotationEffect(.degrees(station.trackBearing))
                .modifier(PulseRingModifier(
                    routeId: imminentRouteId,
                    diameter: max(width, height)
                ))
                .accessibilityLabel("Station: \\(station.name)")
        }
    }
}

// MARK: - Pulse Ring Modifier

/// Adds an expanding, fading ring around a station capsule when a
/// train is ≤1 minute away.  The ring uses the approaching train's
/// MTA route color so the user can instantly tell WHICH line is arriving.
///
/// The animation loops continuously while `routeId` is non-nil and
/// stops (ring disappears) the moment the arrival data clears it.
///
/// Performance: The modifier is only active when `routeId != nil`.
/// When nil, it adds zero overhead — no animation timer, no extra layers.
private struct PulseRingModifier: ViewModifier {
    let routeId: String?
    let diameter: CGFloat

    @State private var isAnimating = false

    func body(content: Content) -> some View {
        if let routeId {
            let color = SubwayRoutesData.color(for: routeId)
            content
                .background(
                    Circle()
                        .stroke(color.opacity(isAnimating ? 0 : 0.6), lineWidth: 2)
                        .frame(
                            width: isAnimating ? diameter * 2.8 : diameter,
                            height: isAnimating ? diameter * 2.8 : diameter
                        )
                        .animation(
                            .easeOut(duration: 1.4).repeatForever(autoreverses: false),
                            value: isAnimating
                        )
                )
                .onAppear { isAnimating = true }
                .onChange(of: routeId) { _, _ in
                    // Reset animation cycle when the approaching route changes
                    isAnimating = false
                    withAnimation { isAnimating = true }
                }
        } else {
            content
        }
    }
}
