// Visual layout for a single arrival chip.
//
// Behavior decisions live in `ArrivalChipLogic` and the data model
// in `ArrivalChipData` — this file is only concerned with how the
// chip looks.
//
// Sizing:
//   - First chip: 116 × 168 (Transit-style hero departure card)
//   - Other chips:  92 × 138 (compact departure cards)
//
// Vertical stack (top → bottom):
//   1. top grabber / shine
//   2. live/scheduled state
//   3. big departure time
//   4. compact metadata tags
//   5. clock and vehicle footer

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
        (isFirst || isSelected) && !isSched && !isCancelled
    }

    // MARK: Colors
    private var chipAccent: Color {
        isCancelled
            ? AppTheme.Colors.alertRed
            : isSched
                ? AppTheme.Colors.textSecondary
                : (chip.isTrackedOnly && !isSelected)
                    ? AppTheme.Colors.textSecondary
                    : accentColor
    }

    private var tagLabel: String {
        isCancelled ? "Cancelled"
            : isSched ? "Sched"
            : chip.isRealTime ? "Live"
            : "En Route"
    }

    private struct MetadataTag: Identifiable {
        let id: String
        let label: String
        let compactLabel: String
        let color: Color

        init(id: String, label: String, compactLabel: String? = nil, color: Color) {
            self.id = id
            self.label = label
            self.compactLabel = compactLabel ?? label
            self.color = color
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            topGrabber
            primaryStatusPill
                .padding(.top, isFirst ? 10 : 8)
            Spacer(minLength: isFirst ? 10 : 7)
            etaCounter
            Spacer(minLength: isFirst ? 6 : 4)
            if !metadataTags.isEmpty {
                metadataTray
            }
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

    private var topGrabber: some View {
        Capsule()
            .fill(
                usesSolidAccentCard
                    ? AnyShapeStyle(.white.opacity(0.34))
                    : (isSched || chip.isTrackedOnly)
                    ? AnyShapeStyle(AppTheme.Colors.textSecondary.opacity(0.12))
                    : AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                chipAccent.opacity(0.30),
                                chipAccent.opacity(0.12),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                      )
            )
            .frame(width: isFirst ? 42 : 30, height: isFirst ? 5 : 4)
            .padding(.top, isFirst ? 11 : 10)
    }

    private var primaryStatusPill: some View {
        Text(tagLabel)
            .font(.system(size: isFirst ? 9 : 8, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundStyle(statusForeground)
            .padding(.horizontal, isFirst ? 7 : 5)
            .padding(.vertical, isFirst ? 3 : 2.5)
            .background(Capsule().fill(statusBackground))
            .dynamicTypeSize(...DynamicTypeSize.large)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 7)
    }

    private var metadataTags: [MetadataTag] {
        var tags: [MetadataTag] = []

        // Variant / express — only on hero chip; non-first chips stay clean.
        if isFirst {
            if chip.serviceVariant.showsPill {
                tags.append(MetadataTag(
                    id: "variant",
                    label: chip.variantLabel ?? chip.serviceVariant.displayLabel,
                    compactLabel: chip.serviceVariant.displayLabel,
                    color: chip.serviceVariant.tintColor(routeColor: chipAccent)
                ))
            } else if chip.isExpress {
                tags.append(MetadataTag(
                    id: "express",
                    label: "Exp",
                    color: chipAccent
                ))
            }
        }

        // High-signal warnings: stalled / delayed. Worth showing on every chip.
        if chip.isStalled {
            tags.append(MetadataTag(
                id: "stalled",
                label: "Stalled",
                compactLabel: "Stall",
                color: AppTheme.Colors.alertRed
            ))
        } else if let delay = chip.delayBadge {
            tags.append(MetadataTag(
                id: "delay",
                label: delay.label,
                compactLabel: compactDelayLabel(delay.label),
                color: delay.isLate ? Color.orange : Color.blue
            ))
        }

        // Hero chip: surface proximity ("approaching", "1 stop away") and
        // genuine quality issues. Drop "Tracked" (redundant with "Live"
        // status pill) and "Est" (low-confidence noise that clutters the row).
        if isFirst {
            if let quality = chip.liveQualityBadge,
               quality != "Est" {
                tags.append(MetadataTag(
                    id: "live-quality",
                    label: quality,
                    compactLabel: compactQualityLabel(quality),
                    color: AppTheme.Colors.textSecondary
                ))
            }
            if let proximity = chip.arrivalProximityText,
               !proximity.isEmpty,
               !chip.isNow {
                tags.append(MetadataTag(
                    id: "proximity",
                    label: proximity,
                    compactLabel: compactProximityLabel(proximity),
                    color: chipAccent
                ))
            }
        }

        return tags
    }

    private var metadataTray: some View {
        let allTags = metadataTags
        let visibleCount = metadataVisibleCount(for: allTags)
        let visibleTags = Array(allTags.prefix(visibleCount))
        let hiddenCount = max(0, allTags.count - visibleTags.count)
        return HStack(spacing: 3) {
            ForEach(visibleTags) { tag in
                metadataToken(tag)
            }
            if hiddenCount > 0 {
                overflowToken(count: hiddenCount)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 7)
        .padding(.bottom, 4)
    }

    private func metadataVisibleCount(for tags: [MetadataTag]) -> Int {
        guard !tags.isEmpty else { return 0 }
        // Hero chip: at most two badges to keep the row breathable.
        // Up-next chips: a single badge (only ever delay/stalled now).
        if isFirst { return min(tags.count, 2) }
        return min(tags.count, 1)
    }

    private func metadataToken(_ tag: MetadataTag) -> some View {
        Text(isFirst ? tag.label : tag.compactLabel)
            .font(.system(size: isFirst ? 8.5 : 8, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .foregroundStyle(usesSolidAccentCard ? .white.opacity(0.92) : tag.color)
            .padding(.horizontal, isFirst ? 6 : 4)
            .padding(.vertical, isFirst ? 3.5 : 2.5)
            .frame(maxWidth: isFirst ? 68 : 44)
            .background(
                Capsule().fill(
                    usesSolidAccentCard ? .white.opacity(0.18) : tag.color.opacity(0.12)
                )
            )
            .accessibilityLabel(tag.label)
            .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private func overflowToken(count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: isFirst ? 8.5 : 8, weight: .heavy, design: .rounded))
            .foregroundStyle(
                usesSolidAccentCard
                    ? .white.opacity(0.92)
                    : AppTheme.Colors.textSecondary
            )
            .padding(.horizontal, isFirst ? 6 : 5)
            .padding(.vertical, isFirst ? 3 : 2.5)
            .background(
                Capsule().fill(
                    usesSolidAccentCard
                        ? .white.opacity(0.18)
                        : AppTheme.Colors.textSecondary.opacity(0.12)
                )
            )
            .accessibilityLabel("\(count) more tags")
            .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private func compactDelayLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "Late ", with: "+")
            .replacingOccurrences(of: "Early ", with: "-")
    }

    private func compactQualityLabel(_ label: String) -> String {
        label == "At stop" ? "At" : label
    }

    private func compactProximityLabel(_ label: String) -> String {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("approach") { return "Near" }
        if normalized.contains("at stop") { return "At" }
        if normalized.contains("stop away") || normalized.contains("stops away") {
            let digits = normalized.prefix { $0.isNumber }
            return digits.isEmpty ? "Near" : "\(digits)st"
        }
        return label
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
                Text(chip.departureDate, style: .time)
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
        .padding(.vertical, 3.5)
        .background(
            Capsule().fill(bgColor)
        )
        .padding(.bottom, chip.busDisplayId == nil ? 10 : 4)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    /// "#1234"-style footer for bus chips.  Bus vehicle IDs are
    /// painted on the bus exterior and are useful to riders who
    /// want to confirm the right bus pulled up.  Trains have no
    /// equivalent rider-visible identifier, so this is bus-only.
    private func busFooter(id: String) -> some View {
        Text("#\(id)")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(
            usesSolidAccentCard
                ? .white.opacity(0.78)
                : AppTheme.Colors.textSecondary.opacity(0.55)
        )
        .padding(.bottom, 8)
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
                                .init(color: chipAccent.opacity(0.98), location: 0.0),
                                .init(color: chipAccent.opacity(0.92), location: 0.72),
                                .init(color: chipAccent.opacity(0.84), location: 1.0),
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
                                .init(color: Color.white.opacity(isSched ? 0.82 : 0.88), location: 0.0),
                                .init(
                                    color: AppTheme.Colors.cardBackground.opacity(isSched ? 0.88 : 0.82),
                                    location: 0.32
                                ),
                                .init(
                                    color: AppTheme.Colors.cardFloating.opacity(isSched ? 0.92 : 0.86),
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
                ? AppTheme.Colors.shadow.opacity(0.05)
                : chipAccent.opacity(usesSolidAccentCard ? 0.28 : (isFirst ? 0.12 : 0.07)),
            radius: usesSolidAccentCard ? 18 : (isFirst ? 12 : 8),
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
