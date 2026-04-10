// Clean vertical timeline visualization for trip itinerary.
// Colored connectors, compact leg rows, live status badges,
// and polished walk segments.

import SwiftUI

struct TripTimelineView: View {
    let trip: TripPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(trip.legs.enumerated()), id: \.element.id) { index, leg in
                legRow(leg, isFirst: index == 0, isLast: index == trip.legs.count - 1)
            }
        }
    }

    // MARK: - Leg Row

    @ViewBuilder
    private func legRow(_ leg: TripLeg, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Time column
            VStack(spacing: 0) {
                Text(timeString(leg.departureTime))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(width: 48, alignment: .trailing)

                Spacer(minLength: 0)

                if isLast {
                    Text(timeString(leg.arrivalTime))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            // Vertical connector
            VStack(spacing: 0) {
                // Top dot
                ZStack {
                    if isFirst {
                        Circle()
                            .fill(AppTheme.Colors.accent.opacity(0.15))
                            .frame(width: 16, height: 16)
                    }
                    Circle()
                        .fill(isFirst ? AppTheme.Colors.accent : legBarColor(leg))
                        .frame(width: 10, height: 10)
                }

                // Connecting line
                if leg.isTransit {
                    Rectangle()
                        .fill(legBarColor(leg))
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                } else {
                    GeometryReader { geo in
                        Path { path in
                            let x = geo.size.width / 2
                            var y: CGFloat = 0
                            while y < geo.size.height {
                                path.move(to: CGPoint(x: x, y: y))
                                path.addLine(to: CGPoint(x: x, y: min(y + 4, geo.size.height)))
                                y += 8
                            }
                        }
                        .stroke(AppTheme.Colors.textTertiary.opacity(0.35), lineWidth: 2)
                    }
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                }

                // Bottom dot (destination on last leg)
                if isLast {
                    ZStack {
                        Circle()
                            .fill(AppTheme.Colors.alertRed.opacity(0.15))
                            .frame(width: 16, height: 16)
                        Circle()
                            .fill(AppTheme.Colors.alertRed)
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .frame(width: 16)

            // Leg detail content
            VStack(alignment: .leading, spacing: 6) {
                // Board stop
                Text(leg.boardStopName)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)

                if leg.isTransit {
                    // Route badge + headsign
                    HStack(spacing: 7) {
                        if let routeId = leg.routeId {
                            RouteBadge(
                                routeID: routeId,
                                size: .small,
                                mode: modeString(leg.mode)
                            )
                        }
                        if let headsign = leg.headsign {
                            Text("→ \(headsign)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.Colors.cardInset.opacity(0.4))
                    )

                    // Stops + duration
                    HStack(spacing: 10) {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.circle")
                                .font(.system(size: 9, weight: .semibold))
                            Text("\(leg.numStops) stops")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(AppTheme.Colors.textTertiary)

                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9, weight: .semibold))
                            Text("\(leg.durationMinutes) min")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                    }

                    // Live status
                    if let liveLabel = leg.liveStatus?.shortLabel, !liveLabel.isEmpty {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(
                                    (leg.liveStatus?.status == "delayed" || leg.liveStatus?.status == "cancelled")
                                        ? AppTheme.Colors.warningYellow
                                        : AppTheme.Colors.successGreen
                                )
                                .frame(width: 6, height: 6)
                            Text(liveLabel)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(
                            (leg.liveStatus?.status == "delayed" || leg.liveStatus?.status == "cancelled")
                                ? AppTheme.Colors.warningYellow
                                : AppTheme.Colors.successGreen
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(AppTheme.Colors.cardInset.opacity(0.4))
                        )
                    }

                    // Alert
                    if let alert = leg.alerts.first {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(alert.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(2)
                        }
                        .foregroundStyle(AppTheme.Colors.warningYellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(AppTheme.Colors.warningYellow.opacity(0.08))
                        )
                    }
                } else {
                    // Walk leg
                    HStack(spacing: 5) {
                        Image(systemName: "figure.walk")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Walk \(leg.durationMinutes) min")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(AppTheme.Colors.cardInset.opacity(0.35))
                    )
                }

                // Alight stop (destination on last leg)
                if isLast {
                    Spacer().frame(height: 6)
                    HStack(spacing: 5) {
                        Image(systemName: "mappin")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.alertRed)
                        Text(leg.alightStopName)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 4)

            Spacer(minLength: 0)
        }
        .frame(minHeight: leg.isTransit ? 90 : 50)
    }

    // MARK: - Helpers

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f.string(from: date)
    }

    private func legBarColor(_ leg: TripLeg) -> Color {
        switch leg.mode {
        case .subway:
            return AppTheme.SubwayColors.color(for: leg.routeId ?? "")
        case .bus:
            return AppTheme.BusColors.localBlue
        case .lirr:
            return AppTheme.CommuterRailColors.lirrBlue
        case .mnr:
            return AppTheme.CommuterRailColors.mnrBlue
        case .walk, .transfer:
            return AppTheme.Colors.textTertiary
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
}

#Preview {
    ScrollView {
        TripTimelineView(
            trip: TripPlan(
                departureTime: Date(),
                arrivalTime: Date().addingTimeInterval(3660),
                totalDurationMinutes: 61,
                legs: [
                    TripLeg(
                        mode: .bus, routeId: "Q9", routeName: "Q9",
                        routeColor: "#D42781", headsign: "Springfield Blvd",
                        boardStopName: "125th St / Jamaica Ave",
                        alightStopName: "Hillside Ave / Parsons Blvd",
                        departureTime: Date(),
                        arrivalTime: Date().addingTimeInterval(1200),
                        numStops: 8, durationMinutes: 20
                    ),
                    TripLeg(
                        mode: .walk, routeId: nil, routeName: nil,
                        routeColor: nil, headsign: nil,
                        boardStopName: "Hillside Ave / Parsons Blvd",
                        alightStopName: "Parsons Blvd Station",
                        departureTime: Date().addingTimeInterval(1200),
                        arrivalTime: Date().addingTimeInterval(1380),
                        numStops: 0, durationMinutes: 3
                    ),
                    TripLeg(
                        mode: .subway, routeId: "E", routeName: "E Train",
                        routeColor: "#EB6800", headsign: "World Trade Center",
                        boardStopName: "Parsons Blvd",
                        alightStopName: "34 St-Penn Station",
                        departureTime: Date().addingTimeInterval(1500),
                        arrivalTime: Date().addingTimeInterval(3360),
                        numStops: 12, durationMinutes: 31
                    ),
                ],
                totalWalkMeters: 400,
                numTransfers: 1
            )
        )
        .padding()
    }
    .background(Color.black)
}