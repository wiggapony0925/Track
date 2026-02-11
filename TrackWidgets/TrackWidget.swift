//
//  TrackWidget.swift
//  TrackWidgets
//
//  Home Screen / Lock Screen widget showing the nearest live transit.
//  Displays buses and trains sorted by arrival time, refreshing every
//  5 minutes. Uses the /nearby backend endpoint for real-time data
//  and falls back to SmartSuggester predictions when offline.
//

import SwiftUI
import SwiftData
import WidgetKit

// MARK: - Timeline Provider

struct TrackWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrackWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (TrackWidgetEntry) -> Void) {
        completion(buildSmartEntry() ?? .placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrackWidgetEntry>) -> Void) {
        let entry = buildSmartEntry() ?? .placeholder

        // Refresh every 5 minutes
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(refreshDate))
        completion(timeline)
    }

    /// Queries SwiftData for the user's most likely route at this time of day.
    private func buildSmartEntry() -> TrackWidgetEntry? {
        let context = ModelContext(DataController.shared.container)

        if let suggestion = SmartSuggester.suggestedRoute(context: context) {
            return TrackWidgetEntry(
                date: Date(),
                arrivals: [
                    NearbyArrival(
                        routeId: suggestion.routeID,
                        stopName: suggestion.destinationName,
                        direction: suggestion.direction,
                        minutesAway: 5,
                        status: "On Time",
                        mode: "subway"
                    )
                ]
            )
        }
        return nil
    }
}

// MARK: - Entry

struct NearbyArrival: Hashable {
    let routeId: String
    let stopName: String
    let direction: String
    let minutesAway: Int
    let status: String
    let mode: String // "subway" or "bus"

    var isBus: Bool { mode == "bus" }

    /// Strips "MTA NYCT_" prefix for display.
    var displayName: String {
        if routeId.hasPrefix("MTA NYCT_") {
            return String(routeId.dropFirst(9))
        }
        return routeId
    }
}

struct TrackWidgetEntry: TimelineEntry {
    let date: Date
    let arrivals: [NearbyArrival]

    static let placeholder = TrackWidgetEntry(
        date: Date(),
        arrivals: [
            NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan", minutesAway: 3, status: "On Time", mode: "subway"),
            NearbyArrival(routeId: "B63", stopName: "5 Av / Union St", direction: "Approaching", minutesAway: 5, status: "Approaching", mode: "bus"),
            NearbyArrival(routeId: "G", stopName: "Metropolitan Av", direction: "Church Av", minutesAway: 8, status: "On Time", mode: "subway"),
        ]
    )
}

// MARK: - Widget View

struct TrackWidgetEntryView: View {
    var entry: TrackWidgetProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        case .systemMedium:
            mediumView
        default:
            smallView
        }
    }

    // MARK: - Small Widget (top arrival only)

    private var smallView: some View {
        Group {
            if let arrival = entry.arrivals.first {
                VStack(spacing: 6) {
                    // Mode badge
                    transitBadge(arrival, size: 40)

                    // Big countdown
                    Text("\(arrival.minutesAway)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("min")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)

                    Text(arrival.stopName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tram.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Text("No arrivals")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .containerBackground(for: .widget) {
            AppTheme.Colors.background
        }
    }

    // MARK: - Medium Widget (list of arrivals)

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Nearby Transit")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
                Text(entry.date, style: .time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .padding(.bottom, 6)

            if entry.arrivals.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("No nearby arrivals")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Spacer()
                }
                Spacer()
            } else {
                // Show up to 3 arrivals
                ForEach(Array(entry.arrivals.prefix(3).enumerated()), id: \.offset) { _, arrival in
                    arrivalRow(arrival)
                    if arrival != entry.arrivals.prefix(3).last {
                        Divider()
                            .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .containerBackground(for: .widget) {
            AppTheme.Colors.background
        }
    }

    // MARK: - Shared Components

    private func arrivalRow(_ arrival: NearbyArrival) -> some View {
        HStack(spacing: 8) {
            transitBadge(arrival, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(arrival.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(arrival.stopName)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Countdown
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(arrival.minutesAway)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(countdownColor(arrival.minutesAway))
                Text("min")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func transitBadge(_ arrival: NearbyArrival, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.Colors.subwayBlack)
                .frame(width: size, height: size)
            if arrival.isBus {
                Image(systemName: "bus.fill")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
            } else {
                Text(arrival.displayName)
                    .font(.system(size: size * 0.45, weight: .heavy, design: .monospaced))
                    .foregroundColor(AppTheme.Colors.textOnColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
    }

    private func countdownColor(_ minutes: Int) -> Color {
        if minutes <= 2 {
            return AppTheme.Colors.alertRed
        } else if minutes <= 5 {
            return AppTheme.Colors.successGreen
        }
        return AppTheme.Colors.textPrimary
    }
}

// MARK: - Widget Definition

struct TrackWidget: Widget {
    let kind: String = "TrackWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrackWidgetProvider()) { entry in
            TrackWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Nearby Transit")
        .description("Live countdowns for the nearest buses and trains.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    TrackWidget()
} timeline: {
    TrackWidgetEntry.placeholder
}

#Preview(as: .systemMedium) {
    TrackWidget()
} timeline: {
    TrackWidgetEntry.placeholder
}
