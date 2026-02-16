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

// MARK: - Service Alerts Section

/// Section displaying transit service alerts.
struct ServiceAlertsSection: View {
    let alerts: [TransitAlert]
    
    var body: some View {
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                DashboardSectionHeader(title: "Service Alerts")
                
                VStack(spacing: 0) {
                    ForEach(Array(alerts.prefix(AppSettings.shared.maxServiceAlerts).enumerated()), id: \.element.id) { index, alert in
                        HStack(spacing: 10) {
                            if let routeId = alert.routeId {
                                RouteBadge(routeID: routeId, size: .small)
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(AppTheme.Colors.warningYellow)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.title)
                                    .font(.custom("Helvetica-Bold", size: 13))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                Text(alert.description)
                                    .font(.custom("Helvetica", size: 12))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                    .lineLimit(2)
                            }
                            
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, AppTheme.Layout.cardPadding)
                        .padding(.vertical, 8)
                        
                        if index < min(alerts.count, AppSettings.shared.maxServiceAlerts) - 1 {
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
