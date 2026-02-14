//
//  LiveNearMeWidget.swift
//  Widgets
//
//  Scheduled widget that shows nearby transit at user-configured times.
//  Activates for a specific duration (default 15 min) when scheduled.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline Provider

struct LiveNearMeProvider: TimelineProvider {
    func placeholder(in context: Context) -> LiveNearMeEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (LiveNearMeEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }

        let schedules = WidgetSchedule.loadAll()
        if schedules.hasActiveSchedule() {
            fetchLiveEntry(maxRoutes: 6) { entry in
                completion(entry ?? .inactive(schedules: schedules))
            }
        } else {
            completion(.inactive(schedules: schedules))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LiveNearMeEntry>) -> Void) {
        let schedules = WidgetSchedule.loadAll()
        let now = Date()

        if schedules.hasActiveSchedule(at: now) {
            // ACTIVE MODE: Fetch live nearby transit
            fetchLiveEntry(maxRoutes: 6) { entry in
                var resolvedEntry = entry ?? .inactive(schedules: schedules)

                // Calculate when this active period ends
                if let activeUntil = schedules.activeUntil(from: now) {
                    // Set high relevance during active period
                    resolvedEntry.relevance = TimelineEntryRelevance(
                        score: 100,
                        duration: activeUntil.timeIntervalSince(now)
                    )

                    // Refresh every 2 minutes, but not past the end of active period
                    let refreshDate = Calendar.current.date(byAdding: .minute, value: 2, to: now)!
                    let nextRefresh = min(refreshDate, activeUntil)

                    let timeline = Timeline(entries: [resolvedEntry], policy: .after(nextRefresh))
                    completion(timeline)
                } else {
                    // Fallback
                    resolvedEntry.relevance = TimelineEntryRelevance(score: 100)
                    let refreshDate = Calendar.current.date(byAdding: .minute, value: 2, to: now)!
                    let timeline = Timeline(entries: [resolvedEntry], policy: .after(refreshDate))
                    completion(timeline)
                }
            }
        } else {
            // INACTIVE MODE: Show next activation time
            let inactiveEntry = LiveNearMeEntry.inactive(schedules: schedules)

            // Calculate next activation
            if let nextActivation = schedules.nextActivation(after: now) {
                // Refresh 1 minute before next activation to prepare
                let wakeTime = Calendar.current.date(byAdding: .minute, value: -1, to: nextActivation) ?? nextActivation
                let timeline = Timeline(entries: [inactiveEntry], policy: .after(wakeTime))
                completion(timeline)
            } else {
                // No upcoming schedules - check again tomorrow
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
                let timeline = Timeline(entries: [inactiveEntry], policy: .after(tomorrow))
                completion(timeline)
            }
        }
    }

    /// Fetches live nearby transit data from the backend API.
    private func fetchLiveEntry(maxRoutes: Int, completion: @escaping (LiveNearMeEntry?) -> Void) {
        let defaults = UserDefaults(suiteName: "group.com.track.shared") ?? UserDefaults.standard
        let lat = defaults.double(forKey: "lastLatitude")
        let lon = defaults.double(forKey: "lastLongitude")
        let hasLocation = defaults.bool(forKey: "hasLastLocation")

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
                        mode: item.mode,
                        arrivalTime: Date().addingTimeInterval(Double(item.minutesAway) * 60)
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
                .prefix(maxRoutes)

                completion(LiveNearMeEntry(date: Date(), state: .active(arrivals: Array(arrivals))))
            } catch {
                completion(nil)
            }
        }
        task.resume()
    }
}


// MARK: - Entry

struct LiveNearMeEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
    var relevance: TimelineEntryRelevance?

    enum WidgetState {
        case active(arrivals: [NearbyArrival])
        case inactive(nextActivation: Date?, schedules: [WidgetSchedule])
    }

    static func inactive(schedules: [WidgetSchedule]) -> LiveNearMeEntry {
        let next = schedules.nextActivation()
        return LiveNearMeEntry(
            date: Date(),
            state: .inactive(nextActivation: next, schedules: schedules),
            relevance: TimelineEntryRelevance(score: 0)
        )
    }

    static let placeholder = LiveNearMeEntry(
        date: Date(),
        state: .active(arrivals: [
            NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan", minutesAway: 2, status: "Arriving", mode: "subway", arrivalTime: Date().addingTimeInterval(120)),
            NearbyArrival(routeId: "B63", stopName: "5 Av / Union St", direction: "Cobble Hill", minutesAway: 4, status: "On Time", mode: "bus", arrivalTime: Date().addingTimeInterval(240)),
            NearbyArrival(routeId: "G", stopName: "Metropolitan Av", direction: "Church Av", minutesAway: 6, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(360)),
            NearbyArrival(routeId: "A", stopName: "Fulton St", direction: "Far Rockaway", minutesAway: 8, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(480)),
            NearbyArrival(routeId: "4", stopName: "Bowling Green", direction: "Woodlawn", minutesAway: 11, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(660)),
            NearbyArrival(routeId: "N", stopName: "Times Square", direction: "Astoria", minutesAway: 13, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(780)),
        ]),
        relevance: TimelineEntryRelevance(score: 100)
    )
}

// MARK: - Widget View

