// A premium segmented tab picker with a sliding glass indicator,
// icons, labels, and optional badge counts. The active tab slides
// with a matched geometry capsule. Designed for the route detail
// sheet and reusable across the app.

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

    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isActive: Bool = selectedId == tab.id
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.Colors.chipSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: AppTheme.Colors.chipGlassHighlight.opacity(0.03), location: 0.0),
                                    .init(color: .clear, location: 0.5),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(AppTheme.Colors.chipBorder, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    // MARK: - Pill label

    private func pillLabel(tab: PillTab, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .semibold))
                .symbolEffect(.bounce, value: isActive)

            Text(tab.label)
                .font(.system(size: 13, weight: isActive ? .bold : .semibold, design: .rounded))
                .lineLimit(1)

            if tab.badgeCount > 0 {
                badgeView(count: tab.badgeCount, isActive: isActive)
            }
        }
        .foregroundColor(isActive ? .white : AppTheme.Colors.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            if isActive {
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: accentColor, location: 0),
                                .init(color: accentColor.opacity(0.82), location: 1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: AppTheme.Colors.chipGlassHighlight.opacity(0.14), location: 0),
                                        .init(color: .clear, location: 0.4),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.18), location: 0),
                                        .init(color: .white.opacity(0.03), location: 1),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
                    .shadow(color: accentColor.opacity(0.3), radius: 8, x: 0, y: 3)
                    .shadow(color: accentColor.opacity(0.1), radius: 16, x: 0, y: 6)
                    .matchedGeometryEffect(id: "activeTab", in: tabNamespace)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: - Badge

    private func badgeView(count: Int, isActive: Bool) -> some View {
        let label = count > 99 ? "99+" : "\(count)"
        return Text(label)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundColor(isActive ? accentColor : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isActive ? .white.opacity(0.9) : accentColor.opacity(0.8))
            )
    }
}
