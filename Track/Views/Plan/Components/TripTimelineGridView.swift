// Transit-style interactive timeline grid. Horizontal scrollable
// time-axis with proportional transit bars, dot-pattern walk segments,
// transfer connectors, live "Now" needle, and paired info rows with
// "Go in X min" countdown + real-time indicator.

import SwiftUI
import Combine

struct TripTimelineGridView: View {
    let trips: [TripPlan]
    let onTripTap: (TripPlan) -> Void
    var recommendedIndex: Int = 0

    @State private var nowDate = Date()
    @State private var appeared = false
    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    // Layout
    private let barHeight: CGFloat = 36
    private let rowSpacing: CGFloat = 4
    private let pxPerMinute: CGFloat = 5.5

    // MARK: - Time Window

    private var windowStart: Date {
        guard let earliest = trips.map(\.departureTime).min() else { return Date() }
        return floorTo(earliest, minutes: intervalMinutes)
    }

    private var windowEnd: Date {
        guard let latest = trips.map(\.arrivalTime).max() else {
            return Date().addingTimeInterval(3600)
        }
        return ceilTo(latest, minutes: intervalMinutes)
    }

    private var windowDuration: TimeInterval {
        max(windowEnd.timeIntervalSince(windowStart), 60)
    }

    private var canvasWidth: CGFloat {
        max(CGFloat(windowDuration / 60) * pxPerMinute, 300)
    }

    private var intervalMinutes: Int {
        let earliest = trips.map(\.departureTime).min() ?? Date()
        let latest = trips.map(\.arrivalTime).max() ?? Date()
        let span = latest.timeIntervalSince(earliest)
        if span > 7200 { return 60 }
        if span > 3600 { return 30 }
        return 15
    }

    private var timeMarkers: [Date] {
        let interval = TimeInterval(intervalMinutes * 60)
        var markers: [Date] = []
        var current = windowStart
        while current <= windowEnd {
            markers.append(current)
            current = current.addingTimeInterval(interval)
        }
        return markers
    }

