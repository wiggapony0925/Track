//
//  DelayBadgeView.swift
//  Track
//
//  Displays the "Real Feel" adjusted arrival time with context.
//

import SwiftUI

struct DelayBadgeView: View {
    let prediction: DelayPrediction

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(prediction.adjustedMinutes)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(badgeColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)

                if prediction.adjustedMinutes != prediction.originalMinutes {
                    Text("(Adj)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppTheme.Colors.warningYellow)
                }
            }

            if let reason = prediction.adjustmentReason {
                Text(reason)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var label = "\(prediction.adjustedMinutes) minutes"
        if prediction.adjustedMinutes != prediction.originalMinutes {
            label += ", adjusted from \(prediction.originalMinutes) minutes"
        }
        if let reason = prediction.adjustmentReason {
            label += ". \(reason)"
        }
        return label
    }

    private var badgeColor: Color {
        if prediction.adjustedMinutes <= 2 {
            return AppTheme.Colors.alertRed
        } else if prediction.adjustedMinutes <= 5 {
            return AppTheme.Colors.successGreen
        } else {
            return AppTheme.Colors.textPrimary
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        DelayBadgeView(prediction: DelayPrediction(
            adjustedMinutes: 6,
            originalMinutes: 5,
            adjustmentReason: "Adjusted for rain (+1m)",
            delayFactor: 1.2
        ))

        DelayBadgeView(prediction: DelayPrediction(
            adjustedMinutes: 3,
            originalMinutes: 3,
            adjustmentReason: nil,
            delayFactor: 1.0
        ))
    }
    .padding()
    .background(AppTheme.Colors.background)
}
