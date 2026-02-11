//
//  NearbyTransitRow.swift
//  Track
//
//  Displays a single nearby transit arrival (bus or train) in the unified list.
//  Tapping expands the row to show arrival details, direction, and status.
//  Extracted from HomeView for reusability and to keep HomeView focused on layout.
//

import SwiftUI

struct NearbyTransitRow: View {
    let arrival: NearbyTransitResponse
    var isTracking: Bool = false
    var onTrack: (() -> Void)?
    var onSelectRoute: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Mode badge
                ZStack {
                    Circle()
                        .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName))
                        .frame(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                    if arrival.isBus {
                        Image(systemName: "bus.fill")
                            .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textOnColor)
                    } else {
                        Text(arrival.displayName)
                            .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .heavy, design: .monospaced))
                            .foregroundColor(AppTheme.SubwayColors.textColor(for: arrival.displayName))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    }
                }
                .accessibilityHidden(true)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(arrival.displayName)
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
                    Text(arrival.stopName)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // View route button for buses
                if arrival.isBus, let onSelectRoute = onSelectRoute {
                    Button {
                        onSelectRoute()
                    } label: {
                        Image(systemName: "map")
                            .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .medium))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                    }
                    .accessibilityLabel("View \(arrival.displayName) route on map")
                }

                // Countdown
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

                // Expand chevron
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .padding(.vertical, 10)
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

                    // Next arrival details
                    HStack(spacing: 10) {
                        Image(systemName: arrival.isBus ? "bus.fill" : "tram.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next Arrival")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .textCase(.uppercase)
                            Text(formatArrivalTime(minutesAway: arrival.minutesAway))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                        }

                        Spacer()

                        // Status pill
                        Text(arrival.status)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textOnColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(transitStatusColor(for: arrival.status))
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

                    // Track button
                    Button {
                        onTrack?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isTracking ? "antenna.radiowaves.left.and.right" : "bell.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text(isTracking ? "Tracking" : "Track This Arrival")
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
        .accessibilityLabel("\(arrival.isBus ? "Bus" : "Train") \(arrival.displayName), \(arrival.stopName), \(arrival.minutesAway) minutes away")
        .accessibilityHint(isExpanded ? "Expanded. Shows arrival details." : "Tap to see arrival details")
    }
}
