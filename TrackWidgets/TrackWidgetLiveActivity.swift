//
//  TrackWidgetLiveActivity.swift
//  TrackWidgets
//
//  Live Activity views for the Dynamic Island and Lock Screen.
//  Redesigned with an Apple Maps navigation feel: glass material,
//  live progress slider, proximity language, and upcoming arrivals.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct TrackWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackActivityAttributes.self) { context in
            // Lock Screen banner
            lockScreenView(context: context)
                .widgetURL(URL(string: "track://route/\(context.attributes.lineId)")!)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view regions
                DynamicIslandExpandedRegion(.leading) {
                    lineBadge(context: context, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    heroCountdown(context: context, size: 28)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 6) {
                        // Destination
                        Text(context.attributes.destination)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Progress slider with moving dot
                        progressSlider(progress: context.state.progress, context: context)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        HStack {
                            // Proximity text
                            Text(context.state.proximityText)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(AppTheme.Colors.textSecondary)

                            Spacer()

                            // Upcoming arrivals
                            upcomingArrivalsText(context: context)
                        }

                        // "I made it!" button for quick dismissal
                        Button(intent: EndTrackingIntent()) {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.thumbsup.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text("I made it!")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                LinearGradient(
                                    colors: [
                                        AppTheme.Colors.successGreen,
                                        AppTheme.Colors.successGreen.opacity(0.8)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                compactLineBadge(context: context)
            } compactTrailing: {
                compactCountdown(context: context)
            } minimal: {
                compactLineBadge(context: context)
            }
            .widgetURL(URL(string: "track://route/\(context.attributes.lineId)")!)
        }
    }

    // MARK: - Lock Screen Banner

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TrackActivityAttributes>) -> some View
    {
        VStack(spacing: 0) {
            // Top Section: Route Badge + Countdown
            HStack(alignment: .top, spacing: 12) {  // Spacing: 16 -> 12
                // Left: Route + Destination
                HStack(alignment: .center, spacing: 10) {  // Spacing: 14 -> 10
                    if let walk = context.state.walkMinutes {
                        // Walking indicator
                        ZStack {
                            Circle()
                                .fill(
                                    context.state.isHurryUp
                                        ? AppTheme.Colors.alertRed.opacity(0.15)
                                        : Color.white.opacity(0.1)
                                )
                                .frame(width: 44, height: 44)  // Reduced from 50

                            Image(systemName: walk <= 2 ? "figure.run" : "figure.walk")
                                .font(.system(size: 22, weight: .bold))  // Reduced from 26
                                .foregroundColor(
                                    context.state.isHurryUp ? AppTheme.Colors.alertRed : .white)
                        }
                    } else {
                        lineBadge(context: context, size: 44)  // Reduced from 50
                    }

                    VStack(alignment: .leading, spacing: 0) {  // Spacing: 2 -> 0
                        if context.state.isHurryUp {
                            Text("Hurry up!")
                                .font(.system(size: 17, weight: .black, design: .rounded))  // 18 -> 17
                                .foregroundColor(AppTheme.Colors.alertRed)
                        } else if context.state.walkMinutes != nil {
                            Text("Time to walk")
                                .font(.system(size: 17, weight: .bold, design: .rounded))  // 18 -> 17
                                .foregroundColor(.white)
                        } else {
                            Text(context.attributes.destination)
                                .font(.system(size: 18, weight: .bold, design: .rounded))  // 19 -> 18
                                .foregroundColor(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.65)  // 0.8 -> 0.65
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(context.state.proximityText)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(
                                context.state.stopsAway == 1
                                    ? AppTheme.Colors.alertRed : AppTheme.Colors.textSecondary
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                Spacer()

                // Right: Hero countdown
                heroCountdownLockScreen(context: context)
            }
            .padding(.horizontal, 20)  // 22 -> 20
            .padding(.top, 14)  // 16 -> 14
            .padding(.bottom, 10)  // 12 -> 10

            // Middle: Progress Slider
            VStack(spacing: 6) {  // 8 -> 6
                progressSlider(progress: context.state.progress, context: context)

                HStack {
                    if let walkMins = context.state.walkMinutes {
                        Label("\(walkMins) min walk", systemImage: "figure.walk")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    } else {
                        HStack(spacing: 4) {  // 6 -> 4
                            lineBadge(context: context, size: 14)  // 16 -> 14
                            Text("to " + context.attributes.destination)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Show next train if available
                    if let next = context.state.nextArrivals.first {
                        Text("Next: \(next) min")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.8))
                    }
                }
                .padding(.horizontal, 2)  // 4 -> 2
            }
            .padding(.horizontal, 20)  // 22 -> 20
            .padding(.bottom, 10)  // 12 -> 10

            // Bottom: "I made it!" Action Button
            Button(intent: EndTrackingIntent()) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.thumbsup.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text("I made it!")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [
                            AppTheme.Colors.successGreen,
                            AppTheme.Colors.successGreen.opacity(0.8)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: AppTheme.Colors.successGreen.opacity(0.3), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .background {
            ZStack {
                // Main dark background
                Color.black

                // Subtle gradient accent from the route color
                let accentColor = context.attributes.isBus
                    ? AppTheme.Colors.mtaBlue
                    : AppTheme.SubwayColors.color(for: context.attributes.lineId)
                
                LinearGradient(
                    colors: [accentColor.opacity(0.12), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if context.state.isHurryUp {
                    AppTheme.Colors.alertRed.opacity(0.1)
                }
            }
        }
        .activityBackgroundTint(Color.black)
    }

    // MARK: - Hero Countdown (Lock Screen)

    @ViewBuilder
    private func heroCountdownLockScreen(context: ActivityViewContext<TrackActivityAttributes>)
        -> some View
    {
        let accentColor =
            context.attributes.isBus
            ? AppTheme.Colors.mtaBlue
            : AppTheme.SubwayColors.color(for: context.attributes.lineId)

        VStack(alignment: .center, spacing: -2) {  // Negative spacing to tighten number and label
            // Big countdown number
            Text(context.state.arrivalTime, style: .timer)
                .font(.system(size: 40, weight: .black, design: .rounded))  // 46 -> 40
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .frame(minWidth: 80)  // 90 -> 80
                .minimumScaleFactor(0.8)

            // "MIN" label with accent bar
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5)  // Reduced radius
                    .fill(accentColor)
                    .frame(width: 24, height: 3)  // 28x4 -> 24x3
                Text("MIN")
                    .font(.system(size: 11, weight: .black, design: .rounded))  // 12 -> 11
                    .foregroundColor(AppTheme.Colors.textSecondary)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accentColor)
                    .frame(width: 24, height: 3)
            }
        }
    }

    // MARK: - Hero Countdown (Dynamic Island)

    @ViewBuilder
    private func heroCountdown(context: ActivityViewContext<TrackActivityAttributes>, size: CGFloat)
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(context.state.arrivalTime, style: .timer)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))

            Text("min")
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: - Compact Countdown

    @ViewBuilder
    private func compactCountdown(context: ActivityViewContext<TrackActivityAttributes>)
        -> some View
    {
        Text(context.state.arrivalTime, style: .timer)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText(countsDown: true))
            .frame(minWidth: 40)
    }

    // MARK: - Upcoming Arrivals Section

    @ViewBuilder
    private func upcomingArrivalsText(context: ActivityViewContext<TrackActivityAttributes>)
        -> some View
    {
        if !context.state.nextArrivals.isEmpty {
            HStack(spacing: 5) {
                Text("NEXT")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))

                HStack(spacing: 3) {
                    ForEach(Array(context.state.nextArrivals.prefix(2).enumerated()), id: \.offset)
                    { _, mins in
                        Text("\(mins)m")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Reusable Components

    @ViewBuilder
    private func progressSlider(
        progress: Double, context: ActivityViewContext<TrackActivityAttributes>
    ) -> some View {
        let accentColor =
            context.attributes.isBus
            ? AppTheme.Colors.mtaBlue
            : AppTheme.SubwayColors.color(for: context.attributes.lineId)

        GeometryReader { geo in
            let clampedProgress = min(1.0, max(0.0, progress))
            let dotX = geo.size.width * clampedProgress

            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 8)

                // Active Track Gradient
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.4), accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: dotX, height: 8)

                // The Vehicle Indicator
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: accentColor.opacity(0.6), radius: 8, x: 0, y: 0)

                    Circle()
                        .fill(accentColor)
                        .frame(width: 9, height: 9)
                }
                .offset(x: dotX - 8)
            }
        }
        .frame(height: 16)
    }

    // MARK: - Badge Helpers

    @ViewBuilder
    private func lineBadge(
        context: ActivityViewContext<TrackActivityAttributes>, size: CGFloat = 36
    ) -> some View {
        let color =
            context.attributes.isBus
            ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: context.attributes.lineId)
        let textColor =
            context.attributes.isBus
            ? .white : AppTheme.SubwayColors.textColor(for: context.attributes.lineId)

        ZStack {
            if context.attributes.isBus {
                // Bus: Rounded rectangle with route name (e.g. "B44")
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(1.0), color.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 1.5)
                    )

                // Show bus route name, with bus icon only as fallback
                VStack(spacing: 0) {
                    Image(systemName: "bus.fill")
                        .font(.system(size: size * 0.22, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                    Text(context.attributes.lineId)
                        .font(.system(size: size * 0.32, weight: .heavy, design: .rounded))
                        .foregroundColor(textColor)
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                }
            } else {
                // Subway/Rail: Circle with line letter/number
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(1.0), color.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 1.5)
                    )

                Text(context.attributes.lineId)
                    .font(.system(size: size * 0.45, weight: .heavy, design: .rounded))
                    .foregroundColor(textColor)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .frame(width: context.attributes.isBus ? size * 1.3 : size, height: size)
    }

    @ViewBuilder
    private func compactLineBadge(context: ActivityViewContext<TrackActivityAttributes>)
        -> some View
    {
        let color =
            context.attributes.isBus
            ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: context.attributes.lineId)
        let textColor =
            context.attributes.isBus
            ? .white : AppTheme.SubwayColors.textColor(for: context.attributes.lineId)

        if context.attributes.isBus {
            // Bus: Show route name in rounded rect (e.g. "B44")
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color)
                    .frame(width: 34, height: 24)
                Text(context.attributes.lineId)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundColor(textColor)
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
            }
        } else {
            // Subway/Rail: Circle with line letter/number
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 24, height: 24)
                Text(context.attributes.lineId)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(textColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
    }
}
