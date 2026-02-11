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
import CoreLocation

// MARK: - Timeline Provider

struct TrackWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrackWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (TrackWidgetEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        fetchLiveEntry { entry in
            completion(entry ?? .placeholder)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrackWidgetEntry>) -> Void) {
        fetchLiveEntry { entry in
            let resolvedEntry = entry ?? buildSmartEntry() ?? .placeholder

            // Refresh every 5 minutes
            let refreshDate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
            let timeline = Timeline(entries: [resolvedEntry], policy: .after(refreshDate))
            completion(timeline)
        }
    }

    /// Fetches live nearby transit data from the backend API.
    /// Uses the user's last known location from shared UserDefaults.
    private func fetchLiveEntry(completion: @escaping (TrackWidgetEntry?) -> Void) {
        // Read cached location from App Group UserDefaults
        let defaults = UserDefaults(suiteName: "group.com.track.shared") ?? UserDefaults.standard
        let lat = defaults.double(forKey: "lastLatitude")
        let lon = defaults.double(forKey: "lastLongitude")
        let hasLocation = defaults.bool(forKey: "hasLastLocation")

        // If no location cached, fall back
        guard hasLocation, (-90...90).contains(lat), (-180...180).contains(lon) else {
            completion(nil)
            return
        }

        let useLocalhost = defaults.bool(forKey: "dev_use_localhost")
        let baseURL: String
        if useLocalhost {
            baseURL = "http://127.0.0.1:8000"
        } else {
            let storedIP = defaults.string(forKey: "dev_custom_ip") ?? "192.168.12.101"
            baseURL = "http://\(storedIP):8000"
        }

        guard var components = URLComponents(string: baseURL + "/nearby") else {
            completion(nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
        ]
        guard let url = components.url else {
            completion(nil)
            return
        }

        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  error == nil else {
                completion(nil)
                return
            }

            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let responses = try decoder.decode([WidgetNearbyResponse].self, from: data)
                let arrivals = responses.prefix(5).map { item in
                    NearbyArrival(
                        routeId: item.routeId,
                        stopName: item.stopName,
                        direction: item.direction,
                        minutesAway: item.minutesAway,
                        status: item.status,
                        mode: item.mode
                    )
                }
                completion(TrackWidgetEntry(date: Date(), arrivals: Array(arrivals)))
            } catch {
                completion(nil)
            }
        }
        task.resume()
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
                        status: "Predicted",
                        mode: "subway"
                    )
                ]
            )
        }
        return nil
    }
}

