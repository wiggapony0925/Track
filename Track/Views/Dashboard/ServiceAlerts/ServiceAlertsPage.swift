//
//  ServiceAlertsPage.swift
//  Track
//
//  Full-page service alerts view navigated to from the map bell button.
//  Shows today's alerts grouped by mode with rich detail, severity badges,
//  and tap-to-expand descriptions. Handles empty & offline states gracefully.
//

import SwiftUI

/// Full-page view for browsing all service alerts.
struct ServiceAlertsPage: View {
    let alerts: [TransitAlert]
    let sheetNavigator: SheetNavigator
    var lastUpdated: Date? = nil

    /// Whether the device is currently online.
    private var isOnline: Bool {
        OfflineCacheManager.shared.isOnline
    }

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

    /// Summary counts by severity for the summary strip.
    private var severeCount: Int { alerts.filter { $0.severity == "severe" }.count }
    private var warningCount: Int { alerts.filter { $0.severity != "severe" }.count }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            header

            Divider()
                .opacity(0.4)

            // MARK: - Content
            if alerts.isEmpty {
                emptyOrOfflineState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        // Date + last-updated row
                        dateBanner
                            .padding(.top, 12)

                        // Quick severity summary
                        severitySummaryStrip

                        // Grouped alerts by mode
                        ForEach(groupedAlerts, id: \.mode) { group in
                            ServiceAlertModeGroup(
                                mode: group.mode,
                                label: group.label,
                                icon: group.icon,
                                alerts: group.alerts
                            )
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .background(AppTheme.Gradients.screen)
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            // Centered title
            Text("Service Alerts")
                .font(.custom("Helvetica-Bold", size: 17))
                .foregroundColor(AppTheme.Colors.textPrimary)

            HStack {
                // Back button
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
                }
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.vertical, 14)
        .background(AppTheme.Gradients.floating)
    }

    // MARK: - Severity Summary Strip

    /// Compact chips showing severe / warning counts at a glance.
    private var severitySummaryStrip: some View {
        HStack(spacing: 10) {
            if severeCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(severeCount) Severe")
                        .font(.custom("Helvetica-Bold", size: 12))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(AppTheme.Colors.alertRed)
                )
            }

            if warningCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(warningCount) Advisory")
                        .font(.custom("Helvetica-Bold", size: 12))
                }
                .foregroundColor(.black.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(AppTheme.Colors.warningYellow)
                )
            }

            Spacer()
        }
        .padding(.horizontal, AppTheme.Layout.margin)
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

    // MARK: - Empty / Offline State

    /// Shows either an "All Clear" message or an offline notice depending
    /// on connectivity. Properly centered in the remaining space below the header.
    private var emptyOrOfflineState: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()

                if isOnline {
                    onlineEmptyState
                } else {
                    offlineEmptyState
                }

                Spacer()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    /// All clear — no alerts and the device is online.
    private var onlineEmptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(AppTheme.Gradients.tintWash(AppTheme.Colors.successGreen, intensity: 0.18))
                    .frame(width: 96, height: 96)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundColor(AppTheme.Colors.successGreen)
            }

            VStack(spacing: 8) {
                Text("All Clear!")
                    .font(.custom("Helvetica-Bold", size: 22))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("No active service alerts right now.\nAll MTA services are running normally.")
                    .font(.custom("Helvetica", size: 15))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            // Last checked timestamp
            if let lastUpdated {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .medium))
                    Text("Checked at \(lastUpdated, style: .time)")
                        .font(.custom("Helvetica", size: 12))
                }
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
    }

    /// Offline — can't fetch alerts because there's no network.
    private var offlineEmptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(AppTheme.Gradients.tintWash(AppTheme.Colors.textSecondary, intensity: 0.12))
                    .frame(width: 96, height: 96)

                Image(systemName: "wifi.slash")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
            }

            VStack(spacing: 8) {
                Text("No Connection")
                    .font(.custom("Helvetica-Bold", size: 22))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("Service alerts require an internet connection.\nPlease check your Wi-Fi or cellular signal.")
                    .font(.custom("Helvetica", size: 15))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            // Last checked timestamp (if we had a previous fetch)
            if let lastUpdated {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .medium))
                    Text("Last checked \(lastUpdated, style: .relative) ago")
                        .font(.custom("Helvetica", size: 12))
                }
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
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

#Preview("Empty — Online") {
    ServiceAlertsPage(
        alerts: [],
        sheetNavigator: SheetNavigator(),
        lastUpdated: Date()
    )
}

#Preview("Empty — Offline") {
    ServiceAlertsPage(
        alerts: [],
        sheetNavigator: SheetNavigator()
    )
}
