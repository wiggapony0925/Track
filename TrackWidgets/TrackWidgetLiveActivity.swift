//
//  TrackWidgetLiveActivity.swift
//  TrackWidgets
//
//  Live Activity views for the Dynamic Island and Lock Screen.
//  Shows real-time countdown for tracked subway and bus arrivals.
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
                        .foregroundColor(.white)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    // Progress bar
                    ProgressView(value: context.state.progress)
                        .tint(context.attributes.isBus ? .blue : .white)
                        .padding(.horizontal, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("To \(context.attributes.destination)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
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

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            // Line badge
            lineBadge(context: context)

            // Status text
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.statusText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("To \(context.attributes.destination)")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Countdown
            Text(context.state.arrivalTime, style: .timer)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.primary)
        }
        .padding(16)
        .background(context.attributes.isBus ? Color.blue.opacity(0.15) : Color.black.opacity(0.05))
    }

    // MARK: - Badge Helpers

    @ViewBuilder
    private func lineBadge(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        ZStack {
            Circle()
                .fill(context.attributes.isBus ? Color.blue : Color.black)
                .frame(width: 36, height: 36)
            if context.attributes.isBus {
                Image(systemName: "bus.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text(context.attributes.lineId)
                    .font(.system(size: 16, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func compactLineBadge(context: ActivityViewContext<TrackActivityAttributes>) -> some View {
        ZStack {
            Circle()
                .fill(context.attributes.isBus ? Color.blue : Color.black)
                .frame(width: 24, height: 24)
            if context.attributes.isBus {
                Image(systemName: "bus.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text(context.attributes.lineId)
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
    }
}
