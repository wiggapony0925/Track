// Transit-style trip result row — proportional Gantt timeline bar
// with route labels inside, walk dots, "or" alternative badges,
// "Go in X min" countdown, and total duration. Matches Transit app.

import SwiftUI

struct TripResultCard: View {
    let trip: TripPlan
    let onTap: () -> Void
    var isRecommended: Bool = false

    private var minutesUntilDeparture: Int {
        Int(trip.departureTime.timeIntervalSinceNow / 60)
    }

    private let barHeight: CGFloat = 36

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // "or" alternative route badges (above the bar)
                alternativeRoutesRow
                    .padding(.bottom, 4)

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

    // MARK: - Alternative Routes Row ("or" badges above transit legs)

    private var alternativeRoutesRow: some View {
        GeometryReader { geo in
            let segments = computeSegments(totalWidth: geo.size.width)

            ZStack(alignment: .leading) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.leg.isTransit, let alts = alternativeRoutes(for: segment.leg), !alts.isEmpty {
                        HStack(spacing: 2) {
                            Text("or")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                            ForEach(alts, id: \.self) { altRouteId in
                                RouteBadge(
                                    routeID: altRouteId,
                                    size: .custom(18, 9),
                                    mode: modeString(segment.leg.mode)
                                )
                            }
                        }
                        .offset(x: segment.offset + segment.width - 40)
                    }
                }
            }
        }
        .frame(height: 22)
    }

    // MARK: - Timeline Bar (Gantt)

    private var timelineBar: some View {
        GeometryReader { geo in
            let segments = computeSegments(totalWidth: geo.size.width)

            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                    if segment.leg.mode == .walk || segment.leg.mode == .transfer {
                        walkSegment(width: segment.width, isFirst: idx == 0, isLast: idx == segments.count - 1)
                    } else {
                        transitSegment(segment.leg, width: segment.width, isFirst: idx == 0, isLast: idx == segments.count - 1)
                    }
                }
            }
        }
        .frame(height: barHeight)
    }

    private func walkSegment(width: CGFloat, isFirst: Bool, isLast: Bool) -> some View {
        HStack(spacing: 0) {
            // Left connector dot
            Circle()
                .fill(AppTheme.Colors.textTertiary.opacity(0.5))
                .frame(width: 5, height: 5)

            // Connector line
            Rectangle()
                .fill(AppTheme.Colors.textTertiary.opacity(0.3))
                .frame(height: 3)

            // Right connector dot
            Circle()
                .fill(AppTheme.Colors.textTertiary.opacity(0.5))
                .frame(width: 5, height: 5)
        }
        .frame(width: width, height: barHeight)
    }

    private func transitSegment(_ leg: TripLeg, width: CGFloat, isFirst: Bool, isLast: Bool) -> some View {
        let color = legColor(leg)
        let corners = segmentCorners(isFirst: isFirst, isLast: isLast)

        return ZStack {
            // Solid color fill with selective rounding
            UnevenRoundedRectangle(
                topLeadingRadius: corners.topLeading,
                bottomLeadingRadius: corners.bottomLeading,
                bottomTrailingRadius: corners.bottomTrailing,
                topTrailingRadius: corners.topTrailing,
                style: .continuous
            )
            .fill(color)

            // Glass shimmer
            UnevenRoundedRectangle(
                topLeadingRadius: corners.topLeading,
                bottomLeadingRadius: corners.bottomLeading,
                bottomTrailingRadius: corners.bottomTrailing,
                topTrailingRadius: corners.topTrailing,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.15), location: 0),
                        .init(color: .white.opacity(0.04), location: 0.35),
                        .init(color: .clear, location: 0.6),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )

            // Route label inside bar
            if let routeId = leg.routeId {
                if width > 54 {
                    // Full label with icon
                    HStack(spacing: 4) {
                        if leg.mode == .bus {
                            Image(systemName: "bus.fill")
                                .font(.system(size: 11, weight: .bold))
                        }
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
                    // Icon only for very narrow segments
                    Image(systemName: leg.mode.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(textColorForLeg(leg))
                }
            }
        }
        .frame(width: width, height: barHeight)
    }

    private struct CornerRadii {
        let topLeading: CGFloat
        let bottomLeading: CGFloat
        let bottomTrailing: CGFloat
        let topTrailing: CGFloat
    }

    private func segmentCorners(isFirst: Bool, isLast: Bool) -> CornerRadii {
        let r: CGFloat = 8
        return CornerRadii(
            topLeading: isFirst ? r : 0,
            bottomLeading: isFirst ? r : 0,
            bottomTrailing: isLast ? r : 0,
            topTrailing: isLast ? r : 0
        )
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
        let urgent = minutesUntilDeparture <= 3
        let color = urgent ? AppTheme.Colors.successGreen : AppTheme.Colors.successGreen

        return HStack(spacing: 4) {
            Text("Go in")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text(minutesUntilDeparture <= 0 ? "now" : "\(minutesUntilDeparture) min")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(color)

            // Live indicator
            Image(systemName: "dot.radiowaves.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
        }
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

    /// Find alternative routes that serve the same stops as this leg
    private func alternativeRoutes(for leg: TripLeg) -> [String]? {
        // Use routeChips to find alternatives for this leg
        let transitChips = trip.routeChips.filter { !$0.isWalk && $0.routeId != nil }
        guard let chipForLeg = transitChips.first(where: { $0.routeId == leg.routeId }) else {
            return nil
        }
        // Return other transit chips that share the same mode
        let alts = transitChips
            .filter { $0.routeId != chipForLeg.routeId && $0.mode == chipForLeg.mode }
            .compactMap { $0.routeId }
        return alts.isEmpty ? nil : Array(alts.prefix(3))
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
