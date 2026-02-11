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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(DataController.shared.container)
    }
}
