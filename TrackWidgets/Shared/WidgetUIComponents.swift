//
//  WidgetUIComponents.swift
//  TrackWidgets
//
//  Shared UI components and styling for all Widget extensions.
//

import SwiftUI

/// Premium Background with subtle gradient and material feel.
/// Used across TrackWidget, SingleRouteWidget, and LiveNearMeWidget.
struct WidgetBackground: View {
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ZStack {
            AppTheme.Colors.background
            
            LinearGradient(
                colors: [
                    AppTheme.Colors.mtaBlue.opacity(colorScheme == .dark ? 0.15 : 0.08),
                    Color.clear,
                    AppTheme.Colors.mtaBlue.opacity(colorScheme == .dark ? 0.05 : 0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}
