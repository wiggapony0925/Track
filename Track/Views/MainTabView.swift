// Tab container wrapping the Home (map + dashboard) and Plan
// (trip planner) experiences.  Uses a compact floating pill tab
// bar that stays out of the way of the map and sheet content.

import SwiftUI

// MARK: - Tab Enum

enum AppTab: String, CaseIterable {
    case home = "Home"
    case plan = "Plan"

    var icon: String {
        switch self {
        case .home: return "tram.fill"
        case .plan: return "arrow.triangle.swap"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: return "tram.fill"
        case .plan: return "arrow.triangle.swap"
        }
    }
}

// Notification for switching tabs from anywhere
extension Notification.Name {
    static let switchToTab = Notification.Name("switchToTab")
}

// MARK: - MainTabView

struct MainTabView: View {
    var locationManager: LocationManager
    @State private var selectedTab: AppTab = .home

    var body: some View {
        ZStack(alignment: .bottom) {
            // Content
            Group {
                switch selectedTab {
                case .home:
                    HomeView(locationManager: locationManager)
                case .plan:
                    PlanView(locationManager: locationManager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Floating pill tab bar
            floatingTabBar
        }
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(for: .switchToTab)) { notification in
            if let tab = notification.object as? AppTab {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedTab = tab
                }
            }
        }
    }

    // MARK: - Floating Pill Tab Bar

    private var floatingTabBar: some View {
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
        .padding(.bottom, 28)
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
    MainTabView(locationManager: LocationManager())
        .preferredColorScheme(.dark)
}
