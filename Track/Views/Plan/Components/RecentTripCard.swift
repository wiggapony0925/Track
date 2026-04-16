// Recent trip card — full-width card with proportional transit
// timeline bar, walk annotations, and clean origin / destination
// header.  Mirrors the TripResultCard design language exactly.

import SwiftUI

struct RecentTripCard: View {
    let trip: SavedTrip
    let onTap: () -> Void

    private let barHeight: CGFloat = 32

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Destination + origin + date
                headerRow
                    .padding(.bottom, 10)

                // Proportional Gantt timeline bar
                timelineBar
                    .padding(.bottom, 8)

                // Walk annotations + chevron
                footerRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(cardBackground)
        }
        .buttonStyle(RecentTripButtonStyle())
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(trip.destinationName)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text("from")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                    Text(trip.originName)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(dateLabel)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(AppTheme.Colors.cardInset.opacity(0.55))
                )
        }
    }

    // MARK: - Timeline Bar

    /// Comfortable minimum widths for legible labels.
    private let comfyTransitWidth: CGFloat = 52
    private let comfyWalkWidth: CGFloat = 30

    private var timelineBar: some View {
        GeometryReader { geo in
            let legs = Array(zip(trip.legSummary, trip.legModes))
            let naturalWidth = naturalBarWidth(legs: legs)
            let needsScroll = naturalWidth > geo.size.width

            let segments = needsScroll
                ? computeSegments(totalWidth: naturalWidth, comfortable: true)
                : computeSegments(totalWidth: geo.size.width, comfortable: false)

            let barContent = HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    if seg.mode == "walk" {
                        walkConnector(width: seg.width, duration: seg.walkMinutes,
                                      isEdge: idx == 0 || idx == segments.count - 1)
                    } else {
                        transitPill(routeId: seg.routeId, mode: seg.mode,
                                    width: seg.width)
                    }
                }
            }

            if needsScroll {
                ScrollView(.horizontal, showsIndicators: false) {
                    barContent
                        .frame(width: naturalWidth, height: barHeight)
                }
                .mask(
                    HStack(spacing: 0) {
                        Color.white
                        LinearGradient(colors: [.white, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 20)
                    }
                )
            } else {
                barContent
            }
        }
        .frame(height: barHeight)
    }

    private func naturalBarWidth(legs: [(String, String)]) -> CGFloat {
        legs.reduce(CGFloat(0)) { total, pair in
            total + (pair.1 == "walk" ? comfyWalkWidth : comfyTransitWidth)
        }
    }

    // Walk connector — dot · walking icon · dot between pills
    private func walkConnector(width: CGFloat, duration: Int, isEdge: Bool) -> some View {
        HStack(spacing: 4) {
            // Leading dot
            Circle()
                .fill(AppTheme.Colors.textTertiary.opacity(0.5))
                .frame(width: 6, height: 6)

            VStack(spacing: 1) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                if duration > 0 && width > 22 {
                    Text("\(duration)m")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            // Trailing dot
            Circle()
                .fill(AppTheme.Colors.textTertiary.opacity(0.5))
                .frame(width: 6, height: 6)
        }
        .frame(width: width, height: barHeight)
    }

    // Fully rounded transit pill — colored, with glass shimmer
    private func transitPill(routeId: String, mode: String, width: CGFloat) -> some View {
        let color = legColor(routeId: routeId, mode: mode)
        let textColor = textColorForLeg(routeId: routeId, mode: mode)
        let radius: CGFloat = 9

        return ZStack {
            // Colored pill
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(color)

            // Glass shimmer
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

            // Route label + mode icon
            if width > 50 {
                HStack(spacing: 3) {
                    Image(systemName: modeIcon(mode))
                        .font(.system(size: 10, weight: .bold))
                    Text(routeId)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(textColor)
            } else if width > 28 {
                Text(routeId)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Image(systemName: modeIcon(mode))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(textColor)
            }
        }
        .frame(width: width, height: barHeight)
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            let descriptions = walkDescriptions

            if !descriptions.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textTertiary)

                    Text(descriptions.joined(separator: "  ·  "))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
            } else {
                // Direct transit — no walks
                Text("Direct")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }

            Spacer()

            if trip.usageCount > 1 {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(trip.usageCount)x")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(AppTheme.Colors.accent.opacity(0.7))
                .padding(.trailing, 10)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.32))
        }
    }

    // MARK: - Segment Computation

    private struct SegmentInfo {
        let routeId: String
        let mode: String
        let walkMinutes: Int
        let width: CGFloat
    }

    private func computeSegments(totalWidth: CGFloat, comfortable: Bool) -> [SegmentInfo] {
        let legs = Array(zip(trip.legSummary, trip.legModes))
        guard !legs.isEmpty else { return [] }

        let minTransit: CGFloat = comfortable ? comfyTransitWidth : 36
        let minWalk: CGFloat = comfortable ? comfyWalkWidth : 24

        // Weights: transit legs get 10 units, walks get their duration (min 2)
        let weights: [CGFloat] = legs.map { routeId, mode in
            if mode == "walk" {
                return max(CGFloat(extractWalkMinutes(routeId)), 2)
            }
            return 10
        }

        let totalWeight = max(weights.reduce(0, +), 1)

        // Proportional widths with minimums
        var widths: [CGFloat] = weights.enumerated().map { idx, w in
            let raw = totalWidth * (w / totalWeight)
            let minW: CGFloat = legs[idx].1 == "walk" ? minWalk : minTransit
            return max(raw, minW)
        }

        // Scale to fit total width exactly
        let sum = widths.reduce(0, +)
        if sum > 0 {
            let scale = totalWidth / sum
            widths = widths.map { $0 * scale }
        }

        return legs.enumerated().map { idx, pair in
            SegmentInfo(
                routeId: pair.0,
                mode: pair.1,
                walkMinutes: extractWalkMinutes(pair.0),
                width: widths[idx]
            )
        }
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        Color.clear
    }

    // MARK: - Helpers

    private func extractWalkMinutes(_ routeId: String) -> Int {
        let parts = routeId.components(separatedBy: " ")
        if let minIdx = parts.firstIndex(of: "min"), minIdx > 0,
           let val = Int(parts[minIdx - 1]) {
            return val
        }
        return 0
    }

    private var walkDescriptions: [String] {
        var descriptions: [String] = []
        let legs = Array(zip(trip.legSummary, trip.legModes))
        for (index, pair) in legs.enumerated() {
            let (routeId, mode) = pair
            guard mode == "walk" else { continue }
            let mins = extractWalkMinutes(routeId)
            guard mins > 0 else { continue }

            if index == 0 {
                if let next = legs.dropFirst(index + 1).first(where: { $0.1 != "walk" }) {
                    descriptions.append("\(mins) min to \(next.0)")
                } else {
                    descriptions.append("\(mins) min walk")
                }
            } else if index == legs.count - 1 {
                descriptions.append("\(mins) min to dest")
            } else {
                if let next = legs.dropFirst(index + 1).first(where: { $0.1 != "walk" }) {
                    descriptions.append("\(mins) min to \(next.0)")
                } else {
                    descriptions.append("\(mins) min transfer")
                }
            }
        }
        return descriptions
    }

    private func legColor(routeId: String, mode: String) -> Color {
        switch mode {
        case "subway": return AppTheme.SubwayColors.color(for: routeId)
        case "bus":    return AppTheme.BusColors.localBlue
        case "lirr":   return AppTheme.CommuterRailColors.lirrColor(for: routeId)
        case "mnr":    return AppTheme.CommuterRailColors.mnrColor(for: routeId)
        default:       return AppTheme.Colors.textTertiary
        }
    }

    private func textColorForLeg(routeId: String, mode: String) -> Color {
        if mode == "subway" {
            return AppTheme.SubwayColors.textColor(for: routeId)
        }
        return .white
    }

    private func modeIcon(_ mode: String) -> String {
        switch mode {
        case "subway": return "tram.fill"
        case "bus":    return "bus.fill"
        case "lirr", "mnr": return "train.side.front.car"
        default:       return "map.fill"
        }
    }

    private var dateLabel: String {
        guard let date = trip.lastUsedAt ?? Optional(trip.savedAt) else {
            return "Saved"
        }
        if Calendar.current.isDateInToday(date) {
            return "Today"
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f.string(from: date)
        }
    }
}

