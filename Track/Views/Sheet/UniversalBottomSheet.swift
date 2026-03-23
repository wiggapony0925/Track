//
//  UniversalBottomSheet.swift
//  Track
//
//  A reusable bottom sheet container that manages all sheet-based navigation
//  in the app. This provides a consistent single-sheet experience where all
//  views (dashboard, route details, settings) are displayed within the same
//  modal, maintaining visual consistency and smooth transitions.
//
//  Usage:
//    UniversalBottomSheet(
//        navigator: sheetNavigator,
//        sheetDetent: $sheetDetent
//    ) { page in
//        switch page {
//        case .dashboard: DashboardView()
//        case .settings: SettingsContentView()
//        // etc.
//        }
//    }
//

import SwiftUI

/// Universal bottom sheet container that hosts all in-sheet navigation.
/// Provides consistent presentation, detents, and transition animations.
/// Note: Individual pages are responsible for their own navigation UI (back buttons, close buttons).
struct UniversalBottomSheet<Content: View>: View {
    /// Navigation state manager
    let navigator: SheetNavigator
    
    /// Current sheet detent (height)
    @Binding var sheetDetent: PresentationDetent
    
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
                ZStack {
                    AppTheme.Gradients.screen
                    AppTheme.Gradients.screenSheen
                    AppTheme.Gradients.screenGlow.opacity(0.72)
                }
                .ignoresSafeArea()
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .presentationDetents([.fraction(0.4), .large], selection: $sheetDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled)
            .presentationBackground(AppTheme.Gradients.floating)
            .presentationCornerRadius(32)
            .interactiveDismissDisabled()
            .preferredColorScheme(colorScheme)
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
    @Previewable @State var detent: PresentationDetent = .fraction(0.4)
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
