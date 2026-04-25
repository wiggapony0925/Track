// A reusable, drag-controlled bottom sheet drawn entirely from SwiftUI
// primitives (no `.sheet` / `.presentationDetents`).
//
// Designed to be hosted as a bottom-aligned overlay on top of any view
// (typically a map).  Only the sheet card itself is hit-testable — the
// empty space above the card passes touches through to the underlying
// map / canvas.
//
//   myContent.overlay(alignment: .bottom) {
//       TrackBottomSheet(
//           selection: $detent,
//           detents: [.fraction(0.45), .large]
//       ) { MyDashboardContent() }
//   }

import SwiftUI

// MARK: - Detent

/// A position the sheet can rest at.  Resolves to a concrete pixel
/// height given the available container size.
enum TrackSheetDetent: Hashable {
    case peek(CGFloat)
    case height(CGFloat)
    case fraction(CGFloat)
    case large

    func resolve(in available: CGFloat, topInset: CGFloat) -> CGFloat {
        let cap = Swift.max(0, available - topInset)
        switch self {
        case .peek(let h): return Swift.min(h, cap)
        case .height(let h): return Swift.min(h, cap)
        case .fraction(let f): return Swift.max(0, Swift.min(cap, available * f))
        case .large: return cap
        }
    }
}

// MARK: - TrackBottomSheet

/// Reusable bottom-sheet container with prop-driven detents.
///
/// Parameters:
///   - selection: bound detent — drives the current resting height.
///   - detents:   ordered list of allowed snap points.
///   - cornerRadius: top-corner radius of the sheet card.
///   - topInset:  reserved space above the sheet at `.large`.
///   - topFade:   when true, fades the very top edge of the card so
///     content doesn't slam into the rounded corners.
///   - background: optional override for the sheet background.
///   - onHeightChange: continuously reports the sheet's pixel height
///     (used by `MapLibreMapView` to update `contentInset.bottom`).
///   - dragHandleAccessibility: VoiceOver label for the handle area.
///   - content:   the sheet body.
struct TrackBottomSheet<Content: View>: View {

    @Environment(\.colorScheme) private var colorScheme

    @Binding var selection: TrackSheetDetent
    var detents: [TrackSheetDetent]
    var cornerRadius: CGFloat = 28
    var topInset: CGFloat = 12
    /// Reserved space at the BOTTOM of the sheet container — typically
    /// the height of the floating tab bar that sits above the home
    /// indicator.  When > 0, the sheet card's bottom edge is lifted by
    /// this amount so the bar fully covers it instead of the sheet
    /// poking out underneath.
    var bottomInset: CGFloat = 0
    var topFade: Bool = false
    var background: AnyView? = nil
    var headerOverflow: CGFloat = 0
    var onHeightChange: ((CGFloat) -> Void)? = nil
    var dragHandleAccessibility: String = "Resize sheet"
    /// When true, the sheet keeps whatever height the user releases at
    /// instead of snapping to the nearest detent.  `detents` is then
    /// only used to derive the min / max drag bounds.
    var freeform: Bool = false
    /// Optional overlay rendered centered on the sheet card's TOP edge.
    /// Drawn inside the same `GeometryReader` that lays out the card,
    /// so it tracks the sheet's height in the same render pass — zero
    /// chasing lag, even on fast flicks. Use this for floating chrome
    /// (search bars, pills) that should ride the sheet's top edge.
    var topEdgeOverlay: (() -> AnyView)? = nil

    @ViewBuilder var content: () -> Content

    /// Live drag offset from the handle gesture (positive = upward drag).
    @GestureState private var dragOffset: CGFloat = 0
    /// Container height captured at gesture-start for end-of-drag projection.
    @State private var containerHeight: CGFloat = 0
    /// Sheet card height at the moment the user touched the handle.
    @State private var dragStartHeight: CGFloat = 0
    @State private var lastReportedHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.height
            let resting = selection.resolve(in: available, topInset: topInset)
            let live = clampedHeight(resting: resting, available: available)

