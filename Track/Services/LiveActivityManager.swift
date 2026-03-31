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

    private init() {
        // Clean up any orphaned Live Activities from previous app sessions.
        // `currentActivityID` is in-memory only, so after a kill/relaunch
        // it's nil while stale activities may still be alive on the Lock Screen.
        cleanupOrphanedActivities()
    }

    // MARK: - Orphan Cleanup

    /// Ends ALL existing Live Activities that weren't started by this session.
    /// Called on init to prevent duplicate Lock Screen widgets after an app
    /// kill/relaunch.
    private func cleanupOrphanedActivities() {
        let existing = Activity<TrackActivityAttributes>.activities
        guard !existing.isEmpty else { return }

        // If there's a saved TrackedRoute, the user is still tracking —
        // adopt the first matching activity instead of killing it.
        if let saved = TrackedRoute.load(), let match = existing.first(where: { _ in true }) {
            currentActivityID = match.id
            AppLogger.shared.log("LIVE_ACTIVITY", message: "Adopted orphaned activity \(match.id) for \(saved.routeId)")
            // End any extras beyond the adopted one
            let extras = existing.filter { $0.id != match.id }
            if !extras.isEmpty {
                Task {
                    for activity in extras {
                        await activity.end(nil, dismissalPolicy: .immediate)
                        AppLogger.shared.log("LIVE_ACTIVITY", message: "Ended extra orphan \(activity.id)")
                    }
                }
            }
        } else {
            // No tracked route saved — kill all orphans
            Task {
                for activity in existing {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    AppLogger.shared.log("LIVE_ACTIVITY", message: "Ended orphaned activity \(activity.id)")
                }
            }
        }
    }

    // MARK: - Start

    /// Starts a new Live Activity for tracking a train or bus arrival.
    ///
    /// - Parameters:
    ///   - lineId: The transit line (e.g. "L", "4", "B63").
    ///   - destination: The direction/destination name.
    ///   - arrivalTime: The estimated arrival time.
    ///   - isBus: Whether this is a bus trip.
    ///   - stationId: The station/stop the user is at.
    ///   - minutesAway: Minutes until arrival (nil if unknown).
    ///   - nextArrivals: Minutes until the next 2–3 trains/buses.
    func startActivity(
        lineId: String,
        destination: String,
        arrivalTime: Date,
        isBus: Bool,
        stationId: String = "",
        minutesAway: Int? = nil,
        nextArrivals: [Int] = [],
        walkMinutes: Int? = nil,
        isHurryUp: Bool = false
    ) async {
        // End ALL existing activities first — not just the one we're tracking.
        // This catches orphans from previous sessions where currentActivityID was lost.
        // Await to avoid racing: old activities must be fully ended before requesting
        // a new one, otherwise ActivityKit may reject or show duplicates.
        await endAllActivities()

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
            minutesAway: minutesAway,
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
    ///   - minutesAway: Updated minutes away (nil if unknown).
    ///   - nextArrivals: Updated upcoming arrival minutes.
    func updateActivity(
        statusText: String,
        arrivalTime: Date,
        progress: Double,
        minutesAway: Int? = nil,
        nextArrivals: [Int] = [],
        walkMinutes: Int? = nil,
        isHurryUp: Bool = false
    ) {
        guard let activityID = currentActivityID else { return }

        let updatedState = TrackActivityAttributes.ContentState(
            statusText: statusText,
            arrivalTime: arrivalTime,
            progress: min(1.0, max(0.0, progress)),
            minutesAway: minutesAway,
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

    /// Ends the current Live Activity (by tracked ID).
    ///
    /// We snapshot the existing activities **before** entering the Task so
    /// the unstructured Task only touches activities that existed at call
    /// time — if `startActivity()` fires right after, the snapshot won't
    /// include the newly created activity.
    func endActivity() {
        let activityID = currentActivityID
        // Clear immediately so `isTracking` returns false
        // and `startActivity()` won't see a stale ID.
        currentActivityID = nil

        // Snapshot current activities on the calling (MainActor) thread.
        let snapshot = Activity<TrackActivityAttributes>.activities

        guard !snapshot.isEmpty else {
            if let id = activityID {
                AppLogger.shared.log("LIVE_ACTIVITY", message: "No activities to end for \(id)")
            }
            return
        }

        if let id = activityID {
            AppLogger.shared.log("LIVE_ACTIVITY", message: "Ending tracked activity \(id)")
        }

        Task {
            let finalState = TrackActivityAttributes.ContentState(
                statusText: "Arrived",
                arrivalTime: Date(),
                progress: 1.0,
                minutesAway: 0,
                nextArrivals: [],
                walkMinutes: nil,
                isHurryUp: false
            )
            for activity in snapshot {
                await activity.end(
                    ActivityContent(state: finalState, staleDate: nil),
                    dismissalPolicy: .after(Date.now.addingTimeInterval(AppSettings.shared.liveActivityDismissalSeconds))
                )
                AppLogger.shared.log("LIVE_ACTIVITY", message: "Ended activity \(activity.id)")
            }
        }
    }

    /// Immediately ends ALL Live Activities without the "Arrived" final state.
    /// Used before starting a new activity to ensure a clean slate.
    /// Now async so callers can `await` it — prevents the race where
    /// `Activity.request()` fires before old activities have finished ending.
    private func endAllActivities() async {
        currentActivityID = nil
        let existing = Activity<TrackActivityAttributes>.activities
        guard !existing.isEmpty else { return }

        for activity in existing {
            await activity.end(nil, dismissalPolicy: .immediate)
            AppLogger.shared.log("LIVE_ACTIVITY", message: "Cleared activity \(activity.id) before new start")
        }
    }
}
