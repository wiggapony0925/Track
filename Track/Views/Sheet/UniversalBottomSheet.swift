// A reusable bottom sheet container that manages all sheet-based navigation
// in the app. This provides a consistent single-sheet experience where all
// views (dashboard, route details, settings) are displayed within the same
// modal, maintaining visual consistency and smooth transitions.
// Usage:
//   UniversalBottomSheet(
//       navigator: sheetNavigator,
//       sheetDetent: $sheetDetent
//   ) { page in
//       switch page {
//       case .dashboard: DashboardView()
//       case .settings: SettingsContentView()
//       // etc.
//       }
//   }

import SwiftUI

// MARK: - Sheet Constants

/// Centralised detent fractions used across the app.
/// All references to sheet detent fractions should go through these
/// constants so adjusting sheet sizes is a single-line change.
enum SheetConstants {
    /// Default resting position — shows navbar + one full favorites row +
    /// the first transit section header.
    static let defaultFraction: CGFloat = 0.45
    /// Convenience detent value for the default resting position.
    static let defaultDetent: PresentationDetent = .fraction(defaultFraction)

    /// Builds the peek detent from the measured navbar height.
    /// Adds a small buffer for the drag indicator + corner radius.
    static func peekDetent(navbarHeight: CGFloat) -> PresentationDetent {
        .height(navbarHeight) // exact fit — no extra content visible
    }
}

// MARK: - Navbar Height Preference Key

/// Bubbles the measured pixel height of the dashboard's fixed navbar
/// (header + search + mode tabs) up to `UniversalBottomSheet` so it
/// can build a content-derived peek detent.
struct NavbarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > value { value = next }
    }
}

/// Tracks sheet pixel height for real-time map contentInset updates.
struct SheetMinYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Sheet Height Observer

/// Bridges real-time sheet height changes directly into the map's
/// UIKit `contentInset` without triggering any SwiftUI re-renders.
///
/// Architecture (60fps interactive tracking):
/// ```
/// Sheet drag gesture
///   → GeometryReader frame changes
///   → PreferenceKey fires
///   → SheetHeightObserver.report(height)
///   → MLNMapView.contentInset.bottom = height   (UIKit, no SwiftUI)
/// ```
final class SheetHeightObserver {
    private(set) var currentHeight: CGFloat = 0
    /// Called on the main thread whenever the sheet pixel height changes.
    /// Wired to `MLNMapView.contentInset.bottom` in `MapLibreMapView.makeUIView`.
    var onHeightChanged: ((CGFloat) -> Void)?

    /// Pending height waiting for the next display-link tick.
    private var pendingHeight: CGFloat?
    /// CADisplayLink that coalesces rapid preference-change calls into
    /// one contentInset update per display frame (120fps on ProMotion).
    private var displayLink: CADisplayLink?

    func report(_ height: CGFloat) {
        // Ignore sub-pixel noise to avoid unnecessary UIKit calls
        guard abs(height - currentHeight) > 0.5 else { return }
        currentHeight = height
        pendingHeight = height
        startDisplayLinkIfNeeded()
    }

    // MARK: - Display Link

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common) // .common ensures updates during sheet drag tracking
        displayLink = link
    }

    @objc private func tick() {
        guard let h = pendingHeight else {
            // Nothing pending — tear down the display link to save power
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        pendingHeight = nil
        onHeightChanged?(h)
    }
}

/// Universal bottom sheet container that hosts all in-sheet navigation.
/// Provides consistent presentation, detents, and transition animations.
/// Note: Individual pages are responsible for their own
/// navigation UI (back buttons, close buttons).
struct UniversalBottomSheet<Content: View>: View {
    /// Navigation state manager
    let navigator: SheetNavigator
    
    /// Current sheet detent (height)
    @Binding var sheetDetent: PresentationDetent

    /// Continuously reports the sheet's pixel height for interactive
    /// map camera tracking.  Optional — nil in previews.
    var sheetHeightObserver: SheetHeightObserver?
    
