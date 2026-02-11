//
//  TrackWidget.swift
//  TrackWidgets
//
//  Lock Screen / Home Screen widget showing the next predicted train.
//  Uses the SmartSuggester pattern to display the most likely commute.
//

import SwiftUI
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
        let entry = TrackWidgetEntry(
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
        let entry = TrackWidgetEntry(
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
                    .fill(entry.isBus ? Color.blue : Color.black)
                    .frame(width: 44, height: 44)
                if entry.isBus {
                    Image(systemName: "bus.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text(entry.lineId)
                        .font(.system(size: 20, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }

            // Big countdown
            Text("\(entry.minutesAway)")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            Text("min")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    // MARK: - Medium Widget

    private var mediumView: some View {
        HStack(spacing: 16) {
            // Line badge
            ZStack {
                Circle()
                    .fill(entry.isBus ? Color.blue : Color.black)
                    .frame(width: 48, height: 48)
                if entry.isBus {
                    Image(systemName: "bus.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text(entry.lineId)
                        .font(.system(size: 22, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.destination)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(entry.status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(entry.status == "On Time" ? .green : .orange)
                    .lineLimit(1)
            }

            Spacer()

            // Countdown
            VStack(spacing: 2) {
                Text("\(entry.minutesAway)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text("min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            Color(.systemBackground)
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
