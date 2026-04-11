// Transit-style interactive timeline grid. Clean horizontal scroll
// with time axis, colored candle bars, walk connectors, live "Now"
// needle, and "Go at" info rows. No background grid clutter.

import SwiftUI
import Combine

struct TripTimelineGridView: View {
    let trips: [TripPlan]
    let onTripTap: (TripPlan) -> Void
    var recommendedIndex: Int = 0

    @State private var nowDate = Date()
    @State private var appeared = false
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    // Layout
    private let barHeight: CGFloat = 40
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
        let ceiled = ceilTo(latest, minutes: intervalMinutes)
        return ceiled.addingTimeInterval(TimeInterval(intervalMinutes * 60))
    }

    private var windowDuration: TimeInterval {
        max(windowEnd.timeIntervalSince(windowStart), 60)
    }

    private var canvasWidth: CGFloat {
        max(CGFloat(windowDuration / 60) * pxPerMinute, 500)
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
            VStack(alignment: .leading, spacing: 0) {
                timeAxisRow
                    .padding(.bottom, 4)

                ForEach(Array(trips.enumerated()), id: \.element.id) { index, trip in
                    if index > 0 {
                        Rectangle()
                            .fill(AppTheme.Colors.borderSubtle.opacity(0.12))
                            .frame(height: 1)
                            .padding(.leading, 16)
                    }

                    Button { onTripTap(trip) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            candleRow(trip)
                            infoRow(trip, isRecommended: index == recommendedIndex)
                        }
                        .padding(.vertical, 16)
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
            // Time labels
            ForEach(timeMarkers, id: \.self) { marker in
                timeLabel(marker)
                    .position(x: xPos(for: marker), y: 12)
            }

            // Tick marks under each label
            ForEach(timeMarkers, id: \.self) { marker in
                Rectangle()
                    .fill(AppTheme.Colors.textTertiary.opacity(0.2))
                    .frame(width: 1, height: 6)
                    .position(x: xPos(for: marker), y: 25)
            }

            // "Now" label
            if nowDate >= windowStart && nowDate <= windowEnd {
                let nx = xPos(for: nowDate)
                VStack(spacing: 2) {
                    Text("Now")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                    Circle()
                        .fill(AppTheme.Colors.successGreen)
                        .frame(width: 6, height: 6)
                        .shadow(color: AppTheme.Colors.successGreen.opacity(0.5), radius: 3)
                }
                .position(x: nx, y: 12)
            }
        }
        .frame(height: 30)
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
            // Clean thin tick lines (not a full grid — just small marks)
            ForEach(timeMarkers, id: \.self) { marker in
                let x = xPos(for: marker)
                Rectangle()
                    .fill(AppTheme.Colors.borderSubtle.opacity(0.1))
                    .frame(width: 0.5, height: barHeight)
                    .position(x: x, y: barHeight / 2)
            }

            // "Now" needle
            if nowDate >= windowStart && nowDate <= windowEnd {
                let nx = xPos(for: nowDate)
                RoundedRectangle(cornerRadius: 1)
                    .fill(AppTheme.Colors.successGreen.opacity(0.5))
                    .frame(width: 2, height: barHeight + 4)
                    .position(x: nx, y: barHeight / 2)
            }

            // Legs
            ForEach(trip.legs) { leg in
                legView(leg)
            }
        }
        .frame(width: canvasWidth, height: barHeight)
    }

    // MARK: - Leg View

    @ViewBuilder
    private func legView(_ leg: TripLeg) -> some View {
        let startX = xPos(for: leg.departureTime)
        let endX = xPos(for: leg.arrivalTime)
        let legW = max(endX - startX, leg.isTransit ? 42 : 20)
        let cx = startX + legW / 2
        let cy = barHeight / 2

        if leg.isTransit {
            transitBar(leg, width: legW)
                .position(x: cx, y: cy)
        } else {
            walkConnector(leg, width: legW)
                .position(x: cx, y: cy)
        }
    }

    // MARK: - Transit Bar

    private func transitBar(_ leg: TripLeg, width: CGFloat) -> some View {
        let color = legColor(leg)

        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color)

            // Subtle glass highlight
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.14), location: 0),
                            .init(color: .clear, location: 0.4),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            // Route label
            if let routeId = leg.routeId {
                let txt = textColorForLeg(leg)
                if width > 52 {
                    HStack(spacing: 3) {
                        if leg.mode == .bus {
                            Image(systemName: "bus.fill")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(routeId)
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(txt)
                } else if width > 28 {
                    Text(routeId)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(txt)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: width, height: barHeight)
        .shadow(color: color.opacity(0.3), radius: 5, y: 3)
    }

    // MARK: - Walk Connector

    private func walkConnector(_ leg: TripLeg, width: CGFloat) -> some View {
        let dotSize: CGFloat = 8
        let iconSize: CGFloat = 14
        let cy = barHeight / 2
        let lineColor = AppTheme.Colors.textTertiary.opacity(0.35)

        return ZStack {
            // Solid thin connecting line
            Rectangle()
                .fill(lineColor)
                .frame(width: max(width - dotSize * 2, 2), height: 2)
                .position(x: width / 2, y: cy)

            // Walk / transfer icon in center
            if width > 32 {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.cardBackground)
                        .frame(width: 24, height: 24)

                    Circle()
                        .strokeBorder(AppTheme.Colors.textTertiary.opacity(0.2), lineWidth: 1)
                        .frame(width: 24, height: 24)

                    Image(systemName: leg.mode == .transfer ? "arrow.left.arrow.right" : "figure.walk")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .position(x: width / 2, y: cy)
            }

            // Start dot
            Circle()
                .fill(AppTheme.Colors.textTertiary.opacity(0.5))
                .frame(width: dotSize, height: dotSize)
                .position(x: dotSize / 2, y: cy)

            // End dot
            Circle()
                .fill(AppTheme.Colors.textTertiary.opacity(0.5))
                .frame(width: dotSize, height: dotSize)
                .position(x: width - dotSize / 2, y: cy)
        }
        .frame(width: width, height: barHeight)
    }

    // MARK: - Info Row

    private func infoRow(_ trip: TripPlan, isRecommended: Bool) -> some View {
        let seconds = trip.departureTime.timeIntervalSince(nowDate)
        let minutes = Int(seconds / 60)

        return HStack(alignment: .center, spacing: 0) {
            goLabel(trip: trip, minutes: minutes)

            if isRecommended {
                bestBadge
                    .padding(.leading, 8)
            }

            Spacer(minLength: 8)

            Text(trip.durationString)
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func goLabel(trip: TripPlan, minutes: Int) -> some View {
        if minutes <= 0 {
            HStack(spacing: 4) {
                Text("Go")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("now")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.successGreen)
            }
        } else if minutes <= 60 {
            HStack(spacing: 5) {
                Text("Go at")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(trip.departureTimeString)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.successGreen)
                Text("·")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                Text("\(minutes) min")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        } else {
            HStack(spacing: 5) {
                Text("Go at")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(trip.departureTimeString)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }
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

private struct TimelineRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed
                          ? AppTheme.Colors.cardInset.opacity(0.3)
                          : Color.clear)
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
