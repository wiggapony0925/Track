// Widget content views shared between the TrackWidgets extension and
// the main app (the in-app schedule preview renders these directly).
//
// All visuals are composed from `WK.*` primitives in WidgetDesignKit.swift
// — change a token there and every widget surface follows.
//
// Public entry points (consumed by the widget extensions):
//   • NearbySmallWidgetView   — single hero arrival (small TrackWidget)
//   • NearbyListWidgetView    — vertical list of arrivals (medium / large)
//   • TrackRouteSmallWidgetView — currently-tracked route hero (small SingleRoute)
//   • TrackRouteListWidgetView  — tracked route + next 3 arrivals (medium / large)

import SwiftUI

// MARK: - Nearby — Small (one hero arrival)

struct NearbySmallWidgetView: View {
    let arrivals: [NearbyArrival]
    let date: Date
    let isActive: Bool

    init(arrivals: [NearbyArrival], date: Date = .now, isActive: Bool = true) {
        self.arrivals = arrivals
        self.date = date
        self.isActive = isActive
    }

    var body: some View {
        if !isActive {
            WK.EmptyState(
                icon: "moon.zzz.fill",
                title: "Paused",
                subtitle: "Outside scheduled hours"
            )
        } else if let arrival = arrivals.first {
            VStack(alignment: .leading, spacing: 8) {
                WK.Header(title: "Nearby", trailing: arrival.stopName)

                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: 12) {
                    WK.LineBadge(
                        lineId: arrival.displayName,
                        isBus: arrival.isBus,
                        isLIRR: arrival.isLIRR,
                        isMNR: arrival.isMNR,
                        size: WK.Tokens.badgeHeroSize
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        WK.CountdownLabel(
                            arrivalTime: arrival.arrivalTime,
                            size: 32,
                            style: .timer
                        )
                        Text(arrival.direction)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if arrivals.count > 1 {
                    nextRow(arrivals[1])
                }
            }
            .padding(WK.Tokens.surfacePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            WK.EmptyState(
                icon: "tram",
                title: "No arrivals nearby",
                subtitle: "Check back soon"
            )
        }
    }

    private func nextRow(_ next: NearbyArrival) -> some View {
        HStack(spacing: 6) {
            Text("Next")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textTertiary)
            WK.LineBadge(
                lineId: next.displayName,
                isBus: next.isBus,
                isLIRR: next.isLIRR,
                isMNR: next.isMNR,
                size: 18
            )
            Text("in \(TrackingTimeSync.remainingMinutes(until: next.arrivalTime))m")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Nearby — List (Medium / Large)

struct NearbyListWidgetView: View {
    let arrivals: [NearbyArrival]
    let maxVisible: Int
    let date: Date
    var isActive: Bool = true

    var body: some View {
        if !isActive {
            WK.EmptyState(
                icon: "moon.zzz.fill",
                title: "Widget Paused",
                subtitle: "Outside your scheduled hours"
            )
        } else if arrivals.isEmpty {
            WK.EmptyState(
                icon: "tram",
                title: "No nearby transit",
                subtitle: "Move closer to a stop"
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                WK.Header(
                    title: "Nearby Transit",
                    trailing: arrivals.first?.stopName
                )

                VStack(spacing: 0) {
                    ForEach(Array(arrivals.prefix(maxVisible).enumerated()),
                            id: \.offset) { index, arrival in
                        WK.ArrivalRow(
                            lineId: arrival.displayName,
                            stopName: arrival.stopName,
                            direction: arrival.direction,
                            arrivalTime: arrival.arrivalTime,
                            isBus: arrival.isBus,
                            isLIRR: arrival.isLIRR,
                            isMNR: arrival.isMNR
                        )
                        .padding(.vertical, 7)

                        if index < min(maxVisible, arrivals.count) - 1 {
                            Divider()
                                .background(AppTheme.Colors.borderSubtle)
                        }
                    }
                }
            }
            .padding(WK.Tokens.surfacePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Tracked Route — Small (single tracked-route hero)

struct TrackRouteSmallWidgetView: View {
    let route: TrackedRoute
    let arrivals: [NearbyArrival]
    let date: Date

    init(route: TrackedRoute, arrivals: [NearbyArrival], date: Date = .now) {
        self.route = route
        self.arrivals = arrivals
        self.date = date
    }

    var body: some View {
        if let arrival = arrivals.first {
            VStack(alignment: .leading, spacing: 8) {
                WK.Header(title: "Tracking", trailing: route.stopName)

                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: 12) {
                    WK.LineBadge(
                        lineId: route.cleanDisplayName,
                        isBus: route.isBus,
                        isLIRR: route.isLIRR,
                        isMNR: route.isMNR,
                        size: WK.Tokens.badgeHeroSize
                    )
                    WK.CountdownLabel(
                        arrivalTime: arrival.arrivalTime,
                        size: 30,
                        style: .timer
                    )
                }

                Text(route.direction)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(WK.Tokens.surfacePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                WK.Header(title: "Tracking", showLive: false)

                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    WK.LineBadge(
                        lineId: route.cleanDisplayName,
                        isBus: route.isBus,
                        isLIRR: route.isLIRR,
                        isMNR: route.isMNR,
                        size: 44
                    )
                    Text("Waiting…")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(WK.Tokens.surfacePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Tracked Route — List (Medium / Large)

struct TrackRouteListWidgetView: View {
    let route: TrackedRoute
    let arrivals: [NearbyArrival]
    let maxVisible: Int
    let date: Date

    var body: some View {
        if arrivals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                WK.Header(title: "Tracking")
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    WK.LineBadge(
                        lineId: route.cleanDisplayName,
                        isBus: route.isBus,
                        isLIRR: route.isLIRR,
                        isMNR: route.isMNR,
                        size: 36
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(route.stopName)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                        Text(route.direction)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Spacer()
                Text("Waiting for next arrival…")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(WK.Tokens.surfacePadding)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // Hero row
                HStack(alignment: .center, spacing: 12) {
                    WK.LineBadge(
                        lineId: route.cleanDisplayName,
                        isBus: route.isBus,
                        isLIRR: route.isLIRR,
                        isMNR: route.isMNR,
                        size: 44
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            WK.LiveDot(compact: true)
                            Text(route.stopName)
                                .font(.system(size: 13, weight: .bold,
                                              design: .rounded))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                        }
                        Text(route.direction)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let next = arrivals.first {
                        WK.CountdownLabel(
                            arrivalTime: next.arrivalTime,
                            size: 24,
                            style: .timer
                        )
                    }
                }

                Divider().background(AppTheme.Colors.borderSubtle)

                Text("UPCOMING")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .foregroundColor(AppTheme.Colors.textTertiary)

                ForEach(Array(arrivals.prefix(maxVisible).enumerated()),
                        id: \.offset) { index, arrival in
                    HStack(spacing: 8) {
                        Text("#\(index + 1)")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                            .frame(width: 18, alignment: .leading)
                        Image(systemName: WK.icon(
                            isBus: route.isBus,
                            isCommuterRail: route.isCommuterRail))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text(arrival.status.isEmpty ? "On time" : arrival.status)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        WK.CountdownLabel(
                            arrivalTime: arrival.arrivalTime,
                            size: 16
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(WK.Tokens.surfacePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Placeholders

extension NearbySmallWidgetView {
    static var placeholder: NearbySmallWidgetView {
        NearbySmallWidgetView(
            arrivals: NearbyArrival.previewSet,
            date: Date()
        )
    }
}

extension NearbyListWidgetView {
    static var placeholder: NearbyListWidgetView {
        NearbyListWidgetView(
            arrivals: NearbyArrival.previewSet,
            maxVisible: 3,
            date: Date()
        )
    }
}

extension TrackRouteSmallWidgetView {
    static var placeholder: TrackRouteSmallWidgetView {
        TrackRouteSmallWidgetView(
            route: TrackedRoute.previewL,
            arrivals: NearbyArrival.previewTrackedSet
        )
    }
}

extension TrackRouteListWidgetView {
    static var placeholder: TrackRouteListWidgetView {
        TrackRouteListWidgetView(
            route: TrackedRoute.previewL,
            arrivals: NearbyArrival.previewTrackedSet,
            maxVisible: 3,
            date: Date()
        )
    }
}

// MARK: - Preview Data

extension NearbyArrival {
    fileprivate static var previewSet: [NearbyArrival] {
        [
            NearbyArrival(routeId: "MTA NYCT_A", stopName: "Jay St-MetroTech",
                          direction: "Manhattan", minutesAway: 3, status: "On Time",
                          mode: "subway", arrivalTime: Date().addingTimeInterval(180)),
            NearbyArrival(routeId: "MTA NYCT_C", stopName: "Jay St-MetroTech",
                          direction: "Manhattan", minutesAway: 7, status: "On Time",
                          mode: "subway", arrivalTime: Date().addingTimeInterval(420)),
            NearbyArrival(routeId: "MTA NYCT_F", stopName: "Jay St-MetroTech",
                          direction: "Manhattan", minutesAway: 11, status: "On Time",
                          mode: "subway", arrivalTime: Date().addingTimeInterval(660)),
        ]
    }

    fileprivate static var previewTrackedSet: [NearbyArrival] {
        [
            NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan",
                          minutesAway: 4, status: "On Time", mode: "subway",
                          arrivalTime: Date().addingTimeInterval(240)),
            NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan",
                          minutesAway: 12, status: "On Time", mode: "subway",
                          arrivalTime: Date().addingTimeInterval(720)),
            NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan",
                          minutesAway: 19, status: "On Time", mode: "subway",
                          arrivalTime: Date().addingTimeInterval(1140)),
        ]
    }
}

extension TrackedRoute {
    fileprivate static var previewL: TrackedRoute {
        TrackedRoute(
            routeId: "MTA NYCT_L",
            displayName: "L",
            stopName: "1st Avenue",
            direction: "Manhattan",
            destination: "8 Av",
            mode: "subway",
            trackedAt: Date()
        )
    }
}
