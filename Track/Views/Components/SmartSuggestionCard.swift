//
//  SmartSuggestionCard.swift
//  Track
//
//  The "Magic Card" that shows the predicted route or nearby stations.
//

import SwiftUI

struct SmartSuggestionCard: View {
    let suggestion: RouteSuggestion?
    let minutesAway: Int
    let onStartTrip: () -> Void

    @Namespace private var cardAnimation

    var body: some View {
        Group {
            if let suggestion = suggestion {
                predictionCard(suggestion)
            } else {
                noPredictionCard
            }
        }
    }

    // MARK: - State 1: Prediction Found

    @ViewBuilder
    private func predictionCard(_ suggestion: RouteSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Going to \(suggestion.destinationName)?")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .matchedGeometryEffect(id: "title", in: cardAnimation)

                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                RouteBadge(routeID: suggestion.routeID, size: .large)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.direction)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(minutesAway)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text("min")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(minutesAway) minutes away")
                }

                Spacer(minLength: 0)
            }

            Button(action: onStartTrip) {
                Text("Start Trip")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.successGreen)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
            }
            .accessibilityHint("Begins tracking your trip on the \(suggestion.routeID) train")
        }
        .padding(AppTheme.Layout.margin)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .shadow(radius: AppTheme.Layout.shadowRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Smart suggestion: \(suggestion.routeID) train to \(suggestion.destinationName), \(minutesAway) minutes away")
    }

    // MARK: - State 2: No Prediction

    private var noPredictionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.wave.fill")
                    .font(.system(size: 22))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                    .accessibilityHidden(true)

                Text("Welcome Back")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .matchedGeometryEffect(id: "title", in: cardAnimation)
            }

            Text("Tap a station to start learning your commute.")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(AppTheme.Layout.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .shadow(radius: AppTheme.Layout.shadowRadius)
    }
}

#Preview {
    VStack(spacing: 20) {
        SmartSuggestionCard(
            suggestion: RouteSuggestion(
                routeID: "2",
                direction: "Uptown",
                destinationName: "Work",
                score: 5
            ),
            minutesAway: 4,
            onStartTrip: {}
        )

        SmartSuggestionCard(
            suggestion: nil,
            minutesAway: 0,
            onStartTrip: {}
        )
    }
    .padding()
    .background(AppTheme.Colors.background)
}
