import SwiftUI
import WidgetKit

struct TripWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TripWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (TripWidgetEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        completion(TripWidgetEntry(date: Date(), trip: TrackedTripSnapshot.load()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<TripWidgetEntry>) -> Void
    ) {
        let trip = TrackedTripSnapshot.load()
        let entry = TripWidgetEntry(date: Date(), trip: trip)
        let refresh = Calendar.current.date(byAdding: .minute, value: 1, to: Date()) ?? Date().addingTimeInterval(60)
        completion(Timeline(entries: [entry], policy: trip == nil ? .never : .after(refresh)))
    }
}

struct TripWidgetEntry: TimelineEntry {
    let date: Date
    let trip: TrackedTripSnapshot?

    static let placeholder = TripWidgetEntry(date: Date(), trip: TrackedTripSnapshot(
        destinationName: "Coney Island-Stillwell Av",
        departureTime: Date().addingTimeInterval(-8 * 60),
        arrivalTime: Date().addingTimeInterval(52 * 60),
        totalDurationMinutes: 60,
        currentLegIndex: 1,
        legs: [
            TrackedTripLeg(
                id: "walk-1",
                mode: "walk",
                routeId: nil,
                routeName: nil,
                routeColorHex: nil,
                textColorHex: nil,
                boardStopName: "Start",
                alightStopName: "W 34 ST/10 AV",
                departureTime: Date().addingTimeInterval(-8 * 60),
                arrivalTime: Date().addingTimeInterval(2 * 60),
                durationMinutes: 10
            ),
            TrackedTripLeg(
                id: "bus-1",
                mode: "bus",
                routeId: "M34+",
                routeName: "M34+",
                routeColorHex: "#1EAEDB",
                textColorHex: "#FFFFFF",
                boardStopName: "W 34 ST/10 AV",
                alightStopName: "Herald Sq",
                departureTime: Date().addingTimeInterval(2 * 60),
                arrivalTime: Date().addingTimeInterval(17 * 60),
                durationMinutes: 15
            ),
            TrackedTripLeg(
                id: "walk-2",
                mode: "walk",
                routeId: nil,
                routeName: nil,
                routeColorHex: nil,
                textColorHex: nil,
                boardStopName: "Herald Sq",
                alightStopName: "34 St-Herald Sq",
                departureTime: Date().addingTimeInterval(17 * 60),
                arrivalTime: Date().addingTimeInterval(22 * 60),
                durationMinutes: 5
            ),
            TrackedTripLeg(
                id: "q-1",
                mode: "subway",
                routeId: "Q",
                routeName: "Q",
                routeColorHex: "#FCCC0A",
                textColorHex: "#111111",
                boardStopName: "34 St-Herald Sq",
                alightStopName: "Coney Island-Stillwell Av",
                departureTime: Date().addingTimeInterval(22 * 60),
                arrivalTime: Date().addingTimeInterval(52 * 60),
                durationMinutes: 30
            )
        ],
        updatedAt: Date()
    ))
}

struct TripWidgetView: View {
    let entry: TripWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let trip = entry.trip {
                switch family {
                case .systemSmall:
                    TripWidgetSmallView(trip: trip)
                case .systemMedium:
                    TripWidgetMediumView(trip: trip)
                case .systemLarge:
                    TripWidgetLargeView(trip: trip)
                default:
                    TripWidgetMediumView(trip: trip)
                }
            } else {
                WK.EmptyState(
                    icon: "point.topleft.down.curvedto.point.bottomright.up",
                    title: "No active trip",
                    subtitle: "Press GO on a trip to track it here",
                    tint: AppTheme.Colors.accent
                )
            }
        }
        .containerBackground(for: .widget) { WK.Surface(tint: entry.trip?.accentColor) }
    }
}

private struct TripWidgetSmallView: View {
    let trip: TrackedTripSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TripWidgetHeader(title: "Trip", destination: trip.destinationName)

