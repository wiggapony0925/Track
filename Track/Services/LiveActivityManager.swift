//
//  LiveActivityManager.swift
//  Track
//
//  Singleton that manages the lifecycle of Live Activities.
//  Handles starting, updating, and ending trip tracking activities
//  that appear on the Dynamic Island and Lock Screen.
//

import Foundation
import ActivityKit
import UIKit

@Observable
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    /// The ID of the currently active Live Activity, if any.
    private(set) var currentActivityID: String?

    /// Whether a Live Activity is currently running.
    var isTracking: Bool { currentActivityID != nil }

    private init() {}

    // MARK: - Start

    /// Starts a new Live Activity for tracking a train or bus arrival.
    ///
    /// - Parameters:
    ///   - lineId: The transit line (e.g. "L", "4", "B63").
    ///   - destination: The direction/destination name.
    ///   - arrivalTime: The estimated arrival time.
    ///   - isBus: Whether this is a bus trip.
    ///   - stationId: The station/stop the user is at.
    ///   - stopsAway: Number of stops until arrival (nil if unknown).
    ///   - nextArrivals: Minutes until the next 2–3 trains/buses.
    func startActivity(
        lineId: String,
        destination: String,
        arrivalTime: Date,
        isBus: Bool,
        stationId: String = "",
        stopsAway: Int? = nil,
        nextArrivals: [Int] = [],
        walkMinutes: Int? = nil,
        isHurryUp: Bool = false
    ) {
        // End any existing activity first
        endActivity()

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            AppLogger.shared.log("LIVE_ACTIVITY", message: "Live Activities not enabled on this device")
            return
        }

        let attributes = TrackActivityAttributes(
            lineId: lineId,
            destination: destination,
            isBus: isBus
        )

        let initialState = TrackActivityAttributes.ContentState(
            statusText: "Tracking...",
            arrivalTime: arrivalTime,
            progress: 0.0,
            stopsAway: stopsAway,
            nextArrivals: nextArrivals,
            walkMinutes: walkMinutes,
            isHurryUp: isHurryUp
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: arrivalTime.addingTimeInterval(AppSettings.shared.liveActivityStaleDateSeconds)),
                pushType: nil
            )
            currentActivityID = activity.id
            HapticManager.notification(.success)
            AppLogger.shared.log("LIVE_ACTIVITY", message: "Started for \(lineId) → \(destination)")
        } catch {
            // Live Activities may not be available on all devices
            AppLogger.shared.logError("startLiveActivity", error: error)
        }
    }

    // MARK: - Update

    /// Updates the running Live Activity with new arrival information.
    /// The arrivalTime can move forward or backward — the countdown
    /// adjusts automatically since SwiftUI's `.timer` style reads
    /// the absolute Date each render.
    ///
    /// - Parameters:
    ///   - statusText: Updated status (e.g. "Arriving in 1 min").
    ///   - arrivalTime: Updated ETA (can be sooner or later than before).
    ///   - progress: Updated progress (0.0–1.0).
    ///   - stopsAway: Updated stop count (nil if unknown).
    ///   - nextArrivals: Updated upcoming arrival minutes.
    func updateActivity(
        statusText: String,
        arrivalTime: Date,
        progress: Double,
        stopsAway: Int? = nil,
        nextArrivals: [Int] = [],
        walkMinutes: Int? = nil,
        isHurryUp: Bool = false
    ) {
        guard let activityID = currentActivityID else { return }

        let updatedState = TrackActivityAttributes.ContentState(
            statusText: statusText,
            arrivalTime: arrivalTime,
            progress: min(1.0, max(0.0, progress)),
            stopsAway: stopsAway,
            nextArrivals: nextArrivals,
            walkMinutes: walkMinutes,
            isHurryUp: isHurryUp
        )

        Task {
            for activity in Activity<TrackActivityAttributes>.activities where activity.id == activityID {
                await activity.update(
                    ActivityContent(state: updatedState, staleDate: arrivalTime.addingTimeInterval(AppSettings.shared.liveActivityStaleDateSeconds))
                )
            }
        }
    }

    // MARK: - End

    /// Ends the current Live Activity.
    func endActivity() {
        guard let activityID = currentActivityID else { return }

        Task {
            for activity in Activity<TrackActivityAttributes>.activities where activity.id == activityID {
                let finalState = TrackActivityAttributes.ContentState(
                    statusText: "Arrived",
                    arrivalTime: Date(),
                    progress: 1.0,
                    stopsAway: 0,
                    nextArrivals: [],
                    walkMinutes: nil,
                    isHurryUp: false
                )
                await activity.end(
                    ActivityContent(state: finalState, staleDate: nil),
                    dismissalPolicy: .after(Date.now.addingTimeInterval(AppSettings.shared.liveActivityDismissalSeconds))
                )
            }
        }

        currentActivityID = nil
        AppLogger.shared.log("LIVE_ACTIVITY", message: "Ended activity \(activityID)")
    }
}
