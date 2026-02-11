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

    var body: some View {
        HStack(spacing: 12) {
            // Bus route badge
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.mtaBlue)
                    .frame(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                Image(systemName: "bus.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
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
        }
        .padding(.vertical, 8)
        .padding(.horizontal, AppTheme.Layout.margin)
        .contentShape(Rectangle())
        .onTapGesture {
            onTrack?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bus \(shortRouteName), \(arrival.statusText)")
        .accessibilityHint(isTracking ? "Currently tracking" : "Tap to track this bus")
    }

    /// Strips the "MTA NYCT_" prefix for display.
    private var shortRouteName: String {
        if arrival.routeId.hasPrefix("MTA NYCT_") {
            return String(arrival.routeId.dropFirst(9))
        }
        return arrival.routeId
    }

    private var statusColor: Color {
        let lower = arrival.statusText.lowercased()
        if lower.contains("approaching") || lower.contains("at stop") {
            return AppTheme.Colors.successGreen
        } else if lower.contains("1 stop") {
            return AppTheme.Colors.warningYellow
        }
        return AppTheme.Colors.textPrimary
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
