// WidgetDesignKit
// =============================================================================
// Single source of truth for every visual element used by:
//   • Home-screen widgets   (TrackWidget, LiveNearMeWidget, SingleRouteWidget)
//   • Live Activity         (Dynamic Island + Lock Screen)
//   • In-app live banner    (TrackLiveBannerView)
//   • In-app schedule UI    (Schedule list + editor)
//
// All widgets share four primitives:
//   1. `WK.Surface`           — gradient card background
//   2. `WK.LineBadge`         — bus / subway / LIRR / MNR bullet
//   3. `WK.CountdownLabel`    — colour-tiered "X min" / "NOW" timer
//   4. `WK.ProgressTrack`     — slim progress bar with travelling dot
//
// Everything else (rows, headers, empty states) composes those four.
// Adjust a token here and every widget + the live activity follow.
//
// Compiles in BOTH the main `Track` target and the `TrackWidgetsExtension`
// target — no `WidgetKit`/UIKit imports.  Plain SwiftUI only.

import SwiftUI

// MARK: - Namespace

/// `WK` ("Widget Kit") namespace — short to keep callsites tidy.
enum WK {

    // MARK: - Tokens

    enum Tokens {
        /// Outer corner radius for widget surfaces (matches iOS widget tray).
        static let surfaceRadius: CGFloat = 22
        /// Bullet / pill corner radius for line badges.
        static let badgeRadius: CGFloat = 8
        /// Default badge size used in lists.
        static let badgeListSize: CGFloat = 30
        /// Hero badge size used in single-route / small-widget heroes.
        static let badgeHeroSize: CGFloat = 56
        /// Progress track height.
        static let trackHeight: CGFloat = 6
        /// Inner padding for any surface.
        static let surfacePadding: CGFloat = 14
    }

    // MARK: - Tier (countdown-driven colour)

    /// Maps a remaining-minutes value to a colour tier so every widget's
    /// countdown / accent / progress bar uses the same urgency colour.
    enum Tier {
        case immediate, soon, comfortable, idle

        static func from(minutes: Int) -> Tier {
            if minutes <= 0 { return .immediate }
            if minutes <= 2 { return .immediate }
            if minutes <= 5 { return .soon }
            if minutes <= 12 { return .comfortable }
            return .idle
        }

        var color: Color {
            switch self {
            case .immediate:  return AppTheme.Colors.alertRed
            case .soon:       return AppTheme.Colors.successGreen
            case .comfortable: return AppTheme.Colors.accent
            case .idle:       return AppTheme.Colors.textPrimary
            }
        }
    }

    // MARK: - Mode helpers

    /// Resolves the brand colour for any line/route across all transit modes.
    static func brandColor(lineId: String, isBus: Bool, isLIRR: Bool = false,
                           isMNR: Bool = false) -> Color {
        if isLIRR { return AppTheme.Colors.accent.opacity(0.95) }
        if isMNR  { return AppTheme.Colors.successGreen }
        if isBus  { return AppTheme.BusColors.localBlue }
        return AppTheme.SubwayColors.color(for: lineId)
    }

    static func brandText(lineId: String, isBus: Bool) -> Color {
        if isBus { return .white }
        return AppTheme.SubwayColors.textColor(for: lineId)
    }

    static func icon(isBus: Bool, isCommuterRail: Bool = false) -> String {
        if isCommuterRail { return "tram.fill" }
        if isBus { return "bus.fill" }
        return "tram.fill"
    }
}

// MARK: - Surface

extension WK {
    /// Gradient card background that all widget views sit on top of.
    /// Use as `.containerBackground(for: .widget) { WK.Surface() }`
    /// or wrap a normal view with `.background { WK.Surface() }`.
    struct Surface: View {
        var tint: Color? = nil

