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
    var topFade: Bool = false
    var background: AnyView? = nil
    var headerOverflow: CGFloat = 0
    var onHeightChange: ((CGFloat) -> Void)? = nil
    var dragHandleAccessibility: String = "Resize sheet"
    /// When true, the sheet keeps whatever height the user releases at
    /// instead of snapping to the nearest detent.  `detents` is then
    /// only used to derive the min / max drag bounds.
    var freeform: Bool = false

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
