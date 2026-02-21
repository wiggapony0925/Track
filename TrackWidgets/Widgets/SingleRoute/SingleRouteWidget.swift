//
//  SingleRouteWidget.swift
//  Widgets
//
//  Widget for tracking a single user-selected route.
//  Shows the next 3 arrivals for the tracked route.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline Provider

struct SingleRouteProvider: TimelineProvider {
    func placeholder(in context: Context) -> SingleRouteEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (SingleRouteEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }

        guard let trackedRoute = TrackedRoute.load() else {
            completion(.empty())
            return
        }

        fetchTrackedRouteEntry(trackedRoute: trackedRoute) { entry in
            completion(entry ?? .noData(trackedRoute: trackedRoute))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SingleRouteEntry>) -> Void) {
        guard let trackedRoute = TrackedRoute.load() else {
            // No route tracked - show empty state, no refresh needed
            let entry = SingleRouteEntry.empty()
            let timeline = Timeline(entries: [entry], policy: .never)
            completion(timeline)
            return
        }

        fetchTrackedRouteEntry(trackedRoute: trackedRoute) { entry in
            var resolvedEntry = entry ?? .noData(trackedRoute: trackedRoute)

            // High relevance when tracking a route
            resolvedEntry.relevance = TimelineEntryRelevance(score: 80)

            // Refresh every 1 minute for live countdown
            let refreshDate = Calendar.current.date(byAdding: .minute, value: 1, to: Date())!
            let timeline = Timeline(entries: [resolvedEntry], policy: .after(refreshDate))
            completion(timeline)
        }
    }

    /// Fetch arrivals for the tracked route from the /nearby API
    private func fetchTrackedRouteEntry(trackedRoute: TrackedRoute, completion: @escaping (SingleRouteEntry?) -> Void) {
        // In challenge mode, return mock data without network
        if ChallengeMode.isEnabled {
            let arrivals = [
                NearbyArrival(routeId: trackedRoute.routeId, stopName: "Times Sq-42 St", direction: "Uptown", minutesAway: 2, status: "Approaching", mode: trackedRoute.mode, arrivalTime: Date().addingTimeInterval(120)),
                NearbyArrival(routeId: trackedRoute.routeId, stopName: "Times Sq-42 St", direction: "Uptown", minutesAway: 8, status: "En Route", mode: trackedRoute.mode, arrivalTime: Date().addingTimeInterval(480)),
                NearbyArrival(routeId: trackedRoute.routeId, stopName: "Times Sq-42 St", direction: "Downtown", minutesAway: 4, status: "En Route", mode: trackedRoute.mode, arrivalTime: Date().addingTimeInterval(240)),
            ]
            completion(SingleRouteEntry(
                date: Date(),
                state: .tracking(route: trackedRoute, arrivals: arrivals),
                relevance: TimelineEntryRelevance(score: 80)
            ))
            return
        }

        let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? UserDefaults.standard
        let lat = defaults.double(forKey: "lastLatitude")
        let lon = defaults.double(forKey: "lastLongitude")
        let hasLocation = defaults.bool(forKey: "hasLastLocation")

        guard hasLocation, (-90...90).contains(lat), (-180...180).contains(lon) else {
            completion(nil)
            return
        }

        let baseURL = WidgetURLHelper.resolvedBaseURL()

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

                // Filter for matching tracked route and take first 3
                let matchingArrivals = responses
                    .filter { $0.routeId == trackedRoute.routeId }
                    .map { item in
                        NearbyArrival(
                            routeId: item.routeId,
                            stopName: item.stopName,
                            direction: item.direction,
                            minutesAway: item.minutesAway,
                            status: item.status,
                            mode: item.mode,
                            // Prefer feed epoch timestamp; fall back to minutesAway offset
                            arrivalTime: item.resolvedArrivalTime
                        )
                    }
                    .prefix(3)

                if !matchingArrivals.isEmpty {
                    completion(SingleRouteEntry(
                        date: Date(),
                        state: .tracking(route: trackedRoute, arrivals: Array(matchingArrivals)),
                        relevance: TimelineEntryRelevance(score: 80)
                    ))
                } else {
                    completion(nil)
                }
            } catch {
                completion(nil)
            }
        }
        task.resume()
    }
}


// MARK: - Entry

