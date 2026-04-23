// Tab container wrapping the Home (map + dashboard) and Plan
// (trip planner) experiences.  Uses a compact floating pill tab
// bar that stays out of the way of the map and sheet content.

import CoreLocation
import SwiftUI

// MARK: - Tab Enum

enum AppTab: String, CaseIterable {
    case home = "Home"
    case trips = "Trips"
    case chat = "Chat"
    case alarms = "Alarms"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .trips: return "arrow.triangle.swap"
        case .chat: return "message.fill"
        case .alarms: return "alarm.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var selectedIcon: String {
        return icon
    }
}

// Notifications for switching tabs or firing quick actions from anywhere
extension Notification.Name {
    static let switchToTab = Notification.Name("switchToTab")
    /// Payload: a `PlanLocation` — tells PlanView to set this as the destination
    /// and begin planning immediately, then switches to the Trips tab.
    static let quickDestination = Notification.Name("quickDestination")
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
            .tabItem {
                Label(AppTab.home.rawValue, systemImage: AppTab.home.icon)
            }
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
            .tabItem {
                Label(AppTab.trips.rawValue, systemImage: AppTab.trips.icon)
            }
            .tag(AppTab.trips)
            
            ChatView(locationManager: locationManager)
            .tabItem {
                Label(AppTab.chat.rawValue, systemImage: AppTab.chat.icon)
            }
            .tag(AppTab.chat)
            
            AlarmsView()
            .tabItem {
                Label(AppTab.alarms.rawValue, systemImage: AppTab.alarms.icon)
            }
            .tag(AppTab.alarms)
            
            SettingsView()
            .tabItem {
                Label(AppTab.settings.rawValue, systemImage: AppTab.settings.icon)
            }
            .tag(AppTab.settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToTab)) { notification in
            if let tab = notification.object as? AppTab {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedTab = tab
                }
            }
        }
    }
}

#Preview {
    MainTabView(locationManager: LocationManager())
        .preferredColorScheme(.dark)
}
