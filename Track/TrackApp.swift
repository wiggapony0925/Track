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
        let staleIPs: Set<String> = ["192.168.12.101", "100.66.48.85"]
        if let storedIP = store.string(forKey: "dev_custom_ip"),
           staleIPs.contains(storedIP) {
            store.set(AppSettings.shared.defaultDeviceIP, forKey: "dev_custom_ip")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(DataController.shared.container)
    }
}
