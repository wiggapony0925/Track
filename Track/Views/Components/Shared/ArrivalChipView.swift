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
    /// True when the backend is tracking this trip in real-time (SIRI/GTFS-RT)
    /// but no GPS marker is visible on the map yet.  Distinct from `isScheduled`
    /// (no real-time data at all) and full live (marker on map, tappable).
    var isTrackedOnly: Bool = false
    let arrivalTimestamp: Int?
    let vehicleId: String?
    let tripId: String?
    /// Raw route ID from the arrival (e.g. "7X", "6X") — used to detect express.
    var routeId: String? = nil
    /// Server-provided express flag — true for subway express routes
    /// (A, B, D, E, 2-5, N, Q, Z, 6X, 7X, FX) and SBS/express/limited buses.
    /// Falls back to client-side detection for backward compat.
    var isExpressFromServer: Bool = false

    /// Express subway variants end in "X" (6X, 7X, FX).
    private static let expressVariants: Set<String> = ["6X", "7X", "FX"]
    var isExpress: Bool {
        if isExpressFromServer { return true }
        // Fallback: client-side detection for older backends
        guard let rid = routeId?.uppercased() else { return false }
        return Self.expressVariants.contains(rid)
    }

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
    /// CRITICAL: When the vehicle has GPS data (non-nil vehicleId),
    /// only show NOW when isAtStop is true (GPS confirms < 50m).
    /// This prevents buses stuck in traffic from showing NOW just
    /// because the feed timestamp counted down to 0.
    var isNow: Bool {
        guard !isScheduled, !isCancelled else { return false }
        if isAtStop { return true }
        // If we have a live vehicle with GPS, require isAtStop — the feed
        // timer alone is unreliable in congested corridors.
        if vehicleId != nil { return false }
        // No vehicle GPS → use feed countdown as before (scheduled/static only)
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
    private var chipWidth: CGFloat { isFirst ? 108 : 86 }
    private var chipHeight: CGFloat { isFirst ? 152 : 124 }
    private var cornerR: CGFloat { isFirst ? 20 : 18 }

    private var usesSolidAccentCard: Bool {
        isFirst && !isSched && !isCancelled
    }

    // MARK: Derived colors
    private var chipAccent: Color {
        isCancelled
            ? AppTheme.Colors.alertRed
            : isSched
                ? AppTheme.Colors.textSecondary
                : chip.isTrackedOnly
                    ? accentColor.opacity(0.55)
                    : accentColor
    }

    private var tagLabel: String {
        isCancelled ? "Cancelled"
            : isSched ? "Sched"
            : chip.isTrackedOnly ? "Tracked"
            : chip.isRealTime ? "Live"
            : "En Route"
    }

    private var tagIcon: String {
        isCancelled ? "xmark.circle.fill"
            : isSched ? "calendar.circle"
            : chip.isTrackedOnly ? "dot.radiowaves.up.forward"
            : chip.isRealTime ? "antenna.radiowaves.left.and.right"
            : "location.circle"
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            accentBar
            statusTag
            if chip.isExpress {
                expressIndicator
            }
            Spacer(minLength: 6)
            etaCounter
            Spacer(minLength: 5)
            secondaryLabel
        }
        .frame(width: chipWidth, height: chipHeight, alignment: .top)
        .background { cardBackground }
        .overlay { cardBorder }
        .overlay { glassHighlight }
        .scaleEffect(isSelected ? 1.06 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isSelected)
        .onTapGesture { onTap?() }
    }

    // MARK: – Subviews

    private var accentBar: some View {
        Capsule()
            .fill(
                usesSolidAccentCard
                    ? AnyShapeStyle(.white.opacity(0.45))
                    : isSched
                    ? AnyShapeStyle(chipAccent.opacity(0.12))
                    : AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                chipAccent.opacity(isFirst ? 0.95 : 0.72),
                                chipAccent.opacity(isFirst ? 0.42 : 0.26),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                      )
            )
            .frame(width: isFirst ? 46 : 32, height: isFirst ? 3.5 : 3)
            .padding(.top, 11)
    }

    private var statusTag: some View {
        HStack(spacing: 3) {
            Image(systemName: tagIcon)
                .font(.system(size: 7.5, weight: .bold))
            Text(tagLabel)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(statusForeground)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(statusBackground)
        )
        .padding(.top, 7)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var etaCounter: some View {
        ArrivalChipETA(
            mins: chip.minutesRemaining,
            isNow: chip.isNow,
            isSched: isSched,
            isFirst: isFirst,
            departureDate: chip.departureDate,
            accentColor: chipAccent,
            usesAccentCard: usesSolidAccentCard
        )
    }

    @ViewBuilder
    private var secondaryLabel: some View {
        let foreColor: Color = isSched
            ? AppTheme.Colors.textSecondary.opacity(0.45)
            : usesSolidAccentCard
                ? .white.opacity(0.92)
                : chipAccent.opacity(0.8)
        let bgColor: Color = isSched
            ? AppTheme.Colors.textSecondary.opacity(0.06)
            : usesSolidAccentCard
                ? .white.opacity(0.18)
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
        .padding(.vertical, 4)
        .background(
            Capsule().fill(bgColor)
        )
        .padding(.bottom, 11)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    /// Small "Exp" diamond indicator for express arrivals.
    private var expressIndicator: some View {
        HStack(spacing: 2) {
            // Mini diamond shape
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(usesSolidAccentCard ? Color.white.opacity(0.9) : chipAccent)
                .frame(width: 7, height: 7)
                .rotationEffect(.degrees(45))
            Text("Exp")
                .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                .foregroundStyle(usesSolidAccentCard ? .white.opacity(0.92) : chipAccent)
        }
        .padding(.top, 2)
    }

    private var cardBackground: some View {
        ZStack {
            if usesSolidAccentCard {
                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: chipAccent.opacity(0.96), location: 0.0),
                                .init(color: chipAccent.opacity(0.88), location: 0.68),
                                .init(color: chipAccent.opacity(0.80), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: AppTheme.Colors.chipGlassHighlight.opacity(isSched ? 0.72 : 0.58), location: 0.0),
                                .init(
                                    color: AppTheme.Colors.cardBackground.opacity(isSched ? 0.78 : 0.62),
                                    location: 0.32
                                ),
                                .init(
                                    color: AppTheme.Colors.cardFloating.opacity(isSched ? 0.85 : 0.72),
                                    location: 1.0
                                ),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            if !isSched && !usesSolidAccentCard {
                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                chipAccent.opacity(isFirst ? 0.12 : 0.06),
                                chipAccent.opacity(isFirst ? 0.05 : 0.02),
                                .clear,
                            ],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: chipHeight * 0.8
                        )
                    )
            }
        }
        .shadow(
            color: isSched
                ? .clear
                : chipAccent.opacity(usesSolidAccentCard ? 0.24 : (isFirst ? 0.16 : 0.08)),
            radius: usesSolidAccentCard ? 18 : (isFirst ? 14 : 8),
            x: 0,
            y: usesSolidAccentCard ? 10 : (isFirst ? 8 : 5)
        )
        .shadow(
            color: usesSolidAccentCard
                ? .white.opacity(0.06)
                : isFirst && !isSched
                ? chipAccent.opacity(0.06) : .clear,
            radius: 24, x: 0, y: 12
        )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: cornerR, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(
                            color: isSelected
                                ? chipAccent.opacity(0.8)
                                : usesSolidAccentCard
                                    ? AppTheme.Colors.chipGlassHighlight.opacity(0.28)
                                : isSched
                                    ? AppTheme.Colors.chipBorder
                                    : chipAccent.opacity(isFirst ? 0.22 : 0.1),
                            location: 0
                        ),
                        .init(
                            color: isSelected
                                ? chipAccent.opacity(0.4)
                                : .clear,
                            location: 1
                        ),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: isSelected ? 1.8 : 0.6
            )
    }

    /// Glass highlight — subtle top-edge shine
    private var glassHighlight: some View {
        RoundedRectangle(cornerRadius: cornerR, style: .continuous)
            .fill(
                LinearGradient(
                    stops: [
                        .init(
                            color: AppTheme.Colors.chipGlassHighlight.opacity(
                                usesSolidAccentCard ? 0.18 : (isSched ? 0.02 : 0.08)
                            ),
                            location: 0
                        ),
                        .init(color: .clear, location: 0.42),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
    }

    private var statusForeground: Color {
        if isCancelled { return AppTheme.Colors.alertRed }
        if isSched { return AppTheme.Colors.textSecondary.opacity(0.60) }
        if usesSolidAccentCard { return .white.opacity(0.92) }
        return chipAccent
    }

    private var statusBackground: Color {
        if isCancelled { return AppTheme.Colors.alertRed.opacity(0.10) }
        if isSched { return AppTheme.Colors.textSecondary.opacity(0.07) }
        if usesSolidAccentCard { return .white.opacity(0.18) }
        return chipAccent.opacity(0.11)
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

    // MARK: – Private helpers

    private var nowLabel: some View {
        Text("NOW")
            .font(.system(size: isFirst ? 28 : 22, weight: .heavy, design: .rounded))
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
            .font(.system(size: isFirst ? 21 : 16, weight: .heavy, design: .rounded))
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
                .font(.system(size: isFirst ? 38 : 31, weight: .heavy, design: .rounded))
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

// MARK: - Scheduled-only Chip (used in the empty-state fallback)

/// A lighter-weight chip for scheduled departures that don't have a
/// live NearbyTransitResponse behind them.
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
            // Glass highlight
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

    // MARK: - Sub-views (extracted to reduce body type-check)

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

// MARK: - ScheduledChipStrip (horizontal row of scheduled-only chips)

/// Horizontal scrolling strip of scheduled departure chips, used as the
/// empty-state fallback when no live vehicles are near the stop.
struct ScheduledChipStrip: View {
    let departures: [ScheduledItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                SectionHeader(title: "Scheduled Departures", size: 10, tracking: 1.0, color: AppTheme.Colors.textSecondary.opacity(0.5))

                // Fading line after label
                LinearGradient(
                    colors: [
                        AppTheme.Colors.textSecondary.opacity(0.1),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 0.5)
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
