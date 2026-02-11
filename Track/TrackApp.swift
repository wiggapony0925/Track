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
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(DataController.shared.container)
    }
}
