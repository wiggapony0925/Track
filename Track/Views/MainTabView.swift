// Tab container wrapping the Home (map + dashboard) and Plan
// (trip planner) experiences.  Uses a compact floating pill tab
// bar that stays out of the way of the map and sheet content.

import CoreLocation
import SwiftUI

// MARK: - Tab Enum

enum AppTab: String, CaseIterable {
    case home = "Home"
    case plan = "Plan"

    var icon: String {
        switch self {
        case .home: return "tram.fill"
        case .plan: return "arrow.up.arrow.down"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: return "tram.fill"
        case .plan: return "arrow.up.arrow.down"
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

    // Shared map state — owned here so both Home and Plan tabs
    // share the same interactive MapLibre map instance data.
    @State private var homeViewModel = HomeViewModel()
    @State private var cameraPosition: TrackCameraPosition = .userLocation
    @State private var showStations: Bool = true
    @State private var currentMapCenter: CLLocationCoordinate2D?
    @State private var currentMapDistance: Double?

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                viewModel: homeViewModel,
                locationManager: locationManager,
                isActive: selectedTab == .home,
                selectedTab: $selectedTab,
                cameraPosition: $cameraPosition,
                showStations: $showStations,
                currentMapCenter: $currentMapCenter,
                currentMapDistance: $currentMapDistance
            )
                .tag(AppTab.home)

            PlanView(
                locationManager: locationManager,
                homeViewModel: homeViewModel,
                selectedTab: $selectedTab,
                cameraPosition: $cameraPosition,
                showStations: $showStations,
                currentMapCenter: $currentMapCenter,
                currentMapDistance: $currentMapDistance
            )
                .tag(AppTab.plan)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
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
        FloatingTabPill(selectedTab: $selectedTab)
            .padding(.bottom, 28)
    }
}

#Preview {
    MainTabView(locationManager: LocationManager())
        .preferredColorScheme(.dark)
}
