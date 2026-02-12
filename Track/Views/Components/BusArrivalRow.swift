//
//  BusArrivalRow.swift
//  Track
//
//  Displays a single bus arrival with the status text from the SIRI API.
//  Unlike subway rows that show calculated minutes, bus rows show direct
//  strings like "Approaching" or "3 stops away".
//  Tapping the row starts a Live Activity to track the bus.
//

import SwiftUI

struct BusArrivalRow: View {
    let arrival: BusArrival
    var isTracking: Bool = false
    var reliabilityWarning: Int? = nil
    var onTrack: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Bus route badge
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.mtaBlue)
                        .frame(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                    Image(systemName: "bus.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textOnColor)
                }
                .accessibilityHidden(true)

                // Route info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(shortRouteName)
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
                        Text(arrival.stopId)
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

                // Status text (e.g. "Approaching", "2 stops away")
                Text(arrival.statusText)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(statusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

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

                    // Next arrival time
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
                        Text(arrival.statusText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textOnColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(statusColor)
                            .clipShape(Capsule())
                    }

                    // Distance info
                    if let meters = arrival.distanceMeters, meters > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppTheme.Colors.mtaBlue)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Distance")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                    .textCase(.uppercase)
                                Text(formattedDistance(meters))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
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
                            Text(isTracking ? "Tracking" : "Track This Bus")
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
        .accessibilityLabel("Bus \(shortRouteName), \(arrival.statusText)")
        .accessibilityHint(isExpanded ? "Expanded. Shows arrival details." : "Tap to see arrival details")
    }

    /// Strips the "MTA NYCT_" prefix for display.
    private var shortRouteName: String {
        stripMTAPrefix(arrival.routeId)
    }

    private var arrivalTimeDescription: String {
        formatArrivalTime(date: arrival.expectedArrival, fallback: arrival.statusText)
    }

    private func formattedDistance(_ meters: Double) -> String {
        formatDistance(meters)
    }

    private var statusColor: Color {
        transitStatusColor(for: arrival.statusText)
    }
}

#Preview {
    VStack {
        BusArrivalRow(
            arrival: BusArrival(
                routeId: "MTA NYCT_B63",
                vehicleId: "MTA NYCT_7582",
                stopId: "MTA_308214",
                statusText: "Approaching",
                expectedArrival: nil,
                distanceMeters: 50
            ),
            isTracking: true
        )
        BusArrivalRow(arrival: BusArrival(
            routeId: "MTA NYCT_B63",
            vehicleId: "MTA NYCT_7590",
            stopId: "MTA_308214",
            statusText: "3 stops away",
            expectedArrival: nil,
            distanceMeters: 1200
        ))
    }
    .background(AppTheme.Colors.background)
}
