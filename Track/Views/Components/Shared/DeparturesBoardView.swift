import SwiftUI

// MARK: - Departures Board View

/// Reusable departures board showing scheduled departure rows with
/// a header, empty states, and swipe-to-change-direction gesture.
struct DeparturesBoardView: View {
    let departures: [ScheduledItem]
    let routeColor: Color
    let isLoading: Bool          // busSchedule == nil && trainArrivals empty
    let hasScheduleData: Bool    // busSchedule != nil || trainArrivals non-empty
    var showsHeader: Bool = true

    /// How many rows to show before requiring "See more" taps.
    private let initialPageSize = 15
    /// Additional rows revealed per "See more" tap.
    private let pageIncrement = 15

    /// Number of departure rows currently visible. Grows in `pageIncrement`
    /// chunks each time the user taps "See more" so the sheet doesn't have
    /// to render hundreds of timetable rows up front.
    @State private var visibleCount: Int = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                departuresHeader
            }

            if departures.isEmpty {
                departuresEmptyState
            } else {
                let visible = Array(departures.prefix(visibleCount))
                let sections = Self.groupByDay(visible)
                VStack(spacing: 16) {
                    ForEach(sections, id: \.id) { section in
                        VStack(spacing: 10) {
                            DepartureDayHeader(
                                date: section.date,
                                count: section.items.count,
                                routeColor: routeColor
                            )
                            VStack(spacing: 10) {
                                ForEach(section.items) { dep in
                                    ScheduledDepartureRow(
                                        departure: dep,
                                        routeColor: routeColor
                                    )
                                }
                            }
                        }
                    }

                    if departures.count > visibleCount {
                        seeMoreButton(remaining: departures.count - visibleCount)
                    }
                }
            }
        }
        .onAppear { visibleCount = initialPageSize }
        .onChange(of: departures.count) { _, _ in visibleCount = initialPageSize }
    }

    /// Footer button that reveals the next `pageIncrement` rows.
    private func seeMoreButton(remaining: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                visibleCount = min(departures.count, visibleCount + pageIncrement)
            }
            HapticManager.impact(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                Text("See \(min(remaining, pageIncrement)) more")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundColor(routeColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                Capsule()
                    .fill(routeColor.opacity(0.10))
                    .overlay(
                        Capsule()
                            .strokeBorder(routeColor.opacity(0.25), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 4)
    }

    // MARK: - Day Grouping

    /// One contiguous block of departures sharing a calendar day in NYC time.
    fileprivate struct DaySection: Identifiable {
        let id: String
        let date: Date
        let items: [ScheduledItem]
    }

    /// Calendar fixed to America/New_York so Transit's day boundaries
    /// (and ours) line up regardless of the device timezone.
    fileprivate static let nycCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return cal
    }()

    fileprivate static func groupByDay(
        _ items: [ScheduledItem]
    ) -> [DaySection] {
        // Keep input order — they're already sorted by departure time.
        var sections: [DaySection] = []
        var currentKey: String?
        var currentBucket: [ScheduledItem] = []
        var currentDate: Date = .now

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = nycCalendar.timeZone

        func flush() {
            guard let key = currentKey, !currentBucket.isEmpty else { return }
            sections.append(
                DaySection(id: key, date: currentDate, items: currentBucket)
            )
            currentBucket = []
        }

        for it in items {
            let key = fmt.string(from: it.departureDate)
            if key != currentKey {
                flush()
                currentKey = key
                currentDate = it.departureDate
            }
            currentBucket.append(it)
        }
        flush()
        return sections
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

// MARK: - Day Section Header

/// Section header drawn above each day's block of scheduled departures.
/// Mirrors Transit's "TODAY · Mon Apr 21" / "TOMORROW · 5:00 AM start"
/// treatment, themed with the current route color.
private struct DepartureDayHeader: View {
    let date: Date
    let count: Int
    let routeColor: Color

    private static let weekdayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        f.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return f
    }()

    private static let firstTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return f
    }()

    /// Returns "TODAY", "TOMORROW", or e.g. "WED" relative to NYC now.
    private var label: String {
        let cal = DeparturesBoardView.nycCalendar
        let now = Date()
        if cal.isDate(date, inSameDayAs: now) { return "TODAY" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(date, inSameDayAs: tomorrow) {
            return "TOMORROW"
        }
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        f.timeZone = cal.timeZone
        return f.string(from: date).uppercased()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Color-bar accent on the left, themed to the route.
            RoundedRectangle(cornerRadius: 2)
                .fill(routeColor)
                .frame(width: 4, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(label)
                        .font(.custom("Helvetica-Bold", size: 13))
                        .tracking(1.0)
                        .foregroundColor(routeColor)

                    Text("·")
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))

                    Text(Self.weekdayFmt.string(from: date))
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                }
                Text("First at \(Self.firstTimeFmt.string(from: date))")
                    .font(.custom("Helvetica", size: 11))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }

            Spacer()

            // Trailing departure-count chip in route color.
            Text("\(count)")
                .font(.custom("Helvetica-Bold", size: 12))
                .foregroundColor(routeColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(routeColor.opacity(0.12))
                )
                .overlay(
                    Capsule().strokeBorder(routeColor.opacity(0.18), lineWidth: 0.5)
                )
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.vertical, 6)
        .background(
            // Subtle fade so the header reads as a divider without a hard rule.
            LinearGradient(
                colors: [
                    routeColor.opacity(0.06),
                    routeColor.opacity(0.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
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
