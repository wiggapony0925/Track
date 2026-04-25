// Live Activity views for the Dynamic Island and Lock Screen.
// Redesigned with an Apple Maps navigation feel: glass material,
// live progress slider, proximity language, and upcoming arrivals.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct TrackWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackActivityAttributes.self) { context in
            // Lock Screen banner
            let encodedId = context.attributes.lineId
                .addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? context.attributes.lineId
            lockScreenView(context: context)
                .widgetURL(
                    URL(string: "track://route/\(encodedId)")
                )
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
            .widgetURL({
                let eid = context.attributes.lineId
                    .addingPercentEncoding(
                        withAllowedCharacters: .urlPathAllowed
                    ) ?? context.attributes.lineId
                return URL(
                    string: "track://route/\(eid)"
                )
            }())
        }
    }

    // MARK: - Lock Screen Banner

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TrackActivityAttributes>) -> some View
    {
        let accent = WK.brandColor(
            lineId: context.attributes.lineId,
            isBus: context.attributes.isBus
        )

        VStack(spacing: 12) {
            // The exact pill the user sees during onboarding.
            WK.LiveActivityPill(
                lineId: context.attributes.lineId,
                stopName: context.attributes.destination,
                arrivalTime: context.state.arrivalTime,
                isBus: context.attributes.isBus
            )

            // Progress to the stop.
            WK.ProgressTrack(
                progress: context.state.progress,
                color: accent,
                height: 5
            )
            .padding(.horizontal, 6)

            // Proximity text + "I made it" CTA.
            HStack(spacing: 10) {
                Text(context.state.proximityText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(intent: EndTrackingIntent()) {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.thumbsup.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("I made it")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(AppTheme.Colors.successGreen)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
        .activityBackgroundTint(Color.black)
    }

    // MARK: - Hero Countdown (Dynamic Island)

    @ViewBuilder
    private func heroCountdown(context: ActivityViewContext<TrackActivityAttributes>, size: CGFloat)
        -> some View
    {
        WK.CountdownLabel(arrivalTime: context.state.arrivalTime,
                          size: size, style: .timer,
                          tint: AppTheme.Colors.successGreen)
    }

    // MARK: - Compact Countdown

    @ViewBuilder
    private func compactCountdown(context: ActivityViewContext<TrackActivityAttributes>)
        -> some View
    {
        WK.CountdownLabel(arrivalTime: context.state.arrivalTime,
                          size: 13, style: .timer,
                          tint: AppTheme.Colors.successGreen)
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
        let accentColor = WK.brandColor(
            lineId: context.attributes.lineId,
            isBus: context.attributes.isBus
        )
        WK.ProgressTrack(progress: progress, color: accentColor, height: 8)
    }

    // MARK: - Badge Helpers

    @ViewBuilder
    private func lineBadge(
        context: ActivityViewContext<TrackActivityAttributes>, size: CGFloat = 36
    ) -> some View {
        WK.LineBadge(
            lineId: context.attributes.lineId,
            isBus: context.attributes.isBus,
            size: size
        )
    }

    @ViewBuilder
    private func compactLineBadge(context: ActivityViewContext<TrackActivityAttributes>)
        -> some View
    {
        WK.LineBadge(
            lineId: context.attributes.lineId,
            isBus: context.attributes.isBus,
            size: 22
        )
    }
}
