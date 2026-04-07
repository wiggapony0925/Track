// A clean segmented tab picker with icons, labels, and optional badge
// counts. Active tab uses a filled capsule with accent color; inactive
// tabs are transparent. Designed for the route detail sheet and reusable
// across the app.

import SwiftUI

// MARK: - Tab descriptor

/// Lightweight descriptor for a single tab pill.
struct PillTab: Identifiable {
    let id: String
    let label: String
    let icon: String
    /// Optional badge count. 0 = hidden, >99 shows "99+".
    var badgeCount: Int = 0
}

// MARK: - PillTabPicker

struct PillTabPicker: View {
    let tabs: [PillTab]
    @Binding var selectedId: String
    var accentColor: Color = AppTheme.Colors.mtaBlue

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let isActive: Bool = selectedId == tab.id
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selectedId = tab.id
                    }
                } label: {
                    pillLabel(tab: tab, isActive: isActive)
                }
                .sensoryFeedback(.selection, trigger: selectedId)
                .accessibilityLabel(Text("\(tab.label) tab"))
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(AppTheme.Colors.cardBackground.opacity(0.6))
        )
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    // MARK: - Pill label

    private func pillLabel(tab: PillTab, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: tab.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isActive ? .white : AppTheme.Colors.textSecondary)

            Text(tab.label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(isActive ? .white : AppTheme.Colors.textSecondary)
                .lineLimit(1)

            if tab.badgeCount > 0 {
                badgeView(count: tab.badgeCount, isActive: isActive)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(
                    isActive
                        ? AnyShapeStyle(
                            LinearGradient(
                                stops: [
                                    .init(color: accentColor, location: 0),
                                    .init(color: accentColor.opacity(0.85), location: 1),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                          )
                        : AnyShapeStyle(Color.clear)
                )
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isActive ? .white.opacity(0.12) : .clear,
                    lineWidth: 0.5
                )
        )
        .shadow(
            color: isActive ? accentColor.opacity(0.2) : .clear,
            radius: 4, x: 0, y: 2
        )
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: - Badge

    private func badgeView(count: Int, isActive: Bool) -> some View {
        let label = count > 99 ? "99+" : "\(count)"
        return Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(isActive ? .white : accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(isActive ? .white.opacity(0.2) : accentColor.opacity(0.12))
            )
    }
}
