//
//  NearbyTransitRow.swift
//  Track
//
//  Displays a single nearby transit arrival (bus or train) in the unified list.
//  Tapping expands the row to show arrival details, direction, and status.
//  Extracted from HomeView for reusability and to keep HomeView focused on layout.
//

import SwiftUI
import CoreLocation

struct NearbyTransitRow: View {
    let arrival: NearbyTransitResponse
    var isTracking: Bool = false
    var onTrack: (() -> Void)?
    var onSelectRoute: (() -> Void)?
    var userLocation: CLLocation?
    
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // MARK: Route Badge (Larger & More Prominent)
                // MARK: Route Badge (Larger & More Prominent)
                RouteBadge(routeID: arrival.displayName, size: .custom(54, 22))
                    .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
                    .accessibilityHidden(true)

                // MARK: Station & Destination Info
                VStack(alignment: .leading, spacing: 4) {
                    // Station name
                    Text(arrival.stopName)
                        .font(.custom("Helvetica-Bold", size: 17))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    
                    // Direction with arrow
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        
                        Text(shortDirectionLabel(arrival.destination ?? arrival.direction))
                            .font(.custom("Helvetica-Bold", size: 14))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    
                    // Distance (if available) or mode type
                    if let stopLat = arrival.stopLat, let stopLon = arrival.stopLon {
                        if let userLocation = userLocation {
                            let distance = userLocation.distance(
                                from: CLLocation(latitude: stopLat, longitude: stopLon)
                            )
                            HStack(spacing: 4) {
                                Image(systemName: "figure.walk")
                                    .font(.system(size: 10, weight: .medium))
                                Text(formatDistance(distance))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.8))
                        }
                    } else {
                        Text(arrival.isBus ? "Bus" : "Subway")
                            .font(.system(size: 11, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                    }
                }
                
                Spacer(minLength: 8)
                
                // MARK: Right Side (Time + Status)
                VStack(alignment: .trailing, spacing: 6) {
                    // Minutes countdown
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(arrival.minutesAway)")
                            .font(.custom("Helvetica-Bold", size: 32))
                            .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                        Text("min")
                            .font(.custom("Helvetica-Bold", size: 13))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .offset(y: -2)
                    }
                    
                    // Status pill
                    HStack(spacing: 4) {
                        Circle()
                            .fill(transitStatusColor(for: arrival.status))
                            .frame(width: 6, height: 6)
                        
                        Text(arrival.status)
                            .font(.custom("Helvetica-Bold", size: 11))
                            .textCase(.uppercase)
                    }
                    .foregroundColor(transitStatusColor(for: arrival.status))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(transitStatusColor(for: arrival.status).opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, AppTheme.Layout.margin)
            .background(AppTheme.Colors.cardBackground)
            .cornerRadius(AppTheme.Layout.cornerRadius)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
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
                                .font(.custom("Helvetica-Bold", size: 11))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .textCase(.uppercase)
                            Text(formatArrivalTime(minutesAway: arrival.minutesAway))
                                .font(.custom("Helvetica-Bold", size: 14))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                        }

                        Spacer()

                        // Status pill
                        Text(arrival.status)
                            .font(.custom("Helvetica-Bold", size: 11))
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
                                .font(.custom("Helvetica-Bold", size: 11))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .textCase(.uppercase)
                            Text(arrival.direction)
                                .font(.custom("Helvetica", size: 14))
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
                                .font(.custom("Helvetica-Bold", size: 13))
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
    
    // MARK: - Helper Functions
    
    /// Formats walking distance to the stop.
    private func formatDistance(_ meters: Double) -> String {
        if meters < 100 {
            return "\(Int(meters))m away"
        } else if meters < 1000 {
            return "\(Int(meters / 10) * 10)m away"
        } else {
            let km = meters / 1000.0
            return String(format: "%.1fkm away", km)
        }
    }
}
