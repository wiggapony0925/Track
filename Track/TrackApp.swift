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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(DataController.shared.container)
    }
}
