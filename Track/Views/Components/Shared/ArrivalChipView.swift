// A single countdown chip showing a transit arrival's ETA, status,
// and clock time. Designed for horizontal ScrollView strips.
// Extracted from RouteDetailSheet to be reusable across any context
// that needs to display arrival chips (detail sheet, widgets, etc.).

import SwiftUI

// MARK: - Chip Configuration

/// Lightweight value bag that decouples ArrivalChipView from
/// RouteDetailSheet's internal state and model types.
struct ArrivalChipData: Identifiable {
    let id: String
    let minutesRemaining: Int
    let secondsRemaining: Double
    let isAtStop: Bool
    let isRealTime: Bool
    let isCancelled: Bool
    let isScheduled: Bool
    let arrivalTimestamp: Int?
    let vehicleId: String?
    let tripId: String?

    /// Convenience: departure date derived from timestamp or projected.
    var departureDate: Date {
        if let ts = arrivalTimestamp {
            return Date(timeIntervalSince1970: Double(ts))
        }
        return Date().addingTimeInterval(Double(minutesRemaining) * 60)
    }

    /// Show "NOW" only when the vehicle is genuinely at the stop.
    /// Using 15 s (not 30 s) prevents multiple chips from flipping
    /// to "NOW" prematurely when arrivals are close together.
    var isNow: Bool {
        guard !isScheduled, !isCancelled else { return false }
        if isAtStop { return true }
        // Only count down to NOW when the arrival timestamp is very close
        // AND the prediction is backed by a live vehicle (not purely static).
        return isRealTime && secondsRemaining <= 15
    }
}

// MARK: - ArrivalChipView

struct ArrivalChipView: View {
    let chip: ArrivalChipData
    let index: Int
    let accentColor: Color
    let isSelected: Bool
    var onTap: (() -> Void)?

    private var isFirst: Bool { index == 0 }
    private var isSched: Bool { chip.isScheduled }
    private var isCancelled: Bool { chip.isCancelled }

    // MARK: Derived layout
    private var chipWidth: CGFloat { isFirst ? 96 : 78 }
    private var chipHeight: CGFloat { isFirst ? 140 : 122 }
    private let cornerR: CGFloat = 20

    // MARK: Derived colors
    private var chipAccent: Color {
        isCancelled
            ? AppTheme.Colors.alertRed
            : isSched
                ? AppTheme.Colors.textSecondary
                : accentColor
    }

    private var tagLabel: String {
        isCancelled ? "Cancelled"
            : isSched ? "Sched"
            : chip.isRealTime ? "Live"
            : "En Route"
    }

