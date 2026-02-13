//
//  TrackWidgetLiveActivity.swift
//  TrackWidgets
//
//  Live Activity views for the Dynamic Island and Lock Screen.
// No changes real-time countdown for tracked subway and bus arrivals.
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
                    lineBadge(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.arrivalTime, style: .timer)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textOnColor)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    // Progress bar
                    ProgressView(value: context.state.progress)
                        .tint(context.attributes.isBus ? AppTheme.Colors.mtaBlue : AppTheme.Colors.textOnColor)
                        .padding(.horizontal, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("To \(context.attributes.destination)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                // Compact: Line icon
                compactLineBadge(context: context)
            } compactTrailing: {
                // Compact: Countdown
                Text(context.state.arrivalTime, style: .timer)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 36)
            } minimal: {
                // Minimal: Just the line icon
                compactLineBadge(context: context)
            }
        }
    }

    // MARK: - Lock Screen Banner

    // MARK: - Lock Screen Banner

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        HStack(spacing: 16) {
            // Line badge (Physical token look)
            lineBadge(context: context, size: 46)

            // Text info
            VStack(alignment: .leading, spacing: 4) {
                // Calm, human copy
                Text(context.attributes.isBus ? "Next bus" : "Next train")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.Colors.textSecondary)
                
                // Destination (Cleaner, no prepositions)
                Text(context.attributes.destination)
                    .font(.headline)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Hero Time (Dominant)
            Text(context.state.arrivalTime, style: .timer)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
                // Softly crossfade animation for timer ticks
                .contentTransition(.numericText(countsDown: true))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .activityBackgroundTint(Color.black.opacity(0.25)) // Lighter tint
        .background(.ultraThinMaterial) // Glass effect
    }

    // MARK: - Badge Helpers

    @ViewBuilder
    private func lineBadge(context: ActivityViewContext<TrackActivityAttributes>, size: CGFloat = 36) -> some View {
        ZStack {
            // Physical token background
            Circle()
                .fill(context.attributes.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: context.attributes.lineId))
                .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1) // Drop shadow
                .overlay(
                    // Subtle inner rim/lighting
                    Circle()
                        .stroke(LinearGradient(
                            colors: [.white.opacity(0.3), .black.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ), lineWidth: 1)
                )
            
            if context.attributes.isBus {
                Image(systemName: "bus.fill")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            } else {
                Text(context.attributes.lineId)
                    .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
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
        // Keep compact simpler but consistent colors
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
