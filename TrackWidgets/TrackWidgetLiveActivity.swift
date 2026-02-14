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
        VStack(spacing: 0) {
            // Top Section: Stickman + Hurry Up / Route Info
            HStack(alignment: .center, spacing: 14) {
                if let walk = context.state.walkMinutes {
                    // Stickman Indicator
                    ZStack {
                        Circle()
                            .fill(context.state.isHurryUp ? AppTheme.Colors.alertRed.opacity(0.15) : Color.white.opacity(0.1))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: walk <= 2 ? "figure.run" : "figure.walk")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(context.state.isHurryUp ? AppTheme.Colors.alertRed : .white)
                    }
                } else {
                    lineBadge(context: context, size: 44)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if context.state.isHurryUp {
                        Text("Hurry up!")
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundColor(AppTheme.Colors.alertRed)
                    } else if context.state.walkMinutes != nil {
                        Text("Time to walk")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    } else {
                        Text(context.attributes.destination)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    
                    HStack(spacing: 6) {
                        if context.state.walkMinutes != nil {
                            lineBadge(context: context, size: 20)
                            Text("in \(Int(context.state.arrivalTime.timeIntervalSince(Date()) / 60)) minutes")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        } else {
                            Text(context.state.proximityText)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(context.state.stopsAway == 1 ? AppTheme.Colors.alertRed : AppTheme.Colors.textSecondary)
                        }
                    }
                }

                Spacer()

                // Hero Timer - Balanced Layout
                VStack(alignment: .center, spacing: -4) {
                    countdownText(context: context, size: 36)
                        .foregroundStyle(.white)
                        .frame(minWidth: 70, alignment: .center)
                    
                    Text("MIN")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.8))
                }
                .padding(.trailing, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Progress Slider
            VStack(spacing: 8) {
                progressSlider(progress: context.state.progress, context: context)
                
                HStack {
                    if let walkMins = context.state.walkMinutes {
                        Label("\(walkMins) min walk", systemImage: "figure.walk")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    } else {
                        Text(context.attributes.lineId + " to " + context.attributes.destination)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // Other Upcoming Trains Section
            if !context.state.nextArrivals.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                        .background(Color.white.opacity(0.05))
                        .padding(.bottom, 12)
                    
                    HStack(spacing: 12) {
                        Text("FOLLOWING")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                        
                        HStack(spacing: 8) {
                            ForEach(Array(context.state.nextArrivals.prefix(2).enumerated()), id: \.offset) { index, mins in
                                HStack(spacing: 6) {
                                    // Ultra-mini badge for upcoming trains
                                    Circle()
                                        .fill(context.attributes.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: context.attributes.lineId))
                                        .frame(width: 14, height: 14)
                                        .overlay(
                                            Text(context.attributes.lineId)
                                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                                .foregroundColor(.white)
                                        )
                                    
                                    Text("\(mins) MIN")
                                        .font(.system(size: 11, weight: .black, design: .rounded))
                                        .foregroundColor(AppTheme.Colors.textPrimary.opacity(0.9))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.06))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                                )
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
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

    // MARK: - Reusable Components

    @ViewBuilder
    private func countdownText(context: ActivityViewContext<TrackActivityAttributes>, size: CGFloat) -> some View {
        Text(context.state.arrivalTime, style: .timer)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
    }

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

                // The "Vehicule" Indicator
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
                    ForEach(Array(context.state.nextArrivals.prefix(2).enumerated()), id: \.offset) { index, mins in
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