struct SingleRouteEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
    var relevance: TimelineEntryRelevance?

    enum WidgetState {
        case tracking(route: TrackedRoute, arrivals: [NearbyArrival])
        case noData(route: TrackedRoute) // Tracked but no arrivals found
        case empty // No route tracked
    }

    static func empty() -> SingleRouteEntry {
        SingleRouteEntry(
            date: Date(),
            state: .empty,
            relevance: TimelineEntryRelevance(score: 0)
        )
    }

    static func noData(trackedRoute: TrackedRoute) -> SingleRouteEntry {
        SingleRouteEntry(
            date: Date(),
            state: .noData(route: trackedRoute),
            relevance: TimelineEntryRelevance(score: 50)
        )
    }

    static let placeholder = SingleRouteEntry(
        date: Date(),
        state: .tracking(
            route: TrackedRoute(
                routeId: "MTA NYCT_L",
                displayName: "L",
                stopName: "1st Avenue",
                direction: "Manhattan",
                destination: "8 Av",
                mode: "subway",
                trackedAt: Date()
            ),
            arrivals: [
                NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan", minutesAway: 2, status: "Arriving", mode: "subway", arrivalTime: Date().addingTimeInterval(120)),
                NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan", minutesAway: 8, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(480)),
                NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan", minutesAway: 15, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(900)),
            ]
        ),
        relevance: TimelineEntryRelevance(score: 80)
    )
}

// MARK: - Widget View

