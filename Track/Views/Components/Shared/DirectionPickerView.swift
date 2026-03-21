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

/// Reusable horizontal direction picker with route-colored pills,
/// service-type badges (Exp/Lcl), and vehicle count badges.
struct DirectionPickerView: View {
    let directions: [DirectionPillData]
    let routeColor: Color
    var onSelect: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Direction")
                .font(.custom("Helvetica-Bold", size: 13))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.horizontal, AppTheme.Layout.margin)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
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
    }

    // MARK: - Pill Label

    private func directionPillLabel(_ dir: DirectionPillData) -> some View {
        HStack(spacing: 6) {
            // Direction arrow
            Image(systemName: directionIcon(for: dir.index, total: directions.count))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(dir.isActive ? .white : routeColor)

            // Label — show the full MTA direction name; the pill
            // scrolls horizontally so there is room for it.
            Text(dir.label)
                .font(.custom("Helvetica-Bold", size: 13))
                .foregroundColor(dir.isActive ? .white : AppTheme.Colors.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            // Express / Local badge
            if let sType = dir.serviceType, !sType.isEmpty {
                serviceTypePill(sType, isActive: dir.isActive)
            }

            // Vehicle count badge
            if dir.vehicleCount > 0 {
                Text("\(dir.vehicleCount)")
                    .font(.custom("Helvetica-Bold", size: 11))
                    .foregroundColor(dir.isActive ? routeColor : .white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(dir.isActive ? AppTheme.Colors.cardFloating.opacity(0.9) : routeColor)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(dir.isActive ? routeColor : AppTheme.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    dir.isActive ? Color.clear : routeColor.opacity(0.25),
                    lineWidth: 1)
        )
        .shadow(
            color: dir.isActive ? routeColor.opacity(0.3) : AppTheme.Colors.shadow.opacity(0.08),
            radius: dir.isActive ? 4 : 2,
            x: 0, y: dir.isActive ? 2 : 1
        )
    }

    // MARK: - Service Type Pill

    private func serviceTypePill(_ serviceType: String, isActive: Bool) -> some View {
        let badgeLabel: String = {
            switch serviceType.lowercased() {
            case "express": return "Exp"
            case "local": return "Lcl"
            case "mixed": return "Exp/Lcl"
            default: return String(serviceType.prefix(3)).capitalized
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
            .font(.custom("Helvetica-Bold", size: 9))
            .foregroundColor(badgeColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(isActive ? AppTheme.Colors.cardFloating.opacity(0.85) : badgeColor.opacity(0.12))
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

/// Reusable service-type badge (Express / Local / Mixed) with icon.
struct ServiceTypeBadge: View {
    let serviceType: String

    private var resolved: (label: String, icon: String, color: Color) {
        switch serviceType.lowercased() {
        case "express":
            return ("Express", "bolt.fill", AppTheme.Colors.successGreen)
        case "local":
            return ("Local", "circle.fill", AppTheme.Colors.textSecondary)
        case "mixed":
            return ("Express/Local", "bolt.horizontal.fill", AppTheme.Colors.warningYellow)
        default:
            return (serviceType.capitalized, "tram.fill", AppTheme.Colors.textSecondary)
        }
    }

    var body: some View {
        let r = resolved
        HStack(spacing: 3) {
            Image(systemName: r.icon)
                .font(.system(size: 7, weight: .bold))
            Text(r.label)
                .font(.custom("Helvetica-Bold", size: 10))
                .textCase(.uppercase)
                .tracking(0.8)
        }
        .foregroundColor(r.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(r.color.opacity(0.1))
        .clipShape(Capsule())
    }
}
