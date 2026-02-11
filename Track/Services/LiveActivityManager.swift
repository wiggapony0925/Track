//
//  LiveActivityManager.swift
//  Track
//
//  Singleton that manages the lifecycle of Live Activities.
//  Handles starting, updating, and ending trip tracking activities
//  that appear on the Dynamic Island and Lock Screen.
//
//  Also records trip data to SwiftData for the intelligence layer:
//  - CommutePattern on start (trains the SmartSuggester)
//  - TripLog on end (tracks actual vs expected duration)
//

import Foundation
import ActivityKit
import SwiftData

@Observable
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    /// The ID of the currently active Live Activity, if any.
    private(set) var currentActivityID: String?

    /// Whether a Live Activity is currently running.
    var isTracking: Bool { currentActivityID != nil }

    // Trip data capture
    private(set) var activeTripStartTime: Date?
    private(set) var activeLineId: String?
    private(set) var activeStationId: String?
    private(set) var activeExpectedDuration: TimeInterval?
    private(set) var activeDestination: String?

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
    ///   - context: SwiftData model context for recording the commute pattern.
    ///   - location: The user's current location for pattern recording.
    func startActivity(
        lineId: String,
        destination: String,
        arrivalTime: Date,
        isBus: Bool,
        stationId: String = "",
        context: ModelContext? = nil,
        location: (latitude: Double, longitude: Double)? = nil
    ) {
        // End any existing activity first
        endActivity()

        // Record trip metadata
        let now = Date()
        activeTripStartTime = now
        activeLineId = lineId
        activeStationId = stationId
        activeExpectedDuration = arrivalTime.timeIntervalSince(now)
        activeDestination = destination

        // Record commute pattern in SwiftData (only with valid location and if learning enabled)
        let learningEnabled = UserDefaults.standard.object(forKey: "backgroundLearningEnabled") as? Bool ?? true
        if let context = context, let location = location, learningEnabled {
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: now)
            let weekday = calendar.component(.weekday, from: now)
            let lat = location.latitude
            let lon = location.longitude

            let pattern = CommutePattern(
                routeID: lineId,
                direction: destination,
                startLatitude: lat,
                startLongitude: lon,
                destinationStationID: stationId,
                destinationName: destination,
                timeOfDay: hour,
                dayOfWeek: weekday
            )

            // Check for existing matching pattern and increment frequency
            let predicate = #Predicate<CommutePattern> { p in
                p.routeID == lineId &&
                p.direction == destination &&
                p.timeOfDay >= (hour - 1) &&
                p.timeOfDay <= (hour + 1)
            }
            let descriptor = FetchDescriptor<CommutePattern>(predicate: predicate)

            do {
                let existing = try context.fetch(descriptor)
                if let match = existing.first {
                    match.frequency += 1
                    match.lastUsed = now
                } else {
                    context.insert(pattern)
                }
                try? context.save()
            } catch {
                context.insert(pattern)
                try? context.save()
            }
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = TrackActivityAttributes(
            lineId: lineId,
            destination: destination,
            isBus: isBus
        )

        let initialState = TrackActivityAttributes.ContentState(
            statusText: "Tracking...",
            arrivalTime: arrivalTime,
            progress: 0.0
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: arrivalTime.addingTimeInterval(60)),
                pushType: nil
            )
            currentActivityID = activity.id
            HapticManager.notification(.success)
        } catch {
            // Live Activities may not be available on all devices
            print("Failed to start Live Activity: \(error)")
        }
    }

    // MARK: - Update

    /// Updates the running Live Activity with new arrival information.
    ///
    /// - Parameters:
    ///   - statusText: Updated status (e.g. "Arriving in 1 min").
    ///   - arrivalTime: Updated ETA.
    ///   - progress: Updated progress (0.0–1.0).
    func updateActivity(
        statusText: String,
        arrivalTime: Date,
        progress: Double
    ) {
        guard let activityID = currentActivityID else { return }

        let updatedState = TrackActivityAttributes.ContentState(
            statusText: statusText,
            arrivalTime: arrivalTime,
            progress: min(1.0, max(0.0, progress))
        )

        Task {
            for activity in Activity<TrackActivityAttributes>.activities where activity.id == activityID {
                await activity.update(
                    ActivityContent(state: updatedState, staleDate: arrivalTime.addingTimeInterval(60))
                )
            }
        }
    }

    // MARK: - End

    /// Ends the current Live Activity and records a TripLog in SwiftData.
    ///
    /// - Parameter context: SwiftData model context for recording the trip log.
    func endActivity(context: ModelContext? = nil) {
        // Record trip log if we have trip metadata and learning is enabled
        let learningEnabled = UserDefaults.standard.object(forKey: "backgroundLearningEnabled") as? Bool ?? true
        if let context = context,
           learningEnabled,
           let startTime = activeTripStartTime,
           let lineId = activeLineId,
           let expectedDuration = activeExpectedDuration {
            let now = Date()
            let actualDuration = now.timeIntervalSince(startTime)
            let delayDelta = Int(actualDuration - expectedDuration)
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: startTime)
            let weekday = calendar.component(.weekday, from: startTime)

            let log = TripLog(
                routeID: lineId,
                originStationID: activeStationId ?? "",
                destinationStationID: activeDestination ?? "",
                timeOfDay: hour,
                dayOfWeek: weekday,
                weatherCondition: .clear,
                mtaPredictedTime: startTime.addingTimeInterval(expectedDuration),
                actualArrivalTime: now,
                delaySeconds: delayDelta,
                tripDate: startTime
            )
            context.insert(log)
            try? context.save()
        }

        // Clear trip metadata
        activeTripStartTime = nil
        activeLineId = nil
        activeStationId = nil
        activeExpectedDuration = nil
        activeDestination = nil

        guard let activityID = currentActivityID else { return }

        Task {
            for activity in Activity<TrackActivityAttributes>.activities where activity.id == activityID {
                let finalState = TrackActivityAttributes.ContentState(
                    statusText: "Arrived",
                    arrivalTime: Date(),
                    progress: 1.0
                )
                await activity.end(
                    ActivityContent(state: finalState, staleDate: nil),
                    dismissalPolicy: .after(Date.now.addingTimeInterval(30))
                )
            }
        }

        currentActivityID = nil
    }
}
