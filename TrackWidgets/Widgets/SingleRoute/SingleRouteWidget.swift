// Widget for tracking a single user-selected route.
// Shows the next 3 arrivals for the tracked route.

import SwiftUI
@preconcurrency import WidgetKit

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

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SingleRouteEntry>) -> Void
    ) {
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
    private func fetchTrackedRouteEntry(
        trackedRoute: TrackedRoute,
        completion: @Sendable @escaping (SingleRouteEntry?) -> Void
    ) {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? UserDefaults.standard
        let lat = defaults.double(forKey: "lastLatitude")
        let lon = defaults.double(forKey: "lastLongitude")
        let hasLocation = defaults.bool(forKey: "hasLastLocation")

        guard hasLocation, (-90...90).contains(lat), (-180...180).contains(lon) else {
            completion(nil)
            return
        }

        let baseURL: String
        #if DEBUG
        let useLocalhost = defaults.bool(forKey: "dev_use_localhost")
        #if targetEnvironment(simulator)
        if useLocalhost {
            baseURL = "http://127.0.0.1:8000"
        } else {
            let storedIP = defaults.string(forKey: "dev_custom_ip") ?? "192.168.12.101"
            baseURL = "http://\(storedIP):8000"
        }
        #else
        if useLocalhost {
            let storedIP = defaults.string(forKey: "dev_custom_ip") ?? "192.168.12.101"
            baseURL = "http://\(storedIP):8000"
        } else {
            baseURL = "https://track-vkrr.onrender.com"
        }
        #endif
        #else
        // Release builds ALWAYS use the production backend
        baseURL = "https://track-vkrr.onrender.com"
        #endif

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
                NearbyArrival(
                    routeId: "L", stopName: "1st Avenue",
                    direction: "Manhattan", minutesAway: 2,
                    status: "Arriving", mode: "subway",
                    arrivalTime: Date().addingTimeInterval(120)
                ),
                NearbyArrival(
                    routeId: "L", stopName: "1st Avenue",
                    direction: "Manhattan", minutesAway: 8,
                    status: "On Time", mode: "subway",
                    arrivalTime: Date().addingTimeInterval(480)
                ),
                NearbyArrival(
                    routeId: "L", stopName: "1st Avenue",
                    direction: "Manhattan", minutesAway: 15,
                    status: "On Time", mode: "subway",
                    arrivalTime: Date().addingTimeInterval(900)
                ),
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
        Group {
            switch family {
            case .systemSmall:  smallView
            case .systemMedium: mediumView
            case .systemLarge:  largeView
            default:            smallView
            }
        }
        .containerBackground(for: .widget) { WK.Surface() }
    }

    // MARK: - Small Widget

    @ViewBuilder
    private var smallView: some View {
        switch entry.state {
        case .tracking(let route, let arrivals):
            TrackRouteSmallWidgetView(route: route, arrivals: arrivals,
                                      date: entry.date)
        case .noData(let route):
            noDataView(route: route)
        case .empty:
            emptyStateView
        }
    }

    // MARK: - Medium Widget

    @ViewBuilder
    private var mediumView: some View {
        switch entry.state {
        case .tracking(let route, let arrivals):
            TrackRouteListWidgetView(route: route, arrivals: arrivals,
                                     maxVisible: 3, date: entry.date)
        case .noData(let route):
            noDataView(route: route)
        case .empty:
            emptyStateView
        }
    }

    // MARK: - Large Widget

    @ViewBuilder
    private var largeView: some View {
        switch entry.state {
        case .tracking(let route, let arrivals):
            TrackRouteListWidgetView(route: route, arrivals: arrivals,
                                     maxVisible: 5, date: entry.date)
        case .noData(let route):
            noDataView(route: route)
        case .empty:
            emptyStateView
        }
    }

    // MARK: - Empty / No-Data

    private var emptyStateView: some View {
        WK.EmptyState(
            icon: "tram",
            title: "No route tracked",
            subtitle: "Long-press a route in the app to start tracking"
        )
    }

    private func noDataView(route: TrackedRoute) -> some View {
        VStack(spacing: 10) {
            WK.LineBadge(
                lineId: route.cleanDisplayName,
                isBus: route.isBus,
                isLIRR: route.isLIRR,
                isMNR: route.isMNR,
                size: 44
            )
            .opacity(0.5)
            Text("Route not nearby")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text("Move closer to \(route.stopName)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WK.Tokens.surfacePadding)
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
