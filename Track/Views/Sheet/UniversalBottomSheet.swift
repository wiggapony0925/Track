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
struct UniversalBottomSheet<Content: View>: View {
    /// Navigation state manager
    let navigator: SheetNavigator
    
    /// Current sheet detent (height)
    @Binding var sheetDetent: PresentationDetent
    
    /// Content builder that maps SheetPage to actual views
    let content: (SheetPage) -> Content
    
    var body: some View {
        VStack(spacing: 0) {
            // Navigation bar for non-root pages
            if navigator.canGoBack {
                sheetNavBar
            }
            
            // Page content with transitions
            content(navigator.currentPage)
                .id(navigator.currentPage.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
        .presentationDetents([.fraction(0.4), .large], selection: $sheetDetent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled)
        .interactiveDismissDisabled()
    }
    
    // MARK: - Navigation Bar
    
    private var sheetNavBar: some View {
        HStack {
            Button {
                navigator.goBack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text(backButtonTitle)
                        .font(.custom("Helvetica", size: 16))
                }
                .foregroundColor(AppTheme.Colors.mtaBlue)
            }
            .accessibilityLabel("Go back")
            
            Spacer()
            
            // Title for current page
            Text(pageTitle)
                .font(.custom("Helvetica-Bold", size: 17))
                .foregroundColor(AppTheme.Colors.textPrimary)
            
            Spacer()
            
            // Close button (returns to root)
            if shouldShowCloseButton {
                Button {
                    navigator.popToRoot()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .accessibilityLabel("Close")
            } else {
                // Spacer to balance the back button
                Color.clear
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.vertical, 12)
        .background(AppTheme.Colors.background)
    }
    
    // MARK: - Helpers
    
    private var backButtonTitle: String {
        // Get the title of the previous page
        guard navigator.pageStack.count > 1 else { return "Back" }
        let previousPage = navigator.pageStack[navigator.pageStack.count - 2]
        switch previousPage {
        case .dashboard:
            return "Home"
        case .settings:
            return "Settings"
        case .widgetSchedules:
            return "Schedules"
        default:
            return "Back"
        }
    }
    
    private var pageTitle: String {
        switch navigator.currentPage {
        case .dashboard:
            return ""
        case .routeDetail(let group, _):
            return group.displayName
        case .settings:
            return "Settings"
        case .widgetSchedules:
            return "Widget Schedules"
        case .scheduleEditor:
            return "Edit Schedule"
        }
    }
    
    private var shouldShowCloseButton: Bool {
        switch navigator.currentPage {
        case .routeDetail, .settings, .widgetSchedules, .scheduleEditor:
            return true
        case .dashboard:
            return false
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
