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
    var departureOption: DepartureOption = .leaveNow
    var onDepartureTimeChange: ((Date?) -> Void)? = nil

    @State private var nowDate = Date()
    @State private var appeared = false
    @State private var isDraggingNeedle = false
    @State private var needleDragX: CGFloat? = nil
    /// After the user drops the needle, it stays pinned here.
    @State private var pinnedNeedleX: CGFloat? = nil
    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    // Layout
    private let barHeight: CGFloat = 40
    private let pxPerMinute: CGFloat = 5.9
    private let minimumWindowMinutes: Double = 90
    private let leadingContextMinutes: Double = 8
    private let trailingContextMinutes: Double = 25
    private let contentInset: CGFloat = 18

    // MARK: - Time Window

    private var displayedSpanMinutes: Double {
        let earliest = trips.map(\.departureTime).min() ?? nowDate
        let latest = trips.map(\.arrivalTime).max() ?? nowDate
        let paddedStart = min(earliest, nowDate).addingTimeInterval(-(leadingContextMinutes * 60))
        let paddedEnd = latest.addingTimeInterval(trailingContextMinutes * 60)
        let paddedSpan = paddedEnd.timeIntervalSince(paddedStart) / 60
        return max(minimumWindowMinutes, paddedSpan)
    }

    private var windowStart: Date {
        let earliest = trips.map(\.departureTime).min() ?? nowDate
        let anchor = min(earliest, nowDate).addingTimeInterval(-(leadingContextMinutes * 60))
        return floorTo(anchor, minutes: intervalMinutes)
    }

    private var windowEnd: Date {
        let latest = trips.map(\.arrivalTime).max() ?? nowDate
        let minimumEnd = windowStart.addingTimeInterval(minimumWindowMinutes * 60)
        let contentEnd = latest.addingTimeInterval(trailingContextMinutes * 60)
        return ceilTo(max(minimumEnd, contentEnd), minutes: intervalMinutes)
    }

    private var windowDuration: TimeInterval {
        max(windowEnd.timeIntervalSince(windowStart), 60)
    }

    private var canvasWidth: CGFloat {
        max(CGFloat(windowDuration / 60) * pxPerMinute, 300)
    }

    private var intervalMinutes: Int {
        if displayedSpanMinutes > 480 { return 60 }
        if displayedSpanMinutes > 180 { return 30 }
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    // Vertical gridlines spanning ALL rows (behind everything)
                    GeometryReader { _ in
                        ForEach(timeMarkers, id: \.self) { marker in
                            Rectangle()
                                .fill(
                                    isMajorMarker(marker)
                                        ? AppTheme.Colors.borderSubtle.opacity(0.16)
                                        : AppTheme.Colors.borderSubtle.opacity(0.08)
                                )
                                .frame(width: isMajorMarker(marker) ? 1 : 0.5)
                                .offset(x: xPos(for: marker))
                        }
                    }

                    // Full-height needle — behind the time axis, above gridlines
                    nowNeedleOverlay

                    VStack(alignment: .leading, spacing: 0) {
                        // Time axis header — opaque so needle slides behind it
                        timeAxisRow
                            .padding(.bottom, 2)
                            .background(AppTheme.Gradients.screen)
                            .zIndex(10)

                        // Each trip: candle bar + info row
                        ForEach(Array(trips.enumerated()), id: \.element.id) { index, trip in
                            if index > 0 {
                                Divider()
                                    .overlay(AppTheme.Colors.borderSubtle.opacity(0.12))
                                    .padding(.vertical, 12)
                            }

                            Button { onTripTap(trip) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    candleRow(trip)
                                    infoRow(trip, isRecommended: index == recommendedIndex)
                                }
                                .padding(.vertical, 10)
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

                    // Invisible anchor at the scroll-target x position
                    Color.clear
                        .frame(width: 1, height: 1)
                        .offset(x: scrollAnchorX)
                        .id("scrollAnchor")
                }
                .frame(width: canvasWidth + 2 * contentInset)
            }
            .onReceive(ticker) { _ in nowDate = Date() }
            .onAppear {
                // Scroll so the first trip departure is visible ~20pt from the left edge
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo("scrollAnchor", anchor: .leading)
                    withAnimation(.easeOut(duration: 0.3).delay(0.05)) {
                        appeared = true
                    }
                }
            }
        }
    }

    /// X offset of the scroll anchor — positions the view so the first departure
    /// (or "Now" needle if earlier) lands near the left edge with a small margin.
    private var scrollAnchorX: CGFloat {
        let earliest = trips.map(\.departureTime).min() ?? nowDate
        let anchor = min(earliest, nowDate)
        // Show the anchor date about 16pt from the left of the viewport
        let tx = xPos(for: anchor) - 16
        return max(0, tx)
    }

    // MARK: - Now Needle (draggable)

    /// The x position of the needle — follows drag when active, pinned after drop, otherwise tracks `nowDate`.
    private var needleX: CGFloat {
        if let dragX = needleDragX { return dragX }
        if let pinX = pinnedNeedleX { return pinX }
        return xPos(for: nowDate)
    }

    /// Whether the needle is pinned to a user-chosen time (not tracking "now").
    private var isNeedlePinned: Bool {
        pinnedNeedleX != nil
    }

    /// The date corresponding to the current needle position.
    private func dateForX(_ x: CGFloat) -> Date {
        let fraction = (x - contentInset) / canvasWidth
        let clamped = max(0, min(1, fraction))
        let seconds = Double(clamped) * windowDuration
        return windowStart.addingTimeInterval(seconds)
    }

    /// Full-height draggable needle rendered above gridlines but below time axis.
    @ViewBuilder
    private var nowNeedleOverlay: some View {
        let nx = needleX
        let showNeedle = (nowDate >= windowStart && nowDate <= windowEnd) || isDraggingNeedle || isNeedlePinned

        if showNeedle {
            // Invisible wider hit-target for easy grabbing
            Rectangle()
                .fill(Color.clear)
                .frame(width: 44)
                .contentShape(Rectangle())
                .overlay {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            isNeedlePinned && !isDraggingNeedle
                                ? AppTheme.Colors.successGreen.opacity(0.9)
                                : isDraggingNeedle
                                    ? AppTheme.Colors.successGreen
                                    : AppTheme.Colors.successGreen.opacity(0.72)
                        )
                        .frame(width: isDraggingNeedle ? 3 : 2)
                        .shadow(color: isDraggingNeedle ? AppTheme.Colors.successGreen.opacity(0.4) : .clear, radius: 4)
                }
                .overlay(alignment: .top) {
                    // Time pill — always visible when pinned, larger when dragging
                    if isDraggingNeedle || isNeedlePinned {
                        let displayDate = dateForX(nx)
                        Text(Self.needleTimeFormatter.string(from: displayDate))
                            .font(.system(size: isDraggingNeedle ? 12 : 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, isDraggingNeedle ? 8 : 6)
                            .padding(.vertical, isDraggingNeedle ? 4 : 2)
                            .background(
                                Capsule()
                                    .fill(AppTheme.Colors.successGreen)
                                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                            )
                            .offset(y: 32)
                    }
                }
                .offset(x: nx)
                .gesture(
                    LongPressGesture(minimumDuration: 0.15)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            switch value {
                            case .second(true, let drag):
                                if !isDraggingNeedle {
                                    isDraggingNeedle = true
                                    let generator = UIImpactFeedbackGenerator(style: .medium)
                                    generator.impactOccurred()
                                }
                                if let drag {
                                    let anchorX = pinnedNeedleX ?? xPos(for: nowDate)
                                    let newX = anchorX + drag.translation.width
                                    needleDragX = max(contentInset, min(newX, contentInset + canvasWidth))
                                }
                            default:
                                break
                            }
                        }
                        .onEnded { _ in
                            if let finalX = needleDragX {
                                let selectedDate = dateForX(finalX)
                                // Pin needle at dropped position
                                pinnedNeedleX = finalX
                                // Light haptic to confirm the drop
                                let generator = UIImpactFeedbackGenerator(style: .light)
                                generator.impactOccurred()
                                onDepartureTimeChange?(selectedDate)
                            }
                            withAnimation(.easeOut(duration: 0.15)) {
                                isDraggingNeedle = false
                                needleDragX = nil
                            }
                        }
                )
                .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.9), value: needleDragX)
                .simultaneousGesture(
                    // Double-tap to reset to "now"
                    TapGesture(count: 2).onEnded {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            pinnedNeedleX = nil
                            needleDragX = nil
                        }
                        onDepartureTimeChange?(nil)
                    }
                )
        }
    }

    private static let needleTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt
    }()

    // MARK: - Time Axis

    private var timeAxisRow: some View {
        ZStack(alignment: .leading) {
            ForEach(timeMarkers, id: \.self) { marker in
                timeLabel(marker, emphasized: isMajorMarker(marker))
                    .position(x: xPos(for: marker), y: 10)
            }

            ForEach(timeMarkers, id: \.self) { marker in
                Rectangle()
                    .fill(
                        isMajorMarker(marker)
                            ? AppTheme.Colors.textTertiary.opacity(0.22)
                            : AppTheme.Colors.textTertiary.opacity(0.12)
                    )
                    .frame(width: isMajorMarker(marker) ? 1 : 0.5, height: isMajorMarker(marker) ? 10 : 6)
                    .position(x: xPos(for: marker), y: 24)
            }

            if nowDate >= windowStart && nowDate <= windowEnd {
                let nx = xPos(for: nowDate)
                VStack(spacing: 1) {
                    Circle()
                        .fill(AppTheme.Colors.successGreen)
                        .frame(width: 5, height: 5)
                        .shadow(color: AppTheme.Colors.successGreen.opacity(0.5), radius: 2)
                    Text("Now")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                }
                .position(x: nx, y: 36)
            }
        }
        .frame(height: 44)
    }

    private func timeLabel(_ date: Date, emphasized: Bool) -> some View {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"

        return Text(fmt.string(from: date))
        .font(.system(size: emphasized ? 11 : 10, weight: .heavy, design: .rounded))
        .foregroundStyle(
            emphasized
                ? AppTheme.Colors.textSecondary
                : AppTheme.Colors.textSecondary.opacity(0.72)
        )
        .fixedSize()
    }

    // MARK: - Leg Layout

    /// Pre-computed geometry for a single trip leg, with overlap resolution
    /// so minimum-width bars never collide.
    private struct LegFrame: Identifiable {
        let id: UUID
        let leg: TripLeg
        let x: CGFloat        // leading-edge x position
        let width: CGFloat
        var centerX: CGFloat { x + width / 2 }
        var trailingX: CGFloat { x + width }
    }

    /// Computes non-overlapping rectangles for every leg in a trip.
    /// Transit and walk-only bars get a larger minimum; mid-trip walk/transfer
    /// segments scale down for tiny durations so they don't bloat the layout.
    private func computeLegFrames(_ trip: TripPlan) -> [LegFrame] {
        let isWalkOnly = !trip.legs.contains(where: { $0.isTransit })
        let gap: CGFloat = 2
        var frames: [LegFrame] = []

        for leg in trip.legs {
            let startX = xPos(for: leg.departureTime)
            let endX = xPos(for: leg.arrivalTime)
            let naturalW = endX - startX

            let minW: CGFloat = {
                if leg.isTransit || isWalkOnly { return 42 }
                // Walk/transfer between transit — scale minimum to content
                if naturalW < 10 { return 10 }
                return 20
            }()

            let legW = max(naturalW, minW)
            var leadingX = startX

            // Shift right if this leg would overlap the previous one
            if let prev = frames.last {
                let minStart = prev.trailingX + gap
                if leadingX < minStart { leadingX = minStart }
            }

            frames.append(LegFrame(id: leg.id, leg: leg, x: leadingX, width: legW))
        }

        return frames
    }

    // MARK: - Candle Row

    private func candleRow(_ trip: TripPlan) -> some View {
        let frames = computeLegFrames(trip)
        let isWalkOnly = !trip.legs.contains(where: { $0.isTransit })

        return ZStack {
            // Transfer connector line (uses pre-computed positions)
            transferConnectorLine(frames)

            // Legs — positioned via pre-computed, overlap-free frames
            ForEach(frames) { frame in
                legView(frame, isWalkOnly: isWalkOnly)
            }

            alternativeBadgesRow(trip, frames: frames)
        }
        .frame(width: canvasWidth + 2 * contentInset, height: barHeight)
    }

    @ViewBuilder
    private func alternativeBadgesRow(_ trip: TripPlan, frames: [LegFrame]) -> some View {
        let transitFrames = frames.filter { $0.leg.isTransit }
        let altChips = trip.routeChips.filter { !$0.isWalk }

        if altChips.count > transitFrames.count,
           let anchorFrame = transitFrames.last {
            let overflowCount = max(0, altChips.count - transitFrames.count - 4)
            let anchorX = min(anchorFrame.x + 32, canvasWidth + contentInset - 104)

            HStack(spacing: 4) {
                Text("or")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)

                ForEach(
                    Array(altChips.suffix(from: min(transitFrames.count, altChips.count))
                        .prefix(4)
                        .enumerated()),
                    id: \.offset
                ) { _, chip in
                    routeChipBadge(chip)
                }

                if overflowCount > 0 {
                    ZStack {
                        Circle()
                            .fill(AppTheme.Colors.cardInset)
                            .frame(width: 20, height: 20)
                        Text("+")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                    }
                }
            }
            .position(x: max(anchorX, 68), y: 2)
        }
    }

    private func routeChipBadge(_ chip: TripRouteChip) -> some View {
        let color: Color = {
            if let mode = chip.routeMode {
                switch mode {
                case .subway:
                    return AppTheme.SubwayColors.color(for: chip.routeId ?? chip.label)
                case .bus:
                    if let hex = chip.colorHex, !hex.isEmpty { return Color(hex: hex) }
                    return AppTheme.BusColors.localBlue
                case .lirr:
                    return AppTheme.CommuterRailColors.lirrBlue
                case .mnr:
                    return AppTheme.CommuterRailColors.mnrBlue
                default:
                    if let hex = chip.colorHex, !hex.isEmpty { return Color(hex: hex) }
                    return AppTheme.Colors.textTertiary
                }
            }

            if let hex = chip.colorHex, !hex.isEmpty { return Color(hex: hex) }
            return AppTheme.Colors.textTertiary
        }()

        let textColor: Color = {
            if let hex = chip.textColorHex, !hex.isEmpty { return Color(hex: hex) }
            return .white
        }()

        return ZStack {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                )

            Image(systemName: chip.routeMode?.icon ?? "tram.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(textColor)
        }
    }

    /// Thin horizontal line connecting first transit start to last transit end.
    private func transferConnectorLine(_ frames: [LegFrame]) -> some View {
        let transitFrames = frames.filter { $0.leg.isTransit }
        guard let first = transitFrames.first, let last = transitFrames.last else {
            return AnyView(EmptyView())
        }
        let startX = first.x
        let endX = last.trailingX
        let lineW = max(endX - startX, 0)
        let cx = startX + lineW / 2
        return AnyView(
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AppTheme.Colors.textTertiary.opacity(0.26))
                .frame(width: lineW, height: 4)
                .position(x: cx, y: barHeight / 2)
        )
    }

    // MARK: - Leg View

    @ViewBuilder
    private func legView(_ frame: LegFrame, isWalkOnly: Bool) -> some View {
        let cy = barHeight / 2

        if frame.leg.isTransit {
            transitBar(frame.leg, width: frame.width)
                .position(x: frame.centerX, y: cy)
        } else if isWalkOnly {
            walkBar(frame.leg, width: frame.width)
                .position(x: frame.centerX, y: cy)
        } else if frame.width < 16 {
            // Tiny walk/transfer segment — compact connector dot
            transferDot(frame.leg)
                .position(x: frame.centerX, y: cy)
        } else {
            walkDots(frame.leg, width: frame.width)
                .position(x: frame.centerX, y: cy)
        }
    }

    // MARK: - Transit Bar

    private func transitBar(_ leg: TripLeg, width: CGFloat) -> some View {
        let color = legColor(leg)

        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(0.92),
                            color,
                            color.opacity(0.82),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.14), location: 0),
                            .init(color: .white.opacity(0.05), location: 0.42),
                            .init(color: .clear, location: 0.62),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)

            if leg.routeId != nil {
                let txt = textColorForLeg(leg)
                let label = routeLabel(for: leg)

                if width > 72 {
                    HStack(spacing: 5) {
                        Text(label)
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                        Image(systemName: vehicleIcon(for: leg))
                            .font(.system(size: 13, weight: .heavy))
                    }
                    .foregroundStyle(txt)
                } else if width > 34 || label.count <= 3 {
                    HStack(spacing: 3) {
                        Text(label)
                            .font(.system(size: width > 58 ? 17 : 14, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                        if width > 52 {
                            Image(systemName: vehicleIcon(for: leg))
                                .font(.system(size: 11, weight: .heavy))
                        }
                    }
                    .foregroundStyle(txt)
                } else {
                    Image(systemName: vehicleIcon(for: leg))
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(txt)
                }
            } else {
                Image(systemName: vehicleIcon(for: leg))
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: width, height: barHeight)
        .shadow(color: color.opacity(0.18), radius: 4, y: 1)
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
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

    // MARK: - Walk Bar (walk-only trips)

    /// Renders a walk leg as a filled capsule — used when the entire trip
    /// is walking and the sparse dots would look too empty.
    private func walkBar(_ leg: TripLeg, width: CGFloat) -> some View {
        let walkDistance: String? = {
            guard leg.walkMeters > 0 else { return nil }
            let miles = leg.walkMeters / 1609.344
            if miles < 0.1 { return nil }
            return String(format: "%.1f mi", miles)
        }()

        return ZStack {
            // Neutral card-like background — matches transit bar shape language
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Colors.textTertiary.opacity(0.10))

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.06), location: 0),
                            .init(color: .clear, location: 0.5),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.Colors.textTertiary.opacity(0.18), lineWidth: 1)

            // Content: icon + duration + optional distance
            HStack(spacing: 6) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                if width > 90, let dist = walkDistance {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(leg.durationMinutes) min")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Text(dist)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                    }
                } else if width > 54 {
                    Text("\(leg.durationMinutes) min")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
            }
        }
        .frame(width: width, height: barHeight)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    // MARK: - Walk Dots (• • • •)

    /// Renders walk/transfer legs as horizontal dot patterns on the
    /// connector line — matching Transit app style exactly.
    /// Adapts dot size and spacing for narrow widths so tiny walks
    /// don't look broken.
    private func walkDots(_ leg: TripLeg, width: CGFloat) -> some View {
        let w = max(width, 18)
        let isCompact = w < 28
        let showsInlineIcon = w > 28
        let showMinutes = showsInlineIcon && leg.durationMinutes > 0
        let dotSize: CGFloat = isCompact ? 5 : 6
        let dotSpacing: CGFloat = isCompact ? 4 : 5

        // When showing minutes label, use fewer dots to make room
        let availableForDots = showMinutes ? max(0, w - 40) : w
        let totalDotWidth = dotSize + dotSpacing
        let dotCount = max(1, min(Int(availableForDots / totalDotWidth), 6))
        let leadingDots = showsInlineIcon ? max(1, (dotCount + 1) / 2) : dotCount
        let trailingDots = showsInlineIcon ? max(0, dotCount - leadingDots) : 0

        return ZStack {
            HStack(spacing: dotSpacing) {
                ForEach(0..<leadingDots, id: \.self) { _ in
                    Circle()
                        .fill(AppTheme.Colors.textTertiary.opacity(0.38))
                        .frame(width: dotSize, height: dotSize)
                }

                if showsInlineIcon {
                    HStack(spacing: 2) {
                        Image(systemName: leg.mode == .transfer ? "arrow.triangle.swap" : "figure.walk")
                            .font(.system(size: isCompact ? 9 : 11, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.9))

                        if showMinutes {
                            Text("\(leg.durationMinutes)")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                        }
                    }

                    ForEach(0..<trailingDots, id: \.self) { _ in
                        Circle()
                            .fill(AppTheme.Colors.textTertiary.opacity(0.38))
                            .frame(width: dotSize, height: dotSize)
                    }
                }
            }
        }
        .frame(width: w, height: barHeight)
    }

    // MARK: - Transfer Dot

    /// Compact connector for very short walk/transfer segments (< 16 px).
    /// Shows a small circle with a mode icon instead of oversized dots.
    private func transferDot(_ leg: TripLeg) -> some View {
        ZStack {
            Circle()
                .fill(AppTheme.Colors.textTertiary.opacity(0.18))
                .frame(width: 14, height: 14)
            Image(systemName: leg.mode == .transfer ? "arrow.triangle.swap" : "figure.walk")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.7))
        }
    }


    private func routeLabel(for leg: TripLeg) -> String {
        if let routeId = leg.routeId, !routeId.isEmpty {
            // Strip common bus suffixes (-SBS, -LTD) for compact display
            if leg.mode == .bus {
                return routeId.components(separatedBy: "-").first ?? routeId
            }
            return routeId
        }
        if let routeName = leg.routeName, !routeName.isEmpty {
            return routeName
        }
        return leg.mode.label
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
        // Position the info row so "Go now/in" aligns with the start of the first bar
        // and the duration label is placed just after the last bar ends.
        let departX = xPos(for: trip.departureTime)
        let arriveX = xPos(for: trip.arrivalTime)

        // Ensure duration label never overlaps the go label by enforcing a minimum gap
        let goLabelEstimatedWidth: CGFloat = 110
        let minDurationX = max(contentInset, departX - 2) + goLabelEstimatedWidth + 8
        let durationX = max(minDurationX, min(arriveX + 6, canvasWidth + contentInset - 64))

        return ZStack(alignment: .topLeading) {
            // "Go now / Go in / Go at" label — anchored at departure x
            goLabel(trip: trip)
                .offset(x: max(contentInset, departX - 2))

            // Duration — anchored just after arrival x, with overlap guard
            Text(trip.durationString)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .offset(x: durationX)
        }
        .frame(width: canvasWidth + 2 * contentInset, height: 24, alignment: .leading)
    }

    private func isMajorMarker(_ date: Date) -> Bool {
        if intervalMinutes >= 60 { return true }
        return Calendar.current.component(.minute, from: date) == 0
    }

    @ViewBuilder
    private func goLabel(trip: TripPlan) -> some View {
        let seconds = trip.departureTime.timeIntervalSince(nowDate)
        let minutes = Int(seconds / 60)
        let hasRealtime = trip.legs.contains { $0.liveStatus?.isRealtime == true }

        if departureOption != .leaveNow {
            HStack(spacing: 3) {
                Text("Go at \(trip.departureTimeString)")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                if hasRealtime {
                    Image(systemName: "dot.radiowaves.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                }
            }
        } else if minutes <= 0 {
            HStack(spacing: 2) {
                Text("Go")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("now")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.successGreen)

                if hasRealtime {
                    Image(systemName: "dot.radiowaves.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                }
            }
        } else if minutes <= 120 {
            HStack(spacing: 2) {
                Text("Go in")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("\(minutes) min")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.successGreen)

                if hasRealtime {
                    Image(systemName: "dot.radiowaves.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                }
            }
        } else {
            Text("Go at \(trip.departureTimeString)")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
    }

    // MARK: - Helpers

    private func xPos(for date: Date) -> CGFloat {
        let fraction = date.timeIntervalSince(windowStart) / windowDuration
        return contentInset + CGFloat(max(0, min(1, fraction))) * canvasWidth
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
        case .lirr:
            if let hex = leg.routeColor, !hex.isEmpty {
                return Color(hex: hex)
            }
            return AppTheme.CommuterRailColors.lirrColor(for: leg.routeId ?? leg.routeName ?? "")
        case .mnr:
            if let hex = leg.routeColor, !hex.isEmpty {
                return Color(hex: hex)
            }
            return AppTheme.CommuterRailColors.mnrColor(for: leg.routeId ?? leg.routeName ?? "")
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