        var body: some View {
            ZStack {
                AppTheme.Gradients.surface
                if let tint {
                    LinearGradient(
                        colors: [tint.opacity(0.18), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                // Subtle top sheen so the card has depth even in flat Light mode.
                LinearGradient(
                    colors: [Color.white.opacity(0.06), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        }
    }
}

// MARK: - Line Badge

extension WK {
    /// Square / pill bullet that displays a route's identifier in its
    /// brand colour.  Works for subway letters, bus numbers, LIRR/MNR
    /// numbers and even multi-character SBS routes.
    struct LineBadge: View {
        let lineId: String
        var isBus: Bool = false
        var isLIRR: Bool = false
        var isMNR: Bool = false
        var size: CGFloat = WK.Tokens.badgeListSize
        /// Subway lines render as circles; buses / commuter rail render
        /// as rounded rectangles to fit longer identifiers.
        var shape: Shape = .auto

        enum Shape { case auto, circle, capsule }

        var body: some View {
            let bg = WK.brandColor(lineId: lineId, isBus: isBus,
                                   isLIRR: isLIRR, isMNR: isMNR)
            let fg = WK.brandText(lineId: lineId, isBus: isBus)
            let resolvedShape: Shape = {
                if shape != .auto { return shape }
                return (isBus || isLIRR || isMNR || lineId.count > 1) ? .capsule : .circle
            }()
            let display = lineId.uppercased()

            ZStack {
                background(shape: resolvedShape, color: bg, size: size)
                Text(display)
                    .font(.system(
                        size: size * (display.count <= 1 ? 0.55 : 0.42),
                        weight: .heavy,
                        design: .rounded
                    ))
                    .foregroundColor(fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, size * 0.18)
            }
            .frame(
                width: resolvedShape == .circle ? size : nil,
                height: size
            )
            .frame(minWidth: size)
        }

        @ViewBuilder
        private func background(shape: Shape, color: Color, size: CGFloat) -> some View {
            switch shape {
            case .circle, .auto:
                Circle().fill(color)
            case .capsule:
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .fill(color)
            }
        }
    }
}

// MARK: - Live Dot

extension WK {
    /// Pulsing red dot + "LIVE" label used as a header indicator.
    struct LiveDot: View {
        var compact: Bool = false
        @State private var pulse = false

        var body: some View {
            HStack(spacing: 4) {
                Circle()
                    .fill(AppTheme.Colors.alertRed)
                    .frame(width: compact ? 4 : 5, height: compact ? 4 : 5)
                    .scaleEffect(pulse ? 1.25 : 0.85)
                    .opacity(pulse ? 1 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: pulse
                    )
                    .onAppear { pulse = true }
                Text("LIVE")
                    .font(.system(size: compact ? 8 : 9, weight: .black, design: .rounded))
                    .tracking(0.5)
                    .foregroundColor(AppTheme.Colors.alertRed)
            }
        }
    }
}

// MARK: - Countdown Label

extension WK {
    /// Big, color-tiered countdown label.  Renders "NOW", "1m", "12m"
    /// or — when `style == .timer` — the system live timer text style
    /// for a true ticking second-by-second display.
    struct CountdownLabel: View {
        let arrivalTime: Date
        var size: CGFloat = 28
        var style: Style = .compact
        /// Override the tier-driven tint (e.g. successGreen for the
        /// Dynamic Island pill so it matches the onboarding mock).
        var tint: Color? = nil

        enum Style {
            /// "12m" / "1m" / "NOW" — fixed text, refreshes per timeline.
            case compact
            /// `Text(date, style: .timer)` — live ticking countdown.
            case timer
        }

        var body: some View {
            let mins = TrackingTimeSync.remainingMinutes(until: arrivalTime)
            let tier = WK.Tier.from(minutes: mins)
            let color = tint ?? tier.color

            Group {
                if mins <= 0 {
                    Text("NOW")
                        .font(.system(size: size * 0.85, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, size * 0.35)
                        .padding(.vertical, size * 0.10)
                        .background(Capsule().fill(AppTheme.Colors.alertRed))
                } else if style == .timer {
                    Text(arrivalTime, style: .timer)
                        .font(.system(size: size, weight: .bold, design: .rounded))
                        .foregroundColor(color)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(mins)")
                            .font(.system(size: size, weight: .bold, design: .rounded))
                            .foregroundColor(color)
                            .monospacedDigit()
                        Text("m")
                            .font(.system(size: size * 0.55, weight: .semibold,
                                          design: .rounded))
                            .foregroundColor(color.opacity(0.7))
                            .padding(.bottom, size * 0.08)
                    }
                }
            }
        }
    }
}

// MARK: - Live Activity Pill (mirrors onboarding mockup)

extension WK {
    /// Black capsule that mirrors the Dynamic Island preview shown
    /// during onboarding.  Used as the lock-screen banner so the user
    /// recognises it immediately from the onboarding hero.
    struct LiveActivityPill: View {
        let lineId: String
        let stopName: String
        let arrivalTime: Date
        var isBus: Bool = false
        var isLIRR: Bool = false
        var isMNR: Bool = false

        @State private var pulse = false

        var body: some View {
            HStack(spacing: 12) {
                LineBadge(
                    lineId: lineId,
                    isBus: isBus,
                    isLIRR: isLIRR,
                    isMNR: isMNR,
                    size: 30
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(stopName)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    CountdownLabel(
                        arrivalTime: arrivalTime,
                        size: 13,
                        style: .timer,
                        tint: AppTheme.Colors.successGreen
                    )
                }

                Spacer(minLength: 0)

                Image(systemName: "dot.radiowaves.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.successGreen)
                    .scaleEffect(pulse ? 1.0 : 0.8)
                    .opacity(pulse ? 1.0 : 0.55)
                    .animation(
                        .easeInOut(duration: 0.9)
                            .repeatForever(autoreverses: true),
                        value: pulse
                    )
                    .onAppear { pulse = true }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(.black)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
        }
    }
}

// MARK: - Progress Track

extension WK {
    /// Thin progress bar with a glowing dot at the play-head.
    /// Used by Live Activity and the in-app banner.
    struct ProgressTrack: View {
        /// 0...1.  Clamped internally.
        let progress: Double
        var color: Color = AppTheme.Colors.accent
        var height: CGFloat = WK.Tokens.trackHeight

        var body: some View {
            GeometryReader { geo in
                let p = max(0, min(1, progress))
                let dotSize = height * 2.2

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.Colors.borderSubtle)
                        .frame(height: height)

                    Capsule()
                        .fill(LinearGradient(
                            colors: [color.opacity(0.85), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: max(height, geo.size.width * p),
                               height: height)

                    Circle()
                        .fill(color)
                        .frame(width: dotSize, height: dotSize)
                        .shadow(color: color.opacity(0.55), radius: 4)
                        .offset(x: max(0, geo.size.width * p - dotSize / 2))
                }
                .frame(height: dotSize, alignment: .center)
            }
            .frame(height: height * 2.2)
        }
    }
}

// MARK: - Arrival Row

extension WK {
    /// Single horizontal row: badge + name/stop + live timer.
    /// Used by the medium / large nearby widgets and by the
    /// "next 3 arrivals" stack inside the single-route widget.
    struct ArrivalRow: View {
        let lineId: String
        let stopName: String
        let direction: String
        let arrivalTime: Date
        var isBus: Bool = false
        var isLIRR: Bool = false
        var isMNR: Bool = false
        var compact: Bool = false

        var body: some View {
            HStack(spacing: compact ? 8 : 10) {
                LineBadge(lineId: lineId, isBus: isBus, isLIRR: isLIRR,
                          isMNR: isMNR,
                          size: compact ? 26 : WK.Tokens.badgeListSize)

                VStack(alignment: .leading, spacing: 1) {
                    Text(stopName)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold,
                                      design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(direction)
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                CountdownLabel(arrivalTime: arrivalTime,
                               size: compact ? 18 : 20)
            }
        }
    }
}

// MARK: - Header

extension WK {
    /// Top-of-widget header with optional LIVE indicator and label.
    struct Header: View {
        let title: String
        var showLive: Bool = true
        var trailing: String? = nil

        var body: some View {
            HStack(spacing: 6) {
                if showLive { LiveDot(compact: true) }
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Empty / Paused States

extension WK {
    /// Generic empty state used when the widget has no data to show
    /// (e.g. "no arrivals nearby" / "outside scheduled hours").
    struct EmptyState: View {
        let icon: String
        let title: String
        var subtitle: String? = nil
        var tint: Color = AppTheme.Colors.textSecondary

        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        }
    }
}
