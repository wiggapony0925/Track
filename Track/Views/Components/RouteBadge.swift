//
//  RouteBadge.swift
//  Track
//
//  Reusable route badge component used across all views.
//  Displays a route ID in a colored circle with consistent sizing.
//

import SwiftUI

struct RouteBadge: View {
    let routeID: String
    let size: BadgeSize

    enum BadgeSize {
        case small
        case medium
        case large

        var dimension: CGFloat {
            switch self {
            case .small: return AppTheme.Layout.badgeSizeSmall
            case .medium: return AppTheme.Layout.badgeSizeMedium
            case .large: return AppTheme.Layout.badgeSizeLarge
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .small: return AppTheme.Layout.badgeFontSmall
            case .medium: return AppTheme.Layout.badgeFontMedium
            case .large: return AppTheme.Layout.badgeFontLarge
            }
        }
    }

    var body: some View {
        Text(routeID)
            .font(.system(size: size.fontSize, weight: .heavy, design: .monospaced))
            .foregroundColor(AppTheme.SubwayColors.textColor(for: routeID))
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .frame(width: size.dimension, height: size.dimension)
            .background(AppTheme.SubwayColors.color(for: routeID))
            .clipShape(Circle())
            .accessibilityLabel("Route \(routeID)")
    }
}

#Preview {
    HStack(spacing: 16) {
        RouteBadge(routeID: "L", size: .small)
        RouteBadge(routeID: "4", size: .medium)
        RouteBadge(routeID: "A", size: .large)
    }
    .padding()
}
