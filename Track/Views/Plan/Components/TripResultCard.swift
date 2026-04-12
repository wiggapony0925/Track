// Transit-style trip result card — rounded transit pills, walk dots,
// gray connectors, "or" alternative badges, "Go in X min" countdown,
// and total duration. Matches Transit app card layout exactly.

import SwiftUI

struct TripResultCard: View {
    let trip: TripPlan
    let onTap: () -> Void
    var isRecommended: Bool = false

    private var minutesUntilDeparture: Int {
        Int(trip.departureTime.timeIntervalSinceNow / 60)
    }

    private let barHeight: CGFloat = 38

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // "or" alternatives row (when applicable)
                orBadgesRow

                // Proportional Gantt timeline bar
                timelineBar
                    .padding(.bottom, 10)

                // "Go in X min" + duration row
                infoRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(TripCardButtonStyle())
    }

    // MARK: - "or" Alternatives Row

    @ViewBuilder
    private var orBadgesRow: some View {
        let transitLegs = trip.legs.filter { $0.isTransit }
        let altChips = trip.routeChips.filter { !$0.isWalk }

        if altChips.count > transitLegs.count, !altChips.isEmpty {
            HStack(spacing: 4) {
                Spacer()
                Text("or")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textTertiary)

                ForEach(
                    Array(altChips.suffix(from: min(transitLegs.count, altChips.count))
                        .prefix(4).enumerated()),
                    id: \.offset
                ) { _, chip in
                    routeChipBadge(chip)
                }

                if altChips.count > transitLegs.count + 4 {
                    Text("+")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
            }
            .padding(.bottom, 5)
        }
    }

    private func routeChipBadge(_ chip: TripRouteChip) -> some View {
        let color: Color = {
            if let hex = chip.colorHex, !hex.isEmpty { return Color(hex: hex) }
            if let mode = chip.routeMode {
                switch mode {
                case .subway: return AppTheme.SubwayColors.color(for: chip.routeId ?? chip.label)
                case .bus:    return AppTheme.BusColors.localBlue
                case .lirr:   return AppTheme.CommuterRailColors.lirrBlue
                case .mnr:    return AppTheme.CommuterRailColors.mnrBlue
                default:      return AppTheme.Colors.textTertiary
                }
            }
            return AppTheme.Colors.textTertiary
        }()

        return ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color)
                .frame(width: 22, height: 22)
            Image(systemName: chip.routeMode?.icon ?? "tram.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Timeline Bar

    private var timelineBar: some View {
        GeometryReader { geo in
            let segments = computeSegments(totalWidth: geo.size.width)

            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                    segmentView(segment, index: idx, total: segments.count)
                }
            }
        }
        .frame(height: barHeight)
    }

    @ViewBuilder
    private func segmentView(_ segment: SegmentInfo, index: Int, total: Int) -> some View {
        if segment.leg.mode == .walk || segment.leg.mode == .transfer {
            if index == 0 || index == total - 1 {
                walkDots(width: segment.width)
            } else {
                walkConnector(width: segment.width)
            }
        } else {
            transitPill(segment.leg, width: segment.width)
        }
    }

    // Walk dots for edge walks (start/end of trip) — Transit-style gray circles
    private func walkDots(width: CGFloat) -> some View {
        let dotSize: CGFloat = 6
        let dotCount = max(2, min(Int(width / 12), 7))
        let totalDotsWidth = CGFloat(dotCount) * dotSize
        let spacing = dotCount > 1
            ? max((width - totalDotsWidth) / CGFloat(dotCount - 1), 4)
            : 0

        return HStack(spacing: spacing) {
            ForEach(0..<dotCount, id: \.self) { _ in
                Circle()
                    .fill(AppTheme.Colors.textTertiary.opacity(0.5))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .frame(width: width, height: barHeight)
    }

    // Gray connector line for mid-trip transfer walks
    private func walkConnector(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(AppTheme.Colors.textTertiary.opacity(0.3))
            .frame(width: max(width - 4, 8), height: 3)
            .frame(width: width, height: barHeight)
    }

    // Fully rounded transit pill — matches Transit app exactly
    private func transitPill(_ leg: TripLeg, width: CGFloat) -> some View {
        let color = legColor(leg)
        let radius: CGFloat = 10

        return ZStack {
            // Fully rounded colored pill
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(color)

            // Subtle glass shimmer
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.14), location: 0),
                            .init(color: .white.opacity(0.03), location: 0.35),
                            .init(color: .clear, location: 0.55),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            // Route label + vehicle icon inside pill
            if let routeId = leg.routeId {
                if width > 54 {
                    HStack(spacing: 4) {
                        Image(systemName: leg.mode.icon)
                            .font(.system(size: 12, weight: .bold))
                        Text(routeId)
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(textColorForLeg(leg))
                } else if width > 30 {
                    Text(routeId)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(textColorForLeg(leg))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    Image(systemName: leg.mode.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(textColorForLeg(leg))
                }
            }
        }
        .frame(width: width, height: barHeight)
        // Alert indicator
        .overlay(alignment: .bottomTrailing) {
            if !leg.alerts.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.warningYellow)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: 4, y: 4)
            }
        }
    }

    // MARK: - Info Row

    private var infoRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // "Go in X min" / "Go now"
            if minutesUntilDeparture >= 0 && minutesUntilDeparture <= 120 {
                goCountdown
            } else {
                Text("Departs \(trip.departureTimeString)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }

            if isRecommended {
                bestBadge
                    .padding(.leading, 8)
            }

            Spacer()

            // Total duration
            Text(trip.durationString)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
    }

    private var goCountdown: some View {
        HStack(spacing: 4) {
            Text(minutesUntilDeparture <= 0 ? "Go" : "Go in")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            HStack(spacing: 2) {
                Text(minutesUntilDeparture <= 0 ? "now" : "\(minutesUntilDeparture) min")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.successGreen)

                // Realtime broadcast indicator (like Transit app)
                if hasRealtimeData {
                    Image(systemName: "dot.radiowaves.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                }
            }
        }
    }

    private var hasRealtimeData: Bool {
        trip.legs.contains { $0.liveStatus?.isRealtime == true }
    }

    private var bestBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 7))
            Text("BEST")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [AppTheme.Colors.successGreen, AppTheme.Colors.successGreen.opacity(0.75)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
        )
    }

    // MARK: - Segment Computation

    private struct SegmentInfo {
        let leg: TripLeg
        let offset: CGFloat
        let width: CGFloat
    }

    private func computeSegments(totalWidth: CGFloat) -> [SegmentInfo] {
        let totalDuration = max(trip.totalDurationMinutes, 1)
        let minTransitWidth: CGFloat = 40
        let minWalkWidth: CGFloat = 28

        var rawWidths: [CGFloat] = trip.legs.map { leg in
            let fraction = CGFloat(leg.durationMinutes) / CGFloat(totalDuration)
            let minW = (leg.mode == .walk || leg.mode == .transfer) ? minWalkWidth : minTransitWidth
            return max(totalWidth * fraction, minW)
        }

        let rawSum = rawWidths.reduce(0, +)
        if rawSum > 0 {
            let scale = totalWidth / rawSum
            rawWidths = rawWidths.map { $0 * scale }
        }

        var result: [SegmentInfo] = []
        var currentOffset: CGFloat = 0
        for (index, leg) in trip.legs.enumerated() {
            let w = rawWidths[index]
            result.append(SegmentInfo(leg: leg, offset: currentOffset, width: w))
            currentOffset += w
        }
        return result
    }

    // MARK: - Helpers

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
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview {
    VStack(spacing: 0) {
        TripResultCard(
            trip: TripPlan(
                departureTime: Date().addingTimeInterval(7 * 60),
                arrivalTime: Date().addingTimeInterval(71 * 60),
                totalDurationMinutes: 64,
                legs: [
                    TripLeg(
                        mode: .walk, routeId: nil, routeName: nil,
                        routeColor: nil, headsign: nil,
                        boardStopName: "Home", alightStopName: "Bus Stop",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(420),
                        numStops: 0, durationMinutes: 7
                    ),
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
                        routeColor: nil, headsign: "WTC",
                        boardStopName: "Station", alightStopName: "Penn",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(1800),
                        numStops: 12, durationMinutes: 31
                    ),
                    TripLeg(
                        mode: .walk, routeId: nil, routeName: nil,
                        routeColor: nil, headsign: nil,
                        boardStopName: "Penn", alightStopName: "Dest",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(180),
                        numStops: 0, durationMinutes: 3
                    ),
                ],
                totalWalkMeters: 800,
                numTransfers: 1
            ),
            onTap: {},
            isRecommended: true
        )

        Divider().padding(.leading, 16)

        TripResultCard(
            trip: TripPlan(
                departureTime: Date().addingTimeInterval(20 * 60),
                arrivalTime: Date().addingTimeInterval(90 * 60),
                totalDurationMinutes: 70,
                legs: [
                    TripLeg(
                        mode: .walk, routeId: nil, routeName: nil,
                        routeColor: nil, headsign: nil,
                        boardStopName: "Home", alightStopName: "Stop",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(120),
                        numStops: 0, durationMinutes: 2
                    ),
                    TripLeg(
                        mode: .bus, routeId: "Q9", routeName: "Q9",
                        routeColor: "#D42781", headsign: "Main St",
                        boardStopName: "Stop", alightStopName: "Jamaica",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(1500),
                        numStops: 12, durationMinutes: 25
                    ),
                    TripLeg(
                        mode: .lirr, routeId: "LIRR", routeName: "Long Island Rail Road",
                        routeColor: "#4D5357", headsign: "Penn Station",
                        boardStopName: "Jamaica", alightStopName: "Penn Station",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(2400),
                        numStops: 4, durationMinutes: 40
                    ),
                    TripLeg(
                        mode: .walk, routeId: nil, routeName: nil,
                        routeColor: nil, headsign: nil,
                        boardStopName: "Penn", alightStopName: "Dest",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(180),
                        numStops: 0, durationMinutes: 3
                    ),
                ],
                totalWalkMeters: 300,
                numTransfers: 1
            ),
            onTap: {},
            isRecommended: false
        )
    }
    .background(Color.black)
}
