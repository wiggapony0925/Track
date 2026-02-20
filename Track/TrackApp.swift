//
//  TrackApp.swift
//  Track
//
//  Created by Jeffrey Fernandez on 2/10/26.
//

import SwiftUI
import SwiftData

@main
struct TrackApp: App {
    init() {
        // Initialize the file logger — clears log.app on every launch
        _ = AppLogger.shared
        // Request notification permissions for service alerts
        AlertNotificationManager.shared.requestPermissionIfNeeded()
        
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
                }
        }
        .modelContainer(DataController.shared.container)
    }
}
