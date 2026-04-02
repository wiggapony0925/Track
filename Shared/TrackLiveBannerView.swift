// A shared view that replicates the iOS Lock Screen Live Activity banner.
// Used by:
// 1. The actual Live Activity (TrackWidgetLiveActivity)
// 2. Medium-sized Home Screen Widgets
// 3. The Widget settings preview page

import SwiftUI
import AppIntents

struct TrackLiveBannerData {
    let lineId: String
    let destination: String
    let isBus: Bool
    let isLIRR: Bool
    let arrivalTime: Date
    let proximityText: String
    /// Minutes away for urgency styling.
    let minutesAway: Int?
    let walkMinutes: Int?
    let isHurryUp: Bool
    let progress: Double
    let nextArrivals: [Int] // Minutes for next arrivals
}

struct TrackLiveBannerView: View {
    let data: TrackLiveBannerData
    let showActionButton: Bool

    var body: some View {
        VStack(spacing: 0) {
            topSection
            middleProgressSection
            if showActionButton {
                actionButton
            }
        }
        .background { bannerBackground }
    }

    private var bannerBackground: some View {
        ZStack {
            Color.black
            let accentColor: Color = data.isBus
                ? AppTheme.Colors.mtaBlue
                : AppTheme.SubwayColors.color(for: data.lineId)
            LinearGradient(
                colors: [accentColor.opacity(0.12), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if data.isHurryUp {
                AppTheme.Colors.alertRed.opacity(0.1)
            }
        }
    }

    private var topSection: some View {
        HStack(alignment: .top, spacing: 12) {
            leftRouteContent
            Spacer()
            heroCountdownLockScreen()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var leftRouteContent: some View {
        HStack(alignment: .center, spacing: 10) {
            leftBadgeOrWalkIcon
            VStack(alignment: .leading, spacing: 0) {
                bannerTitleContent
                let proximityColor: Color = data.minutesAway == 1
                    ? AppTheme.Colors.alertRed : AppTheme.Colors.textSecondary
                Text(data.proximityText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(proximityColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder
    private var leftBadgeOrWalkIcon: some View {
        if let walk = data.walkMinutes {
            let bgColor: Color = data.isHurryUp
                ? AppTheme.Colors.alertRed.opacity(0.15)
                : Color.white.opacity(0.1)
            let iconName: String = walk <= 2 ? "figure.run" : "figure.walk"
            let iconColor: Color = data.isHurryUp ? AppTheme.Colors.alertRed : .white
            ZStack {
                Circle().fill(bgColor).frame(width: 44, height: 44)
                Image(systemName: iconName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(iconColor)
            }
        } else {
            lineBadge(size: 44)
        }
    }

    @ViewBuilder
    private var bannerTitleContent: some View {
        if data.isHurryUp {
            Text("Hurry up!")
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundColor(AppTheme.Colors.alertRed)
        } else if data.walkMinutes != nil {
            Text("Time to walk")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        } else {
            Text(data.destination)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.65)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var middleProgressSection: some View {
        VStack(spacing: 6) {
            progressSlider(progress: data.progress)

            HStack {
                if let walkMins = data.walkMinutes {
                    Label("\(walkMins) min walk", systemImage: "figure.walk")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                } else {
                    HStack(spacing: 4) {
                        lineBadge(size: 14, compact: true)
                        Text("to " + data.destination)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let next = data.nextArrivals.first {
                    Text("Next: \(next) min")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.8))
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, showActionButton ? 10 : 14)
    }

    // MARK: - Subcomponents

    @ViewBuilder
    private func heroCountdownLockScreen() -> some View {
        let accentColor =
            data.isBus
            ? AppTheme.Colors.mtaBlue
            : AppTheme.SubwayColors.color(for: data.lineId)

        VStack(alignment: .center, spacing: -2) {
            Text(data.arrivalTime, style: .timer)
                .font(.system(size: 40, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                // .contentTransition(.numericText(countsDown: true))
                // Requires iOS 16.2+, safe to omit in shared
                // view or wrap in available check if needed.
                // We'll leave it simple for widgets.
                .frame(minWidth: 80)
                .minimumScaleFactor(0.8)

            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accentColor)
                    .frame(width: 24, height: 3)
                Text("MIN")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accentColor)
                    .frame(width: 24, height: 3)
            }
        }
    }

    @ViewBuilder
    private func progressSlider(progress: Double) -> some View {
        let accentColor =
            data.isBus
            ? AppTheme.Colors.mtaBlue
            : AppTheme.SubwayColors.color(for: data.lineId)

        GeometryReader { geo in
            let clampedProgress = min(1.0, max(0.0, progress))
            let dotX = geo.size.width * clampedProgress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 8)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.4), accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, dotX), height: 8)

                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: accentColor.opacity(0.6), radius: 8, x: 0, y: 0)
                    Circle()
                        .fill(accentColor)
                        .frame(width: 9, height: 9)
                }
                .offset(x: max(0, dotX - 8))
            }
        }
        .frame(height: 16)
    }

    @ViewBuilder
    private func lineBadge(size: CGFloat, compact: Bool = false) -> some View {
        let color =
            data.isBus
            ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: data.lineId)
        let textColor =
            data.isBus
            ? .white : AppTheme.SubwayColors.textColor(for: data.lineId)

        if compact {
            if data.isBus {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(color)
                        .frame(width: size * 2.2, height: size)
                    Text(data.lineId)
                        .font(.system(size: size * 0.7, weight: .heavy, design: .rounded))
                        .foregroundColor(textColor)
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                }
            } else {
                ZStack {
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                    Text(data.lineId)
                        .font(.system(size: size * 0.7, weight: .heavy, design: .rounded))
                        .foregroundColor(textColor)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
        } else {
            ZStack {
                if data.isBus {
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
                    VStack(spacing: 0) {
                        Image(systemName: "bus.fill")
                            .font(.system(size: size * 0.22, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                        Text(data.lineId)
                            .font(.system(size: size * 0.32, weight: .heavy, design: .rounded))
                            .foregroundColor(textColor)
                            .minimumScaleFactor(0.4)
                            .lineLimit(1)
                    }
                } else {
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
                    Text(data.lineId)
                        .font(.system(size: size * 0.45, weight: .heavy, design: .rounded))
                        .foregroundColor(textColor)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
            .frame(width: data.isBus ? size * 1.3 : size, height: size)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
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
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Placeholder

extension TrackLiveBannerData {
    static var placeholderA: TrackLiveBannerData {
        TrackLiveBannerData(
            lineId: "A",
            destination: "Inwood-207 St",
            isBus: false,
            isLIRR: false,
            arrivalTime: Date().addingTimeInterval(298), // 4:58
            proximityText: "Waiting for next train...",
            minutesAway: nil,
            walkMinutes: nil,
            isHurryUp: false,
            progress: 0.1,
            nextArrivals: [12]
        )
    }
    
    static var placeholderB44: TrackLiveBannerData {
        TrackLiveBannerData(
            lineId: "B44",
            destination: "Williamsburg Bridge Plaza",
            isBus: true,
            isLIRR: false,
            arrivalTime: Date().addingTimeInterval(420), // 7:00
            proximityText: "2 min away",
            minutesAway: 2,
            walkMinutes: nil,
            isHurryUp: false,
            progress: 0.8,
            nextArrivals: [15, 23]
        )
    }
}
