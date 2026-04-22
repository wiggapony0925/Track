// The big-number area inside an `ArrivalChipView`.  Renders one of:
//   - "NOW" word          (when chip.isNow)
//   - clock time          (when minutes > 75)
//   - large minute number (default)

import SwiftUI

struct ArrivalChipETA: View {
    let mins: Int
    let isNow: Bool
    let isSched: Bool
    let isFirst: Bool
    var departureDate: Date?
    var accentColor: Color = AppTheme.Colors.textPrimary
    var usesAccentCard: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            if isNow {
                nowLabel
            } else if mins > 75, let depDate = departureDate {
                clockLabel(depDate)
            } else {
                minutesLabel
            }
        }
        .monospacedDigit()
    }

    private var nowLabel: some View {
        Text("NOW")
            .font(.system(size: isFirst ? 30 : 23, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(
                usesAccentCard
                    ? AnyShapeStyle(.white)
                    : AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                AppTheme.Colors.countdown(0),
                                AppTheme.Colors.countdown(0).opacity(0.75),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .shadow(
                color: usesAccentCard
                    ? .white.opacity(0.18)
                    : AppTheme.Colors.countdown(0).opacity(0.5),
                radius: 12,
                x: 0,
                y: 2
            )
            .shadow(
                color: usesAccentCard
                    ? .clear
                    : AppTheme.Colors.countdown(0).opacity(0.15),
                radius: 24,
                x: 0,
                y: 4
            )
            .contentTransition(.numericText(countsDown: true))
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: mins)
            .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private func clockLabel(_ date: Date) -> some View {
        Text(date, format: .dateTime.hour().minute())
            .font(.system(size: isFirst ? 22 : 17, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .minimumScaleFactor(0.65)
            .foregroundStyle(
                usesAccentCard
                    ? .white.opacity(0.96)
                    : isSched
                        ? AppTheme.Colors.textSecondary.opacity(0.4)
                        : accentColor
            )
            .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var minutesLabel: some View {
        let countdownColor = isSched
            ? AppTheme.Colors.textSecondary.opacity(0.4)
            : AppTheme.Colors.countdown(mins)
        return VStack(spacing: 1) {
            Text("\(mins)")
                .font(.system(size: isFirst ? 40 : 33, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(
                    usesAccentCard
                        ? AnyShapeStyle(.white)
                        : isSched
                        ? AnyShapeStyle(countdownColor)
                        : AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    countdownColor,
                                    countdownColor.opacity(0.7),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                          )
                )
                .shadow(
                    color: usesAccentCard ? .white.opacity(0.14) : (isSched ? .clear : countdownColor.opacity(0.2)),
                    radius: 6, x: 0, y: 2
                )
                .contentTransition(.numericText(countsDown: true))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: mins)
            Text("MIN")
                .font(.system(size: isFirst ? 11 : 10, weight: .bold, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(
                    usesAccentCard
                        ? .white.opacity(0.82)
                        : isSched
                        ? AppTheme.Colors.textSecondary.opacity(0.3)
                        : AppTheme.Colors.textSecondary.opacity(0.5)
                )
                .tracking(1.2)
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}
