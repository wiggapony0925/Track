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

// MARK: - Preference Key

/// Tracks the sheet's minY in the global coordinate space so we can
/// compute its pixel height continuously during interactive drags.
private struct SheetMinYKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
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
            .presentationDetents([.fraction(SheetConstants.defaultFraction), .large], selection: $sheetDetent)
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
            // ── Interactive sheet height tracking ──
            // The sheet re-proposes its height to the content on every
            // drag frame, so proxy.size.height tracks the sheet's pixel
            // height in real-time — no need for screen-height math.
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
                sheetHeightObserver?.report(height)
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

#Preview {
    @Previewable @State var detent: PresentationDetent = SheetConstants.defaultDetent
    let navigator = SheetNavigator()
    
    Color.gray.opacity(0.3)
        .sheet(isPresented: .constant(true)) {
            UniversalBottomSheet(
                navigator: navigator,
                sheetDetent: $detent
            ) { page in
                switch page {
                case .dashboard:
                    Text("Dashboard Content")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppTheme.Colors.background)
                default:
                    Text("Other Page")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppTheme.Colors.background)
                }
            }
        }
}