    // MARK: - Body

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                // Vertical gridlines spanning ALL rows (behind everything)
                GeometryReader { _ in
                    ForEach(timeMarkers, id: \.self) { marker in
                        Rectangle()
                            .fill(AppTheme.Colors.borderSubtle.opacity(0.1))
                            .frame(width: 0.5)
                            .offset(x: xPos(for: marker))
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    // Time axis header
                    timeAxisRow
                        .padding(.bottom, 2)

                    // Each trip: candle bar + info row
                    ForEach(Array(trips.enumerated()), id: \.element.id) { index, trip in
                        if index > 0 {
                            Divider()
                                .padding(.horizontal, 16)
                                .padding(.vertical, 2)
                        }

                        Button { onTripTap(trip) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                candleRow(trip)
                                    .padding(.bottom, 2)
                                infoRow(trip, isRecommended: index == recommendedIndex)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(TimelineRowButtonStyle())
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(
                            .spring(response: 0.4, dampingFraction: 0.85)
                                .delay(Double(index) * 0.05),
                            value: appeared
                        )
                    }
                }
            }
            .frame(width: canvasWidth)
        }
        .onReceive(ticker) { _ in nowDate = Date() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(0.1)) {
                appeared = true
            }
        }
    }

    // MARK: - Time Axis

    private var timeAxisRow: some View {
        ZStack(alignment: .leading) {
            ForEach(timeMarkers, id: \.self) { marker in
                timeLabel(marker)
                    .position(x: xPos(for: marker), y: 10)
            }

            ForEach(timeMarkers, id: \.self) { marker in
                Rectangle()
                    .fill(AppTheme.Colors.textTertiary.opacity(0.25))
                    .frame(width: 1, height: 8)
                    .position(x: xPos(for: marker), y: 24)
            }

            if nowDate >= windowStart && nowDate <= windowEnd {
                let nx = xPos(for: nowDate)
                VStack(spacing: 1) {
                    Text("Now")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                    Circle()
                        .fill(AppTheme.Colors.successGreen)
                        .frame(width: 5, height: 5)
                        .shadow(color: AppTheme.Colors.successGreen.opacity(0.5), radius: 2)
                }
                .position(x: nx, y: 10)
            }
        }
        .frame(height: 28)
    }

    private func timeLabel(_ date: Date) -> some View {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm"
        let time = fmt.string(from: date)

        let ampmFmt = DateFormatter()
        ampmFmt.dateFormat = "a"
        let ampm = ampmFmt.string(from: date)

        return HStack(spacing: 1) {
            Text(time)
                .font(.system(size: 12, weight: .bold, design: .rounded))
            Text(ampm)
                .font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .foregroundStyle(AppTheme.Colors.textSecondary)
        .fixedSize()
    }

    // MARK: - Candle Row

    private func candleRow(_ trip: TripPlan) -> some View {
        ZStack {
            // "Now" needle
            if nowDate >= windowStart && nowDate <= windowEnd {
                let nx = xPos(for: nowDate)
                RoundedRectangle(cornerRadius: 1)
                    .fill(AppTheme.Colors.successGreen.opacity(0.5))
                    .frame(width: 2, height: barHeight + 4)
                    .position(x: nx, y: barHeight / 2)
            }

            // Transfer connector line
            transferConnectorLine(trip)

            // Legs
            ForEach(trip.legs) { leg in
                legView(leg, trip: trip)
            }
        }
        .frame(width: canvasWidth, height: barHeight)
    }

    /// Thin horizontal line connecting first transit start to last transit end.
    private func transferConnectorLine(_ trip: TripPlan) -> some View {
        let transitLegs = trip.legs.filter { $0.isTransit }
        guard let first = transitLegs.first, let last = transitLegs.last else {
            return AnyView(EmptyView())
        }
        let startX = xPos(for: first.departureTime)
        let endX = xPos(for: last.arrivalTime)
        let lineW = max(endX - startX, 0)
        let cx = startX + lineW / 2
        return AnyView(
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AppTheme.Colors.textTertiary.opacity(0.22))
                .frame(width: lineW, height: 3)
                .position(x: cx, y: barHeight / 2)
        )
    }

    // MARK: - Leg View

    @ViewBuilder
    private func legView(_ leg: TripLeg, trip: TripPlan) -> some View {
        let startX = xPos(for: leg.departureTime)
        let endX = xPos(for: leg.arrivalTime)
        let legW = max(endX - startX, leg.isTransit ? 44 : 24)
        let cx = startX + legW / 2
        let cy = barHeight / 2

        if leg.isTransit {
            transitBar(leg, width: legW)
                .position(x: cx, y: cy)
        } else {
            walkDots(leg, width: legW, trip: trip)
                .position(x: cx, y: cy)
        }
    }

    // MARK: - Transit Bar

    private func transitBar(_ leg: TripLeg, width: CGFloat) -> some View {
        let color = legColor(leg)

        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.14), location: 0),
                            .init(color: .clear, location: 0.4),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            if let routeId = leg.routeId {
                let txt = textColorForLeg(leg)
                if width > 54 {
                    HStack(spacing: 4) {
                        Image(systemName: vehicleIcon(for: leg))
                            .font(.system(size: 13, weight: .bold))
                        Text(routeId)
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(txt)
                } else if width > 36 {
                    HStack(spacing: 2) {
                        Image(systemName: vehicleIcon(for: leg))
                            .font(.system(size: 11, weight: .bold))
                        Text(routeId)
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    }
                    .foregroundStyle(txt)
                } else {
                    Image(systemName: vehicleIcon(for: leg))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(txt)
                }
            } else {
                Image(systemName: vehicleIcon(for: leg))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: width, height: barHeight)
        .shadow(color: color.opacity(0.3), radius: 5, y: 3)
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

    private func vehicleIcon(for leg: TripLeg) -> String {
        switch leg.mode {
        case .bus:     return "bus.fill"
        case .subway:  return "tram.fill"
        case .lirr:    return "train.side.front.car"
        case .mnr:     return "train.side.front.car"
        default:       return "tram.fill"
        }
    }

    // MARK: - Walk Dots (• • • •)

    /// Renders walk/transfer legs as horizontal dot patterns on the
    /// connector line — matching Transit app style exactly.
    private func walkDots(_ leg: TripLeg, width: CGFloat, trip: TripPlan) -> some View {
        let w = max(width, 24)
        let dotSize: CGFloat = 5
        let dotSpacing: CGFloat = 7
        let totalDotWidth = dotSize + dotSpacing
        let dotCount = max(2, min(Int(w / totalDotWidth), 6))

        return HStack(spacing: dotSpacing) {
            ForEach(0..<dotCount, id: \.self) { _ in
                Circle()
                    .fill(AppTheme.Colors.textTertiary.opacity(0.5))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .frame(width: w, height: barHeight)
    }

    // MARK: - Walk Summary Row

    /// Shows "🚶 X min to E  ·  X min to dest" below the timeline bar.
    @ViewBuilder
    private func walkSummaryRow(_ trip: TripPlan) -> some View {
        let descriptions = walkLegDescriptions(trip)
        if !descriptions.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textTertiary)

                Text(descriptions.joined(separator: "  ·  "))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 16)
        }
    }

    private func walkLegDescriptions(_ trip: TripPlan) -> [String] {
        var descriptions: [String] = []
        for (index, leg) in trip.legs.enumerated() {
            guard leg.mode == .walk || leg.mode == .transfer,
                  leg.durationMinutes > 0 else { continue }

            if index == 0 {
                if let next = trip.legs.dropFirst(index + 1).first(where: { $0.isTransit }) {
                    descriptions.append("\(leg.durationMinutes) min to \(next.routeId ?? "stop")")
                } else {
                    descriptions.append("\(leg.durationMinutes) min walk")
                }
            } else if index == trip.legs.count - 1 {
                descriptions.append("\(leg.durationMinutes) min to dest")
            } else {
                if let next = trip.legs.dropFirst(index + 1).first(where: { $0.isTransit }) {
                    descriptions.append("\(leg.durationMinutes) min to \(next.routeId ?? "transfer")")
                } else {
                    descriptions.append("\(leg.durationMinutes) min transfer")
                }
            }
        }
        return descriptions
    }

    // MARK: - Info Row

    private func infoRow(_ trip: TripPlan, isRecommended: Bool) -> some View {
        let seconds = trip.departureTime.timeIntervalSince(nowDate)
        let minutes = Int(seconds / 60)
        let hasRealtime = trip.legs.contains { $0.liveStatus?.isRealtime == true }

        return HStack(alignment: .center, spacing: 0) {
            goLabel(trip: trip, minutes: minutes, hasRealtime: hasRealtime)

            if isRecommended {
                bestBadge
                    .padding(.leading, 8)
            }

            Spacer(minLength: 8)

            Text(trip.durationString)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func goLabel(trip: TripPlan, minutes: Int, hasRealtime: Bool) -> some View {
        if minutes <= 0 {
            HStack(spacing: 4) {
                Text("Go")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                HStack(spacing: 2) {
                    Text("now")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                    if hasRealtime {
                        Image(systemName: "dot.radiowaves.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.successGreen)
                    }
                }
            }
        } else if minutes <= 120 {
            HStack(spacing: 4) {
                Text("Go in")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                HStack(spacing: 2) {
                    Text("\(minutes) min")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                    if hasRealtime {
                        Image(systemName: "dot.radiowaves.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.successGreen)
                    }
                }
            }
        } else {
            Text("Departs \(trip.departureTimeString)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
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
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(AppTheme.Colors.successGreen)
        )
    }

    // MARK: - Helpers

    private func xPos(for date: Date) -> CGFloat {
        let fraction = date.timeIntervalSince(windowStart) / windowDuration
        return CGFloat(max(0, min(1, fraction))) * canvasWidth
    }

    private func floorTo(_ date: Date, minutes: Int) -> Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let m = (c.minute ?? 0)
        var nc = c
        nc.minute = m - (m % minutes)
        nc.second = 0
        return cal.date(from: nc) ?? date
    }

    private func ceilTo(_ date: Date, minutes: Int) -> Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let m = (c.minute ?? 0)
        let rem = m % minutes
        if rem == 0 { return date }
        var nc = c
        nc.minute = m + (minutes - rem)
        nc.second = 0
        return cal.date(from: nc) ?? date
    }

    // MARK: - Colors

    private func legColor(_ leg: TripLeg) -> Color {
        // Always prefer the app's own theme colors for known modes.
        // Only fall back to GTFS routeColor for unknown modes.
        switch leg.mode {
        case .subway:  return AppTheme.SubwayColors.color(for: leg.routeId ?? "")
        case .bus:     return AppTheme.BusColors.color(forServiceType: leg.busServiceType)
        case .lirr:    return AppTheme.CommuterRailColors.lirrBlue
        case .mnr:     return AppTheme.CommuterRailColors.mnrBlue
        default:
            if let hex = leg.routeColor, !hex.isEmpty {
                return Color(hex: hex)
            }
            return AppTheme.Colors.textTertiary
        }
    }

    private func textColorForLeg(_ leg: TripLeg) -> Color {
        if let hex = leg.textColorHex, !hex.isEmpty {
            return Color(hex: hex)
        }
        if leg.mode == .subway, let routeId = leg.routeId {
            return AppTheme.SubwayColors.textColor(for: routeId)
        }
        return .white
    }
}

// MARK: - Button Style

private struct TimelineRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed
                          ? AppTheme.Colors.cardInset.opacity(0.3)
                          : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
