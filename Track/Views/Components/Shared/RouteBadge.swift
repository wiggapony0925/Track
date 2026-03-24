//
//  RouteBadge.swift
//  Track
//
//  Reusable route badge component used across all views.
//  Displays a route ID with distinct visual styles:
//  - Subway: Circle with official MTA route colors
//  - Bus: Rounded pill/capsule shape (Blue for local, Purple for SBS)
//  - LIRR: Rounded rectangle with train icon, LIRR blue
//  - Metro-North: Rounded rectangle with train icon, MNR blue
//

import SwiftUI

struct RouteBadge: View {
    let routeID: String
    let size: BadgeSize

    enum BadgeSize: Equatable {
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
    /// Transit mode: "subway", "bus", "lirr", "mnr". Determines badge style.
    var mode: String? = nil
    
    // MARK: - Derived State
    
    /// Whether this badge represents a LIRR route
    private var isLIRR: Bool { mode == "lirr" }
    
    /// Whether this badge represents a Metro-North route
    private var isMNR: Bool { mode == "mnr" }
    
    /// Whether this badge represents commuter rail (LIRR or MNR)
    private var isCommuterRail: Bool { isLIRR || isMNR }
    
    /// Resolved bus flag — either explicit `isBus` or derived from `mode`
    private var resolvedIsBus: Bool { isBus || mode == "bus" }
    
    /// Detects SBS (Select Bus Service) routes for distinct purple styling.
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
        if resolvedIsBus {
            return busBackgroundColor
        }
        if isLIRR {
            return AppTheme.CommuterRailColors.lirrBlue
        }
        if isMNR {
            return AppTheme.CommuterRailColors.mnrBlue
        }
        return AppTheme.SubwayColors.color(for: routeID)
    }

    var body: some View {
        if isCommuterRail {
            // Commuter Rail Style: Rounded rectangle with train icon
            commuterRailBadge
        } else if resolvedIsBus {
            // Bus Style: Rounded rectangle/pill with distinct colors
            busBadge
        } else {
            // Subway Style: Official Circle
            subwayBadge
        }
    }
    
    // MARK: - Subway Badge (Circle)
    
    private var subwayBadge: some View {
        Text(routeID)
            .font(.system(size: size.fontSize, weight: .heavy, design: .rounded))
            .foregroundColor(AppTheme.SubwayColors.textColor(for: routeID))
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .frame(width: size.dimension, height: size.dimension)
            .background(backgroundColor)
            .clipShape(Circle())
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityLabel("Subway Route \(routeID)")
    }
    
    // MARK: - Bus Badge (Pill)
    
    private var busBadge: some View {
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
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityLabel("\(isSBS ? "Select Bus Service" : "Bus") Route \(routeID)")
    }
    
    // MARK: - Commuter Rail Badge (Rounded Rect + Train Icon)
    
    private var commuterRailBadge: some View {
        HStack(spacing: size == .small ? 2 : 4) {
            // LIRR: front-facing train icon | MNR: rear-facing train icon
            Image(systemName: isLIRR ? "train.side.front.car" : "train.side.rear.car")
                .font(.system(size: commuterIconSize, weight: .bold))
                .foregroundColor(.white)
            
            Text(commuterDisplayText)
                .font(.system(size: commuterFontSize, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
        }
        .padding(.horizontal, size == .small ? 6 : 8)
        .padding(.vertical, size == .small ? 3 : 5)
        .frame(minHeight: size.dimension)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        )
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityLabel("\(isLIRR ? "LIRR" : "Metro-North") \(routeID)")
    }
    
    /// Abbreviated display text for commuter rail
    private var commuterDisplayText: String {
        // If the route name is very long (e.g. "Port Washington Branch"),
        // abbreviate it. Otherwise show as-is.
        let name = routeID
        if name.hasSuffix(" Branch") {
            return String(name.dropLast(7))
        }
        if name.hasSuffix(" Line") {
            return String(name.dropLast(5))
        }
        return name
    }
    
    private var commuterIconSize: CGFloat {
        switch size {
        case .small: return 9
        case .medium: return 12
        case .large: return 16
        case .custom(let d, _): return d * 0.35
        }
    }
    
    private var commuterFontSize: CGFloat {
        switch size {
        case .small: return 10
        case .medium: return 13
        case .large: return 16
        case .custom(_, let f): return f * 0.8
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
        
        // LIRR routes (rounded rect + train icon)
        HStack(spacing: 16) {
            RouteBadge(routeID: "Port Washington Branch", size: .small, mode: "lirr")
            RouteBadge(routeID: "Babylon Branch", size: .medium, mode: "lirr")
            RouteBadge(routeID: "Ronkonkoma Branch", size: .large, mode: "lirr")
        }
        
        // Metro-North routes (rounded rect + train icon)
        HStack(spacing: 16) {
            RouteBadge(routeID: "Harlem Line", size: .small, mode: "mnr")
            RouteBadge(routeID: "Hudson Line", size: .medium, mode: "mnr")
            RouteBadge(routeID: "New Haven Line", size: .large, mode: "mnr")
        }
    }
    .padding()
    .background(Color.black)
}
