// Compact proportional timeline bar — shows trip legs as colored segments
// with walk dots.  Reusable across TripDetailSheet summary card,
// TripResultCard, and RecentTripCard.

import SwiftUI

struct MiniTimelineBar: View {
    let legs: [TripLeg]
    var height: CGFloat = 10
    var barCornerRadius: CGFloat = 4
    var dotSize: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let totalDuration = max(1, legs.map(\.durationMinutes).reduce(0, +))

            HStack(spacing: 2) {
                ForEach(Array(legs.enumerated()), id: \.element.id) { _, leg in
                    let fraction = CGFloat(leg.durationMinutes) / CGFloat(totalDuration)
                    let segWidth = max(6, fraction * totalWidth)

                    if leg.mode == .walk || leg.mode == .transfer {
                        HStack(spacing: 3) {
                            ForEach(0..<max(1, Int(segWidth / 8)), id: \.self) { _ in
                                Circle()
                                    .fill(AppTheme.Colors.textTertiary.opacity(0.5))
                                    .frame(width: dotSize, height: dotSize)
                            }
                        }
                        .frame(width: segWidth, height: height)
                    } else {
                        RoundedRectangle(cornerRadius: barCornerRadius)
                            .fill(segmentColor(for: leg))
                            .frame(width: segWidth, height: height)
                    }
                }
            }
        }
        .frame(height: height)
    }

    private func segmentColor(for leg: TripLeg) -> Color {
        if let hex = leg.routeColor, !hex.isEmpty {
            return Color(hex: hex)
        }
        if let routeId = leg.routeId {
            let stripped = stripMTAAgencyPrefix(routeId)
            return AppTheme.SubwayColors.color(for: stripped)
        }
        return AppTheme.Colors.accent
    }
}

#Preview {
    MiniTimelineBar(legs: [
        TripLeg(
            mode: .bus, routeId: "Q9", routeName: "Q9",
            routeColor: "#D42781", headsign: "Springfield",
            boardStopName: "A", alightStopName: "B",
            departureTime: .now, arrivalTime: .now,
            numStops: 5, durationMinutes: 20
        ),
        TripLeg(
            mode: .walk, routeId: nil, routeName: nil,
            routeColor: nil, headsign: nil,
            boardStopName: "B", alightStopName: "C",
            departureTime: .now, arrivalTime: .now,
            numStops: 0, durationMinutes: 3
        ),
        TripLeg(
            mode: .subway, routeId: "E", routeName: "E",
            routeColor: "#0062CF", headsign: "WTC",
            boardStopName: "C", alightStopName: "D",
            departureTime: .now, arrivalTime: .now,
            numStops: 12, durationMinutes: 31
        ),
    ])
    .frame(height: 10)
    .padding()
    .preferredColorScheme(.dark)
}
