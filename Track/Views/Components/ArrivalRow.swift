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

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
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
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(AppTheme.Colors.successGreen)
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
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(arrival.minutesAway)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("min")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                }

                // Expand chevron
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, AppTheme.Layout.margin)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            // Expanded detail section
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    // Estimated arrival time
                    HStack(spacing: 10) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Estimated Arrival")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .textCase(.uppercase)
                            Text(arrivalTimeDescription)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                        }

                        Spacer()

                        // Status pill
                        Text(statusText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textOnColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(arrival.minutesAway <= 2 ? AppTheme.Colors.alertRed : AppTheme.Colors.successGreen)
                            .clipShape(Capsule())
                    }

                    // Direction info
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Direction")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .textCase(.uppercase)
                            Text(arrival.direction)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                        }
                    }

                    // Delay prediction info if available
                    if let prediction = prediction, prediction.adjustedMinutes != prediction.originalMinutes {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppTheme.Colors.warningYellow)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Delay Prediction")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                    .textCase(.uppercase)
                                Text(prediction.adjustmentReason ?? "Adjusted by +\(prediction.adjustedMinutes - prediction.originalMinutes) min")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppTheme.Colors.warningYellow)
                                    .lineLimit(2)
                            }
                        }
                    }

                    // Track button
                    Button {
                        onTrack?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isTracking ? "antenna.radiowaves.left.and.right" : "bell.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text(isTracking ? "Tracking" : "Track This Train")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(AppTheme.Colors.textOnColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isTracking ? AppTheme.Colors.successGreen : AppTheme.Colors.mtaBlue)
                        .cornerRadius(AppTheme.Layout.cornerRadius)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(arrival.routeID) train, \(arrival.direction), \(arrival.minutesAway) minutes away")
        .accessibilityHint(isExpanded ? "Expanded. Shows arrival details." : "Tap to see arrival details")
    }

    private var arrivalTimeDescription: String {
        if arrival.minutesAway <= 0 {
            return "Arriving now"
        } else {
            return formatArrivalTime(minutesAway: arrival.minutesAway)
        }
    }

    private var statusText: String {
        arrivalStatusPill(minutesAway: arrival.minutesAway).label
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
