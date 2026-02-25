//
//  DataController.swift
//  Shared
//
//  Shared data container using App Groups so both the main app
//  and the Widget Extension can access the same SwiftData store.
//
//  Best Practices:
//  - Uses isDirectory: false for file URLs to avoid blocking I/O
//
//  Target Membership: Track AND TrackWidgets
//

import Foundation
import SwiftData

struct DataController {
    static let shared = DataController()
    let container: ModelContainer

    init() {
        // SwiftData models for local persistence
        // Note: WidgetSchedule uses UserDefaults for widget access
        let schema = Schema([
            CommutePattern.self,
            TripLog.self,
            Station.self,
            Route.self,
        ])

        // Point to the Shared App Group container
        let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: kAppGroupIdentifier
        )

        let config: ModelConfiguration
        if let groupURL {
            // Use isDirectory: false to avoid blocking file system check
            let fileURL = groupURL.appendingPathComponent("Track.sqlite", isDirectory: false)
            config = ModelConfiguration(url: fileURL)
        } else {
            // Fallback to default container if App Group is unavailable
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }

        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // Attempt in-memory fallback so the app can still launch
            #if DEBUG
            print("⚠️ ModelContainer init failed: \(error). Falling back to in-memory store.")
            #endif
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                container = try ModelContainer(for: schema, configurations: fallback)
            } catch {
                fatalError("Failed to load even in-memory ModelContainer: \(error)")
            }
        }
    }
}