struct SingleRouteWidgetView: View {
    var entry: SingleRouteProvider.Entry
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
        default:
            smallView
        }
    }

    /// Dynamic background that adapts to system theme
    private var dynamicBackground: some View {
        WidgetBackground()
    }

    // MARK: - Small Widget
    // Content is in Shared/WidgetSmallViews.swift (TrackRouteSmallWidgetView) so the
    // main app can render it for live settings previews without duplicating code.

    private var smallView: some View {
        Group {
            switch entry.state {
            case .tracking(let route, let arrivals):
                TrackRouteSmallWidgetView(route: route, arrivals: arrivals, date: entry.date)

            case .noData(let route):
                noDataView(route: route)

            case .empty:
                emptyStateView
            }
        }
        .containerBackground(for: .widget) {
            dynamicBackground
        }
    }

    // MARK: - Medium Widget

    private var mediumView: some View {
        Group {
            switch entry.state {
            case .tracking(let route, let arrivals):
                if let firstArrival = arrivals.first {
                    // Convert widget state into Live Activity banner data
                    let progress = calculateProgress(arrival: firstArrival)
                    let nextArrivals = arrivals.dropFirst().prefix(2).map { $0.minutesAway }
                    
                    TrackLiveBannerView(
                        data: TrackLiveBannerData(
                            lineId: route.cleanDisplayName,
                            destination: "to " + (route.destination ?? route.direction),
                            isBus: route.isBus,
                            isLIRR: route.isLIRR,
                            arrivalTime: firstArrival.arrivalTime,
                            proximityText: stopsAwayText(for: firstArrival),
                            stopsAway: nil,
                            walkMinutes: nil,
                            isHurryUp: firstArrival.minutesAway <= 2,
                            progress: progress,
                            nextArrivals: Array(nextArrivals)
                        ),
                        showActionButton: false
                    )
                } else {
                    noDataView(route: route)
                }

            case .noData(let route):
                noDataView(route: route)

            case .empty:
                emptyStateView
            }
        }
        .containerBackground(for: .widget) {
            dynamicBackground
        }
    }

    private func calculateProgress(arrival: NearbyArrival) -> Double {
        let maxMins: Double = 20.0
        let currentMins = max(0.0, Double(arrival.minutesAway))
        let remainingRatio = currentMins / maxMins
        return max(0.0, min(1.0, 1.0 - remainingRatio))
    }
    
    private func stopsAwayText(for arrival: NearbyArrival) -> String {
        if arrival.minutesAway <= 0 {
            return "Arriving now"
        } else if arrival.minutesAway <= 2 {
            return "Arriving shortly"
        }
        return "Waiting for next vehicle..."
    }

    // MARK: - Large Widget

    private var largeView: some View {
        Group {
            switch entry.state {
            case .tracking(let route, let arrivals):
                VStack(alignment: .leading, spacing: 0) {
                    // Enhanced header
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.Colors.mtaBlue.opacity(0.15))
                                .frame(width: 44, height: 44)
                            Image(systemName: "star.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(AppTheme.Colors.mtaBlue)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Tracking Active")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                            Text("\(route.stopName)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 1) {
                            Text(entry.date, style: .time)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(AppTheme.Colors.successGreen)
                                    .frame(width: 5, height: 5)
                                Text("LIVE")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundColor(AppTheme.Colors.successGreen)
                            }
                        }
                    }
                    .padding(.bottom, 24)

                    // Hero Card
                    if let first = arrivals.first {
                        HStack(spacing: 16) {
                            transitBadge(route: route, size: 64)
                                .shadow(color: (route.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: route.cleanDisplayName)).opacity(0.4), radius: 10, x: 0, y: 5)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route.direction)
                                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                
                                Text(first.status)
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundColor(statusTextColor(first.status))
                            }
                            
                            Spacer()
                            
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(timerInterval: Date()...max(Date(), first.arrivalTime), countsDown: true)
                                    .font(.system(size: 42, weight: .bold, design: .rounded))
                                    .foregroundColor(AppTheme.Colors.countdown(first.minutesAway))
                                    .monospacedDigit()
                            }
                        }
                        .padding(16)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(20)
                        .padding(.bottom, 20)
                    }

                    // Secondary Arrivals
                    VStack(spacing: 12) {
                        ForEach(Array(arrivals.dropFirst().prefix(3).enumerated()), id: \.offset) { _, arrival in
                            HStack {
                                Text("Following Arrival")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                Spacer()
                                Text(timerInterval: Date()...max(Date(), arrival.arrivalTime), countsDown: true)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 8)
                            Divider()
                        }
                    }

                    Spacer()

                    HStack {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 10))
                        Text("This widget updates live using system countdowns")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            case .noData(let route):
                noDataView(route: route)

            case .empty:
                emptyStateView
            }
        }
        .containerBackground(for: .widget) {
            dynamicBackground
        }
    }

    // MARK: - Empty & No Data States

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tram.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text("No route tracked")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text("Tap 'Track' in the app\non any route")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noDataView(route: TrackedRoute) -> some View {
        VStack(spacing: 12) {
            transitBadge(route: route, size: 44)
                .opacity(0.5)
            Text("Route not nearby")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text("Move closer to \(route.stopName)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func transitBadge(route: TrackedRoute, size: CGFloat) -> some View {
        if route.isCommuterRail {
            // Commuter Rail: Rounded rect with train icon
            HStack(spacing: 2) {
                Image(systemName: "train.side.front.car")
                    .font(.system(size: size * 0.35, weight: .bold))
                    .foregroundColor(.white)
                Text(route.cleanDisplayName)
                    .font(.system(size: size * 0.3, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .frame(minWidth: size, minHeight: size)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(route.isLIRR ? AppTheme.CommuterRailColors.lirrBlue : AppTheme.CommuterRailColors.mnrBlue)
            )
        } else {
            ZStack {
                Circle()
                    .fill(route.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: route.cleanDisplayName))
                    .frame(width: size, height: size)

                if route.isBus {
                    Image(systemName: "bus.fill")
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text(route.cleanDisplayName)
                        .font(.system(size: size * 0.45, weight: .heavy, design: .rounded))
                        .foregroundColor(AppTheme.SubwayColors.textColor(for: route.cleanDisplayName))
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
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
}

// MARK: - Widget Definition

struct SingleRouteWidget: Widget {
    let kind: String = "SingleRouteWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SingleRouteProvider()) { entry in
            SingleRouteWidgetView(entry: entry)
        }
        .configurationDisplayName("Track Route")
        .description("Track a specific route with live countdown and next arrivals.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Previews

#Preview(as: .systemSmall) {
    SingleRouteWidget()
} timeline: {
    SingleRouteEntry.placeholder
    SingleRouteEntry.empty()
}

#Preview(as: .systemMedium) {
    SingleRouteWidget()
} timeline: {
    SingleRouteEntry.placeholder
}

#Preview(as: .systemLarge) {
    SingleRouteWidget()
} timeline: {
    SingleRouteEntry.placeholder
}
