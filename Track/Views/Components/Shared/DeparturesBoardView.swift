import SwiftUI

// MARK: - Departures Board View

/// Reusable departures board showing scheduled departure rows with
/// a header, empty states, and swipe-to-change-direction gesture.
struct DeparturesBoardView: View {
    let departures: [ScheduledItem]
    let routeColor: Color
    let isLoading: Bool          // busSchedule == nil && trainArrivals empty
    let hasScheduleData: Bool    // busSchedule != nil || trainArrivals non-empty

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            departuresHeader

            if departures.isEmpty {
                departuresEmptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(departures) { departure in
                        ScheduledDepartureRow(departure: departure, routeColor: routeColor)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var departuresHeader: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(routeColor.opacity(0.5))
                .frame(width: 3, height: 18)
            Text("Scheduled")
                .font(.custom("Helvetica-Bold", size: 14))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .textCase(.uppercase)
                .tracking(0.8)

            Spacer()

            if departures.count > 0 {
                Text("\(departures.count) not on route")
                    .font(.custom("Helvetica", size: 11))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppTheme.Colors.textSecondary.opacity(0.06))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var departuresEmptyState: some View {
        if !hasScheduleData && isLoading {
            ArrivalRowSkeleton(count: 4)
        } else {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.successGreen.opacity(0.08))
                        .frame(width: 52, height: 52)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(AppTheme.Colors.successGreen.opacity(0.7))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("All departures are live-tracked")
                        .font(.custom("Helvetica-Bold", size: 15))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Every scheduled vehicle is reporting its position")
                        .font(.custom("Helvetica", size: 13))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }

                Spacer()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(AppTheme.Colors.successGreen.opacity(0.1), lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, AppTheme.Layout.margin)
        }
    }
}

// MARK: - Scheduled Departure Row

/// A single scheduled departure row with clock-time pill and details.
struct ScheduledDepartureRow: View {
    let departure: ScheduledItem
    let routeColor: Color

    var body: some View {
        HStack(spacing: 0) {
            clockTimePill
            dashedConnector
            ScheduledDepartureDetails(departure: departure)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(rowBackground)
        .overlay(rowBorderOverlay)
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    // MARK: - Extracted Sub-Views

    private var clockTimePill: some View {
        let pillOpacity: Double = 0.08
        let minuteColor: Color = routeColor.opacity(0.8)
        return VStack(spacing: 4) {
            Text(departure.formattedTime)
                .font(.custom("Helvetica-Bold", size: 15))
                .foregroundColor(AppTheme.Colors.textPrimary)

            Text("in \(departure.minutesAway) min")
                .font(.custom("Helvetica-Bold", size: 11))
                .foregroundColor(minuteColor)
        }
        .frame(width: 80)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(routeColor.opacity(pillOpacity))
        )
    }

    private var dashedConnector: some View {
        let connectorColor: Color = routeColor.opacity(0.15)
        return Rectangle()
            .fill(connectorColor)
            .frame(width: 20, height: 2)
    }

    private var rowBackground: some View {
        let cr: CGFloat = AppTheme.Layout.cornerRadius
        return RoundedRectangle(cornerRadius: cr)
            .fill(AppTheme.Gradients.surface)
            .shadow(color: AppTheme.Colors.shadow.opacity(0.12), radius: 6, x: 0, y: 2)
            .shadow(color: AppTheme.Colors.shadowStrong.opacity(0.06), radius: 2, x: 0, y: 1)
    }

    private var rowBorderOverlay: some View {
        let cr: CGFloat = AppTheme.Layout.cornerRadius
        let borderColor: Color = routeColor.opacity(0.08)
        return RoundedRectangle(cornerRadius: cr)
            .strokeBorder(borderColor, lineWidth: 1)
    }
}

// MARK: - Scheduled Departure Details

/// Detail column for a scheduled departure showing headsign, stop, and status.
struct ScheduledDepartureDetails: View {
    let departure: ScheduledItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !departure.headsign.isEmpty {
                Text(departure.headsign)
                    .font(.custom("Helvetica-Bold", size: 14))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
            }

            if !departure.stopName.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                    Text(departure.stopName)
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(AppTheme.Colors.warningYellow.opacity(0.8))
                    .frame(width: 6, height: 6)
                Text("Not on route yet")
                    .font(.custom("Helvetica-Bold", size: 10))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
            }
        }
    }
}

// MARK: - Direction Picker Skeleton

/// Shimmer placeholder for direction pills while shape / arrivals load.
struct DirectionPickerSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBar(width: 70, height: 12, opacity: 0.08)
                .padding(.horizontal, AppTheme.Layout.margin)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([CGFloat(110), 90], id: \.self) { width in
                        SkeletonBar(width: width, height: 40, opacity: 0.10)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
        .shimmer()
    }
}
