// Lighter-weight chip for scheduled departures that don't have a
// live `NearbyTransitResponse` behind them.  Used in the empty-state
// fallback `ScheduledChipStrip` when no live vehicles are near the
// stop but the GTFS timetable still has departures to surface.

import SwiftUI

struct ScheduledChipView: View {
    let departure: ScheduledItem

    private let cornerR: CGFloat = 18

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
        .frame(width: 76)
        .frame(minHeight: 118)
        .background {
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .fill(AppTheme.Gradients.floating)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: AppTheme.Colors.chipGlassHighlight.opacity(0.04), location: 0),
                            .init(color: .clear, location: 0.3),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: AppTheme.Colors.chipBorder, location: 0),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
        }
    }

    // MARK: - Sub-views

    private var accentBar: some View {
        Capsule()
            .fill(AppTheme.Colors.textSecondary.opacity(0.15))
            .frame(width: 24, height: 2.5)
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