    private var tagIcon: String {
        isCancelled ? "xmark.circle.fill"
            : isSched ? "calendar.circle"
            : chip.isRealTime ? "antenna.radiowaves.left.and.right"
            : "location.circle"
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            accentBar
            statusTag
            Spacer(minLength: 4)
            etaCounter
            Spacer(minLength: 4)
            secondaryLabel
        }
        .frame(width: chipWidth)
        .frame(minHeight: chipHeight)
        .background { cardBackground }
        .overlay { cardBorder }
        .scaleEffect(isSelected ? 1.06 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isSelected)
        .onTapGesture { onTap?() }
    }

    // MARK: – Subviews

    private var accentBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                isSched
                    ? AnyShapeStyle(chipAccent.opacity(0.2))
                    : AnyShapeStyle(LinearGradient(
                        colors: [
                            chipAccent.opacity(isFirst ? 0.9 : 0.65),
                            chipAccent.opacity(isFirst ? 0.5 : 0.3)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                      ))
            )
            .frame(width: isFirst ? 40 : 30, height: 3)
            .padding(.top, 10)
    }

    private var statusTag: some View {
        HStack(spacing: 3) {
            Image(systemName: tagIcon)
                .font(.system(size: 7, weight: .semibold))
            Text(tagLabel)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(
            isCancelled
                ? AppTheme.Colors.alertRed
                : isSched
                    ? AppTheme.Colors.textSecondary.opacity(0.55)
                    : chipAccent
        )
        .padding(.top, 6)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var etaCounter: some View {
        ArrivalChipETA(
            mins: chip.minutesRemaining,
            isNow: chip.isNow,
            isSched: isSched,
            isFirst: isFirst,
            departureDate: chip.departureDate,
            accentColor: chipAccent
        )
    }

    @ViewBuilder
    private var secondaryLabel: some View {
        let foreColor: Color = isSched
            ? AppTheme.Colors.textSecondary.opacity(0.45)
            : chipAccent.opacity(0.8)
        let bgColor: Color = isSched
            ? AppTheme.Colors.textSecondary.opacity(0.06)
            : chipAccent.opacity(0.1)

        Group {
            if chip.minutesRemaining > 75 {
                Text("in \(chip.minutesRemaining) min")
            } else if let ts = chip.arrivalTimestamp {
                let date: Date = Date(timeIntervalSince1970: Double(ts))
                Text(date, style: .time)
            } else if isSched {
                Text(chip.departureDate, style: .time)
            } else {
                Text("")
            }
        }
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .foregroundStyle(foreColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            Capsule().fill(bgColor)
        )
        .padding(.bottom, 12)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: cornerR, style: .continuous)
            .fill(AppTheme.Gradients.floating)
            .overlay(
                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                    .fill(isFirst && !isSched ? chipAccent.opacity(0.03) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                    .stroke(AppTheme.Colors.borderSubtle, lineWidth: 1)
            )
            .shadow(
                color: isSched
                    ? .clear
                    : chipAccent.opacity(isFirst && !isSelected ? 0.18 : 0.08),
                radius: isFirst ? 16 : 8, x: 0, y: isFirst ? 8 : 6
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: cornerR, style: .continuous)
            .strokeBorder(
                isSelected
                    ? chipAccent.opacity(0.8)
                    : isSched
                        ? AppTheme.Colors.textSecondary.opacity(0.10)
                        : chipAccent.opacity(isFirst ? 0.25 : 0.12),
                lineWidth: isSelected ? 2.0 : 0.8
            )
    }
}

// MARK: - ArrivalChipETA (the big number area)

struct ArrivalChipETA: View {
    let mins: Int
    let isNow: Bool
    let isSched: Bool
    let isFirst: Bool
    var departureDate: Date?
    var accentColor: Color = AppTheme.Colors.textPrimary

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

    // MARK: – Private helpers

    private var nowLabel: some View {
        Text("NOW")
            .font(.system(size: isFirst ? 28 : 22, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(AppTheme.Colors.countdown(0))
            .shadow(color: AppTheme.Colors.countdown(0).opacity(0.35), radius: 8, x: 0, y: 2)
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
                isSched
                    ? AppTheme.Colors.textSecondary.opacity(0.4)
                    : accentColor
            )
            .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var minutesLabel: some View {
        VStack(spacing: 2) {
            Text("\(mins)")
                .font(.system(size: isFirst ? 38 : 30, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(
                    isSched
                        ? AppTheme.Colors.textSecondary.opacity(0.4)
                        : AppTheme.Colors.countdown(mins)
                )
                .contentTransition(.numericText(countsDown: true))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: mins)
            Text("MIN")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(
                    isSched
                        ? AppTheme.Colors.textSecondary.opacity(0.3)
                        : AppTheme.Colors.textSecondary.opacity(0.7)
                )
                .tracking(0.5)
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

// MARK: - Scheduled-only Chip (used in the empty-state fallback)

/// A lighter-weight chip for scheduled departures that don't have a
/// live NearbyTransitResponse behind them.
struct ScheduledChipView: View {
    let departure: ScheduledItem

    var body: some View {
        VStack(spacing: 0) {
            accentBar
            statusLabel
            Spacer(minLength: 4)
            primaryETA
            Spacer(minLength: 4)
            secondaryCapsule
        }
        .monospacedDigit()
        .frame(width: 78)
        .frame(minHeight: 122)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.Gradients.floating)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(AppTheme.Colors.borderSubtle, lineWidth: 1)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    AppTheme.Colors.textSecondary.opacity(0.10),
                    lineWidth: 0.8
                )
        }
    }

    // MARK: - Sub-views (extracted to reduce body type-check)

    private var accentBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(AppTheme.Colors.textSecondary.opacity(0.18))
            .frame(width: 28, height: 3)
            .padding(.top, 10)
    }

    private var statusLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "calendar.circle")
                .font(.system(size: 7, weight: .semibold))
            Text("Sched")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.45))
        .padding(.top, 6)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    @ViewBuilder
    private var primaryETA: some View {
        let mins: Int = departure.minutesAway
        if mins > 75 {
            Text(departure.departureDate, format: .dateTime.hour().minute())
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .minimumScaleFactor(0.65)
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
                .dynamicTypeSize(...DynamicTypeSize.large)
        } else {
            VStack(spacing: 2) {
                Text("\(mins)")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
                Text("MIN")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.3))
                    .tracking(0.5)
            }
            .dynamicTypeSize(...DynamicTypeSize.large)
        }
    }

    private var secondaryCapsule: some View {
        let mins: Int = departure.minutesAway
        let text: String = mins > 75 ? "in \(mins) min" : departure.formattedTime
        return Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(AppTheme.Colors.textSecondary.opacity(0.06))
            )
            .padding(.bottom, 12)
            .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

// MARK: - ScheduledChipStrip (horizontal row of scheduled-only chips)

/// Horizontal scrolling strip of scheduled departure chips, used as the
/// empty-state fallback when no live vehicles are near the stop.
struct ScheduledChipStrip: View {
    let departures: [ScheduledItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Text("Scheduled Departures")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(departures) { departure in
                        ScheduledChipView(departure: departure)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.vertical, 6)
            }
        }
    }
}