            ZStack(alignment: .bottom) {
                // Fully transparent, NON-interactive spacer so taps in
                // the area above the sheet card pass through to the map.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)

                sheetCard
                    .frame(height: live, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .bottom)
                    // Lift the card off the bottom so the floating tab
                    // bar fully overlays it and the sheet doesn't peek
                    // out from beneath the bar.
                    .padding(.bottom, bottomInset)
                    // "Vacuum" effect: as the sheet collapses toward 0,
                    // the card shrinks/squishes toward bottom-center so
                    // it looks like the floating tab bar is eating it.
                    // No `.animation(...)` here — these scales follow
                    // `live` directly so the squeeze tracks the finger
                    // at full frame-rate without a competing spring.
                    .scaleEffect(
                        x: vacuumScaleX(live: live),
                        y: vacuumScaleY(live: live),
                        anchor: .bottom
                    )
                    .opacity(vacuumOpacity(live: live))

                // Top-edge overlay (e.g. floating search bar). Positioned
                // inside the SAME GeometryReader as the sheet card and
                // driven by the SAME `live` value, so the two views are
                // laid out together every frame — zero chasing lag.
                if let topEdgeOverlay {
                    // Hand-off opacity: as the sheet collapses toward the
                    // tab-bar grabber, the search pill needs to be GONE
                    // before it can collide with the train glyph that
                    // sits ~56pt above the bar.  Without this, the pill
                    // stays mostly opaque (vacuumOpacity only fades the
                    // last 25%) and lands directly on top of the train.
                    let handoff = searchBarHandoffOpacity(live: live)
                    topEdgeOverlay()
                        .frame(maxWidth: .infinity)
                        .position(x: geo.size.width / 2,
                                  y: max(0, available - live - bottomInset))
                        .scaleEffect(
                            x: vacuumScaleX(live: live),
                            y: vacuumScaleY(live: live),
                            anchor: .center
                        )
                        .opacity(vacuumOpacity(live: live) * handoff)
                        .allowsHitTesting(handoff > 0.5)
                }
            }
            .onAppear {
                containerHeight = available
                reportHeight(live)
            }
            .onChange(of: available) { _, new in containerHeight = new }
            .onChange(of: live) { _, new in reportHeight(new) }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Sheet Card

