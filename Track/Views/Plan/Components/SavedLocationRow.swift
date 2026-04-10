// A row for a saved location (Home, Work, School, etc.)
// displayed in the destination search or Plan tab.

import SwiftUI

struct SavedLocationRow: View {
    let location: SavedLocation
    let style: RowStyle
    let onTap: () -> Void
    var onMore: (() -> Void)?

    enum RowStyle {
        case compact     // Used inside search results (icon + name)
        case detailed    // Used on the Plan tab (icon + name + address + menu)
        case setPrompt   // "Set home" / "Set work" prompts
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon circle
                ZStack {
                    Circle()
                        .fill(iconBackground)
                        .frame(width: iconSize, height: iconSize)
                    Image(systemName: location.iconName)
                        .font(.system(size: iconFontSize, weight: .semibold))
                        .foregroundColor(iconForeground)
                }

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.name)
                        .font(style == .detailed ? AppTheme.Typography.cardTitle : AppTheme.Typography.body)
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)

                    if style == .detailed, !location.address.isEmpty {
                        Text(location.address)
                            .font(AppTheme.Typography.caption)
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                // More button or chevron
                if let onMore, style == .detailed {
                    Button(action: onMore) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, style == .detailed ? 14 : 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Style Properties

    private var iconSize: CGFloat {
        style == .detailed ? 40 : 32
    }

    private var iconFontSize: CGFloat {
        style == .detailed ? 16 : 14
    }

    private var iconBackground: Color {
        switch location.resolvedCategory {
        case .home:     return AppTheme.Colors.accent.opacity(0.15)
        case .work:     return AppTheme.Colors.warningYellow.opacity(0.15)
        case .school:   return AppTheme.Colors.successGreen.opacity(0.15)
        case .partner:  return AppTheme.Colors.alertRed.opacity(0.15)
        case .calendar: return AppTheme.Colors.accent.opacity(0.15)
        case .custom:   return AppTheme.Colors.cardInset
        }
    }

    private var iconForeground: Color {
        switch location.resolvedCategory {
        case .home:     return AppTheme.Colors.accent
        case .work:     return AppTheme.Colors.warningYellow
        case .school:   return AppTheme.Colors.successGreen
        case .partner:  return AppTheme.Colors.alertRed
        case .calendar: return AppTheme.Colors.accent
        case .custom:   return AppTheme.Colors.textSecondary
        }
    }
}

// MARK: - "Set" Prompt Row

/// "Set home", "Set work" placeholder rows when no saved location exists yet.
struct SetLocationPromptRow: View {
    let category: SavedLocationCategory
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: category.defaultIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .frame(width: 32, height: 32)

                Text("Set \(category.label.lowercased())")
                    .font(AppTheme.Typography.body)
                    .foregroundColor(AppTheme.Colors.textSecondary)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 0) {
        SavedLocationRow(
            location: SavedLocation(
                name: "Home",
                address: "117-13 125th St",
                latitude: 40.6745,
                longitude: -73.7955,
                category: .home
            ),
            style: .detailed,
            onTap: {},
            onMore: {}
        )
        SetLocationPromptRow(category: .work, onTap: {})
    }
    .background(Color.black)
}
