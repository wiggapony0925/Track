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
    let onTrack: () -> Void

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
                Text("Your usual: \(suggestion.destinationName)")
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
                            .foregroundColor(AppTheme.Colors.countdown(minutesAway))
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

            Button(action: onTrack) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Track Arrival")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundColor(AppTheme.Colors.textOnColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.Colors.mtaBlue)
                .cornerRadius(AppTheme.Layout.cornerRadius)
            }
            .accessibilityHint("Track the \(suggestion.routeID) train arrival")
        }
        .padding(AppTheme.Layout.margin)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .shadow(radius: AppTheme.Layout.shadowRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Predicted route: \(suggestion.routeID) train to \(suggestion.destinationName), \(minutesAway) minutes away")
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

            Text("Browse nearby buses and trains to see what's arriving.")
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
            onTrack: {}
        )

        SmartSuggestionCard(
            suggestion: nil,
            minutesAway: 0,
            onTrack: {}
        )
    }
    .padding()
    .background(AppTheme.Colors.background)
}
