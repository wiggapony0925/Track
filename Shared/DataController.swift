// Shared data container using App Groups so both the main app
// and the Widget Extension can access the same SwiftData store.
// Best Practices:
// - Uses isDirectory: false for file URLs to avoid blocking I/O
// Target Membership: Track AND TrackWidgets

import Foundation
import SwiftData

struct DataController {
    static let shared = DataController()
    let container: ModelContainer

    init() {
        // SwiftData models for local persistence
        // Note: WidgetSchedule uses UserDefaults for widget access
        // Trip-plan models only exist in the main app target.
        var modelTypes: [any PersistentModel.Type] = [
            CommutePattern.self,
            TripLog.self,
            Station.self,
            Route.self,
        ]
        #if !WIDGET_EXTENSION
        modelTypes += [
            SavedLocation.self,
            RecentSearchLocation.self,
            SavedTrip.self,
        ]
        #endif
        let schema = Schema(modelTypes)

        // Point to the Shared App Group container
        let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )

        let fileURL = groupURL?.appendingPathComponent("Track.sqlite", isDirectory: false)

        let config: ModelConfiguration
        if let fileURL {
            config = ModelConfiguration(url: fileURL)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }

        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            #if DEBUG
            print("⚠️ ModelContainer init failed: \(error). Falling back to in-memory store.")
            #endif
            // Attempt in-memory fallback so the app can still launch
            container = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }
    }
}
