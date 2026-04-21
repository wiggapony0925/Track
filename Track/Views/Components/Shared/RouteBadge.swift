// Reusable route badge component used across all views.
// Displays a route ID with distinct visual styles:
// - Subway: Circle with official MTA route colors
// - Bus: Rounded pill/capsule shape (Blue for local, Purple for SBS)
// - LIRR: Rounded rectangle with train icon, LIRR blue
// - Metro-North: Rounded rectangle with train icon, MNR blue

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
    /// Server-provided express flag — overrides client-side detection when true.
    var isExpressOverride: Bool = false
    /// Backend bus service type (e.g. "Local", "Select Bus Service", "Limited", "Express").
    var busServiceType: String? = nil
    
    // MARK: - Derived State
    
    /// Whether this badge represents a LIRR route
    private var isLIRR: Bool { mode == "lirr" }
    
    /// Whether this badge represents a Metro-North route
    private var isMNR: Bool { mode == "mnr" }
    
    /// Whether this badge represents commuter rail (LIRR or MNR)
    private var isCommuterRail: Bool { isLIRR || isMNR }
    
    /// Resolved bus flag — either explicit `isBus` or derived from `mode`
    private var resolvedIsBus: Bool { isBus || mode == "bus" }
    
    /// Detects SBS (Select Bus Service) routes — prefers the backend
    /// `busServiceType` field, falling back to name-based detection.
    private var isSBS: Bool {
        resolvedBusServiceType?.lowercased() == "select bus service"
    }

    private var resolvedBusServiceType: String? {
        if let svc = busServiceType, !svc.isEmpty {
            return svc
        }
        let upper = routeID.uppercased()
        if upper.contains("SBS") || upper.hasSuffix("+") {
            return "Select Bus Service"
        }
        if upper.hasPrefix("BXM") || upper.hasPrefix("BM") || upper.hasPrefix("QM")
            || upper.hasPrefix("SIM") || upper.hasPrefix("X") {
            return "Express"
        }
        return nil
    }

    /// Display text for bus badges.
    /// The backend normalises SBS routes to "+" notation (e.g. "M34+"),
    /// so no client-side suffix stripping is needed. Any residual "-SBS" /
    /// "+SBS" suffix is stripped as a safety net for stale data.
    private var busDisplayText: String {
        var text = routeID
        for suffix in ["-SBS", "+SBS"] {
            if let range = text.range(of: suffix, options: .caseInsensitive) {
                text.removeSubrange(range)
                // Append "+" so the badge reads "M34+" in the worst case
                if !text.hasSuffix("+") { text += "+" }
            }
        }
        return text
    }

    /// Express subway variants use a diamond-shaped badge (MTA standard).
    /// Only these three variant route IDs get a diamond — regular express
    /// routes (A, B, D, E, 2-5, N, Q, Z) keep their standard circle badge.
    private static let expressVariants: Set<String> = ["6X", "7X", "FX"]

    private var isExpressSubway: Bool {
        Self.expressVariants.contains(routeID.uppercased())
    }

    /// The base route number shown inside the diamond (e.g., "7" for "7X").
    private var expressBaseRoute: String {
        String(routeID.uppercased().dropLast())
    }
    
    /// Bus background color — uses hex when available, then service type,
    /// then name-based SBS detection, else local blue.
    private var busBackgroundColor: Color {
        // Use the service-type palette when the backend told us the type
        if let svc = resolvedBusServiceType {
            return AppTheme.BusColors.color(forServiceType: svc)
        }
        // Fallback: cyan for SBS-looking names, local blue otherwise
        return isSBS ? AppTheme.BusColors.sbsCyan : AppTheme.BusColors.localBlue
    }

    private var commuterRailBackgroundColor: Color {
        if let hex = hexColor {
            return Color(hex: hex)
        }
        if isLIRR {
            return AppTheme.CommuterRailColors.lirrColor(for: routeID)
        }
        if isMNR {
            return AppTheme.CommuterRailColors.mnrColor(for: routeID)
        }
        return AppTheme.Colors.mtaBlue
    }

    private var backgroundColor: Color {
        if resolvedIsBus {
            return busBackgroundColor
        }
        if let hex = hexColor {
            return Color(hex: hex)
        }
        if isLIRR {
            return commuterRailBackgroundColor
        }
        if isMNR {
            return commuterRailBackgroundColor
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
        } else if isExpressSubway {
            // Express Subway: Diamond shape (MTA standard for 6X, 7X, FX)
            expressDiamondBadge
        } else {
            // Subway Style: Official Circle
            subwayBadge
        }
    }
    
    // MARK: - Subway Badge (Circle)
    
    private var subwayBadge: some View {
        let dim = size.dimension
        return Text(routeID)
            .font(.system(size: size.fontSize, weight: .heavy, design: .rounded))
            .foregroundColor(AppTheme.SubwayColors.textColor(for: routeID))
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .frame(width: dim, height: dim)
            .background(
                ZStack {
                    // Base fill
                    Circle().fill(backgroundColor)
                    // Top-lit specular highlight
                    Circle().fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(0.28),
                                .white.opacity(0.08),
                                .clear,
                            ],
                            center: .init(x: 0.35, y: 0.2),
                            startRadius: 0,
                            endRadius: dim * 0.6
                        )
                    )
                    // Bottom shadow for 3D curvature
                    Circle().fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.5),
                                .init(color: .black.opacity(0.18), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    // Inner highlight ring
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.3), location: 0),
                                    .init(color: .white.opacity(0.05), location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: size == .large ? 1.5 : 0.8
                        )
                }
            )
            .clipShape(Circle())
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityLabel("Subway Route \(routeID)")
    }

    // MARK: - Express Diamond Badge

    /// Diamond-shaped badge for express subway variants (6X, 7X, FX).
    /// Shows the base route number inside a 45° rotated square.
    private var expressDiamondBadge: some View {
        let base = expressBaseRoute
        let dim = size.dimension
        let cr = dim * 0.12
        let innerDim = dim * 0.72
        return Text(base)
            .font(.system(
                size: size.fontSize * 0.85,
                weight: .heavy,
                design: .rounded
            ))
            .foregroundColor(AppTheme.SubwayColors.textColor(for: base))
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .frame(width: innerDim, height: innerDim)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cr, style: .continuous)
                        .fill(backgroundColor)
                        .rotationEffect(.degrees(45))
                    RoundedRectangle(cornerRadius: cr, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    .white.opacity(0.25),
                                    .white.opacity(0.06),
                                    .clear,
                                ],
                                center: .init(x: 0.35, y: 0.2),
                                startRadius: 0,
                                endRadius: innerDim * 0.55
                            )
                        )
                        .rotationEffect(.degrees(45))
                    RoundedRectangle(cornerRadius: cr, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.5),
                                    .init(color: .black.opacity(0.16), location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .rotationEffect(.degrees(45))
                    RoundedRectangle(cornerRadius: cr, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.3), location: 0),
                                    .init(color: .clear, location: 0.6),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                        .rotationEffect(.degrees(45))
                }
            )
            .frame(width: dim, height: dim)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityLabel("Express Subway Route \(routeID)")
    }
    
    // MARK: - Bus Badge (Pill)
    
    private var busBadge: some View {
        Text(busDisplayText)
            .font(.system(size: size.fontSize, weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minWidth: size.dimension, minHeight: size.dimension)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(backgroundColor)
                    // Specular highlight
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    .white.opacity(0.22),
                                    .white.opacity(0.04),
                                    .clear,
                                ],
                                center: .init(x: 0.3, y: 0.15),
                                startRadius: 0,
                                endRadius: 40
                            )
                        )
                    // Bottom darkening
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.55),
                                    .init(color: .black.opacity(0.12), location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    // Top-lit border
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.25), location: 0),
                                    .init(color: .white.opacity(0.04), location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                }
            )
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityLabel("\(isSBS ? "Select Bus Service" : "Bus") Route \(routeID)")
    }
    
    // MARK: - Commuter Rail Badge (Rounded Rect + Train Icon)
    
    private var commuterRailBadge: some View {
        HStack(spacing: size == .small ? 3 : 5) {
            Image(systemName: isLIRR ? "train.side.front.car" : "train.side.rear.car")
                .font(.system(size: commuterIconSize, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            
            Text(commuterDisplayText)
                .font(.system(size: commuterFontSize, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
        }
        .padding(.horizontal, size == .small ? 7 : 10)
        .padding(.vertical, size == .small ? 4 : 6)
        .frame(minHeight: size.dimension)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(0.20),
                                .white.opacity(0.04),
                                .clear,
                            ],
                            center: .init(x: 0.25, y: 0.15),
                            startRadius: 0,
                            endRadius: 50
                        )
                    )
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.55),
                                .init(color: .black.opacity(0.12), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.25), location: 0),
                                .init(color: .white.opacity(0.04), location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
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
        
        // Express subway (diamonds)
        HStack(spacing: 16) {
            RouteBadge(routeID: "6X", size: .small)
            RouteBadge(routeID: "7X", size: .medium)
            RouteBadge(routeID: "FX", size: .large)
        }
        
        // Bus routes (rounded rectangles) — full service-type palette
        HStack(spacing: 16) {
            RouteBadge(routeID: "B63", size: .medium, isBus: true, busServiceType: "Local")
            RouteBadge(routeID: "M15-SBS", size: .medium, isBus: true, busServiceType: "Select Bus Service")
            RouteBadge(routeID: "Q9", size: .medium, isBus: true, busServiceType: "Limited")
            RouteBadge(routeID: "BxM1", size: .medium, isBus: true, busServiceType: "Express")
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
