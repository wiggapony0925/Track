//
//  ArrivalRow.swift
//  Track
//
//  Displays a single train arrival with delay-adjusted timing.
//  Tapping the row starts a Live Activity to track the arrival.
//

import SwiftUI

struct ArrivalRow: View {
    let arrival: TrainArrival
    let prediction: DelayPrediction?
    var isTracking: Bool = false
    var reliabilityWarning: Int? = nil
    var onTrack: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            RouteBadge(routeID: arrival.routeID, size: .medium)

            // Direction
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(arrival.direction)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if isTracking {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(AppTheme.Colors.alertRed)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text(arrival.stationID)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                    if let delay = reliabilityWarning {
                        Text("⚠️ Usually \(delay)m late")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(AppTheme.Colors.warningYellow)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            // Time display
            if let prediction = prediction {
                DelayBadgeView(prediction: prediction)
            } else {
                Text("\(arrival.minutesAway) min")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, AppTheme.Layout.margin)
        .contentShape(Rectangle())
        .onTapGesture {
            onTrack?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(arrival.routeID) train, \(arrival.direction), \(arrival.minutesAway) minutes away")
        .accessibilityHint(isTracking ? "Currently tracking" : "Tap to track this arrival")
    }
}

#Preview {
    VStack {
        ArrivalRow(
            arrival: TrainArrival(
                routeID: "L",
                stationID: "L01",
                direction: "Manhattan",
                scheduledTime: Date().addingTimeInterval(300),
                estimatedTime: Date().addingTimeInterval(360),
                minutesAway: 5
            ),
            prediction: DelayPrediction(
                adjustedMinutes: 6,
                originalMinutes: 5,
                adjustmentReason: "Adjusted for rain (+1m)",
                delayFactor: 1.2
            ),
            isTracking: true
        )
        ArrivalRow(
            arrival: TrainArrival(
                routeID: "G",
                stationID: "G29",
                direction: "Church Av",
                scheduledTime: Date().addingTimeInterval(480),
                estimatedTime: Date().addingTimeInterval(480),
                minutesAway: 8
            ),
            prediction: nil
        )
    }
    .background(AppTheme.Colors.background)
}
