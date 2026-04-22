import SwiftUI

// MARK: - Direction Pill Data

/// Value bag for a single direction pill in the picker.
struct DirectionPillData: Identifiable {
    let id: String
    let index: Int
    let label: String
    let serviceType: String?    // "express" / "local" / "mixed" / nil
    let vehicleCount: Int
    let isActive: Bool
}

// MARK: - Direction Picker View

/// Reusable horizontal direction picker with route-colored capsule pills,
/// service-type badges, and vehicle count badges.
struct DirectionPickerView: View {
    let directions: [DirectionPillData]
    let routeColor: Color
    var onSelect: ((Int) -> Void)?

    private var labelWidthLimit: CGFloat {
        directions.count <= 2 ? 150 : 126
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(directions) { dir in
                    Button {
                        onSelect?(dir.index)
                    } label: {
                        directionPillLabel(dir)
                    }
                    .accessibilityLabel(
                        "\(dir.label), \(dir.vehicleCount) vehicles"
                    )
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
        }
    }

    // MARK: - Pill Label

    private func directionPillLabel(_ dir: DirectionPillData) -> some View {
        HStack(spacing: 5) {
            // Direction arrow
            Image(systemName: directionIcon(for: dir.index, total: directions.count))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(dir.isActive ? .white : routeColor.opacity(0.65))
                .symbolEffect(.bounce, value: dir.isActive)

            Text(dir.label)
                .font(.system(size: 13, weight: dir.isActive ? .bold : .semibold, design: .rounded))
                .foregroundColor(dir.isActive ? .white : AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.tail)
                .frame(maxWidth: labelWidthLimit, alignment: .leading)

            // Express / Local badge — compact
            if let sType = dir.serviceType, !sType.isEmpty {
                serviceTypePill(sType, isActive: dir.isActive)
            }

            // Vehicle count — dot-number
            if dir.vehicleCount > 0 {
                HStack(spacing: 3) {
                    Circle()
                        .fill(dir.isActive ? .white.opacity(0.7) : routeColor.opacity(0.45))
                        .frame(width: 4, height: 4)
                    Text("\(dir.vehicleCount)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundColor(dir.isActive ? .white.opacity(0.85) : AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            ZStack {
                if dir.isActive {
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: routeColor, location: 0),
                                    .init(color: routeColor.opacity(0.82), location: 1),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    // Glass highlight on active
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: AppTheme.Colors.chipGlassHighlight.opacity(0.18), location: 0),
                                    .init(color: .clear, location: 0.4),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                } else {
                    Capsule()
                        .fill(AppTheme.Colors.chipSurface)
                    // Subtle glass highlight on inactive
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: AppTheme.Colors.chipGlassHighlight.opacity(0.04), location: 0),
                                    .init(color: .clear, location: 0.5),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    dir.isActive
                        ? AnyShapeStyle(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.22), location: 0),
                                    .init(color: .white.opacity(0.04), location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                          )
                        : AnyShapeStyle(AppTheme.Colors.chipBorder),
                    lineWidth: dir.isActive ? 0.5 : 0.5
                )
        )
        .shadow(
            color: dir.isActive ? routeColor.opacity(0.3) : .clear,
            radius: 8, x: 0, y: 4
        )
        .shadow(
            color: dir.isActive ? routeColor.opacity(0.1) : .clear,
            radius: 16, x: 0, y: 6
        )
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: - Service Type Pill

    private func serviceTypePill(_ serviceType: String, isActive: Bool) -> some View {
        let badgeLabel: String = {
            switch serviceType.lowercased() {
            case "express": return "EXP"
            case "local": return "LCL"
            case "mixed": return "E/L"
            default: return String(serviceType.prefix(3)).uppercased()
            }
        }()
        let badgeColor: Color = {
            switch serviceType.lowercased() {
            case "express": return AppTheme.Colors.successGreen
            case "mixed": return AppTheme.Colors.warningYellow
            default: return AppTheme.Colors.textSecondary
            }
        }()

        return Text(badgeLabel)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(0.3)
            .foregroundColor(isActive ? .white.opacity(0.9) : badgeColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                isActive
                    ? Color.white.opacity(0.18)
                    : badgeColor.opacity(0.12)
            )
            .clipShape(Capsule())
    }

    // MARK: - Direction Icon

    private func directionIcon(for index: Int, total: Int) -> String {
        if total <= 2 {
            return index == 0 ? "arrow.up" : "arrow.down"
        }
        let icons = [
            "arrow.up", "arrow.down", "arrow.left", "arrow.right",
            "arrow.up.right", "arrow.down.left", "arrow.up.left", "arrow.down.right",
            "arrow.turn.up.right", "arrow.turn.down.left",
            "arrow.turn.up.left", "arrow.turn.down.right",
            "arrow.uturn.up", "arrow.uturn.down",
            "arrow.uturn.left", "arrow.uturn.right",
        ]
        return icons[index % icons.count]
    }
}

// MARK: - Service Type Badge (Standalone)

/// Reusable service-type badge — renders a compact pill describing the
/// route's service variant (Express subway, SBS / Limited / Express bus,
/// Local, or a Mixed Express+Local direction).  Used by:
///   • `DirectionPickerView` to label a direction's express mix
///   • `MapControlsOverlay` route header to flag SBS / Express / Limited
///
/// Returns `nil` for unremarkable defaults (e.g. plain Local bus or
/// non-express subway) so callers can omit the pill entirely instead
/// of showing a redundant "Local" tag next to the route badge.
struct ServiceTypeBadge: View {
    let serviceType: String

    /// Convenience init for a subway route — passes "express" when the
    /// route is an express variant (e.g. `<6>`, `<7>`, FX), otherwise
    /// returns nil-equivalent ("local") which the caller can filter on.
    static func subway(isExpress: Bool) -> ServiceTypeBadge? {
        isExpress ? ServiceTypeBadge(serviceType: "express") : nil
    }

    /// Convenience init for a bus route — returns nil for plain "Local"
    /// (the most common case) so the route badge stands on its own.
    static func bus(serviceType: String?) -> ServiceTypeBadge? {
        guard let svc = serviceType?.trimmingCharacters(in: .whitespaces),
              !svc.isEmpty else { return nil }
        if svc.lowercased() == "local" { return nil }
        return ServiceTypeBadge(serviceType: svc)
    }

    private var resolved: (label: String, icon: String, color: Color) {
        switch serviceType.lowercased() {
        case "express":
            return ("Express", "bolt.fill", AppTheme.Colors.successGreen)
        case "select bus service", "sbs":
            return ("SBS", "bolt.horizontal.fill", AppTheme.BusColors.sbsCyan)
        case "limited":
            return ("Limited", "forward.fill", AppTheme.BusColors.limitedPurple)
        case "school":
            return ("School", "graduationcap.fill", AppTheme.BusColors.schoolOrange)
        case "local":
            return ("Local", "circle.fill", AppTheme.Colors.textSecondary)
        case "mixed":
            return ("Exp / Local", "bolt.horizontal.fill", AppTheme.Colors.warningYellow)
        default:
            return (serviceType.capitalized, "tram.fill", AppTheme.Colors.textSecondary)
        }
    }

    var body: some View {
        let r = resolved
        HStack(spacing: 3) {
            Image(systemName: r.icon)
                .font(.system(size: 8, weight: .semibold))
            Text(r.label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .foregroundColor(r.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(r.color.opacity(0.1))
        .clipShape(Capsule())
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}
