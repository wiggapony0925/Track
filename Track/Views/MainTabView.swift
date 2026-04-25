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
    /// Settled drag-search pin (`nil` when not active). Shared with the
    /// Chat tab so MetroMind can bias "near me" answers to the pin
    /// instead of the device GPS.
    @State private var chatBiasPin: CLLocationCoordinate2D?
    /// Active "Go" navigation session.  When `activeTrip` becomes non-nil
    /// the immersive `GoTripView` is presented as a full-screen cover,
    /// effectively locking the user into the trip until they exit.
    @State private var goSession = GoTripSession()
    /// Single source of truth for "where the user is right now" — either
    /// real GPS or the dropped search pin.  Injected into the environment
    /// so Home / Plan / Chat all agree on the active source.
    @State private var locationContext = LocationContext()
    var body: some View {
        // Bind the floating tab bar once, then use it as a `.safeAreaInset`
        // on each tab's content. Mounting the inset on `TabView` itself
        // doesn't always propagate space to lazily-built tab children
        // (composer / chat input ended up hidden behind the bar). Per-tab
        // insets reliably reserve the room.
        let bar = FloatingTabBar(selection: $selectedTab)

        TabView(selection: $selectedTab) {
            HomeView(
                viewModel: homeViewModel,
                locationManager: locationManager,
                isActive: selectedTab == .home,
                selectedTab: $selectedTab,
                cameraPosition: $cameraPosition,
                showStations: $showStations,
                currentMapCenter: $currentMapCenter,
                currentMapDistance: $currentMapDistance,
                chatBiasPin: $chatBiasPin
            )
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { bar }
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
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { bar }
            .tag(AppTab.trips)

            ChatView(locationManager: locationManager, biasPin: $chatBiasPin)
                .toolbar(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { bar }
                .tag(AppTab.chat)

            AlarmsView()
                .toolbar(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { bar }
                .tag(AppTab.alarms)

            SettingsView()
                .toolbar(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { bar }
                .tag(AppTab.settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToTab)) { notification in
            if let tab = notification.object as? AppTab {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedTab = tab
                }
            }
        }
        // ── Drive LocationContext from the existing inputs ──────────────────────────────────────────────────────────────────────────────────────
        // The drag pin lives in `chatBiasPin` for backward compatibility
        // with HomeView; mirror it into the context so PlanView, ChatView,
        // and any future feature can react via the shared @Observable.
        .onAppear {
            locationContext.setGPSCoordinate(locationManager.currentLocation?.coordinate)
            locationContext.setDroppedPin(chatBiasPin)
        }
        .onChange(of: chatBiasPin?.latitude) { _, _ in
            locationContext.setDroppedPin(chatBiasPin)
        }
        .onChange(of: chatBiasPin?.longitude) { _, _ in
            locationContext.setDroppedPin(chatBiasPin)
        }
        .onChange(of: locationManager.currentLocation) { _, new in
            locationContext.setGPSCoordinate(new?.coordinate)
        }
        .environment(locationContext)
        .environment(goSession)
        // NOTE: read `goSession.activeTrip` directly here so that
        // SwiftUI's @Observable tracking registers the dependency on
        // this view's body. Reading it only inside the `Binding(get:)`
        // closure below is *not* enough — the closure isn't evaluated
        // during body, so the cover would never re-present when the
        // user taps GO from TripDetailSheet.
        .fullScreenCover(item: Binding<TripPlan?>(
            get: { goSession.activeTrip },
            set: { newValue in
                if newValue == nil { goSession.stop() }
            }
        )) { trip in
            GoTripView(trip: trip)
                .environment(goSession)
        }
    }
}

#Preview {
    MainTabView(locationManager: LocationManager())
        .preferredColorScheme(.dark)
}
