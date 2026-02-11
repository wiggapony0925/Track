//
//  TrackWidget.swift
//  TrackWidgets
//
//  Lock Screen / Home Screen widget showing the next predicted train.
//  Uses the SmartSuggester pattern to display the most likely commute.
//

import SwiftUI
import SwiftData
import WidgetKit

// MARK: - Timeline Provider

struct TrackWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrackWidgetEntry {
        TrackWidgetEntry(
            date: Date(),
            lineId: "L",
            destination: "Manhattan",
            minutesAway: 5,
            status: "On Time",
            isBus: false
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TrackWidgetEntry) -> Void) {
        let entry = buildSmartEntry() ?? TrackWidgetEntry(
            date: Date(),
            lineId: "L",
            destination: "Manhattan",
            minutesAway: 5,
            status: "On Time",
            isBus: false
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrackWidgetEntry>) -> Void) {
        let currentDate = Date()

        let entry = buildSmartEntry() ?? TrackWidgetEntry(
            date: currentDate,
            lineId: "L",
            destination: "Manhattan",
            minutesAway: 5,
            status: "On Time",
            isBus: false
        )

        // Refresh every 5 minutes
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 5, to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(refreshDate))
        completion(timeline)
    }

    /// Queries SwiftData for the user's most likely route at this time of day.
    private func buildSmartEntry() -> TrackWidgetEntry? {
        let context = ModelContext(DataController.shared.container)

        if let suggestion = SmartSuggester.suggestedRoute(context: context) {
            return TrackWidgetEntry(
                date: Date(),
                lineId: suggestion.routeID,
                destination: suggestion.destinationName,
                minutesAway: 5,
                status: "On Time",
                isBus: false
            )
        }
        return nil
    }
}

// MARK: - Entry

struct TrackWidgetEntry: TimelineEntry {
    let date: Date
    let lineId: String
    let destination: String
    let minutesAway: Int
    let status: String
    let isBus: Bool
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

    // MARK: - Small Widget

    private var smallView: some View {
        VStack(spacing: 8) {
            // Line badge
            ZStack {
                Circle()
                    .fill(entry.isBus ? AppTheme.Colors.mtaBlue : AppTheme.Colors.subwayBlack)
                    .frame(width: 44, height: 44)
                if entry.isBus {
                    Image(systemName: "bus.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textOnColor)
                } else {
                    Text(entry.lineId)
                        .font(.system(size: 20, weight: .heavy, design: .monospaced))
                        .foregroundColor(AppTheme.Colors.textOnColor)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }

            // Big countdown
            Text("\(entry.minutesAway)")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Text("min")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            AppTheme.Colors.background
        }
    }

    // MARK: - Medium Widget

    private var mediumView: some View {
        HStack(spacing: AppTheme.Layout.margin) {
            // Line badge
            ZStack {
                Circle()
                    .fill(entry.isBus ? AppTheme.Colors.mtaBlue : AppTheme.Colors.subwayBlack)
                    .frame(width: 48, height: 48)
                if entry.isBus {
                    Image(systemName: "bus.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textOnColor)
                } else {
                    Text(entry.lineId)
                        .font(.system(size: 22, weight: .heavy, design: .monospaced))
                        .foregroundColor(AppTheme.Colors.textOnColor)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.destination)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(entry.status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(entry.status == "On Time" ? AppTheme.Colors.successGreen : AppTheme.Colors.warningYellow)
                    .lineLimit(1)
            }

            Spacer()

            // Countdown
            VStack(spacing: 2) {
                Text("\(entry.minutesAway)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text("min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(AppTheme.Layout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            AppTheme.Colors.background
        }
    }
}

// MARK: - Widget Definition

struct TrackWidget: Widget {
    let kind: String = "TrackWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrackWidgetProvider()) { entry in
            TrackWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Next Train")
        .description("Shows your predicted next commute at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    TrackWidget()
} timeline: {
    TrackWidgetEntry(
        date: Date(),
        lineId: "L",
        destination: "Manhattan",
        minutesAway: 4,
        status: "On Time",
        isBus: false
    )
}

#Preview(as: .systemMedium) {
    TrackWidget()
} timeline: {
    TrackWidgetEntry(
        date: Date(),
        lineId: "L",
        destination: "Manhattan",
        minutesAway: 4,
        status: "On Time",
        isBus: false
    )
}