/// Lightweight Codable model for decoding the /nearby API response in the widget.
private struct WidgetNearbyResponse: Codable {
    let routeId: String
    let stopName: String
    let direction: String
    let minutesAway: Int
    let status: String
    let mode: String

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case stopName = "stop_name"
        case direction
        case minutesAway = "minutes_away"
        case status
        case mode
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
            NearbyArrival(routeId: "B63", stopName: "5 Av / Union St", direction: "Cobble Hill", minutesAway: 5, status: "Approaching", mode: "bus"),
            NearbyArrival(routeId: "G", stopName: "Metropolitan Av", direction: "Church Av", minutesAway: 8, status: "On Time", mode: "subway"),
            NearbyArrival(routeId: "A", stopName: "Fulton St", direction: "Far Rockaway", minutesAway: 11, status: "On Time", mode: "subway"),
            NearbyArrival(routeId: "4", stopName: "Bowling Green", direction: "Woodlawn", minutesAway: 14, status: "On Time", mode: "subway"),
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
        case .systemLarge:
            largeView
        default:
            smallView
        }
    }

    // MARK: - Small Widget

    private var smallView: some View {
        Group {
            if let arrival = entry.arrivals.first {
                VStack(spacing: 3) {
                    // Mode badge
                    transitBadge(arrival, size: AppTheme.Layout.badgeSizeLarge)

                    // Big countdown
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(arrival.minutesAway)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                        Text("min")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }

                    // Stop name
                    Text(arrival.stopName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    // Direction
                    Text("→ \(arrival.direction)")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    // Next arrival preview if available
                    if entry.arrivals.count > 1 {
                        Divider()
                            .padding(.horizontal, 8)
                        let nextArrival = entry.arrivals[1]
                        HStack(spacing: 4) {
                            transitBadge(nextArrival, size: 16)
                            Text("\(nextArrival.minutesAway) min")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundColor(AppTheme.Colors.countdown(nextArrival.minutesAway))
                        }
                    }
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

    // MARK: - Medium Widget

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "tram.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                Text("Nearby Transit")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
                Text(entry.date, style: .time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .padding(.bottom, 8)

            if entry.arrivals.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "tram.fill")
                            .font(.system(size: 20, weight: .light))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("No nearby arrivals")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                // Show up to 3 arrivals
                ForEach(Array(entry.arrivals.prefix(3).enumerated()), id: \.offset) { index, arrival in
                    arrivalRow(arrival)
                    if index < min(entry.arrivals.count, 3) - 1 {
                        Divider()
                            .padding(.leading, 36)
                            .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(AppTheme.Layout.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .containerBackground(for: .widget) {
            AppTheme.Colors.background
        }
    }

    // MARK: - Large Widget

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "tram.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                Text("Nearby Transit")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
                Text(entry.date, style: .time)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .padding(.bottom, 10)

            if entry.arrivals.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "tram.fill")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("No nearby arrivals")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("Open Track to refresh")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                // Show up to 5 arrivals
                ForEach(Array(entry.arrivals.prefix(5).enumerated()), id: \.offset) { index, arrival in
                    largeArrivalRow(arrival)
                    if index < min(entry.arrivals.count, 5) - 1 {
                        Divider()
                            .padding(.leading, 40)
                            .padding(.vertical, 3)
                    }
                }

                Spacer(minLength: 8)

                // Footer
                HStack {
                    Spacer()
                    Text("Updated \(entry.date, style: .relative)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(AppTheme.Layout.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .containerBackground(for: .widget) {
            AppTheme.Colors.background
        }
    }

    /// A taller arrival row for the large widget with more detail.
    private func largeArrivalRow(_ arrival: NearbyArrival) -> some View {
        HStack(spacing: 10) {
            transitBadge(arrival, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(arrival.stopName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                Text("→ \(arrival.direction)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(arrival.minutesAway)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    Text("min")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                Text(arrival.status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(statusTextColor(arrival.status))
                    .lineLimit(1)
            }
        }
    }

    private func statusTextColor(_ status: String) -> Color {
        let lower = status.lowercased()
        if lower.contains("on time") {
            return AppTheme.Colors.successGreen
        } else if lower.contains("delayed") || lower.contains("late") {
            return AppTheme.Colors.alertRed
        }
        return AppTheme.Colors.textSecondary
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
                HStack(spacing: 4) {
                    Text(arrival.stopName)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                    Text("→ \(arrival.direction)")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Status pill + Countdown
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(arrival.minutesAway)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    Text("min")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                Text(arrival.status)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func transitBadge(_ arrival: NearbyArrival, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName))
                .frame(width: size, height: size)
            if arrival.isBus {
                Image(systemName: "bus.fill")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
            } else {
                Text(arrival.displayName)
                    .font(.system(size: size * 0.45, weight: .heavy, design: .monospaced))
                    .foregroundColor(AppTheme.SubwayColors.textColor(for: arrival.displayName))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        let lower = status.lowercased()
        if lower.contains("on time") {
            return AppTheme.Colors.successGreen
        } else if lower.contains("delayed") || lower.contains("late") {
            return AppTheme.Colors.alertRed
        }
        return AppTheme.Colors.mtaBlue
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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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

#Preview(as: .systemLarge) {
    TrackWidget()
} timeline: {
    TrackWidgetEntry.placeholder
}
