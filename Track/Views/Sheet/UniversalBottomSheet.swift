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
    /// Default resting position measured from live drag calibration.
    static let defaultHeight: CGFloat = 350
    /// Lowest collapsed height measured from live drag calibration.
    static let minimumHeight: CGFloat = 165
    /// Convenience detent value for the default resting position.
    static let defaultDetent: TrackSheetDetent = .height(defaultHeight)

    /// Builds the peek detent from the measured navbar height.
    /// Never allow the sheet to collapse below the calibrated minimum.
    static func peekDetent(navbarHeight: CGFloat) -> TrackSheetDetent {
        .height(max(navbarHeight, minimumHeight))
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
/// Renders through ``TrackBottomSheet`` (custom drag-controlled overlay)
/// while preserving the legacy `@Binding var sheetDetent: PresentationDetent`
/// API so every existing call site keeps compiling.
///
/// Detent semantics — ``TrackBottomSheet`` props are derived from existing
/// ``SheetConstants`` so the sheet keeps using the project-wide 45% default
/// and the navbar-derived peek.  Override by passing a different
/// `detents` / `defaultDetent` set when constructing.
struct UniversalBottomSheet<Content: View>: View {
    /// Navigation state manager
    let navigator: SheetNavigator

    /// Current sheet detent (height) — native ``TrackSheetDetent`` so
    /// freeform `.height(x)` values written by inner views (e.g. the
    /// dashboard's continuous drag) propagate without lossy bridging.
    @Binding var sheetDetent: TrackSheetDetent

    /// Continuously reports the sheet's pixel height for interactive
    /// map camera tracking.  Optional — nil in previews.
    var sheetHeightObserver: SheetHeightObserver?

    /// Optional live-height callback for SwiftUI consumers (e.g. the
    /// floating tab pill) that need to ride along with the drag.  This
    /// is in addition to ``sheetHeightObserver`` which targets UIKit.
    var onLiveHeightChange: ((CGFloat) -> Void)? = nil

    /// Theme setting — must be read here so the sheet inherits the correct color scheme.
    @AppStorage("appTheme") private var appTheme = "system"

    /// Content builder that maps SheetPage to actual views
    let content: (SheetPage) -> Content

    /// Measured height of the dashboard navbar (header + search + tabs).
    /// Drives the peek detent so it adapts to content changes automatically.
    @State private var navbarHeight: CGFloat = 150 // sensible default until measured

    /// Brief dimming overlay for smooth dark ↔ light transition.
    @State private var themeTransitionOpacity: Double = 0

    /// Maps the appTheme string to a ColorScheme for the sheet.
    private var colorScheme: ColorScheme? {
        switch appTheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    /// Detents used by the underlying ``TrackBottomSheet``.
    /// Order doesn't matter — closest-snap picks the right one.
    private var trackDetents: [TrackSheetDetent] {
        [
            .height(0),                                            // fully collapsed — shows peek button
            SheetConstants.peekDetent(navbarHeight: navbarHeight),
            SheetConstants.defaultDetent,
            .large,
        ]
    }

    var body: some View {
        TrackBottomSheet(
            selection: $sheetDetent,
            detents: trackDetents,
            cornerRadius: 28,
            topInset: 12,
            topFade: false,
            onHeightChange: { h in
                sheetHeightObserver?.report(h)
                onLiveHeightChange?(h)
            },
            freeform: true
        ) {
            content(navigator.currentPage)
                .id(navigator.currentPage.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .onPreferenceChange(NavbarHeightKey.self) { height in
                    guard height > 0 else { return }
                    navbarHeight = height
                }
                .preferredColorScheme(colorScheme)
        }
        // Smooth dim overlay when color scheme changes — preserved from
        // the original `.sheet`-based implementation.
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

