//
//  WidgetSmallViews.swift
//  Shared
//
//  The actual small-widget content views, shared between the TrackWidgets
//  extension and the main app (for live in-settings previews).
//
//  No WidgetKit import — these are plain SwiftUI so they compile in both
//  targets. Each widget wraps these in .containerBackground(...) in the
//  extension; the main app renders them directly inside a clipped frame.
//

import SwiftUI

// MARK: - Nearby Arrivals Small View
// Used by TrackWidget (small) + NearbyArrivalsPreview in settings.

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
        Group {
            if !isActive {
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.xmark")
                        .font(.system(size: 28))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Text("Outside\nscheduled\nhours")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let arrival = arrivals.first {
                VStack(spacing: 6) {
                    // Header: LIVE label + time
                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(AppTheme.Colors.alertRed)
                                .frame(width: 4, height: 4)
                            Text("LIVE")
                                .font(.system(size: 8, weight: .black))
                                .foregroundColor(AppTheme.Colors.alertRed)
                        }
                        Spacer()
                        Text(date, style: .time)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    Spacer(minLength: 0)

                    // Hero Badge
                    transitBadge(arrival: arrival, size: 50)

                    // Live Timer — centred under the badge
                    if TrackingTimeSync.remainingMinutes(until: arrival.arrivalTime) <= 0 {
                        Text("NOW")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(AppTheme.Colors.alertRed)
                            .clipShape(Capsule())
                    } else {
                        Text(arrival.arrivalTime, style: .timer)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.countdown(TrackingTimeSync.remainingMinutes(until: arrival.arrivalTime)))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                            .padding(.top, 4)
                    }

                    // Stop / Direction
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

                    // Next arrival footer
                    if let next = arrivals.dropFirst().first {
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
                nearbyEmptyState
            }
        }
    }

    @ViewBuilder
    private func transitBadge(arrival: NearbyArrival, size: CGFloat) -> some View {
        if arrival.isCommuterRail {
            HStack(spacing: 3) {
                Image(systemName: "train.side.front.car")
                    .font(.system(size: size * 0.32, weight: .bold))
                    .foregroundColor(.white)
                Text(arrival.displayName)
                    .font(.system(size: size * 0.28, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(minWidth: size, minHeight: size)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(arrival.isLIRR ? AppTheme.CommuterRailColors.lirrBlue : AppTheme.CommuterRailColors.mnrBlue)
                    .shadow(color: (arrival.isLIRR ? AppTheme.CommuterRailColors.lirrBlue : AppTheme.CommuterRailColors.mnrBlue).opacity(0.3), radius: 6, x: 0, y: 3)
            )
        } else {
            ZStack {
                Circle()
                    .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName))
                    .frame(width: size, height: size)
                    .shadow(color: (arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName)).opacity(0.3), radius: 6, x: 0, y: 3)

                if arrival.isBus {
                    Image(systemName: "bus.fill")
                        .font(.system(size: size * 0.44, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text(arrival.displayName)
                        .font(.system(size: size * 0.48, weight: .heavy, design: .rounded))
                        .foregroundColor(AppTheme.SubwayColors.textColor(for: arrival.displayName))
                        .minimumScaleFactor(0.4)
                }
            }
        }
    }

    private var nearbyEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tram.fill")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text("No transit nearby")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Nearby List Widget View (Medium / Large)
// Used by TrackWidget and WidgetSchedulesContentView.

struct NearbyListWidgetView: View {
    let arrivals: [NearbyArrival]
    let maxVisible: Int
    let date: Date
    var isActive: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.mtaBlue.opacity(0.15))
                        .frame(width: 20, height: 20)
                    Image(systemName: "tram.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                }
                
                Text(isActive ? "Nearby Transit" : "Transit Paused")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                
                Spacer()
                
                if isActive {
                    Text(date, style: .time)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }
            .padding(.bottom, 2)
            
            if !isActive {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.xmark")
                            .font(.system(size: 24))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("Outside scheduled hours")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Spacer()
            } else if arrivals.isEmpty {
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
                    ForEach(Array(arrivals.prefix(maxVisible).enumerated()), id: \.offset) { _, arrival in
                        NearbyWidgetRowView(arrival: arrival)
                        if arrival != arrivals.prefix(maxVisible).last {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NearbyWidgetRowView: View {
    let arrival: NearbyArrival

    var body: some View {
        HStack(spacing: 12) {
            // Route Badge
            if arrival.isCommuterRail {
                HStack(spacing: 2) {
                    Image(systemName: "train.side.front.car")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                    Text(arrival.displayName)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.3)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
                .frame(minWidth: 32, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(arrival.isLIRR ? AppTheme.CommuterRailColors.lirrBlue : AppTheme.CommuterRailColors.mnrBlue)
                        .shadow(color: (arrival.isLIRR ? AppTheme.CommuterRailColors.lirrBlue : AppTheme.CommuterRailColors.mnrBlue).opacity(0.3), radius: 3)
                )
            } else {
                ZStack {
                    Circle()
                        .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName))
                        .frame(width: 28, height: 28)
                        .shadow(color: (arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName)).opacity(0.3), radius: 3, x: 0, y: 1)
                    
                    if arrival.isBus {
                        Image(systemName: "bus.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Text(arrival.displayName)
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .foregroundColor(AppTheme.SubwayColors.textColor(for: arrival.displayName))
                            .minimumScaleFactor(0.4)
                    }
                }
            }

            // Stop & Direction
            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.stopName)
                    .font(.custom("Helvetica-Bold", size: 14))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Text(arrival.direction)
                        .font(.custom("Helvetica-Bold", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            
            Spacer(minLength: 8)
            
            // ETA & Status
            VStack(alignment: .trailing, spacing: 4) {
                Text(arrival.arrivalTime, style: .timer)
                    .font(.custom("Helvetica-Bold", size: 18))
                    .foregroundColor(AppTheme.Colors.countdown(TrackingTimeSync.remainingMinutes(until: arrival.arrivalTime)))
                    .monospacedDigit()
                
                if !arrival.status.isEmpty {
                    Text(arrival.status.prefix(4).uppercased() + (arrival.status.count > 4 ? "." : ""))
                        .font(.custom("Helvetica-Bold", size: 8))
                        .foregroundColor(statusTextColor(arrival.status))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(statusTextColor(arrival.status).opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }
    
    // Extracted localized color function
    private func statusTextColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "on time": return AppTheme.Colors.successGreen
        case "delayed", "delay": return AppTheme.Colors.alertRed
        case "approaching": return AppTheme.Colors.countdown(5)
        default: return AppTheme.Colors.textSecondary
        }
    }
}

// MARK: - Track Route Small View
// Used by SingleRouteWidget (small) + TrackRoutePreview in settings.

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
        Group {
            if let firstArrival = arrivals.first {
                VStack(spacing: 4) {
                    // Header: LIVE label + time
                    HStack {
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(AppTheme.Colors.alertRed.opacity(0.1))
                                .frame(width: 32, height: 12)
                            HStack(spacing: 2) {
                                Circle()
                                    .fill(AppTheme.Colors.alertRed)
                                    .frame(width: 4, height: 4)
                                Text("LIVE")
                                    .font(.system(size: 7, weight: .black))
                                    .foregroundColor(AppTheme.Colors.alertRed)
                            }
                            .padding(.horizontal, 4)
                        }
                        Spacer()
                        Text(date, style: .time)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                    Spacer(minLength: 0)

                    // Route badge
                    transitBadge(size: 44)

                    // Hero ETA
                    if TrackingTimeSync.remainingMinutes(until: firstArrival.arrivalTime) <= 0 {
                        Text("NOW")
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .frame(minWidth: 72)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(AppTheme.Colors.alertRed)
                            .clipShape(Capsule())
                    } else {
                        Text(firstArrival.arrivalTime, style: .timer)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.countdown(TrackingTimeSync.remainingMinutes(until: firstArrival.arrivalTime)))
                            .monospacedDigit()
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }

                    // Stop / Direction
                    VStack(spacing: 1) {
                        Text(route.stopName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("→ \(route.direction)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)

                    Spacer(minLength: 0)

                    // Next arrival footer
                    if let next = arrivals.dropFirst().first {
                        HStack(spacing: 4) {
                            Text("Next:")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                            Text(next.arrivalTime, style: .timer)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .monospacedDigit()
                        }
                        .padding(.bottom, 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                trackRouteNoDataView
            }
        }
    }

    @ViewBuilder
    private func transitBadge(size: CGFloat) -> some View {
        if route.isCommuterRail {
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
                    .shadow(color: (route.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: route.cleanDisplayName)).opacity(0.3), radius: 6, x: 0, y: 3)
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

    private var trackRouteNoDataView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tram.fill")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text("No route tracked")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Placeholder Data (for settings preview and widget previews)

extension NearbySmallWidgetView {
    static var placeholder: NearbySmallWidgetView {
        NearbySmallWidgetView(
            arrivals: [
                NearbyArrival(routeId: "MTA NYCT_A", stopName: "Jay St-MetroTech", direction: "Manhattan", minutesAway: 3, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(180)),
                NearbyArrival(routeId: "MTA NYCT_C", stopName: "Jay St-MetroTech", direction: "Manhattan", minutesAway: 7, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(420)),
                NearbyArrival(routeId: "MTA NYCT_F", stopName: "Jay St-MetroTech", direction: "Manhattan", minutesAway: 11, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(660)),
            ]
        )
    }
}

extension NearbyListWidgetView {
    static var placeholder: NearbyListWidgetView {
        NearbyListWidgetView(
            arrivals: NearbySmallWidgetView.placeholder.arrivals,
            maxVisible: 3,
            date: Date()
        )
    }
}

extension TrackRouteSmallWidgetView {
    static var placeholder: TrackRouteSmallWidgetView {
        TrackRouteSmallWidgetView(
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
                NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan", minutesAway: 4, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(240)),
                NearbyArrival(routeId: "L", stopName: "1st Avenue", direction: "Manhattan", minutesAway: 12, status: "On Time", mode: "subway", arrivalTime: Date().addingTimeInterval(720)),
            ]
        )
    }
}
