//
//  RouteBadge.swift
//  Track
//
//  Reusable route badge component used across all views.
//  Displays a route ID with distinct visual styles:
//  - Subway/Rail: Circle with official MTA route colors
//  - Bus: Rounded pill/capsule shape (Blue for local, Purple for SBS)
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

    var isBus: Bool = false
    var hexColor: String? = nil
    
    /// Detects SBS (Select Bus Service) routes for distinct purple styling.
    /// SBS routes typically have "SBS" in their name (e.g., "M15-SBS", "Bx12-SBS")
    private var isSBS: Bool {
        routeID.uppercased().contains("SBS")
    }
    
    /// Bus background color: Purple for SBS, Blue for local buses
    private var busBackgroundColor: Color {
        if let hex = hexColor {
            return Color(hex: hex)
        }
        return isSBS ? AppTheme.BusColors.sbsPurple : AppTheme.BusColors.localBlue
    }

    private var backgroundColor: Color {
        if let hex = hexColor {
            return Color(hex: hex)
        }
        if isBus {
            return busBackgroundColor
        }
        return AppTheme.SubwayColors.color(for: routeID)
    }

    var body: some View {
        if isBus {
            // Bus Style: Rounded rectangle/pill with distinct colors
            Text(routeID)
                .font(.system(size: size.fontSize, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(minWidth: size.dimension, minHeight: size.dimension)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundColor)
                )
                .accessibilityLabel("\(isSBS ? "Select Bus Service" : "Bus") Route \(routeID)")
        } else {
            // Subway/Rail Style: Official Circle
            Text(routeID)
                .font(.custom("Helvetica-Bold", size: size.fontSize))
                .foregroundColor(AppTheme.SubwayColors.textColor(for: routeID))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .frame(width: size.dimension, height: size.dimension)
                .background(backgroundColor)
                .clipShape(Circle())
                .accessibilityLabel("Subway Route \(routeID)")
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        // Subway routes (circles)
        HStack(spacing: 16) {
            RouteBadge(routeID: "L", size: .small)
            RouteBadge(routeID: "4", size: .medium)
            RouteBadge(routeID: "A", size: .large)
            RouteBadge(routeID: "N", size: .medium)
        }
        
        // Bus routes (rounded rectangles)
        HStack(spacing: 16) {
            RouteBadge(routeID: "B63", size: .medium, isBus: true)
            RouteBadge(routeID: "M15-SBS", size: .medium, isBus: true)
            RouteBadge(routeID: "Bx12-SBS", size: .medium, isBus: true)
        }
    }
    .padding()
    .background(Color.black)
}
