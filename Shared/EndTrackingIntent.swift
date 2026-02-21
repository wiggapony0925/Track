//
//  EndTrackingIntent.swift
//  Shared
//
//  AppIntent for the "I made it!" button in the Live Activity.
//  Ends the current live activity and clears the tracked route.
//

import ActivityKit
import AppIntents
import Foundation
import WidgetKit

struct EndTrackingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End Tracking"
    static var description = IntentDescription("Ends the current trip tracking session.")

    @MainActor
    func perform() async throws -> some IntentResult {
        // 1. End the Live Activity
        for activity in Activity<TrackActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        // 2. Clear shared state so the main app knows we're done
        TrackedRoute.clear()

        // 3. Reload widgets to reflect "not tracking" state
        WidgetCenter.shared.reloadAllTimelines()

        return .result()
    }
}
