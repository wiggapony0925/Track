//
//  ServiceAlertsSection.swift
//  Track
//
//  A modern, grouped service alerts section displayed in the dashboard.
//  Alerts are grouped by transit mode (Subway, Bus, LIRR, Metro-North)
//  and displayed in expandable cards with severity-based color coding.
//  Follows the app's glassmorphic card design system.
//

import SwiftUI

// MARK: - Section

/// Top-level alerts section that groups alerts by mode and shows a summary banner.
struct ServiceAlertsSection: View {
    let alerts: [TransitAlert]
    
    /// Group alerts by mode, maintaining a consistent display order.
    private var groupedAlerts: [(mode: String, label: String, icon: String, alerts: [TransitAlert])] {
        let modeOrder = ["subway", "bus", "lirr", "mnr"]
        let grouped = Dictionary(grouping: alerts, by: \.mode)
        
        return modeOrder.compactMap { mode in
            guard let modeAlerts = grouped[mode], !modeAlerts.isEmpty else { return nil }
            let first = modeAlerts[0]
            return (mode: mode, label: first.modeLabel, icon: first.modeIcon, alerts: modeAlerts)
        }
    }
    
    var body: some View {
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // Section header with alert count
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.warningYellow)
                        
                        Text("SERVICE ALERTS")
                            .font(AppTheme.Typography.sectionHeader)
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    
                    Spacer()
                    
                    // Total count badge
                    Text("\(alerts.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(severityColor(for: alerts))
                        )
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.top, 8)
                
                // Mode groups
                ForEach(groupedAlerts, id: \.mode) { group in
                    ServiceAlertModeGroup(
                        mode: group.mode,
                        label: group.label,
                        icon: group.icon,
                        alerts: group.alerts
                    )
                }
            }
        }
    }
    
    /// Returns red if any alert is severe, yellow otherwise.
    private func severityColor(for alerts: [TransitAlert]) -> Color {
        alerts.contains(where: { $0.severity == "severe" })
            ? AppTheme.Colors.alertRed
            : AppTheme.Colors.warningYellow
    }
}

// MARK: - Mode Group

/// An expandable card for one transit mode's alerts.
struct ServiceAlertModeGroup: View {
    let mode: String
    let label: String
    let icon: String
    let alerts: [TransitAlert]
    
    @State private var isExpanded = false
    
    /// Show first 2 by default, expand to reveal the rest.
    private let previewCount = 2
    
    private var visibleAlerts: [TransitAlert] {
        isExpanded ? alerts : Array(alerts.prefix(previewCount))
    }
    
    private var hasMore: Bool {
        alerts.count > previewCount
    }
    
    private var modeColor: Color {
        switch mode {
        case "bus":   return AppTheme.Colors.mtaBlue
        case "lirr":  return AppTheme.CommuterRailColors.lirrBlue
        case "mnr":   return AppTheme.CommuterRailColors.mnrBlue
        default:      return AppTheme.Colors.subwayBlack
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mode header bar
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(modeColor))
                
                Text(label)
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                
                Text("(\(alerts.count))")
                    .font(.custom("Helvetica", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                
                Spacer()
                
                if hasMore {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Show Less" : "Show All")
                                .font(.custom("Helvetica", size: 12))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.cardPadding)
            .padding(.vertical, 10)
            
            Divider()
                .padding(.leading, AppTheme.Layout.cardPadding)
            
            // Alert rows
            VStack(spacing: 0) {
                ForEach(Array(visibleAlerts.enumerated()), id: \.element.id) { index, alert in
                    ServiceAlertRow(alert: alert, mode: mode)
                    
                    if index < visibleAlerts.count - 1 {
                        Divider()
                            .padding(.leading, AppTheme.Layout.cardPadding + 34)
                    }
                }
            }
        }
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

// MARK: - Alert Row

/// A single alert row with route badge, severity indicator, and description.
struct ServiceAlertRow: View {
    let alert: TransitAlert
    let mode: String
    
    @State private var showFullDescription = false
    
    private var severityColor: Color {
        alert.severity == "severe" ? AppTheme.Colors.alertRed : AppTheme.Colors.warningYellow
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // Left: route badge or severity icon
                if let routeId = alert.routeId, !routeId.isEmpty {
                    RouteBadge(
                        routeID: routeId,
                        size: .small,
                        isBus: mode == "bus",
                        mode: mode
                    )
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(severityColor)
                        .frame(width: 26, height: 26)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    // Title
                    Text(alert.title)
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(showFullDescription ? nil : 2)
                    
                    // Description
                    if !alert.description.isEmpty {
                        Text(alert.description)
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(showFullDescription ? nil : 2)
                    }
                    
                    // Severity badge
                    HStack(spacing: 4) {
                        Circle()
                            .fill(severityColor)
                            .frame(width: 6, height: 6)
                        
                        Text(alert.severity == "severe" ? "Severe" : "Warning")
                            .font(.custom("Helvetica", size: 11))
                            .foregroundColor(severityColor)
                    }
                    .padding(.top, 2)
                }
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppTheme.Layout.cardPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFullDescription.toggle()
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Service Alerts") {
    ScrollView {
        ServiceAlertsSection(alerts: [
            TransitAlert(
                routeId: "A",
                title: "A train running with delays",
                description: "Southbound A trains are running with delays due to signal problems at 59 St-Columbus Circle.",
                severity: "warning",
                mode: "subway"
            ),
            TransitAlert(
                routeId: "1",
                title: "Service suspended between 96 St and South Ferry",
                description: "1 train service is suspended in both directions between 96 St and South Ferry due to a signal malfunction.",
                severity: "severe",
                mode: "subway"
            ),
            TransitAlert(
                routeId: "B63",
                title: "B63 route detoured",
                description: "B63 buses are detoured in both directions via Atlantic Ave due to road construction.",
                severity: "warning",
                mode: "bus"
            ),
            TransitAlert(
                routeId: "LIRR_1",
                title: "Babylon Branch delays up to 20 min",
                description: "Trains on the Babylon Branch are experiencing delays of up to 20 minutes.",
                severity: "severe",
                mode: "lirr"
            ),
        ])
    }
    .background(AppTheme.Colors.background)
}
