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
        let schedules = WidgetSchedule.loadAll()
        let isActive = schedules.isEmpty || schedules.hasActiveSchedule()

        print("[TrackWidget] getTimeline called at \(Date())")
        print("[TrackWidget] Loaded \(schedules.count) schedules. isActive: \(isActive)")

        if !isActive {
            let nextActivation = schedules.nextActivation() ?? Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
            
            // To ensure WidgetKit doesn't go to sleep forever if the next activation is days away,
            // we enforce a maximum sleep time of 15 minutes before checking the schedule again.
            let maxSleep = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
            let refreshDate = min(nextActivation, maxSleep)
            
            print("[TrackWidget] Paused. Next activation estimated: \(nextActivation), actually refreshing at: \(refreshDate)")

            let entry = TrackWidgetEntry(date: Date(), arrivals: [], isActive: false)
            completion(Timeline(entries: [entry], policy: .after(refreshDate)))
            return
        }

        print("[TrackWidget] Active! Fetching live entry...")
        fetchLiveEntry { entry in
            var resolvedEntry = entry ?? buildSmartEntry() ?? .placeholder
            resolvedEntry = TrackWidgetEntry(date: resolvedEntry.date, arrivals: resolvedEntry.arrivals, isActive: true)

            // Refresh every 5 minutes while active
            let refreshDate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
            let timeline = Timeline(entries: [resolvedEntry], policy: .after(refreshDate))
            completion(timeline)
        }
    }

    /// Fetches live nearby transit data from the backend API.
    /// Uses the user's last known location from shared UserDefaults.
    private func fetchLiveEntry(completion: @escaping (TrackWidgetEntry?) -> Void) {
        // In challenge mode, return mock data without network
        if ChallengeMode.isEnabled {
            let arrivals = [
                NearbyArrival(routeId: "1", stopName: "Times Sq-42 St", direction: "Uptown", minutesAway: 2, status: "Approaching", mode: "subway", arrivalTime: Date().addingTimeInterval(120)),
                NearbyArrival(routeId: "7", stopName: "Times Sq-42 St", direction: "Queens", minutesAway: 3, status: "Approaching", mode: "subway", arrivalTime: Date().addingTimeInterval(180)),
                NearbyArrival(routeId: "N", stopName: "Times Sq-42 St", direction: "Uptown", minutesAway: 5, status: "En Route", mode: "subway", arrivalTime: Date().addingTimeInterval(300)),
                NearbyArrival(routeId: "A", stopName: "42 St-Port Authority", direction: "Uptown", minutesAway: 4, status: "En Route", mode: "subway", arrivalTime: Date().addingTimeInterval(240)),
                NearbyArrival(routeId: "M42", stopName: "W 42 ST/7 AV", direction: "East", minutesAway: 6, status: "Approaching", mode: "bus", arrivalTime: Date().addingTimeInterval(360)),
            ]
            completion(TrackWidgetEntry(date: Date(), arrivals: arrivals, isActive: true))
            return
        }

        // Read cached location from App Group UserDefaults
        let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? UserDefaults.standard
        let lat = defaults.double(forKey: "lastLatitude")
        let lon = defaults.double(forKey: "lastLongitude")
        let hasLocation = defaults.bool(forKey: "hasLastLocation")

        // If no location cached, fall back
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

        let task = URLSession.shared.dataTask(with: url) { (data: Data?, response: URLResponse?, error: Error?) in
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
                        // Prefer feed epoch timestamp; fall back to minutesAway offset
                        arrivalTime: item.resolvedArrivalTime
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

                completion(TrackWidgetEntry(date: Date(), arrivals: Array(arrivals), isActive: true))
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
                        mode: "subway",
                        arrivalTime: Date().addingTimeInterval(300)
                    )
                ],
                isActive: true
            )
        }
        return nil
    }
}


struct TrackWidgetEntry: TimelineEntry {
    let date: Date
    let arrivals: [NearbyArrival]
    let isActive: Bool

    static let placeholder = TrackWidgetEntry(
        date: Date(),
        arrivals: [
            NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan", minutesAway: 3, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(180)),
            NearbyArrival(routeId: "B63", stopName: "5 Av / Union St", direction: "Cobble Hill", minutesAway: 5, status: "Approaching", mode: "bus", arrivalTime: Date().addingTimeInterval(300)),
            NearbyArrival(routeId: "G", stopName: "Metropolitan Av", direction: "Church Av", minutesAway: 8, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(480)),
            NearbyArrival(routeId: "A", stopName: "Fulton St", direction: "Far Rockaway", minutesAway: 11, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(660)),
            NearbyArrival(routeId: "4", stopName: "Bowling Green", direction: "Woodlawn", minutesAway: 14, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(840)),
        ],
        isActive: true
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
        case .accessoryRectangular:
            accessoryRectangularView
        case .accessoryInline:
            accessoryInlineView
        default:
            smallView
        }
    }

    // MARK: - Accessory Widgets

    private var accessoryRectangularView: some View {
        Group {
            if !entry.isActive {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transit Paused")
                        .font(.system(size: 14, weight: .bold))
                    Text("Outside scheduled hours")
                        .font(.system(size: 12))
                }
            } else if let arrival = entry.arrivals.first {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: arrival.isBus ? "bus.fill" : "tram.fill")
                        Text(arrival.displayName)
                            .font(.system(size: 14, weight: .bold))
                        Spacer()
                        Text(arrival.arrivalTime, style: .timer)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    Text(arrival.stopName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            } else {
                Text("No arrivals nearby")
                    .font(.system(size: 14, weight: .medium))
            }
        }
    }

    private var accessoryInlineView: some View {
        Group {
            if !entry.isActive {
                Text("Transit Paused")
            } else if let arrival = entry.arrivals.first {
                Text("\(arrival.displayName) in \(arrival.minutesAway)m")
            } else {
                Text("No Nearby Transit")
            }
        }
    }

    // MARK: - Small Widget
    // Content is in Shared/WidgetSmallViews.swift (NearbySmallWidgetView) so the
    // main app can render it for live settings previews without duplicating code.

    private var smallView: some View {
        NearbySmallWidgetView(arrivals: entry.arrivals, date: entry.date, isActive: entry.isActive)
            .containerBackground(for: .widget) {
                WidgetBackground()
            }
    }

    // MARK: - Medium Widget

    private var mediumView: some View {
        NearbyListWidgetView(arrivals: entry.arrivals, maxVisible: 3, date: entry.date, isActive: entry.isActive)
            .containerBackground(for: .widget) {
                WidgetBackground()
            }
    }

    // MARK: - Large Widget

    private var largeView: some View {
        NearbyListWidgetView(arrivals: entry.arrivals, maxVisible: 6, date: entry.date, isActive: entry.isActive)
            .containerBackground(for: .widget) {
                WidgetBackground()
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
        .configurationDisplayName("Nearby Transit")
        .description("Live countdowns for the nearest buses and trains.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
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
