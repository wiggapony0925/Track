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
    
    /// Content builder that maps SheetPage to actual views
    let content: (SheetPage) -> Content
    
    var body: some View {
        // Page content with transitions
        content(navigator.currentPage)
            .id(navigator.currentPage.id)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .presentationDetents([.fraction(0.4), .large], selection: $sheetDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled)
            .interactiveDismissDisabled()
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