struct LiveNearMeWidgetView: View {
    var entry: LiveNearMeProvider.Entry
    @Environment(\.widgetFamily) var family
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        switch family {
        case .systemMedium:
            mediumView
        case .systemLarge:
            largeView
        default:
            mediumView
        }
    }

    // MARK: - Medium Widget

    private var mediumView: some View {
        Group {
            switch entry.state {
            case .active(let arrivals):
                activeView(arrivals: arrivals, isLarge: false)
            case .inactive(let nextActivation, let schedules):
                inactiveStateView(nextActivation: nextActivation, schedules: schedules)
            }
        }
        .containerBackground(for: .widget) {
            WidgetBackground()
        }
    }

    // MARK: - Large Widget

    private var largeView: some View {
        Group {
            switch entry.state {
            case .active(let arrivals):
                activeView(arrivals: arrivals, isLarge: true)
            case .inactive(let nextActivation, let schedules):
                inactiveStateView(nextActivation: nextActivation, schedules: schedules)
            }
        }
        .containerBackground(for: .widget) {
            WidgetBackground()
        }
    }

    // MARK: - Active State

    private func activeView(arrivals: [NearbyArrival], isLarge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with pulsing indicator
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.successGreen.opacity(0.15))
                        .frame(width: isLarge ? 32 : 28, height: isLarge ? 32 : 28)
                    Circle()
                        .fill(AppTheme.Colors.successGreen)
                        .frame(width: isLarge ? 8 : 6, height: isLarge ? 8 : 6)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text("Live Near Me")
                        .font(.system(size: isLarge ? 16 : 14, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Showing nearby transit")
                        .font(.system(size: isLarge ? 10 : 9, weight: .medium, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 0) {
                    Text(entry.date, style: .time)
                        .font(.system(size: isLarge ? 12 : 11, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    if let activeUntil = calculateActiveUntil() {
                        Text("Until \(activeUntil, style: .time)")
                            .font(.system(size: isLarge ? 9 : 8, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.successGreen)
                    }
                }
            }
            .padding(.bottom, isLarge ? 12 : 10)

            if arrivals.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tram.fill")
                            .font(.system(size: 32, weight: .light))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("No nearby arrivals")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                // Route cards
                if isLarge {
                    VStack(spacing: 8) {
                        ForEach(Array(arrivals.prefix(5).enumerated()), id: \.offset) { index, arrival in
                            largeArrivalRow(arrival, index: index)
                        }
                    }
                } else {
                    let columns = [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ]

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(arrivals.prefix(4).enumerated()), id: \.offset) { index, arrival in
                            mediumArrivalCard(arrival)
                        }
                    }
                }
            }
        }
        .padding(isLarge ? 16 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Inactive State

    private func inactiveStateView(nextActivation: Date?, schedules: [WidgetSchedule]) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.mtaBlue.opacity(0.1))
                    .frame(width: 60, height: 60)
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }

            Text("Widget Inactive")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary)

            if let next = nextActivation {
                VStack(spacing: 4) {
                    Text("Next activation:")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                    Text(next, style: .relative)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                }
            } else if schedules.isEmpty {
                VStack(spacing: 4) {
                    Text("No schedules configured")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                    Text("Configure in Settings")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Arrival Views

    private func mediumArrivalCard(_ arrival: NearbyArrival) -> some View {
        VStack(spacing: 4) {
            transitBadge(arrival, size: 28)
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(arrival.arrivalTime, style: .timer)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    .monospacedDigit()
            }

            Text(arrival.stopName)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }

    private func largeArrivalRow(_ arrival: NearbyArrival, index: Int) -> some View {
        HStack(spacing: 12) {
            transitBadge(arrival, size: 34)
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(arrival.displayName)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text(arrival.stopName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 0) {
                Text(arrival.arrivalTime, style: .timer)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    .monospacedDigit()
                
                if !arrival.status.isEmpty {
                    Text(arrival.status)
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundColor(statusTextColor(arrival.status))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(statusTextColor(arrival.status).opacity(0.1))
                        .cornerRadius(4)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(index < 3 ? Color.white.opacity(0.05) : Color.clear)
        .cornerRadius(10)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func transitBadge(_ arrival: NearbyArrival, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName))
                .frame(width: size, height: size)

            if arrival.isBus {
                Image(systemName: "bus.fill")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text(arrival.displayName)
                    .font(.system(size: size * 0.45, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.SubwayColors.textColor(for: arrival.displayName))
                    .minimumScaleFactor(0.4)
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

    private func calculateActiveUntil() -> Date? {
        let schedules = WidgetSchedule.loadAll()
        return schedules.activeUntil(from: entry.date)
    }
}

// MARK: - Widget Definition

struct LiveNearMeWidget: Widget {
    let kind: String = "LiveNearMeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LiveNearMeProvider()) { entry in
            LiveNearMeWidgetView(entry: entry)
        }
        .configurationDisplayName("Live Near Me")
        .description("Shows nearby transit on your schedule. Configure in Settings.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Previews

#Preview("Active", as: .systemMedium) {
    LiveNearMeWidget()
} timeline: {
    LiveNearMeEntry.placeholder
}

#Preview("Inactive", as: .systemMedium) {
    LiveNearMeWidget()
} timeline: {
    LiveNearMeEntry.inactive(schedules: [])
}
