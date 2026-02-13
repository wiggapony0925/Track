//
//  TrackWidgetLiveActivity.swift
//  TrackWidgets
//
//  Live Activity views for the Dynamic Island and Lock Screen.
//  Redesigned with an Apple Maps navigation feel: glass material,
//  live progress slider, proximity language, and upcoming arrivals.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct TrackWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackActivityAttributes.self) { context in
            // Lock Screen banner
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view regions
                DynamicIslandExpandedRegion(.leading) {
                    lineBadge(context: context, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdownText(context: context, size: 22)
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
                    HStack {
                        // Proximity text
                        Text(context.state.proximityText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)

                        Spacer()

                        // Upcoming arrivals
                        upcomingArrivalsText(context: context)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                compactLineBadge(context: context)
            } compactTrailing: {
                countdownText(context: context, size: 14)
                    .frame(minWidth: 36)
            } minimal: {
                compactLineBadge(context: context)
            }
        }
    }

    // MARK: - Lock Screen Banner

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        VStack(spacing: 12) {
            // Top row: Badge + Destination + Countdown
            HStack(spacing: 14) {
                // Physical badge — slightly bigger, more shadow
                lineBadge(context: context, size: 50)

                // Destination and proximity
                VStack(alignment: .leading, spacing: 2) {
                    // Destination name — primary, no "Next train" prefix
                    Text(context.attributes.destination)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)

                    // Dynamic proximity text
                    Text(context.state.proximityText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }

                Spacer()

                // Hero countdown — dominant, animates up or down
                countdownText(context: context, size: 36)
            }

            // Progress slider with moving dot
            progressSlider(progress: context.state.progress, context: context)

            // Upcoming arrivals row
            if !context.state.nextArrivals.isEmpty {
                HStack(spacing: 4) {
                    Text("Next:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))

                    ForEach(Array(context.state.nextArrivals.prefix(3).enumerated()), id: \.offset) { index, mins in
                        if index > 0 {
                            Text("•")
                                .font(.system(size: 11))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                        }
                        Text("\(mins) min")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                    }

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial)
        .activityBackgroundTint(.clear)
    }

    // MARK: - Reusable Components

    /// Animated countdown that smoothly transitions when the arrival time changes
    /// (whether sooner or later). Uses the absolute `arrivalTime` Date so
    /// SwiftUI's `.timer` style always reflects the latest ETA.
    @ViewBuilder
    private func countdownText(context: ActivityViewContext<TrackActivityAttributes>, size: CGFloat) -> some View {
        Text(context.state.arrivalTime, style: .timer)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundColor(AppTheme.Colors.textPrimary)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .contentTransition(.numericText(countsDown: true))
    }

    /// Live progress slider showing train position between previous stop and user's stop.
    @ViewBuilder
    private func progressSlider(progress: Double, context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        let accentColor = context.attributes.isBus
            ? AppTheme.Colors.mtaBlue
            : AppTheme.SubwayColors.color(for: context.attributes.lineId)

        GeometryReader { geo in
            let clampedProgress = min(1.0, max(0.0, progress))
            let dotX = geo.size.width * clampedProgress

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(AppTheme.Colors.textSecondary.opacity(0.2))
                    .frame(height: 4)

                // Filled track
                Capsule()
                    .fill(accentColor)
                    .frame(width: dotX, height: 4)

                // Moving dot indicator
                Circle()
                    .fill(accentColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: accentColor.opacity(0.4), radius: 3, x: 0, y: 1)
                    .offset(x: dotX - 5)
            }
        }
        .frame(height: 10)
    }

    /// Small faded text showing the next 2–3 arrival times.
    @ViewBuilder
    private func upcomingArrivalsText(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        if !context.state.nextArrivals.isEmpty {
            HStack(spacing: 3) {
                Text("Next:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                ForEach(Array(context.state.nextArrivals.prefix(2).enumerated()), id: \.offset) { index, mins in
                    if index > 0 {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    Text("\(mins)m")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
    }

    // MARK: - Badge Helpers

    @ViewBuilder
    private func lineBadge(context: ActivityViewContext<TrackActivityAttributes>, size: CGFloat = 36) -> some View {
        ZStack {
            // Physical token background with shadow for depth
            Circle()
                .fill(context.attributes.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: context.attributes.lineId))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                .overlay(
                    // Subtle inner rim/lighting for physical feel
                    Circle()
                        .stroke(LinearGradient(
                            colors: [.white.opacity(0.3), .black.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ), lineWidth: 1)
                )

            if context.attributes.isBus {
                Image(systemName: "bus.fill")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            } else {
                Text(context.attributes.lineId)
                    .font(.system(size: size * 0.45, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func compactLineBadge(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        ZStack {
            Circle()
                .fill(context.attributes.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: context.attributes.lineId))
                .frame(width: 24, height: 24)
            if context.attributes.isBus {
                Image(systemName: "bus.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text(context.attributes.lineId)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
    }
}
