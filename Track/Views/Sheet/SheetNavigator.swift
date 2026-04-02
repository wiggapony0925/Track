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
        withAnimation(.easeInOut(duration: 0.25)) {
            pageStack.append(page)
        }
    }
    
    /// Go back to the previous page
    func goBack() {
        guard canGoBack else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            _ = pageStack.popLast()
        }
    }
    
    /// Return to the dashboard (root)
    func popToRoot() {
        withAnimation(.easeInOut(duration: 0.25)) {
            pageStack = [.dashboard]
        }
    }
    
    /// Replace the current page (useful for detail views)
    func replace(with page: SheetPage) {
        guard !pageStack.isEmpty else {
            pageStack = [page]
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            pageStack[pageStack.count - 1] = page
        }
    }
}
