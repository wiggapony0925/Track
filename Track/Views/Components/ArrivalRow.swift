//
//  ArrivalRow.swift
//  Track
//
//  Displays a single train arrival with delay-adjusted timing.
//

import SwiftUI

struct ArrivalRow: View {
    let arrival: TrainArrival
    let prediction: DelayPrediction?

    var body: some View {
        HStack(spacing: 12) {
            // Route badge
            Text(arrival.routeID)
                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(AppTheme.Colors.mtaBlue)
                .clipShape(Circle())
                .accessibilityLabel("Route \(arrival.routeID)")

            // Direction
            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.direction)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text(arrival.stationID)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }

            Spacer()

            // Time display
            if let prediction = prediction {
                DelayBadgeView(prediction: prediction)
            } else {
                VStack(alignment: .trailing) {
                    Text("\(arrival.minutesAway) min")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(arrival.routeID) train, \(arrival.direction), \(arrival.minutesAway) minutes away")
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
            )
        )
    }
    .background(AppTheme.Colors.background)
}