// MARK: - Button Style

private struct RecentTripButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 10) {
        // Multi-leg: Walk → Bus → Walk → Subway → Walk
        RecentTripCard(
            trip: SavedTrip(
                originName: "Home",
                originAddress: "117-13 125th St",
                originLat: 40.6745,
                originLon: -73.7955,
                destinationName: "Times Square",
                destinationAddress: "42 St",
                destinationLat: 40.7580,
                destinationLon: -73.9855,
                legSummary: ["Walk 7 min", "Q9", "Walk 3 min", "E", "Walk 1 min"],
                legModes: ["walk", "bus", "walk", "subway", "walk"],
                savedAt: Date(),
                usageCount: 4
            ),
            onTap: {}
        )

        // Simple 2-leg: Bus → Subway
        RecentTripCard(
            trip: SavedTrip(
                originName: "111-04 14th Rd",
                originAddress: "111-04 14th Rd",
                originLat: 40.6745,
                originLon: -73.7955,
                destinationName: "John Jay College of Criminal Justice",
                destinationAddress: "524 W 59th St",
                destinationLat: 40.7715,
                destinationLon: -73.9885,
                legSummary: ["Walk 4 min", "Q80", "Walk 2 min", "Q8", "Walk 3 min", "Q76", "Walk 1 min"],
                legModes: ["walk", "bus", "walk", "bus", "walk", "bus", "walk"],
                savedAt: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            ),
            onTap: {}
        )

        // Direct subway
        RecentTripCard(
            trip: SavedTrip(
                originName: "Penn Station",
                originAddress: "Penn Station",
                originLat: 40.7505,
                originLon: -73.9935,
                destinationName: "Fulton St",
                destinationAddress: "Fulton St",
                destinationLat: 40.7100,
                destinationLon: -74.0065,
                legSummary: ["A"],
                legModes: ["subway"],
                savedAt: Calendar.current.date(byAdding: .day, value: -3, to: Date())!,
                usageCount: 12
            ),
            onTap: {}
        )
    }
    .padding(.horizontal, 16)
    .background(AppTheme.Colors.background)
}
