//
//  ServiceAlertsPage.swift
//  Track
//
//  Full-page service alerts view navigated to from the map bell button.
//  Shows today's alerts grouped by mode with rich detail, severity badges,
//  and tap-to-expand descriptions.
//

import SwiftUI

/// Full-page view for browsing all service alerts.
struct ServiceAlertsPage: View {
    let alerts: [TransitAlert]
    let sheetNavigator: SheetNavigator
    var lastUpdated: Date? = nil
    
    /// Group alerts by mode, maintaining a consistent display order.
    /// Within each mode, sorted by severity (severe first) then recency.
    private var groupedAlerts: [(mode: String, label: String, icon: String, alerts: [TransitAlert])] {
        let modeOrder = ["subway", "bus", "lirr", "mnr"]
        let grouped = Dictionary(grouping: alerts, by: \.mode)
        
        return modeOrder.compactMap { mode in
            guard let modeAlerts = grouped[mode], !modeAlerts.isEmpty else { return nil }
            let first = modeAlerts[0]
            let sorted = modeAlerts.sortedBySeverityAndTime()
            return (mode: mode, label: first.modeLabel, icon: first.modeIcon, alerts: sorted)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            header
            
            // MARK: - Content
            if alerts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        // Today's date banner
                        dateBanner
                        
                        // Grouped alerts
                        ForEach(groupedAlerts, id: \.mode) { group in
                            ServiceAlertModeGroup(
                                mode: group.mode,
                                label: group.label,
                                icon: group.icon,
                                alerts: group.alerts
                            )
                        }
                        
                        Spacer()
                            .frame(height: 20)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .background(AppTheme.Colors.background)
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            Button {
                sheetNavigator.goBack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Back")
                        .font(.custom("Helvetica", size: 15))
                }
                .foregroundColor(AppTheme.Colors.mtaBlue)
            }
            
            Spacer()
            
            Text("Service Alerts")
                .font(.custom("Helvetica-Bold", size: 17))
                .foregroundColor(AppTheme.Colors.textPrimary)
            
            Spacer()
            
            // Alert count badge
            if !alerts.isEmpty {
                Text("\(alerts.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(severityColor)
                    )
            } else {
                // Spacer to keep title centered
                Color.clear.frame(width: 40)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.vertical, 12)
        .background(AppTheme.Colors.background)
    }
    
    // MARK: - Date Banner
    
    private var dateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
            
            Text("Today — \(Date(), format: .dateTime.weekday(.wide).month(.wide).day())")
                .font(.custom("Helvetica", size: 13))
                .foregroundColor(AppTheme.Colors.textSecondary)
            
            Spacer()
            
            if let lastUpdated {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text(lastUpdated, style: .time)
                        .font(.custom("Helvetica", size: 11))
                }
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.successGreen.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(AppTheme.Colors.successGreen)
            }
            
            Text("All Clear!")
                .font(.custom("Helvetica-Bold", size: 20))
                .foregroundColor(AppTheme.Colors.textPrimary)
            
            Text("No active service alerts right now.\nAll MTA services are running normally.")
                .font(.custom("Helvetica", size: 14))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    /// Returns red if any alert is severe, yellow otherwise.
    private var severityColor: Color {
        alerts.contains(where: { $0.severity == "severe" })
            ? AppTheme.Colors.alertRed
            : AppTheme.Colors.warningYellow
    }
}

#Preview("With Alerts") {
    ServiceAlertsPage(
        alerts: [
            TransitAlert(routeId: "A", title: "A train delays", description: "Delays due to signal problems.", severity: "warning", mode: "subway"),
            TransitAlert(routeId: "1", title: "Service suspended", description: "Between 96 St and South Ferry.", severity: "severe", mode: "subway"),
            TransitAlert(routeId: "B63", title: "B63 detoured", description: "Via Atlantic Ave.", severity: "warning", mode: "bus"),
        ],
        sheetNavigator: SheetNavigator()
    )
}

#Preview("Empty") {
    ServiceAlertsPage(
        alerts: [],
        sheetNavigator: SheetNavigator()
    )
}
