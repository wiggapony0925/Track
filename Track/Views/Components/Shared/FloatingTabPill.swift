// Compact floating pill tab bar used by MainTabView.
// Lives here as a reusable component so it can be embedded
// inside individual tab views when needed (e.g. above a sheet).

import SwiftUI

struct FloatingTabPill: View {
    @Binding var selectedTab: AppTab
    @Environment(\.colorScheme) private var colorScheme

    /// Match the sheet's base surface so the pill and the sheet read as
    /// the same material in both light and dark mode.
    /// Sheet dark base = `chipSurface`; sheet light base = `cardBackground`.
    private var pillSurface: Color {
        colorScheme == .dark
            ? AppTheme.Colors.chipSurface
            : AppTheme.Colors.cardBackground
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                tabItem(tab)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(pillSurface)
                .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
                .overlay(
                    Capsule()
                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.3), lineWidth: 0.5)
                )
        )
    }

    private func tabItem(_ tab: AppTab) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selectedTab == tab ? tab.selectedIcon : tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.monochrome)

                if selectedTab == tab {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8, anchor: .leading)),
                            removal: .opacity
                        ))
                }
            }
            .foregroundStyle(
                selectedTab == tab
                    ? AppTheme.Colors.textOnColor
                    : AppTheme.Colors.textSecondary
            )
            .padding(.horizontal, selectedTab == tab ? 14 : 12)
            .padding(.vertical, 7)
            .background {
                if selectedTab == tab {
                    Capsule()
                        .fill(AppTheme.Colors.accent)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    FloatingTabPill(selectedTab: .constant(.home))
        .preferredColorScheme(.dark)
}