    private var sheetCard: some View {
        // No drag-handle capsule.  Drag is initiated from the consumer
        // (e.g. DashboardView's navbar gesture).
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(
            sheetBackground
                .clipShape(SheetTopRoundedShape(radius: cornerRadius))
                // Three-layer elevation — wide ambient halo + medium drop +
                // tight contact shadow. Mimics the shadow stack used by
                // first-class iOS sheets (Maps, Stocks, Transit).
                .shadow(color: Color.black.opacity(0.10), radius: 36, x: 0, y: -12)
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: -4)
                .shadow(color: Color.black.opacity(0.05), radius: 1,  x: 0, y: -0.5)
                .padding(.top, headerOverflow)
        )
    }

    // MARK: - Vacuum (sheet-eaten) helpers

    /// Threshold (in pixels) above which the vacuum effect is identity.
    /// Pulled from `SheetConstants.vacuumThreshold` so DashboardView's
    /// release-commit logic and HomeView's collapse snap all use the
    /// same boundary — the squish only begins the instant the sheet's
    /// top edge meets the navigator, and once it does the collapse is
    /// guaranteed to complete.
    private var vacuumThreshold: CGFloat { SheetConstants.vacuumThreshold }

    private func vacuumProgress(live: CGFloat) -> CGFloat {
        // 0 = fully visible, 1 = fully consumed.
        let t = (vacuumThreshold - max(0, live)) / vacuumThreshold
        return min(1, max(0, t))
    }

    private func vacuumScaleY(live: CGFloat) -> CGFloat {
        // Squish vertically nearly to a sliver — the card collapses
        // down toward the bar's top edge as if it's being pulled into
        // the navigator.
        let p = vacuumProgress(live: live)
        return 1 - p * 0.85
    }

    private func vacuumScaleX(live: CGFloat) -> CGFloat {
        // Pinch horizontally hard too so the card converges to a
        // single point at the navigator's center, instead of just
        // shrinking in height.
        let p = vacuumProgress(live: live)
        return 1 - p * 0.7
    }

    private func vacuumOpacity(live: CGFloat) -> Double {
        // Hold full opacity until the sheet is well into the squish,
        // then fade out the last 25% to mask the final disappearance.
        let p = Double(vacuumProgress(live: live))
        return p < 0.75 ? 1.0 : max(0, 1.0 - (p - 0.75) / 0.25)
    }

    /// Linear fade for the top-edge overlay (search pill) as the sheet
    /// approaches the floating tab bar.  This is much more aggressive
    /// than `vacuumOpacity` because the pill collides with the train
    /// grabber that pops out of the bar at `live < 80`.  By the time
    /// the bar is collapsed enough to show the train, the pill must be
    /// fully invisible — otherwise the two glyphs stack on top of one
    /// another (see screenshots in the redesign PR).
    private func searchBarHandoffOpacity(live: CGFloat) -> Double {
        // Start fading at 220pt of sheet height, fully gone by 110pt
        // (well above the 80pt collapse trigger so there's no overlap
        // window during a fast drag).
        let upper: CGFloat = 220
        let lower: CGFloat = 110
        if live >= upper { return 1.0 }
        if live <= lower { return 0.0 }
        return Double((live - lower) / (upper - lower))
    }

    /// iOS 26 no longer permits `UIScreen.main`.  Pull the screen size
    /// from the first connected foreground window scene; if no scene is
    /// active (e.g. unit tests, previews), fall back to a sane default.
    private static func fallbackScreenHeight() -> CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        return scene?.screen.bounds.height ?? 800
    }

    // MARK: - Background

    /// Premium layered background:
    ///   1. `.regularMaterial` masked by a top fade — frosted glass that
    ///      goes fully transparent at the top edge so the map/route map
    ///      blooms through near the handle.
    ///   2. Aurora ramp — a soft RadialGradient using the app accent,
    ///      anchored at the top-leading corner.  Gives the sheet a gentle
    ///      colored glow without competing with content.
    ///   3. Vertical accent wash that builds toward the bottom — same
    ///      shape as the route detail panel so the two surfaces feel
    ///      part of the same family.
    ///   4. Solid `cardBackground` ramp that anchors the bottom 60%
    ///      so text + chips read at full contrast.
    /// Override entirely by passing the `background:` prop.
    private var sheetBackground: some View {
        let baseSurface = colorScheme == .dark
            ? AppTheme.Colors.chipSurface
            : AppTheme.Colors.cardBackground
        return ZStack(alignment: .bottom) {
            if let custom = background {
                custom
            } else {
                // In dark mode, use the same shared neutral gray token that
                // defines chip/container surfaces so the sheet matches the
                // Home/Trips pill background. Light mode keeps the existing
                // card surface.
                baseSurface

                // 2. Aurora glow — a soft accent halo from the top-leading
                // corner.  Adds dimension without looking like a gradient.
                GeometryReader { proxy in
                    RadialGradient(
                        colors: [
                            AppTheme.Colors.accent.opacity(0.22),
                            AppTheme.Colors.accent.opacity(0.08),
                            Color.clear,
                        ],
                        center: UnitPoint(x: 0.15, y: 0.0),
                        startRadius: 0,
                        endRadius: max(proxy.size.width, 360) * 0.85
                    )
                    .blendMode(.plusLighter)
                    .opacity(0.85)
                }
                .allowsHitTesting(false)

                // 3. Vertical accent wash toward the bottom.
                LinearGradient(
                    stops: [
                        .init(color: AppTheme.Colors.accent.opacity(0.00), location: 0.00),
                        .init(color: AppTheme.Colors.accent.opacity(0.04), location: 0.20),
                        .init(color: AppTheme.Colors.accent.opacity(0.10), location: 0.45),
                        .init(color: AppTheme.Colors.accent.opacity(0.20), location: 0.70),
                        .init(color: AppTheme.Colors.accent.opacity(0.30), location: 0.90),
                        .init(color: AppTheme.Colors.accent.opacity(0.34), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // 4. Solid base-surface ramp.
                LinearGradient(
                    stops: [
                        .init(color: baseSurface.opacity(0.00), location: 0.00),
                        .init(color: baseSurface.opacity(0.00), location: 0.22),
                        .init(color: baseSurface.opacity(0.18), location: 0.40),
                        .init(color: baseSurface.opacity(0.42), location: 0.58),
                        .init(color: baseSurface.opacity(0.65), location: 0.74),
                        .init(color: baseSurface.opacity(0.82), location: 0.90),
                        .init(color: baseSurface.opacity(0.92), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    // MARK: - Height + Snap helpers

    /// Live height while the user is dragging the handle.
    /// Drag is downward → translation.height > 0 → sheet shrinks.
    private func clampedHeight(resting: CGFloat, available: CGFloat) -> CGFloat {
        let base = dragStartHeight > 0 ? dragStartHeight : resting
        let candidate = base - dragOffset
        let resolved = detents.map { $0.resolve(in: available, topInset: topInset) }
        let smallest = resolved.min() ?? 0
        let largest = resolved.max() ?? available
        return min(max(candidate, smallest * 0.85), largest)
    }

    /// Pick the configured detent whose resolved height is closest to
    /// the projected end-of-drag height.
    private func nearestDetent(to height: CGFloat, in available: CGFloat) -> TrackSheetDetent {
        guard !detents.isEmpty else { return selection }
        return detents.min(by: {
            abs($0.resolve(in: available, topInset: topInset) - height)
                < abs($1.resolve(in: available, topInset: topInset) - height)
        }) ?? selection
    }

    /// Reports the sheet's pixel height to the host live, every frame
    /// of the drag.  The previous shake was caused by `.local` drag
    /// coordinates on the navbar (now fixed to `.global` in
    /// `DashboardView`), not by per-frame map updates — so debouncing
    /// here is no longer needed and was making the map feel laggy.
    private func reportHeight(_ h: CGFloat) {
        guard abs(h - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = h
        onHeightChange?(h)
    }
}

// MARK: - Top-Rounded Shape

/// Rectangle with only the top two corners rounded.  Uses a continuous
/// (squircle) curve to match Apple's first-party sheets like Maps and
/// Stocks — looks noticeably more refined than circular corners.
private struct SheetTopRoundedShape: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        // Use a UIBezierPath-based continuous-curve clone for the actual
        // visual (UIKit gives us proper squircles); the SwiftUI path above
        // is only a fallback for non-UIKit contexts.
        return Path(
            UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: [.topLeft, .topRight],
                cornerRadii: CGSize(width: r, height: r)
            ).cgPath
        )
    }
}
