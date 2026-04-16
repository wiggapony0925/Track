// Compact floating pill tab bar used by MainTabView.
// Lives here as a reusable component so it can be embedded
// inside individual tab views when needed (e.g. above a sheet).

import SwiftUI

struct FloatingTabPill: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                tabItem(tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
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
            HStack(spacing: 6) {
                Image(systemName: selectedTab == tab ? tab.selectedIcon : tab.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.monochrome)

                if selectedTab == tab {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
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
            .padding(.horizontal, selectedTab == tab ? 18 : 16)
            .padding(.vertical, 10)
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
