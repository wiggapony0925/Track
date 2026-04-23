// Root view of the Track NYC Transit app.
// Hosts login, onboarding, location gate, and the main dashboard.

@preconcurrency import ObjectiveC
import SwiftUI
import CoreLocation

struct ContentView: View {
    @ObservedObject private var supabase = SupabaseManager.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appTheme") private var appTheme = "system"
    @State private var locationManager = LocationManager()

    /// Brief dimming overlay used for a smooth "lightbulb" transition
    /// when the color scheme changes instead of a hard flicker.
    @State private var themeTransitionOpacity: Double = 0

    // Watch scene transitions so we instantly re-check location status
    // when the user returns from the iOS Settings app after granting permission.
    @Environment(\.scenePhase) private var scenePhase

    /// Unified authentication state
    private var isAuth: Bool {
        supabase.isAuthenticated
    }

    /// True when the user has granted location access.
    private var locationGranted: Bool {
        locationManager.authorizationStatus == .authorizedWhenInUse ||
        locationManager.authorizationStatus == .authorizedAlways
    }

    /// Maps the appTheme string to a ColorScheme.
    private var colorScheme: ColorScheme? {
        switch appTheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var body: some View {
        Group {
            if !supabase.isAuthResolved {
                authLoadingView
            } else if !isAuth {
                LoginView()
            } else if !hasCompletedOnboarding {
                OnboardingView()
            } else if locationGranted {
                MainTabView(locationManager: locationManager)
            } else {
                LocationPermissionView(
                    authorizationStatus: $locationManager.authorizationStatus,
                    onRequestPermission: {
                        locationManager.requestPermission()
                    }
                )
            }
        }
        .preferredColorScheme(colorScheme)
        .tint(AppTheme.Colors.mtaBlue)
        // Smooth "lightbulb" dim-in / dim-out when the color scheme changes.
        // A black overlay quickly fades to ~40% opacity, the scheme flips
        // underneath, then the overlay fades back to 0 — avoiding a hard flicker.
        .overlay {
            Color.black
                .opacity(themeTransitionOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.25), value: themeTransitionOpacity)
        }
        .onChange(of: appTheme) { _, _ in
            // Dim up → let the scheme change → dim back down
            themeTransitionOpacity = 0.4
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                themeTransitionOpacity = 0
            }
        }
        .onAppear {
            if supabase.isAuthResolved && isAuth && hasCompletedOnboarding {
                // Fire the full sync AFTER the first transit fetch completes.
                // HomeViewModel posts .transitDataLoaded when hasLoadedOnce
                // flips to true, so sync starts as soon as the critical-path
                // /nearby/grouped data lands — on fast WiFi this is <500 ms
                // instead of a fixed 5 s sleep.  Falls back to 6 s max.
                Task {
                    // Wait until transit data is ready, then fire
                    // the lower-priority sync. Polls every 250 ms
                    // with a 6 s hard ceiling so we never hang.
                    if !TransitDataReadyFlag.isReady {
                        let deadline = ContinuousClock.now + .seconds(6)
                        while !TransitDataReadyFlag.isReady,
                              ContinuousClock.now < deadline {
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
                    await SyncManager.shared.performFullSync()
                }

                // Warm the Trip-page caches in the background BEFORE the
                // user navigates to the Trips tab, so PlanView renders
                // instantly from PlannerDataCache instead of waiting on
                // the network. Per-bucket TTLs prevent over-fetching.
                PrefetchService.shared.prefetchPlannerData()

                // Auto-request if still undecided (e.g. first launch)
                if locationManager.authorizationStatus == .notDetermined {
                    locationManager.requestPermission()
                }
            }
        }
        // Re-check location the moment the user returns to the app
        // (e.g. after enabling location access in iOS Settings).
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active, !supabase.isLoading {
                Task {
                    await supabase.refreshSessionIfNeeded()

                    if supabase.isAuthenticated && hasCompletedOnboarding {
                        // Trigger a status refresh — CLLocationManager will publish
                        // the latest authorizationStatus via didChangeAuthorization.
                        locationManager.refreshAuthorizationStatus()

                        // Re-warm planner caches on foreground. The service
                        // is throttled (30 s minimum interval) and only
                        // refreshes buckets that are actually stale.
                        PrefetchService.shared.prefetchPlannerData()
                    }
                }
            }
        }
    }

    private var authLoadingView: some View {
        SplashLoadingView()
    }
}


#Preview {
    ContentView()
}
