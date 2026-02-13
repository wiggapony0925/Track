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

                // Load interaction stats for sorting
                let stats = defaults.dictionary(forKey: "route_interaction_stats") as? [String: Int] ?? [:]

                let arrivals = responses.map { item in
                    NearbyArrival(
                        routeId: item.routeId,
                        stopName: item.stopName,
                        direction: item.direction,
                        minutesAway: item.minutesAway,
                        status: item.status,
                        mode: item.mode
                    )
                }
                .sorted { a, b in
                    // Prioritize routes with more user interactions
                    let countA = stats[a.routeId] ?? 0
                    let countB = stats[b.routeId] ?? 0
                    
                    if countA != countB {
                        return countA > countB
                    }
                    // Fallback to soonest arrival
                    return a.minutesAway < b.minutesAway
                }
                .prefix(5)

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
            NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan", minutesAway: 2, status: "Arriving", mode: "subway"),
            NearbyArrival(routeId: "B63", stopName: "5 Av / Union St", direction: "Cobble Hill", minutesAway: 4, status: "On Time", mode: "bus"),
            NearbyArrival(routeId: "G", stopName: "Metropolitan Av", direction: "Church Av", minutesAway: 6, status: "On Time", mode: "subway"),
            NearbyArrival(routeId: "A", stopName: "Fulton St", direction: "Far Rockaway", minutesAway: 8, status: "On Time", mode: "subway"),
            NearbyArrival(routeId: "4", stopName: "Bowling Green", direction: "Woodlawn", minutesAway: 11, status: "On Time", mode: "subway"),
            NearbyArrival(routeId: "N", stopName: "Times Square", direction: "Astoria", minutesAway: 13, status: "On Time", mode: "subway"),
            NearbyArrival(routeId: "M15", stopName: "1 Av / E 14 St", direction: "South Ferry", minutesAway: 15, status: "Delayed", mode: "bus"),
            NearbyArrival(routeId: "7", stopName: "Grand Central", direction: "Flushing", minutesAway: 18, status: "On Time", mode: "subway"),
        ]
    )
}

// MARK: - Widget View

