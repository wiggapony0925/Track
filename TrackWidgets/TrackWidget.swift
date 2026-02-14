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
                        mode: "subway",
                        arrivalTime: Date().addingTimeInterval(300)
                    )
                ]
            )
        }
        return nil
    }
}


struct TrackWidgetEntry: TimelineEntry {
    let date: Date
    let arrivals: [NearbyArrival]

    static let placeholder = TrackWidgetEntry(
        date: Date(),
        arrivals: [
            NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan", minutesAway: 3, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(180)),
            NearbyArrival(routeId: "B63", stopName: "5 Av / Union St", direction: "Cobble Hill", minutesAway: 5, status: "Approaching", mode: "bus", arrivalTime: Date().addingTimeInterval(300)),
            NearbyArrival(routeId: "G", stopName: "Metropolitan Av", direction: "Church Av", minutesAway: 8, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(480)),
            NearbyArrival(routeId: "A", stopName: "Fulton St", direction: "Far Rockaway", minutesAway: 11, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(660)),
            NearbyArrival(routeId: "4", stopName: "Bowling Green", direction: "Woodlawn", minutesAway: 14, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(840)),
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
                VStack(spacing: 6) {
                    // Top Bar: Live indicator
                    HStack {
                        Capsule()
                            .fill(AppTheme.Colors.alertRed)
                            .frame(width: 4, height: 4)
                        Text("LIVE")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(AppTheme.Colors.alertRed)
                        Spacer()
                        Text(entry.date, style: .time)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    Spacer(minLength: 0)

                    // Hero Badge
                    ZStack {
                        Circle()
                            .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName))
                            .frame(width: 50, height: 50)
                            .shadow(color: (arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName)).opacity(0.3), radius: 6, x: 0, y: 3)
                        
                        if arrival.isBus {
                            Image(systemName: "bus.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Text(arrival.displayName)
                                .font(.system(size: 24, weight: .heavy, design: .rounded))
                                .foregroundColor(AppTheme.SubwayColors.textColor(for: arrival.displayName))
                        }
                    }

                    // Live Timer
                    Text(arrival.arrivalTime, style: .timer)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)

                    VStack(spacing: 1) {
                        Text(arrival.stopName)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Text("→ \(arrival.direction)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)

                    Spacer(minLength: 0)

                    // Divider and next arrival preview
                    if entry.arrivals.count > 1 {
                        let next = entry.arrivals[1]
                        HStack(spacing: 4) {
                            Text("NEXT")
                                .font(.system(size: 7, weight: .black))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                            Text(next.displayName)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(next.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: next.displayName))
                            Text(next.arrivalTime, style: .timer)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                        .padding(.bottom, 8)
                    }
                }
            } else {
                emptyState
            }
        }
        .containerBackground(for: .widget) {
            WidgetBackground()
        }
    }

    // MARK: - Medium Widget

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Premium Header
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.mtaBlue.opacity(0.15))
                        .frame(width: 24, height: 24)
                    Image(systemName: "tram.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                }
                
                Text("Nearby Transit")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                
                Spacer()
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(AppTheme.Colors.successGreen)
                        .frame(width: 4, height: 4)
                    Text("LIVE")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(AppTheme.Colors.successGreen)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(AppTheme.Colors.successGreen.opacity(0.1))
                .clipShape(Capsule())
            }

            if entry.arrivals.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("No arrivals found nearby")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Spacer()
                }
                Spacer()
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(entry.arrivals.prefix(3).enumerated()), id: \.offset) { index, arrival in
                        HStack(spacing: 12) {
                            // Badge with ring
                            ZStack {
                                Circle()
                                    .strokeBorder(arrival.isBus ? AppTheme.Colors.mtaBlue.opacity(0.2) : AppTheme.SubwayColors.color(for: arrival.displayName).opacity(0.2), lineWidth: 1)
                                    .frame(width: 34, height: 34)
                                
                                Circle()
                                    .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName))
                                    .frame(width: 28, height: 28)
                                
                                if arrival.isBus {
                                    Image(systemName: "bus.fill")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                } else {
                                    Text(arrival.displayName)
                                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                                        .foregroundColor(AppTheme.SubwayColors.textColor(for: arrival.displayName))
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 1) {
                                Text(arrival.stopName)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                Text("→ \(arrival.direction)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(arrival.arrivalTime, style: .timer)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                                    .monospacedDigit()
                                if !arrival.status.isEmpty && arrival.status != "On Time" {
                                    Text(arrival.status)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(AppTheme.Colors.alertRed)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .containerBackground(for: .widget) {
            WidgetBackground()
        }
    }

    // MARK: - Large Widget

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 14) {
             // Header
            HStack(spacing: 10) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                
                VStack(alignment: .leading, spacing: 0) {
                    Text("Nearby Predictions")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Auto-refreshing live arrivals")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                
                Spacer()
                
                Text(entry.date, style: .time)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .padding(.bottom, 4)

            if entry.arrivals.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(entry.arrivals.prefix(5).enumerated()), id: \.offset) { index, arrival in
                        HStack(spacing: 14) {
                            // Badge with subtle depth
                            ZStack {
                                Circle()
                                    .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName))
                                    .frame(width: 38, height: 38)
                                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                                
                                if arrival.isBus {
                                    Image(systemName: "bus.fill")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                } else {
                                    Text(arrival.displayName)
                                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                                        .foregroundColor(AppTheme.SubwayColors.textColor(for: arrival.displayName))
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(arrival.stopName)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                Text(arrival.direction)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(arrival.arrivalTime, style: .timer)
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                                    .monospacedDigit()
                                Text("m")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                            }
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(12)
                    }
                }
            }
        }
        .padding(16)
        .containerBackground(for: .widget) {
            WidgetBackground()
        }
    }

    // MARK: - Helpers

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tram.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text("No arrivals 😭")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
