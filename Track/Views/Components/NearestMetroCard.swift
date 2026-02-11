//
//  NearestMetroCard.swift
//  Track
//
//  Shows the nearest transit stop when no transit is within walking
//  distance. Displays route, stop name, distance, and a button
//  to center the map on that stop.
//

import SwiftUI
import CoreLocation

struct NearestMetroCard: View {
    let arrival: NearbyTransitResponse
    let distanceMeters: Double?
    let onCenter: (CLLocationCoordinate2D) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "tram.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                Text("Nearest Metro")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
            }

            // Route + stop info
            HStack(spacing: 12) {
                RouteBadge(routeID: arrival.displayName, size: .large)

                VStack(alignment: .leading, spacing: 2) {
                    Text(arrival.stopName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let distance = distanceMeters {
                            Image(systemName: "figure.walk")
                                .font(.system(size: 12, weight: .medium))
                            Text(formattedDistance(distance))
                                .font(.system(size: 14, weight: .medium))
                        }

                        Text("• \(arrival.minutesAway) min")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    }
                    .foregroundColor(AppTheme.Colors.textSecondary)
                }

                Spacer(minLength: 0)
            }

            // Center on map button
            if let lat = arrival.stopLat, let lon = arrival.stopLon {
                Button {
                    onCenter(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Show on Map")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(AppTheme.Colors.textOnColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.Colors.mtaBlue)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
                }
                .accessibilityHint("Centers the map on \(arrival.stopName)")
            }
        }
        .padding(AppTheme.Layout.cardPadding)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .shadow(radius: AppTheme.Layout.shadowRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    /// Formats meters as a human-readable distance string.
    private func formattedDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters)) m"
        }
        let km = meters / 1000
        return String(format: "%.1f km", km)
    }
}
