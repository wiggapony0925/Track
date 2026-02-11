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
                    .matchedGeometryEffect(id: "title", in: cardAnimation)

                Spacer()
            }

            HStack(spacing: 12) {
                // Route Badge
                Text(suggestion.routeID)
                    .font(.system(size: 22, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.Colors.mtaBlue)
                    .clipShape(Circle())
                    .accessibilityLabel("Route \(suggestion.routeID)")

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(suggestion.direction)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(minutesAway)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                        Text("min")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(minutesAway) minutes away")
                }

                Spacer()
            }

            Button(action: onStartTrip) {
                Text("Start Trip")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Smart suggestion: \(suggestion.routeID) train to \(suggestion.destinationName), \(minutesAway) minutes away")
    }

    // MARK: - State 2: No Prediction

    private var noPredictionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where are you headed?")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .matchedGeometryEffect(id: "title", in: cardAnimation)

            Text("We'll learn your commute and suggest routes over time.")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(AppTheme.Colors.textSecondary)
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
