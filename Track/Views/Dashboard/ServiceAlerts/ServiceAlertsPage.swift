// Full-page service alerts view navigated to from the map bell button.
// Shows today's alerts grouped by mode with rich detail, severity badges,
// and tap-to-expand descriptions. Handles empty & offline states gracefully.

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
    private var groupedAlerts: [(
        mode: String, label: String,
        icon: String, alerts: [TransitAlert]
    )] {
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
            header

            if alerts.isEmpty {
                emptyOrOfflineState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        statusBar
                            .padding(.top, 8)

                        ForEach(groupedAlerts, id: \.mode) { group in
                            ServiceAlertModeGroup(
                                mode: group.mode,
                                label: group.label,
                                icon: group.icon,
                                alerts: group.alerts
                            )
                        }

                        disclaimerFooter
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .background(AppTheme.Gradients.screen)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(severityGradient)
                    Text("Service Alerts")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                }

                HStack {
                    Button {
                        sheetNavigator.goBack()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                            Text("Back")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(AppTheme.Colors.mtaBlue.opacity(0.1))
                        )
                    }

                    Spacer()

                    if !alerts.isEmpty {
                        Text("\(alerts.count)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(severityColor)
                            )
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 10)
            .padding(.bottom, 12)

            Rectangle()
                .fill(AppTheme.Colors.borderSubtle.opacity(0.5))
                .frame(height: 1)
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textTertiary)

                Text(Date(), format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)

                Spacer()

                if let lastUpdated {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(AppTheme.Colors.successGreen)
                            .frame(width: 5, height: 5)
                        Text("Updated \(lastUpdated, style: .time)")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundColor(AppTheme.Colors.textTertiary)
                }
            }

            HStack(spacing: 8) {
                if severeCount > 0 {
                    severityPill(
                        icon: "exclamationmark.octagon.fill",
                        count: severeCount,
                        label: "Severe",
                        color: AppTheme.Colors.alertRed
                    )
                }

                if warningCount > 0 {
                    severityPill(
                        icon: "exclamationmark.triangle.fill",
                        count: warningCount,
                        label: "Advisory",
                        color: AppTheme.Colors.warningYellow
                    )
                }

                Spacer()
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    private func severityPill(
        icon: String, count: Int, label: String, color: Color
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text("\(count)")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(color.opacity(0.10))
                .overlay(
                    Capsule()
                        .stroke(color.opacity(0.18), lineWidth: 1)
                )
        )
    }

    // MARK: - Disclaimer Footer

    private var disclaimerFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .semibold))
            Text("Alert data sourced from MTA GTFS-RT feeds. May be delayed.")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(AppTheme.Colors.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
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
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                AppTheme.Colors.successGreen.opacity(0.14),
                                AppTheme.Colors.successGreen.opacity(0.04),
                                Color.clear,
                            ],
                            center: .center, startRadius: 20, endRadius: 56
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                AppTheme.Colors.successGreen,
                                AppTheme.Colors.successGreen.opacity(0.7),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(spacing: 6) {
                Text("All Clear")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("No active service alerts.\nAll MTA services are running normally.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            if let lastUpdated {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Checked at \(lastUpdated, style: .time)")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundColor(AppTheme.Colors.textTertiary)
            }
        }
        .padding(.horizontal, 40)
    }

    /// Offline — can't fetch alerts because there's no network.
    private var offlineEmptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                AppTheme.Colors.textTertiary.opacity(0.10),
                                Color.clear,
                            ],
                            center: .center, startRadius: 16, endRadius: 52
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: "wifi.slash")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }

            VStack(spacing: 6) {
                Text("No Connection")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text(
                    "Service alerts require an internet connection."
                    + "\nCheck your Wi-Fi or cellular signal."
                )
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            if let lastUpdated {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Last checked \(lastUpdated, style: .relative) ago")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(AppTheme.Colors.textTertiary)
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

    /// Gradient for the header bell icon based on severity mix.
    private var severityGradient: LinearGradient {
        let colors: [Color] = severeCount > 0
            ? [AppTheme.Colors.alertRed, AppTheme.Colors.warningYellow]
            : [AppTheme.Colors.warningYellow, AppTheme.Colors.warningYellow.opacity(0.7)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

#Preview("With Alerts") {
    ServiceAlertsPage(
        alerts: [
            TransitAlert(
                routeId: "A", title: "A train delays",
                description: "Delays due to signal problems.",
                severity: "warning", mode: "subway"),
            TransitAlert(
                routeId: "1", title: "Service suspended",
                description: "Between 96 St and South Ferry.",
                severity: "severe", mode: "subway"),
            TransitAlert(
                routeId: "B63", title: "B63 detoured",
                description: "Via Atlantic Ave.",
                severity: "warning", mode: "bus"),
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
