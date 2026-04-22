// Observable navigation state manager for the universal bottom sheet.
// Provides a navigation stack within the sheet, allowing pages to be
// pushed and popped while maintaining consistent sheet behavior.

import SwiftUI

/// Manages navigation state within the universal bottom sheet.
/// Provides a stack-based navigation model for seamless page transitions.
@Observable
@MainActor
final class SheetNavigator {
    /// The current navigation stack of pages
    private(set) var pageStack: [SheetPage] = [.dashboard]
    
    /// The currently visible page (top of the stack)
    var currentPage: SheetPage {
        pageStack.last ?? .dashboard
    }
    
    /// Whether we can navigate back
    var canGoBack: Bool {
        pageStack.count > 1
    }
    
    /// Navigate to a new page by pushing it onto the stack
    func navigate(to page: SheetPage) {
        // Route detail is rendered in its own overlay (HomeView) with its
        // own move/opacity transition, so animating the stack mutation
        // here just adds a redundant 180ms ease that delays the overlay
        // appearing.  Other pages still get the cross-fade transition.
        if case .routeDetail = page {
            pageStack.append(page)
            return
        }
        withAnimation(.easeOut(duration: 0.18)) {
            pageStack.append(page)
        }
    }
    
    /// Go back to the previous page
    func goBack() {
        guard canGoBack else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            _ = pageStack.popLast()
        }
    }
    
    /// Return to the dashboard (root)
    func popToRoot() {
        withAnimation(.easeOut(duration: 0.18)) {
            pageStack = [.dashboard]
        }
    }
    
    /// Replace the current page (useful for detail views)
    func replace(with page: SheetPage) {
        guard !pageStack.isEmpty else {
            pageStack = [page]
            return
        }
        withAnimation(.easeOut(duration: 0.18)) {
            pageStack[pageStack.count - 1] = page
        }
    }
}