            VStack(alignment: .leading, spacing: 2) {
                Text(trip.statusTitle)
                    .font(.system(size: 19, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text("Arrive at \(trip.arrivalText)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            TripWidgetProgressBar(trip: trip, compact: true)

            Spacer(minLength: 0)

            TripWidgetCurrentLegView(trip: trip, compact: true)
        }
        .padding(WK.Tokens.surfacePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TripWidgetMediumView: View {
    let trip: TrackedTripSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            TripWidgetSummaryCard(trip: trip, compact: false)
            TripWidgetCurrentLegView(trip: trip, compact: false)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TripWidgetLargeView: View {
    let trip: TrackedTripSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TripWidgetSummaryCard(trip: trip, compact: false)

            VStack(alignment: .leading, spacing: 8) {
                Text("ROUTE")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(AppTheme.Colors.textTertiary)

                ForEach(Array(trip.legs.prefix(5).enumerated()), id: \.element.id) { index, leg in
                    TripWidgetLegRow(
                        leg: leg,
                        isCurrent: index == trip.currentLegIndex,
                        isPassed: index < trip.currentLegIndex
                    )
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.Colors.cardElevated.opacity(0.82))
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TripWidgetSummaryCard: View {
    let trip: TrackedTripSnapshot
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 8 : 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(trip.statusTitle)
                        .font(.system(size: compact ? 18 : 20, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                    Text("Arrive at \(trip.arrivalText)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Text(trip.durationString)
                    .font(.system(size: compact ? 14 : 16, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            TripWidgetProgressBar(trip: trip, compact: compact)
        }
        .padding(.horizontal, compact ? 12 : 14)
        .padding(.vertical, compact ? 10 : 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.68), lineWidth: 1)
        )
    }
}

private struct TripWidgetHeader: View {
    let title: String
    let destination: String

    var body: some View {
        HStack(spacing: 6) {
            WK.LiveDot(compact: true)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer(minLength: 0)
            Text(destination)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .lineLimit(1)
        }
    }
}

private struct TripWidgetProgressBar: View {
    let trip: TrackedTripSnapshot
    var compact: Bool

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                let total = max(1, trip.legs.map(\.durationMinutes).reduce(0, +))
                let dotSize: CGFloat = compact ? 9 : 11

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.Colors.borderSubtle.opacity(0.36))
                        .frame(height: compact ? 9 : 11)

                    HStack(spacing: compact ? 3 : 4) {
                        ForEach(Array(trip.legs.enumerated()), id: \.element.id) { index, leg in
                            Capsule()
                                .fill(leg.segmentColor.opacity(index < trip.currentLegIndex ? 0.42 : 1.0))
                                .frame(
                                    width: max(compact ? 12 : 18, geo.size.width * CGFloat(leg.durationMinutes) / CGFloat(total) - 4),
                                    height: compact ? 9 : 11
                                )
                        }
                    }
                    .mask(Capsule().frame(width: geo.size.width, height: compact ? 9 : 11))

                    Circle()
                        .fill(.white)
                        .frame(width: dotSize, height: dotSize)
                        .overlay(Circle().stroke(trip.accentColor, lineWidth: 2))
                        .shadow(color: trip.accentColor.opacity(0.4), radius: 4)
                        .offset(x: max(0, min(geo.size.width - dotSize, geo.size.width * trip.progress - dotSize / 2)))
                }
            }
            .frame(height: compact ? 12 : 14)

            if !compact {
                HStack(spacing: 5) {
                    Text(trip.departureText)
                    Spacer(minLength: 0)
                    Text("\(Int((trip.progress * 100).rounded()))%")
                        .foregroundStyle(trip.accentColor)
                    Spacer(minLength: 0)
                    Text(trip.arrivalText)
                }
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .monospacedDigit()
            }
        }
    }
}

private struct TripWidgetCurrentLegView: View {
    let trip: TrackedTripSnapshot
    let compact: Bool

    var body: some View {
        if let leg = trip.currentLeg {
            HStack(spacing: compact ? 8 : 10) {
                if leg.isTransit {
                    WK.LineBadge(
                        lineId: leg.displayRoute,
                        isBus: leg.isBus,
                        isLIRR: leg.isLIRR,
                        isMNR: leg.isMNR,
                        size: compact ? 28 : 34
                    )
                } else {
                    Image(systemName: "figure.walk.circle.fill")
                        .font(.system(size: compact ? 27 : 32, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(leg.isTransit ? "Ride to" : "Walk to")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                    Text(leg.alightStopName)
                        .font(.system(size: compact ? 12 : 14, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(compact ? 1 : 2)
                }
                Spacer(minLength: 0)
                Text(leg.remainingText)
                    .font(.system(size: compact ? 11 : 13, weight: .black, design: .rounded))
                    .foregroundStyle(trip.accentColor)
                    .monospacedDigit()
            }
            .padding(compact ? 0 : 10)
            .background {
                if !compact {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.Colors.cardElevated.opacity(0.72))
                }
            }
        }
    }
}

private struct TripWidgetLegRow: View {
    let leg: TrackedTripLeg
    let isCurrent: Bool
    let isPassed: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(isCurrent ? leg.segmentColor.opacity(0.18) : AppTheme.Colors.cardInset)
                    .frame(width: 28, height: 28)
                Image(systemName: leg.iconName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isPassed ? AppTheme.Colors.textTertiary : leg.segmentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(leg.isTransit ? leg.displayRoute : "Walk")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(isPassed ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(leg.alightStopName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(leg.remainingText)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(isCurrent ? leg.segmentColor : AppTheme.Colors.textTertiary)
                .monospacedDigit()
        }
    }
}

struct TripWidget: Widget {
    let kind = "TripWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TripWidgetProvider()) { entry in
            TripWidgetView(entry: entry)
        }
        .configurationDisplayName("Trip Widget")
        .description("Track your active trip with a route-card progress bar and next step.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

private extension TrackedTripSnapshot {
    var currentLeg: TrackedTripLeg? {
        guard legs.indices.contains(currentLegIndex) else { return legs.first(where: \.isTransit) ?? legs.first }
        return legs[currentLegIndex]
    }

    var statusTitle: String {
        guard let leg = currentLeg else { return "Trip active" }
        if leg.isTransit { return "Ride \(leg.displayRoute)" }
        let minutes = max(0, Int(ceil(leg.arrivalTime.timeIntervalSinceNow / 60)))
        return minutes <= 1 ? "Leave now" : "Walk \(minutes)m"
    }

    var accentColor: Color {
        currentLeg?.segmentColor ?? AppTheme.Colors.accent
    }

    var departureText: String { Self.timeFormatter.string(from: departureTime) }
    var arrivalText: String { Self.timeFormatter.string(from: arrivalTime) }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

private extension TrackedTripLeg {
    var segmentColor: Color {
        if let routeColorHex, !routeColorHex.isEmpty {
            return Color.tripWidgetHex(routeColorHex)
        }
        switch mode {
        case "walk", "transfer": return AppTheme.Colors.cardInset
        case "bus": return AppTheme.BusColors.localBlue
        case "lirr": return AppTheme.Colors.accent
        case "mnr": return AppTheme.Colors.successGreen
        default: return AppTheme.SubwayColors.color(for: displayRoute)
        }
    }

    var iconName: String {
        switch mode {
        case "walk", "transfer": return "figure.walk"
        case "bus": return "bus.fill"
        case "lirr", "mnr": return "train.side.front.car"
        default: return "tram.fill"
        }
    }

    var remainingText: String {
        let minutes = max(0, Int(ceil(arrivalTime.timeIntervalSinceNow / 60)))
        return minutes <= 0 ? "now" : "\(minutes)m"
    }
}

private extension Color {
    static func tripWidgetHex(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red: Double
        let green: Double
        let blue: Double
        switch cleaned.count {
        case 6:
            red = Double((value >> 16) & 0xFF) / 255.0
            green = Double((value >> 8) & 0xFF) / 255.0
            blue = Double(value & 0xFF) / 255.0
        default:
            red = 0.0
            green = 0.0
            blue = 0.0
        }
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

#Preview(as: .systemMedium) {
    TripWidget()
} timeline: {
    TripWidgetEntry.placeholder
}

#Preview(as: .systemSmall) {
    TripWidget()
} timeline: {
    TripWidgetEntry.placeholder
}

#Preview(as: .systemLarge) {
    TripWidget()
} timeline: {
    TripWidgetEntry.placeholder
}
