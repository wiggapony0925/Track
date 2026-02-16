//
//  DashboardHelpers.swift
//  Track
//
//  Shared helper views used across dashboard components.
//  Includes section headers, empty states, alerts, and outages sections.
//

import SwiftUI

// MARK: - Section Header

/// Reusable section header with optional update timestamp.
struct DashboardSectionHeader: View {
    let title: String
    let updated: Date?
    
    init(title: String, updated: Date? = nil) {
        self.title = title
        self.updated = updated
    }
    
    var body: some View {
        HStack {
            Text(title)
                .font(AppTheme.Typography.sectionHeader)
                .foregroundColor(AppTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .lineLimit(1)
            
            if let updated = updated {
                Spacer()
                Text("Updated \(updated, style: .time)")
                    .font(.custom("Helvetica", size: 12))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 8)
    }
}

// MARK: - Empty State View

/// Generic empty state view with icon and message.
struct EmptyStateView: View {
    let icon: String
    let message: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text(message)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - Elevator Outages Section

/// Section displaying elevator and escalator outages.
struct ElevatorOutagesSection: View {
    let outages: [ElevatorStatus]
    
    var body: some View {
        if !outages.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                DashboardSectionHeader(title: "Elevator & Escalator Outages")
                
                VStack(spacing: 0) {
                    ForEach(Array(outages.prefix(AppSettings.shared.maxElevatorOutages).enumerated()), id: \.element.id) { index, outage in
                        HStack(spacing: 10) {
                            Image(systemName: outage.equipmentType.lowercased().contains("elevator")
                                  ? "arrow.up.arrow.down.circle.fill"
                                  : "stairs")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.alertRed)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(outage.station)
                                    .font(.custom("Helvetica-Bold", size: 13))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                Text(outage.description)
                                    .font(.custom("Helvetica", size: 12))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                    .lineLimit(2)
                            }
                            
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, AppTheme.Layout.cardPadding)
                        .padding(.vertical, 8)
                        
                        if index < min(outages.count, AppSettings.shared.maxElevatorOutages) - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.cardPadding + 34)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
    }
}

#Preview("Section Header") {
    VStack {
        DashboardSectionHeader(title: "Nearby Arrivals", updated: Date())
        DashboardSectionHeader(title: "Stations")
    }
    .background(AppTheme.Colors.background)
}

#Preview("Empty State") {
    EmptyStateView(icon: "tram.fill", message: "No subway arrivals nearby")
        .background(AppTheme.Colors.background)
}

// MARK: - Commuter Rail Section Header

/// Compact section header for commuter rail dashboards (LIRR, MNR).
struct CommuterRailSectionHeader: View {
    let title: String
    let iconName: String
    let color: Color
    let updated: Date?
    
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color)
            )
            
            Spacer()
            
            if let updated = updated {
                Text(updated, style: .time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

// MARK: - Commuter Rail Arrival Row

/// Shared arrival row for commuter rail (LIRR, MNR).
struct CommuterRailArrivalRow: View {
    let arrival: TrainArrival
    let brandColor: Color
    let isTracking: Bool
    let onTrack: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Route badge
            Text(arrival.routeID)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 50, height: 28)
                .background(brandColor)
                .cornerRadius(6)
            
            // Station and destination info
            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.destination ?? arrival.direction)
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                
                Text(arrival.stationName)
                    .font(.custom("Helvetica", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Time info
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(arrival.minutesAway)")
                        .font(.custom("Helvetica-Bold", size: 24))
                        .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    Text("min")
                        .font(.custom("Helvetica-Bold", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                
                Text(arrival.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(arrival.status.lowercased().contains("on time") ? AppTheme.Colors.successGreen : AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, AppTheme.Layout.margin)
        .contentShape(Rectangle())
        .onTapGesture {
            onTrack()
        }
    }
}

// MARK: - Out of Area Notice View

/// Friendly notice shown when user is out of service area but we still show closest departures.
struct OutOfAreaNoticeView: View {
    let message: String
    let subtitle: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.slash")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(AppTheme.Colors.warningYellow)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.custom("Helvetica-Bold", size: 14))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                
                Text(subtitle)
                    .font(.custom("Helvetica", size: 12))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            
            Spacer()
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 12)
        .background(AppTheme.Colors.warningYellow.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                .stroke(AppTheme.Colors.warningYellow.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

// MARK: - Far From Transit View

/// Cute "oh no, you're far away" hero banner shown when the user is far from
/// a transit mode but we still have departures to show below it.
/// Shows a friendly icon, empathetic message, and a subtle hint that results follow.
struct FarFromTransitView: View {
    let icon: String
    let title: String
    let subtitle: String
    let accentColor: Color
    
    var body: some View {
        VStack(spacing: 12) {
            // Animated circle with icon
            ZStack {
                // Outer pulse ring
                Circle()
                    .fill(accentColor.opacity(0.06))
                    .frame(width: 88, height: 88)
                
                // Inner circle
                Circle()
                    .fill(accentColor.opacity(0.12))
                    .frame(width: 64, height: 64)
                
                // Icon
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(accentColor)
            }
            
            // Title
            Text(title)
                .font(.custom("Helvetica-Bold", size: 17))
                .foregroundColor(AppTheme.Colors.textPrimary)
            
            // Subtitle
            Text(subtitle)
                .font(.custom("Helvetica", size: 13))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            // Divider hint that content follows
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("Nearest departures below")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(accentColor.opacity(0.7))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                .fill(accentColor.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                        .strokeBorder(accentColor.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

// MARK: - No Service Empty State

/// Full empty state when no service is available at all.
struct NoServiceEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let brandColor: Color
    
    var body: some View {
        VStack(spacing: 16) {
            // Icon in circle
            ZStack {
                Circle()
                    .fill(brandColor.opacity(0.1))
                    .frame(width: 64, height: 64)
                
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(brandColor)
            }
            
            // Title
            Text(title)
                .font(.custom("Helvetica-Bold", size: 18))
                .foregroundColor(AppTheme.Colors.textPrimary)
            
            // Message
            Text(message)
                .font(.custom("Helvetica", size: 14))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            
            // Search hint
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                Text("Try searching for a station")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(brandColor)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
