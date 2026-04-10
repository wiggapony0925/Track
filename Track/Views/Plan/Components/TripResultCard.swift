// Premium trip result card — Gantt timeline, live countdown,
// glass-highlighted recommended card, layered route badges,
// and rich depth cues.

import SwiftUI

struct TripResultCard: View {
    let trip: TripPlan
    let onTap: () -> Void
    var isRecommended: Bool = false

    private var minutesUntilDeparture: Int {
        Int(trip.departureTime.timeIntervalSinceNow / 60)
    }

    private var arrivalTimeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: trip.arrivalTime)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 14) {
                topRow
                timelineBar.padding(.vertical, 2)
                bottomRow
            }
            .padding(16)
            .background(cardBackground)
        }
        .buttonStyle(TripCardButtonStyle())
    }

    // MARK: - Top Row

    private var topRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Go at \(trip.departureTimeString)")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    if isRecommended {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                            Text("BEST")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [AppTheme.Colors.successGreen, AppTheme.Colors.successGreen.opacity(0.75)],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                                .shadow(color: AppTheme.Colors.successGreen.opacity(0.3), radius: 6, y: 2)
                        )
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                    Text("Arrive \(arrivalTimeString)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(trip.durationString)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                HStack(spacing: 8) {
                    // Transfers
                    HStack(spacing: 3) {
                        Image(systemName: trip.numTransfers == 0 ? "arrow.right" : "arrow.triangle.swap")
                            .font(.system(size: 8, weight: .bold))
                        Text(trip.numTransfers == 0 ? "Direct" : "\(trip.numTransfers) xfer")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(AppTheme.Colors.textTertiary)

                    // Countdown badge
                    if minutesUntilDeparture >= 0 && minutesUntilDeparture <= 60 {
                        Text("in \(minutesUntilDeparture)m")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(
                                minutesUntilDeparture <= 3
                                    ? AppTheme.Colors.alertRed
                                    : AppTheme.Colors.accent
                            )
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(
                                        minutesUntilDeparture <= 3
                                            ? AppTheme.Colors.alertRed.opacity(0.12)
                                            : AppTheme.Colors.accent.opacity(0.1)
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(
                                                minutesUntilDeparture <= 3
                                                    ? AppTheme.Colors.alertRed.opacity(0.15)
                                                    : AppTheme.Colors.accent.opacity(0.12),
                                                lineWidth: 0.5
                                            )
                                    )
                        )
                    }
                }

                if trip.disruptionLevel != "normal" || trip.reliabilityScore < 85 {
                    Text(trip.disruptionLevel != "normal" ? "Live disruption" : "Tight connection")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            trip.disruptionLevel != "normal"
                                ? AppTheme.Colors.warningYellow
                                : AppTheme.Colors.accent
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                trip.disruptionLevel != "normal"
                                    ? AppTheme.Colors.warningYellow.opacity(0.12)
                                    : AppTheme.Colors.accent.opacity(0.1)
                            )
                        )
                }
            }
        }
    }

    // MARK: - Timeline Bar

    private var timelineBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(trip.legs) { leg in
                    legSegment(leg, totalWidth: geo.size.width)
                }
            }
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func legSegment(_ leg: TripLeg, totalWidth: CGFloat) -> some View {
        let fraction = max(
            CGFloat(leg.durationMinutes) / CGFloat(max(trip.totalDurationMinutes, 1)),
            0.06
        )
        let width = max(totalWidth * fraction, leg.mode == .walk ? 24 : 46)

        if leg.mode == .walk || leg.mode == .transfer {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(AppTheme.Colors.textTertiary.opacity(0.35))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(width: width, height: 44)
            .background(AppTheme.Colors.cardInset.opacity(0.35))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(legColor(leg))

                // Glass shimmer top-edge
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.2), location: 0),
                                .init(color: .clear, location: 0.45),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                HStack(spacing: 3) {
                    if leg.mode == .lirr || leg.mode == .mnr {
                        Image(systemName: leg.mode.icon)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Text(leg.routeId ?? "")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(textColorForLeg(leg))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .frame(width: width, height: 44)
            .shadow(color: legColor(leg).opacity(0.25), radius: 4, y: 2)
        }
    }

    // MARK: - Bottom Row

    private var bottomRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(displayRouteChips.enumerated()), id: \.offset) { index, chip in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.4))
                }
                routeChipView(chip)
            }

            Spacer()

            if let alert = trip.primaryAlert {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(alert.severity.capitalized)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(AppTheme.Colors.warningYellow)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(AppTheme.Colors.warningYellow.opacity(0.12))
                )
            } else if trip.totalWalkMeters > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 10, weight: .semibold))
                    Text(walkString)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(AppTheme.Colors.cardInset.opacity(0.5))
                        .overlay(
                            Capsule()
                                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.1), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    @ViewBuilder
    private func routeChipView(_ chip: TripRouteChip) -> some View {
        if chip.isWalk {
            HStack(spacing: 4) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 10, weight: .bold))
                Text(chip.label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(AppTheme.Colors.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(AppTheme.Colors.cardInset.opacity(0.45))
            )
        } else if let routeId = chip.routeId {
            RouteBadge(
                routeID: routeId,
                size: .small,
                mode: chip.routeMode.flatMap(modeString)
            )
        } else {
            Text(chip.label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(AppTheme.Colors.cardInset.opacity(0.45))
                )
        }
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)

            // Glass highlight
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isRecommended ? 0.06 : 0.02), location: 0),
                            .init(color: .clear, location: 0.35),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )

            // Border
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isRecommended
                        ? LinearGradient(
                            colors: [AppTheme.Colors.accent.opacity(0.4), AppTheme.Colors.accent.opacity(0.15)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [AppTheme.Colors.borderSubtle.opacity(0.25), AppTheme.Colors.borderSubtle.opacity(0.1)],
                            startPoint: .top, endPoint: .bottom
                        ),
                    lineWidth: isRecommended ? 1.5 : 0.5
                )
        }
        .shadow(
            color: isRecommended ? AppTheme.Colors.accent.opacity(0.14) : .black.opacity(0.06),
            radius: isRecommended ? 20 : 10,
            y: isRecommended ? 6 : 3
        )
    }

    // MARK: - Helpers

    private var walkString: String {
        if trip.totalWalkMeters > 1609 {
            return String(format: "%.1f mi", trip.totalWalkMeters / 1609.34)
        }
        return "\(Int(trip.totalWalkMeters))m"
    }

    private var displayRouteChips: [TripRouteChip] {
        if !trip.routeChips.isEmpty {
            return Array(trip.routeChips.prefix(5))
        }
        return trip.legs.map { leg in
            TripRouteChip(
                kind: leg.isTransit ? "transit" : "walk",
                label: leg.isTransit
                    ? (leg.routeId ?? leg.routeName ?? leg.mode.label)
                    : "Walk \(leg.durationMinutes)m",
                routeId: leg.routeId,
                colorHex: leg.routeColor,
                mode: leg.mode.rawValue,
                durationSeconds: leg.durationMinutes * 60,
                walkMeters: leg.walkMeters
            )
        }
    }

    private func modeString(_ mode: TripLegMode) -> String? {
        switch mode {
        case .bus:  return "bus"
        case .lirr: return "lirr"
        case .mnr:  return "mnr"
        default:    return nil
        }
    }

    private func legColor(_ leg: TripLeg) -> Color {
        if let hex = leg.routeColor, !hex.isEmpty {
            return Color(hex: hex)
        }
        switch leg.mode {
        case .subway:  return AppTheme.SubwayColors.color(for: leg.routeId ?? "")
        case .bus:     return AppTheme.BusColors.localBlue
        case .lirr:    return AppTheme.CommuterRailColors.lirrBlue
        case .mnr:     return AppTheme.CommuterRailColors.mnrBlue
        default:       return AppTheme.Colors.textTertiary
        }
    }

    private func textColorForLeg(_ leg: TripLeg) -> Color {
        if leg.mode == .subway, let routeId = leg.routeId {
            return AppTheme.SubwayColors.textColor(for: routeId)
        }
        return .white
    }
}

