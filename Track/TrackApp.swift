import SwiftUI
import SwiftData

@main
struct TrackApp: App {
    @Environment(\.scenePhase) private var scenePhase
    init() {
        // Initialize the file logger — clears log.app on every launch
        _ = AppLogger.shared

        // Validate local-server flag before warming. If dev_use_localhost is
        // set but the Mac isn't on the same network, this clears the flag and
        // falls back to production before HomeView fires its first request.
        TrackAPI.validateLocalServer()

        // Pre-warm TCP/TLS connection to the backend immediately at launch.
        // On cellular, TLS handshake takes 1–3 s. Doing it here — before
        // ContentView even renders — means the /nearby/grouped request fired
        // from HomeView.onAppear finds the connection already open.
        TrackAPI.warmConnection()

        // Fetch remote config overrides (refresh interval, feature flags)
        // in the background so the values are ready before the first refresh.
        // Uses Task (not .detached) to stay on @MainActor and avoid
        // sending non-Sendable [String: Any] across isolation boundaries.
        Task(priority: .utility) {
            if let config = await TrackAPI.fetchRemoteConfig() {
                AppSettings.applyRemoteOverrides(config)
            }
        }
        // Request notification permissions for service alerts
        AlertNotificationManager.shared.requestPermissionIfNeeded()

        // Open the on-device GTFS bundle (offline drag-search + /nearby
        // fallback).  Bootstrap is synchronous and cheap when a bundle
        // already exists on disk; first launch on a fresh install kicks
        // off a background download (~3.5 MB) and the UI degrades to
        // network-only until it finishes.
        Task { @MainActor in
            _ = GTFSBundleManager.shared.bootstrap()
            await GTFSBundleManager.shared.refreshIfNeeded()
        }
        
        // Migrate stale device IP to the current default from settings.json.
        // If the user's stored IP matches an old hardcoded value, replace it
        // so they automatically pick up the new USB/WiFi address.
        let store = UserDefaults.standard
        let staleIPs: Set<String> = ["100.66.48.85", "169.254.175.168"]
        if let storedIP = store.string(forKey: "dev_custom_ip"),
           staleIPs.contains(storedIP) {
            store.set(AppSettings.shared.defaultDeviceIP, forKey: "dev_custom_ip")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    // Store the deep-link flag so HomeView can pick it up.
                    // The actual navigation happens in HomeView.handleDeepLink.
                    guard url.scheme == "track", url.host == "route" else { return }
                    UserDefaults.standard.set(true, forKey: "pending_deep_link")
                    Analytics.shared.event("deep_link_opened",
                                           properties: ["host": url.host ?? "?"])
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Analytics.shared.appDidBecomeActive(entrySource: "warm")
                        // Pick up any new GTFS bundle the backend has built
                        // since the last foreground.  Throttled to once per
                        // hour by GTFSBundleManager so this is essentially
                        // free on rapid app-switches.
                        Task { @MainActor in
                            await GTFSBundleManager.shared.refreshIfNeeded()
                        }
                    case .background:
                        Analytics.shared.appDidEnterBackground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
        .modelContainer(DataController.shared.container)
    }
 }
