import SwiftUI

// MARK: - Route Alert Banner

/// Compact alert banner shown at the top of a route detail,
/// with severity coloring, timestamp, and multi-alert count.
struct RouteAlertBanner: View {
    let alert: TransitAlert
    let totalAlertCount: Int

    private var bannerColor: Color {
        alert.severity == "severe" ? AppTheme.Colors.alertRed : AppTheme.Colors.warningYellow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // "Latest alert • X ago" label
            HStack(spacing: 6) {
                Circle()
                    .fill(bannerColor)
                    .frame(width: 6, height: 6)

                Text("Latest alert")
                    .font(.custom("Helvetica-Bold", size: 10))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                if let ts = alert.updatedAt {
                    Text("•")
                        .font(.system(size: 8))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                    HStack(spacing: 0) {
                        Text(Date(timeIntervalSince1970: TimeInterval(ts)), style: .relative)
                        Text(" ago")
                    }
                    .font(.custom("Helvetica", size: 10))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                }

                Spacer()

                if totalAlertCount > 1 {
                    Text("\(totalAlertCount) alerts")
                        .font(.custom("Helvetica", size: 10))
                        .foregroundColor(bannerColor)
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            // Main banner strip
            alertStrip(title: alert.title, extraCount: totalAlertCount - 1, color: bannerColor)
        }
    }

    private func alertStrip(title: String, extraCount: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)

            Text(title)
                .font(.custom("Helvetica-Bold", size: 12))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.9)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color)
                .shadow(color: color.opacity(0.3), radius: 6, x: 0, y: 3)
        )
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

// MARK: - Inline Alert Banner

/// Lightweight alert banner built from the backend's `InlineAlertResponse`.
/// Used as a fallback when full `TransitAlert` data hasn't loaded yet.
struct InlineAlertBannerView: View {
    let alert: InlineAlertResponse
    let totalAlertCount: Int

    private var bannerColor: Color {
        alert.severity == "severe" ? AppTheme.Colors.alertRed : AppTheme.Colors.warningYellow
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)

            Text(alert.title)
                .font(.custom("Helvetica-Bold", size: 12))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            if totalAlertCount > 1 {
                Text("+\(totalAlertCount - 1)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(bannerColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.9)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(bannerColor)
                .shadow(color: bannerColor.opacity(0.3), radius: 6, x: 0, y: 3)
        )
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

// MARK: - Alert Banner Skeleton

/// Shimmer placeholder for the alert banner while arrivals are in-flight.
struct AlertBannerSkeleton: View {
    var body: some View {
        HStack(spacing: 10) {
            SkeletonBar(width: 14, height: 14, opacity: 0.12)
            SkeletonBar(width: 200, height: 14, opacity: 0.10)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        )
        .padding(.horizontal, AppTheme.Layout.margin)
        .shimmer()
    }
}

// MARK: - Route Alerts Section

/// Full alerts section with header and expandable alert rows.
struct RouteAlertsSection: View {
    let alerts: [TransitAlert]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.warningYellow)

                Text("Active Alerts")
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer()

                Text("\(alerts.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            alerts.contains(where: { $0.severity == "severe" })
                                ? AppTheme.Colors.alertRed
                                : AppTheme.Colors.warningYellow
                        )
                    )
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            // Alert rows
            VStack(spacing: 0) {
                ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                    RouteDetailAlertRow(alert: alert)

                    if index < alerts.count - 1 {
                        Divider()
                            .padding(.leading, AppTheme.Layout.cardPadding + 34)
                    }
                }
            }
            .background(AppTheme.Colors.cardBackground)
            .cornerRadius(AppTheme.Layout.cornerRadius)
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            .padding(.horizontal, AppTheme.Layout.margin)
        }
    }
}

// MARK: - No Alerts Empty State

/// Shown when the Alerts tab is selected but there are no active alerts.
struct NoAlertsEmptyState: View {
    let routeDisplayName: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(AppTheme.Colors.successGreen)

            Text("All Clear")
                .font(.custom("Helvetica-Bold", size: 17))
                .foregroundColor(AppTheme.Colors.textPrimary)

            Text("No active service alerts for the \(routeDisplayName)")
                .font(.custom("Helvetica", size: 14))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

// MARK: - Route Detail Alert Row

/// A compact alert row with expand/collapse for description.
struct RouteDetailAlertRow: View {
    let alert: TransitAlert
    @State private var isExpanded = false

    private var severityColor: Color {
        alert.severity == "severe" ? AppTheme.Colors.alertRed : AppTheme.Colors.warningYellow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(severityColor)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(alert.title)
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(isExpanded ? nil : 2)

                    if isExpanded && !alert.description.isEmpty {
                        Text(alert.description)
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }

                    HStack(spacing: 8) {
                        Text(alert.severity == "severe" ? "⚠️ Severe" : "Warning")
                            .font(.custom("Helvetica-Bold", size: 10))
                            .foregroundColor(severityColor)

                        if let ts = alert.updatedAt {
                            HStack(spacing: 0) {
                                Text(Date(timeIntervalSince1970: TimeInterval(ts)), style: .relative)
                                Text(" ago")
                            }
                            .font(.custom("Helvetica", size: 10))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                        }
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, AppTheme.Layout.cardPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }
        }
    }
}