struct TrackWidgetEntryView: View {
    var entry: TrackWidgetProvider.Entry
    @Environment(\.widgetFamily) var family
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        case .systemMedium:
            mediumView
        case .systemLarge:
            largeView
        case .systemExtraLarge:
            extraLargeView
        default:
            smallView
        }
    }

    /// Dynamic background that adapts to system theme
    private var dynamicBackground: some View {
        ZStack {
            // Base background
            AppTheme.Colors.background

            // Subtle gradient overlay
            LinearGradient(
                gradient: Gradient(colors: [
                    AppTheme.Colors.mtaBlue.opacity(colorScheme == .dark ? 0.15 : 0.08),
                    Color.clear
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Small Widget

    private var smallView: some View {
        Group {
            if let arrival = entry.arrivals.first {
                VStack(spacing: 6) {
                    // Human icon header
                    HStack(spacing: 4) {
                        Image(systemName: "figure.walk")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                        Text("Next")
                            .font(.custom("Helvetica-Bold", size: 10))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Spacer()
                        Text(entry.date, style: .time)
                            .font(.custom("Helvetica", size: 9))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    Spacer(minLength: 0)

                    // Route badge with glow effect
                    ZStack {
                        Circle()
                            .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName))
                            .frame(width: 52, height: 52)
                            .shadow(color: (arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName)).opacity(0.4), radius: 8, x: 0, y: 4)

                        Text(arrival.displayName)
                            .font(.custom("Helvetica-Bold", size: 24))
                            .foregroundColor(arrival.isBus ? .white : AppTheme.SubwayColors.textColor(for: arrival.displayName))
                            .minimumScaleFactor(0.5)
                    }

                    // Big countdown
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(arrival.minutesAway)")
                            .font(.custom("Helvetica-Bold", size: 38))
                            .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                        Text("min")
                            .font(.custom("Helvetica", size: 14))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }

                    // Stop name
                    Text(arrival.stopName)
                        .font(.custom("Helvetica-Bold", size: 11))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    // Direction
                    Text("→ \(arrival.direction)")
                        .font(.custom("Helvetica", size: 10))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    Spacer(minLength: 0)

                    // Next 2 arrivals preview
                    if entry.arrivals.count > 1 {
                        VStack(spacing: 4) {
                            Divider()
                                .padding(.horizontal, 8)
                            HStack(spacing: 6) {
                                ForEach(Array(entry.arrivals.dropFirst().prefix(2).enumerated()), id: \.offset) { _, nextArrival in
                                    HStack(spacing: 3) {
                                        transitBadge(nextArrival, size: 16)
                                        Text("\(nextArrival.minutesAway)")
                                            .font(.custom("Helvetica-Bold", size: 11))
                                            .foregroundColor(AppTheme.Colors.countdown(nextArrival.minutesAway))
                                        Text("m")
                                            .font(.custom("Helvetica", size: 9))
                                            .foregroundColor(AppTheme.Colors.textSecondary)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                    Image(systemName: "tram.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Text("No arrivals")
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .containerBackground(for: .widget) {
            dynamicBackground
        }
    }

    // MARK: - Medium Widget

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Enhanced Header with human icon
            HStack(spacing: 6) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                Image(systemName: "tram.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                Text("Nearby Transit")
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(entry.date, style: .time)
                        .font(.custom("Helvetica-Bold", size: 11))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Updated")
                        .font(.custom("Helvetica", size: 8))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }
            .padding(.bottom, 10)

            if entry.arrivals.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "figure.walk")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                        Image(systemName: "tram.fill")
                            .font(.system(size: 22, weight: .light))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("No nearby arrivals")
                            .font(.custom("Helvetica-Bold", size: 13))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                // Show up to 4 arrivals with better visual hierarchy
                VStack(spacing: 0) {
                    ForEach(Array(entry.arrivals.prefix(4).enumerated()), id: \.offset) { index, arrival in
                        mediumArrivalRow(arrival, index: index)
                        if index < min(entry.arrivals.count, 4) - 1 {
                            Divider()
                                .padding(.leading, 38)
                                .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .containerBackground(for: .widget) {
            dynamicBackground
        }
    }

    /// Enhanced arrival row for medium widget
    private func mediumArrivalRow(_ arrival: NearbyArrival, index: Int) -> some View {
        HStack(spacing: 10) {
            // Badge with shadow
            ZStack {
                transitBadge(arrival, size: 30)
                    .shadow(color: (arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName)).opacity(0.3), radius: 4, x: 0, y: 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.displayName)
                    .font(.custom("Helvetica-Bold", size: index == 0 ? 15 : 14))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(arrival.stopName)
                        .font(.custom("Helvetica", size: 11))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                    Text("→")
                        .font(.custom("Helvetica", size: 10))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Text(arrival.direction)
                        .font(.custom("Helvetica", size: 10))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Countdown with status
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(arrival.minutesAway)")
                        .font(.custom("Helvetica-Bold", size: index == 0 ? 24 : 20))
                        .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    Text("min")
                        .font(.custom("Helvetica", size: 10))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                if !arrival.status.isEmpty {
                    Text(arrival.status)
                        .font(.custom("Helvetica-Bold", size: 8))
                        .foregroundColor(statusTextColor(arrival.status))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusTextColor(arrival.status).opacity(0.15))
                        .cornerRadius(4)
                }
            }
        }
    }

    // MARK: - Large Widget

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Enhanced Header with human icon
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.mtaBlue.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "figure.walk")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nearby Transit")
                        .font(.custom("Helvetica-Bold", size: 17))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Next arrivals near you")
                        .font(.custom("Helvetica", size: 11))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(entry.date, style: .time)
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Updated")
                        .font(.custom("Helvetica", size: 9))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }
            .padding(.bottom, 12)

            if entry.arrivals.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.Colors.mtaBlue.opacity(0.1))
                                .frame(width: 60, height: 60)
                            Image(systemName: "figure.walk")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(AppTheme.Colors.mtaBlue)
                        }
                        Image(systemName: "tram.fill")
                            .font(.system(size: 32, weight: .light))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("No nearby arrivals")
                            .font(.custom("Helvetica-Bold", size: 15))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("Open Track to refresh")
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                // Show up to 6 arrivals with enhanced styling
                VStack(spacing: 0) {
                    ForEach(Array(entry.arrivals.prefix(6).enumerated()), id: \.offset) { index, arrival in
                        largeArrivalRow(arrival, index: index)
                        if index < min(entry.arrivals.count, 6) - 1 {
                            Divider()
                                .padding(.leading, 44)
                                .padding(.vertical, 4)
                        }
                    }
                }

                Spacer(minLength: 10)

                // Enhanced Footer
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Text("Updated \(entry.date, style: .relative)")
                        .font(.custom("Helvetica", size: 11))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Spacer()
                    Text("\(entry.arrivals.count) arrivals")
                        .font(.custom("Helvetica-Bold", size: 10))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .containerBackground(for: .widget) {
            dynamicBackground
        }
    }

    /// A taller arrival row for the large widget with more detail.
    private func largeArrivalRow(_ arrival: NearbyArrival, index: Int = 0) -> some View {
        HStack(spacing: 12) {
            // Badge with prominent shadow
            ZStack {
                transitBadge(arrival, size: 36)
                    .shadow(color: (arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName)).opacity(0.4), radius: 6, x: 0, y: 3)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(arrival.displayName)
                    .font(.custom("Helvetica-Bold", size: index == 0 ? 16 : 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(arrival.stopName)
                    .font(.custom("Helvetica", size: 12))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                Text("→ \(arrival.direction)")
                    .font(.custom("Helvetica", size: 11))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(arrival.minutesAway)")
                        .font(.custom("Helvetica-Bold", size: index == 0 ? 26 : 22))
                        .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    Text("min")
                        .font(.custom("Helvetica", size: 11))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                if !arrival.status.isEmpty {
                    Text(arrival.status)
                        .font(.custom("Helvetica-Bold", size: 9))
                        .foregroundColor(statusTextColor(arrival.status))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusTextColor(arrival.status).opacity(0.15))
                        .cornerRadius(6)
                }
            }
        }
    }

    // MARK: - Extra Large Widget (iPad)

    private var extraLargeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Premium Header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.mtaBlue.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "figure.walk")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nearby Transit")
                        .font(.custom("Helvetica-Bold", size: 22))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Live arrivals near your location")
                        .font(.custom("Helvetica", size: 13))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.date, style: .time)
                        .font(.custom("Helvetica-Bold", size: 16))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Last updated")
                        .font(.custom("Helvetica", size: 11))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }
            .padding(.bottom, 16)

            if entry.arrivals.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.Colors.mtaBlue.opacity(0.1))
                                .frame(width: 80, height: 80)
                            Image(systemName: "figure.walk")
                                .font(.system(size: 32, weight: .medium))
                                .foregroundColor(AppTheme.Colors.mtaBlue)
                        }
                        Image(systemName: "tram.fill")
                            .font(.system(size: 48, weight: .light))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("No nearby arrivals")
                            .font(.custom("Helvetica-Bold", size: 18))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("Open Track to view transit")
                            .font(.custom("Helvetica", size: 14))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                // Show up to 8 arrivals in a grid
                VStack(spacing: 0) {
                    ForEach(Array(entry.arrivals.prefix(8).enumerated()), id: \.offset) { index, arrival in
                        extraLargeArrivalRow(arrival, index: index)
                        if index < min(entry.arrivals.count, 8) - 1 {
                            Divider()
                                .padding(.leading, 52)
                                .padding(.vertical, 5)
                        }
                    }
                }

                Spacer(minLength: 12)

                // Enhanced Footer
                HStack {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                    Text("Auto-refreshing every 5 minutes")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Spacer()
                    Text("\(entry.arrivals.count) total arrivals")
                        .font(.custom("Helvetica-Bold", size: 12))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(AppTheme.Colors.mtaBlue.opacity(0.1))
                        .cornerRadius(8)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .containerBackground(for: .widget) {
            dynamicBackground
        }
    }

    /// Premium arrival row for extra large widget
    private func extraLargeArrivalRow(_ arrival: NearbyArrival, index: Int) -> some View {
        HStack(spacing: 16) {
            // Large badge with glow
            ZStack {
                transitBadge(arrival, size: 44)
                    .shadow(color: (arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName)).opacity(0.5), radius: 8, x: 0, y: 4)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(arrival.displayName)
                        .font(.custom("Helvetica-Bold", size: index == 0 ? 18 : 17))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    if arrival.isBus {
                        Text("BUS")
                            .font(.custom("Helvetica-Bold", size: 9))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.Colors.mtaBlue.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                Text(arrival.stopName)
                    .font(.custom("Helvetica", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Text(arrival.direction)
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(arrival.minutesAway)")
                        .font(.custom("Helvetica-Bold", size: index == 0 ? 32 : 28))
                        .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    Text("min")
                        .font(.custom("Helvetica", size: 13))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                if !arrival.status.isEmpty {
                    Text(arrival.status)
                        .font(.custom("Helvetica-Bold", size: 10))
                        .foregroundColor(statusTextColor(arrival.status))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(statusTextColor(arrival.status).opacity(0.15))
                        .cornerRadius(8)
                }
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
                    .font(.custom("Helvetica-Bold", size: 14))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(arrival.stopName)
                        .font(.custom("Helvetica", size: 11))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                    Text("→ \(arrival.direction)")
                        .font(.custom("Helvetica", size: 10))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Status pill + Countdown
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(arrival.minutesAway)")
                        .font(.custom("Helvetica-Bold", size: 20))
                        .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    Text("min")
                        .font(.custom("Helvetica", size: 10))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                Text(arrival.status)
                    .font(.custom("Helvetica-Bold", size: 9))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// Unified transit badge — shows route name in a colored circle
    /// for both bus and train routes.
    @ViewBuilder
    private func transitBadge(_ arrival: NearbyArrival, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName))
                .frame(width: size, height: size)
            Text(arrival.displayName)
                .font(.custom("Helvetica-Bold", size: size * 0.45))
                .foregroundColor(arrival.isBus ? .white : AppTheme.SubwayColors.textColor(for: arrival.displayName))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
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
        .description("Live countdowns for the nearest buses and trains with beautiful design.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled() // Allows full-bleed backgrounds
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

#Preview(as: .systemExtraLarge) {
    TrackWidget()
} timeline: {
    TrackWidgetEntry.placeholder
}
