// Visual layout for a single arrival chip.
//
// Behavior decisions live in `ArrivalChipLogic` and the data model
// in `ArrivalChipData` — this file is only concerned with how the
// chip looks.
//
// Sizing:
//   - First chip: 116 × 168 (slightly larger primary card)
//   - Other chips:  92 × 138 (room for two-row tag stack + ETA + footer)
//
// Vertical stack (top → bottom):
//   1. accent bar           (3-4 pt)
//   2. tag row              (status pill + variant/express pill side by side)
//   3. ETA counter          (the big number)
//   4. secondary label      (clock time / "in N min")
//   5. bus footer (optional) (#1234 for buses only)

import SwiftUI

struct ArrivalChipView: View {
    let chip: ArrivalChipData
    let index: Int
    let accentColor: Color
    let isSelected: Bool
    var onTap: (() -> Void)?

    private var isFirst: Bool { index == 0 }
    private var isSched: Bool { chip.isScheduled }
    private var isCancelled: Bool { chip.isCancelled }

    // MARK: Layout
    private var chipWidth: CGFloat { isFirst ? 116 : 92 }
    private var chipHeight: CGFloat { isFirst ? 168 : 138 }
    private var cornerR: CGFloat { isFirst ? 20 : 18 }

    private var usesSolidAccentCard: Bool {
        isFirst && !isSched && !isCancelled && !chip.isTrackedOnly
    }

    // MARK: Colors
    private var chipAccent: Color {
        isCancelled
            ? AppTheme.Colors.alertRed
            : (isSched || chip.isTrackedOnly)
                ? AppTheme.Colors.textSecondary
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
            tagRow
            Spacer(minLength: 4)
            etaCounter
            Spacer(minLength: 4)
            secondaryLabel
            if let busId = chip.busDisplayId {
                busFooter(id: busId)
            }
        }
        .frame(width: chipWidth, height: chipHeight, alignment: .top)
        .background { cardBackground }
        .overlay { cardBorder }
        .overlay { glassHighlight }
        .scaleEffect(isSelected ? 1.06 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isSelected)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    // MARK: Subviews

    private var accentBar: some View {
        Capsule()
            .fill(
                usesSolidAccentCard
                    ? AnyShapeStyle(.white.opacity(0.45))
                    : (isSched || chip.isTrackedOnly)
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
            .frame(width: isFirst ? 50 : 36, height: isFirst ? 4 : 3)
            .padding(.top, 11)
    }

    /// Status tag + service-variant pill on the same line so they
    /// don't compete with the ETA number for vertical space.
    private var tagRow: some View {
        HStack(spacing: 4) {
            statusTag
            variantOrExpressIndicator
        }
        .padding(.top, 7)
        .padding(.horizontal, 6)
    }

    private var statusTag: some View {
        HStack(spacing: 3) {
            Image(systemName: tagIcon)
                .font(.system(size: 8, weight: .bold))
            Text(tagLabel)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(statusForeground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            Capsule()
                .fill(statusBackground)
        )
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    @ViewBuilder
    private var variantOrExpressIndicator: some View {
        if chip.serviceVariant.showsPill {
            ServiceVariantPill(
                variant: chip.serviceVariant,
                customLabel: chip.variantLabel,
                routeColor: chipAccent,
                isCompact: true
            )
        } else if chip.isExpress {
            expressIndicator
        }
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
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .foregroundStyle(foreColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(bgColor)
        )
        .padding(.bottom, chip.busDisplayId == nil ? 11 : 4)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    /// "#1234"-style footer for bus chips.  Bus vehicle IDs are
    /// painted on the bus exterior and are useful to riders who
    /// want to confirm the right bus pulled up.  Trains have no
    /// equivalent rider-visible identifier, so this is bus-only.
    private func busFooter(id: String) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: "bus.fill")
                .font(.system(size: 7.5, weight: .semibold))
            Text("#\(id)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(
            usesSolidAccentCard
                ? .white.opacity(0.78)
                : AppTheme.Colors.textSecondary.opacity(0.55)
        )
        .padding(.bottom, 9)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    /// Legacy "Exp" diamond for backends that haven't started
    /// sending the typed `service_variant` yet.
    private var expressIndicator: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(usesSolidAccentCard ? Color.white.opacity(0.9) : chipAccent)
                .frame(width: 7, height: 7)
                .rotationEffect(.degrees(45))
            Text("Exp")
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(usesSolidAccentCard ? .white.opacity(0.92) : chipAccent)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(
            Capsule().fill(chipAccent.opacity(0.12))
        )
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

    /// Subtle top-edge shine.
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
