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
                compactCountdown(context: context)
            } minimal: {
                compactLineBadge(context: context)
            }
        }
    }

    // MARK: - Lock Screen Banner

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        VStack(spacing: 0) {
            // Top Section: Route Badge + Countdown
            HStack(alignment: .center, spacing: 16) {
                // Left: Route badge and info
                HStack(spacing: 14) {
                    if let walk = context.state.walkMinutes {
                        // Walking indicator
                        ZStack {
                            Circle()
                                .fill(context.state.isHurryUp ? AppTheme.Colors.alertRed.opacity(0.15) : Color.white.opacity(0.1))
                                .frame(width: 50, height: 50)
                            
                            Image(systemName: walk <= 2 ? "figure.run" : "figure.walk")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(context.state.isHurryUp ? AppTheme.Colors.alertRed : .white)
                        }
                    } else {
                        lineBadge(context: context, size: 50)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if context.state.isHurryUp {
                            Text("Hurry up!")
                                .font(.system(size: 17, weight: .black, design: .rounded))
                                .foregroundColor(AppTheme.Colors.alertRed)
                        } else if context.state.walkMinutes != nil {
                            Text("Time to walk")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        } else {
                            Text(context.attributes.destination)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        
                        Text(context.state.proximityText)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(context.state.stopsAway == 1 ? AppTheme.Colors.alertRed : AppTheme.Colors.textSecondary)
                    }
                }

                Spacer()

                // Right: Hero countdown
                heroCountdownLockScreen(context: context)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Progress Slider
            VStack(spacing: 10) {
                progressSlider(progress: context.state.progress, context: context)
                
                HStack {
                    if let walkMins = context.state.walkMinutes {
                        Label("\(walkMins) min walk", systemImage: "figure.walk")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    } else {
                        HStack(spacing: 6) {
                            lineBadge(context: context, size: 16)
                            Text("to " + context.attributes.destination)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            // Following Trains Section
            if !context.state.nextArrivals.isEmpty {
                upcomingArrivalsSection(context: context)
            } else {
                Spacer()
                    .frame(height: 8)
            }
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 32)
                    .fill(.ultraThinMaterial)
                
                if context.state.isHurryUp {
                    AppTheme.Colors.alertRed.opacity(0.08)
                        .clipShape(RoundedRectangle(cornerRadius: 32))
                }
            }
        }
        .activityBackgroundTint(Color.black.opacity(0.4))
    }
    
    // MARK: - Hero Countdown (Lock Screen)
    
    @ViewBuilder
    private func heroCountdownLockScreen(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        let accentColor = context.attributes.isBus
            ? AppTheme.Colors.mtaBlue
            : AppTheme.SubwayColors.color(for: context.attributes.lineId)
        
        VStack(alignment: .center, spacing: 2) {
            // Big countdown number
            Text(context.state.arrivalTime, style: .timer)
                .font(.system(size: 42, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .frame(minWidth: 80)
            
            // "MIN" label with accent bar
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 24, height: 3)
                Text("MIN")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 24, height: 3)
            }
        }
    }
    
    // MARK: - Hero Countdown (Dynamic Island)
    
    @ViewBuilder
    private func heroCountdown(context: ActivityViewContext<TrackActivityAttributes>, size: CGFloat) -> some View {
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
    private func compactCountdown(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        Text(context.state.arrivalTime, style: .timer)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText(countsDown: true))
            .frame(minWidth: 40)
    }
    
    // MARK: - Upcoming Arrivals Section
    
    @ViewBuilder
    private func upcomingArrivalsSection(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
            
            HStack(spacing: 12) {
                Text("NEXT")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                
                HStack(spacing: 8) {
                    ForEach(Array(context.state.nextArrivals.prefix(3).enumerated()), id: \.offset) { _, mins in
                        nextArrivalPill(mins: mins, context: context)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
    
    @ViewBuilder
    private func nextArrivalPill(mins: Int, context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        let accentColor = context.attributes.isBus
            ? AppTheme.Colors.mtaBlue
            : AppTheme.SubwayColors.color(for: context.attributes.lineId)
        
        HStack(spacing: 6) {
            Circle()
                .fill(accentColor)
                .frame(width: 14, height: 14)
                .overlay(
                    Text(context.attributes.lineId.prefix(1))
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                )
            
            Text("\(mins)")
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundColor(.white)
            
            Text("min")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    // MARK: - Reusable Components

    @ViewBuilder
    private func progressSlider(progress: Double, context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        let accentColor = context.attributes.isBus
            ? AppTheme.Colors.mtaBlue
            : AppTheme.SubwayColors.color(for: context.attributes.lineId)

        GeometryReader { geo in
            let clampedProgress = min(1.0, max(0.0, progress))
            let dotX = geo.size.width * clampedProgress

            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 6)
                
                // Active Track Gradient
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.3), accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: dotX, height: 6)

                // The Vehicle Indicator
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: accentColor.opacity(0.6), radius: 6, x: 0, y: 0)
                    
                    Circle()
                        .fill(accentColor)
                        .frame(width: 8, height: 8)
                }
                .offset(x: dotX - 7)
            }
        }
        .frame(height: 14)
    }

    @ViewBuilder
    private func upcomingArrivalsText(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        if !context.state.nextArrivals.isEmpty {
            HStack(spacing: 6) {
                Text("NEXT")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                
                HStack(spacing: 4) {
                    ForEach(Array(context.state.nextArrivals.prefix(2).enumerated()), id: \.offset) { _, mins in
                        Text("\(mins)m")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.05))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Badge Helpers

    @ViewBuilder
    private func lineBadge(context: ActivityViewContext<TrackActivityAttributes>, size: CGFloat = 36) -> some View {
        let color = context.attributes.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: context.attributes.lineId)
        let textColor = context.attributes.isBus ? .white : AppTheme.SubwayColors.textColor(for: context.attributes.lineId)
        
        ZStack {
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
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )

            if context.attributes.isBus {
                Image(systemName: "bus.fill")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text(context.attributes.lineId)
                    .font(.system(size: size * 0.45, weight: .heavy, design: .rounded))
                    .foregroundColor(textColor)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func compactLineBadge(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        let color = context.attributes.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: context.attributes.lineId)
        let textColor = context.attributes.isBus ? .white : AppTheme.SubwayColors.textColor(for: context.attributes.lineId)
        
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 24, height: 24)
            if context.attributes.isBus {
                Image(systemName: "bus.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text(context.attributes.lineId)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(textColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
    }
}
