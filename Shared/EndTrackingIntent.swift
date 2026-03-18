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
    static let title: LocalizedStringResource = "End Tracking"
    static let description: IntentDescription = IntentDescription("Ends the current trip tracking session.")

    @MainActor
    func perform() async throws -> some IntentResult {
        // End all active Live Activities
        for activity in Activity<TrackActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        // Clear shared state so the main app knows we're done
        TrackedRoute.clear()

        // Reload widgets to reflect "not tracking" state
        WidgetCenter.shared.reloadAllTimelines()

        return .result()
    }
}
