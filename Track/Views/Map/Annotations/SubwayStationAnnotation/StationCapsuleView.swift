import SwiftUI

/// A track-aligned marker for consolidated subway stations.
///
/// **Shape is a visual flag for the `is_transfer` status:**
///
///   - **Non-transfer** (`isTransfer == false`) →
///     A **colored circle** filled with the route's MTA trunk color
///     and a **white stroke**. This instantly conveys which line serves
///     the stop. Elevated stops get a subtle drop shadow.
///
///   - **Transfer hub** (`isTransfer == true`) →
///     A **white pill** (capsule) with a **thick dark outline** that
///     stretches across the parallel offset lines. Width scales with
///     the number of trunk-color groups so multi-line hubs like
///     Times Sq (7 groups) are visually wider than a 2-group stop.
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

    /// Trunk color for non-transfer (single-line) stations.
    /// Falls back to gray if `routes` is unexpectedly empty.
    private var primaryColor: Color {
        guard let firstRoute = station.routes.first else { return .gray }
        return SubwayRoutesData.color(for: firstRoute)
    }

    var body: some View {
        let scale = zoomScale

        if station.isTransfer {
            // ── Transfer hub: white pill with dark outline ──
            // Width stretches with the number of trunk-color groups so
            // the pill visually spans the parallel offset lines.
            transferPill(scale: scale)
        } else {
            // ── Single-line stop: colored circle with white stroke ──
            routeDot(scale: scale)
        }
    }

    // MARK: - Single-line stop (colored dot)

    @ViewBuilder
    private func routeDot(scale: CGFloat) -> some View {
        let diameter: CGFloat = (isAtGrade ? 4.5 : isElevated ? 5.5 : 6.0) * scale
        let strokeWidth = max(0.5, (isElevated ? 0.75 : 1.0) * scale)

        Circle()
            .fill(primaryColor)
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: strokeWidth)
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
            .accessibilityLabel("Station: \(station.name)")
    }

    // MARK: - Transfer hub (white pill)

    @ViewBuilder
    private func transferPill(scale: CGFloat) -> some View {
        let groups = station.colorGroupCount
        let lineCount = CGFloat(station.routes.count)
        let baseHeight: CGFloat = min(5 + lineCount * 0.35, 8)
        let baseWidth: CGFloat = max(6, min(5 + CGFloat(groups) * 3.5, 18))
        let width = baseWidth * scale
        let height = baseHeight * scale
        let strokeWidth = max(0.75, 1.25 * scale)

        let strokeColor: Color = isElevated
            ? Color(.systemGray3)
            : station.structure == .openCut
                ? Color(.systemGray4)
                : Color(.darkGray)

        Capsule()
            .fill(Color.white)
            .frame(width: width, height: height)
            .overlay(
                Capsule()
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
            .rotationEffect(.degrees(station.trackBearing))
            .shadow(
                color: isElevated ? Color.black.opacity(0.3) : .clear,
                radius: isElevated ? 2.0 * scale : 0,
                x: 0,
                y: isElevated ? 1.2 * scale : 0
            )
            .modifier(PulseRingModifier(
                routeId: imminentRouteId,
                diameter: max(width, height)
            ))
            .accessibilityLabel("Transfer station: \(station.name)")
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