// MARK: - Button Style

private struct TripCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    VStack(spacing: 12) {
        TripResultCard(
            trip: TripPlan(
                departureTime: Date().addingTimeInterval(5 * 60),
                arrivalTime: Date().addingTimeInterval(66 * 60),
                totalDurationMinutes: 61,
                legs: [
                    TripLeg(
                        mode: .bus, routeId: "Q9", routeName: "Q9",
                        routeColor: "#D42781", headsign: "Main St",
                        boardStopName: "Start", alightStopName: "Middle",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(1200),
                        numStops: 8, durationMinutes: 20
                    ),
                    TripLeg(
                        mode: .walk, routeId: nil, routeName: nil,
                        routeColor: nil, headsign: nil,
                        boardStopName: "Middle", alightStopName: "Station",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(180),
                        numStops: 0, durationMinutes: 3
                    ),
                    TripLeg(
                        mode: .subway, routeId: "E", routeName: "E Train",
                        routeColor: "#EB6800", headsign: "WTC",
                        boardStopName: "Station", alightStopName: "Penn",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(1800),
                        numStops: 12, durationMinutes: 31
                    ),
                ],
                totalWalkMeters: 400,
                numTransfers: 1
            ),
            onTap: {},
            isRecommended: true
        )
    }
    .padding()
    .background(Color.black)
}
