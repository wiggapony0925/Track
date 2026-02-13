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
        case custom(CGFloat, CGFloat) // dimension, fontSize

        var dimension: CGFloat {
            switch self {
            case .small: return AppTheme.Layout.badgeSizeSmall
            case .medium: return AppTheme.Layout.badgeSizeMedium
            case .large: return AppTheme.Layout.badgeSizeLarge
            case .custom(let d, _): return d
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .small: return AppTheme.Layout.badgeFontSmall
            case .medium: return AppTheme.Layout.badgeFontMedium
            case .large: return AppTheme.Layout.badgeFontLarge
            case .custom(_, let f): return f
            }
        }
    }

    var body: some View {
        Text(routeID)
            .font(.custom("Helvetica-Bold", size: size.fontSize))
            .foregroundColor(AppTheme.SubwayColors.textColor(for: routeID))
            .minimumScaleFactor(0.4)
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
