// Transit-style trip result card — proportional Gantt timeline,
// "Go in X min" countdown, route badges above bar, compact
// premium card with glass depth cues.

import SwiftUI

struct TripResultCard: View {
    let trip: TripPlan
    let onTap: () -> Void
    var isRecommended: Bool = false

    private var minutesUntilDeparture: Int {
        Int(trip.departureTime.timeIntervalSinceNow / 60)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Row 1: Countdown + Duration
                countdownRow
                    .padding(.bottom, 10)

                // Row 2: Route badges above timeline
                routeBadgeRow
                    .padding(.bottom, 6)

                // Row 3: Proportional Gantt timeline bar
                timelineBar
                    .padding(.bottom, 10)

                // Row 4: Departure → Arrival + meta
                detailRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(cardBackground)
        }
        .buttonStyle(TripCardButtonStyle())
    }

    // MARK: - Countdown Row

    private var countdownRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // "Go in X min" or "Go now"
            if minutesUntilDeparture >= 0 && minutesUntilDeparture <= 120 {
                HStack(spacing: 6) {
                    countdownBadge
                    if isRecommended {
                        bestBadge
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Text("Departs \(trip.departureTimeString)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    if isRecommended {
                        bestBadge
                    }
                }
            }

            Spacer()

            // Duration
            Text(trip.durationString)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            // Disruption / alert indicator
            if trip.disruptionLevel != "normal" {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.warningYellow)
                    .padding(.leading, 6)
            } else if let alert = trip.primaryAlert {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(
                        alert.severity == "warning"
                            ? AppTheme.Colors.warningYellow
                            : AppTheme.Colors.alertRed
                    )
                    .padding(.leading, 6)
            }
        }
    }

    private var countdownBadge: some View {
        let urgent = minutesUntilDeparture <= 3
        let label: String = {
            if minutesUntilDeparture <= 0 { return "Go now" }
            return "Go in \(minutesUntilDeparture) min"
        }()

        return Text(label)
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundStyle(urgent ? AppTheme.Colors.alertRed : AppTheme.Colors.accent)
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

    // MARK: - Route Badge Row

    private var routeBadgeRow: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let segments = computeSegments(totalWidth: totalWidth)

                ZStack(alignment: .leading) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.leg.isTransit {
                            badgeForLeg(segment.leg)
                                .offset(x: segment.offset + (segment.width / 2) - 14)
                        }
                    }
                }
            }
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private func badgeForLeg(_ leg: TripLeg) -> some View {
        if let routeId = leg.routeId {
            RouteBadge(
                routeID: routeId,
                size: .small,
                mode: modeString(leg.mode)
            )
        } else {
            Image(systemName: leg.mode.icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(legColor(leg))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(legColor(leg).opacity(0.15))
                )
        }
    }

    // MARK: - Timeline Bar (Gantt)

    private var timelineBar: some View {
        GeometryReader { geo in
            let segments = computeSegments(totalWidth: geo.size.width)

            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.leg.mode == .walk || segment.leg.mode == .transfer {
                        walkSegment(width: segment.width)
                    } else {
                        transitSegment(segment.leg, width: segment.width)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(height: 28)
    }

    private func walkSegment(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(0..<min(Int(width / 8), 5), id: \.self) { _ in
                Circle()
                    .fill(AppTheme.Colors.textTertiary.opacity(0.4))
                    .frame(width: 4, height: 4)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: 28)
        .background(AppTheme.Colors.cardInset.opacity(0.5))
    }

    private func transitSegment(_ leg: TripLeg, width: CGFloat) -> some View {
        let color = legColor(leg)

        return ZStack {
            // Solid color fill
            Rectangle()
                .fill(color)

            // Glass shimmer
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.18), location: 0),
                            .init(color: .white.opacity(0.06), location: 0.3),
                            .init(color: .clear, location: 0.6),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            // Route label inside bar (only if wide enough)
            if width > 40, let routeId = leg.routeId {
                Text(routeId)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(textColorForLeg(leg))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: width, height: 28)
    }

    // MARK: - Detail Row

    private var detailRow: some View {
        HStack(spacing: 0) {
            // Departure time
            Text(trip.departureTimeString)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textTertiary)

            // Arrow
            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.5))
                .padding(.horizontal, 5)

            // Arrival time
            Text(trip.arrivalTimeString)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textTertiary)

            Spacer()

            // Transfer count
            HStack(spacing: 4) {
                Image(systemName: trip.numTransfers == 0 ? "arrow.right" : "arrow.triangle.swap")
                    .font(.system(size: 9, weight: .bold))
                Text(trip.numTransfers == 0 ? "Direct" : "\(trip.numTransfers) xfer")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .foregroundStyle(AppTheme.Colors.textTertiary)

            // Walk distance
            if trip.totalWalkMeters > 50 {
                HStack(spacing: 3) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 9, weight: .semibold))
                    Text(walkString)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .padding(.leading, 10)
            }
        }
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)

            // Glass highlight for recommended
            if isRecommended {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.04), location: 0),
                                .init(color: .clear, location: 0.3),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            }

            // Border
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isRecommended
                        ? LinearGradient(
                            colors: [AppTheme.Colors.accent.opacity(0.35), AppTheme.Colors.accent.opacity(0.1)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [AppTheme.Colors.borderSubtle.opacity(0.2), AppTheme.Colors.borderSubtle.opacity(0.08)],
                            startPoint: .top, endPoint: .bottom
                        ),
                    lineWidth: isRecommended ? 1.2 : 0.5
                )
        }
        .shadow(
            color: isRecommended ? AppTheme.Colors.accent.opacity(0.1) : .black.opacity(0.04),
            radius: isRecommended ? 16 : 8,
            y: isRecommended ? 4 : 2
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
        let minTransitWidth: CGFloat = 36
        let minWalkWidth: CGFloat = 20

        // First pass: compute raw proportional widths
        var rawWidths: [CGFloat] = trip.legs.map { leg in
            let fraction = CGFloat(leg.durationMinutes) / CGFloat(totalDuration)
            let minW = (leg.mode == .walk || leg.mode == .transfer) ? minWalkWidth : minTransitWidth
            return max(totalWidth * fraction, minW)
        }

        // Normalize so they sum to totalWidth
        let rawSum = rawWidths.reduce(0, +)
        if rawSum > 0 {
            let scale = totalWidth / rawSum
            rawWidths = rawWidths.map { $0 * scale }
        }

        // Build segment info with offsets
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

    private var walkString: String {
        if trip.totalWalkMeters > 1609 {
            return String(format: "%.1f mi", trip.totalWalkMeters / 1609.34)
        }
        let mins = Int(trip.totalWalkMeters / 83.0)
        return "\(mins) min"
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

        TripResultCard(
            trip: TripPlan(
                departureTime: Date().addingTimeInterval(15 * 60),
                arrivalTime: Date().addingTimeInterval(75 * 60),
                totalDurationMinutes: 60,
                legs: [
                    TripLeg(
                        mode: .subway, routeId: "1", routeName: "1 Train",
                        routeColor: "#EE352E", headsign: "South Ferry",
                        boardStopName: "168 St", alightStopName: "Times Sq",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(1500),
                        numStops: 10, durationMinutes: 25
                    ),
                    TripLeg(
                        mode: .transfer, routeId: nil, routeName: nil,
                        routeColor: nil, headsign: nil,
                        boardStopName: "Times Sq", alightStopName: "Times Sq",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(180),
                        numStops: 0, durationMinutes: 3
                    ),
                    TripLeg(
                        mode: .subway, routeId: "7", routeName: "7 Train",
                        routeColor: "#B933AD", headsign: "Flushing",
                        boardStopName: "Times Sq", alightStopName: "Flushing",
                        departureTime: Date(), arrivalTime: Date().addingTimeInterval(1920),
                        numStops: 15, durationMinutes: 32
                    ),
                ],
                totalWalkMeters: 200,
                numTransfers: 1
            ),
            onTap: {},
            isRecommended: false
        )
    }
    .padding()
    .background(Color.black)
}