    /// Theme setting — must be read here so the sheet inherits the correct color scheme.
    @AppStorage("appTheme") private var appTheme = "system"
    
    /// Content builder that maps SheetPage to actual views
    let content: (SheetPage) -> Content

    /// Measured height of the dashboard navbar (header + search + tabs).
    /// Drives the peek detent so it adapts to content changes automatically.
    @State private var navbarHeight: CGFloat = 150 // sensible default until measured

    /// Pre-computed detent set to avoid compiler type-check complexity.
    private var sheetDetents: Set<PresentationDetent> {
        [SheetConstants.peekDetent(navbarHeight: navbarHeight), .fraction(SheetConstants.defaultFraction), .large]
    }

    /// Brief dimming overlay for smooth dark ↔ light transition.
    @State private var themeTransitionOpacity: Double = 0

    /// Last measured pixel height of the sheet — updated by GeometryReader
    /// on every frame but only forwarded to the observer at detent snap points.
    @State private var lastKnownHeight: CGFloat = 0

    /// Tracks whether the initial contentInset has been reported to the map.
    @State private var hasReportedInitial = false

    /// Maps the appTheme string to a ColorScheme for the sheet.
    private var colorScheme: ColorScheme? {
        switch appTheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var body: some View {
        // Page content with transitions
        content(navigator.currentPage)
            .id(navigator.currentPage.id)
            .background {
                AppTheme.Colors.cardBackground
                    .ignoresSafeArea()
            }
            .transition(.asymmetric(
                  insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .presentationDetents(sheetDetents, selection: $sheetDetent)
            .onPreferenceChange(NavbarHeightKey.self) { height in
                guard height > 0 else { return }
                navbarHeight = height
            }
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled)
            .presentationBackground {
                ZStack {
                    AppTheme.Colors.cardBackground
                    // Gentle accent wash — keeps the sheet warm,
                    // not dead-dark. Matches Transit-style treatment.
                    LinearGradient(
                        stops: [
                            .init(color: AppTheme.Colors.accent.opacity(0.08), location: 0.0),
                            .init(color: AppTheme.Colors.accent.opacity(0.04), location: 0.25),
                            .init(color: AppTheme.Colors.cardBackground.opacity(0.0), location: 0.5),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
            }
            .presentationCornerRadius(32)
            .interactiveDismissDisabled()
            .preferredColorScheme(colorScheme)
            // ── Sheet height tracking at snap points only ──
            // The GeometryReader passively records the sheet's pixel height
            // each frame, but we only forward it to the map observer when
            // the detent actually snaps — not on every mid-drag frame.
            // This prevents per-frame setContentInset calls, which were
            // causing MapLibre to continuously reposition the camera center
            // (visible as a shake during interactive drag).
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: SheetMinYKey.self,
                            value: proxy.size.height
                        )
                }
            }
            .onPreferenceChange(SheetMinYKey.self) { height in
                // Passively record height — do NOT report to observer here.
                lastKnownHeight = height
            }
            .onChange(of: sheetDetent) { _, _ in
                // Sheet has settled at a new snap point — safe to update
                // the map's contentInset without causing drag-frame jitter.
                guard lastKnownHeight > 0 else { return }
                sheetHeightObserver?.report(lastKnownHeight)
            }
            .onChange(of: lastKnownHeight) { _, h in
                // Report the very first real height so the map inset is
                // correct as soon as the sheet appears (before any snap).
                guard !hasReportedInitial, h > 0 else { return }
                hasReportedInitial = true
                sheetHeightObserver?.report(h)
            }
            // Smooth dim overlay when color scheme changes
            .overlay {
                Color.black
                    .opacity(themeTransitionOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.25), value: themeTransitionOpacity)
            }
            .onChange(of: appTheme) { _, _ in
                themeTransitionOpacity = 0.4
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    themeTransitionOpacity = 0
                }
            }
    }
}

