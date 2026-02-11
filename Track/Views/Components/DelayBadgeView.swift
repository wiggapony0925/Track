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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(prediction.adjustedMinutes)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(badgeColor)
                Text("min")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)

                if prediction.adjustedMinutes != prediction.originalMinutes {
                    Text("(Adjusted)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.warningYellow)
                }
            }

            if let reason = prediction.adjustmentReason {
                Text(reason)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(AppTheme.Layout.margin)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
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
