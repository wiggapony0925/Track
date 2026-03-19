import SwiftUI
import CoreLocation

// MARK: - Stop Row Data

/// Value bag fed to `StopRowView` — decouples the component from
/// sheet-internal types like `BusStop`, `NearbyTransitResponse`, etc.
struct StopRowData: Identifiable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let isCurrent: Bool
    let isPassed: Bool
    let isSelected: Bool
    let transfers: [String]            // route display names for transfer badges
    let accessibilityOutages: [String] // descriptions
    let hasElevatorOutage: Bool
    let nextArrivalMinutes: Int?       // nil = no arrival
    let nextArrivalIsScheduled: Bool
    let nextArrivalIsAtStop: Bool      // minutesAway <= 0
    let nextArrivalTimestamp: Int?
    let isFirst: Bool
    let isLast: Bool
}

// MARK: - Stops List View

/// Reusable stops list with route-colored dot timeline, transfer badges,
/// accessibility outage warnings, and next-arrival ETAs.
struct StopsListView: View {
    let stops: [StopRowData]
    let routeColor: Color
    let isLoading: Bool               // shape == nil → show skeleton
    let selectedStopId: String?
    var onStopTapped: ((StopRowData) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(routeColor)

                Text("Stops")
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer()

                if !stops.isEmpty {
                    HStack(spacing: 0) {
                        Text("\(stops.count)")
                            .font(.custom("Helvetica-Bold", size: 12))
                            .foregroundColor(routeColor)
                        Text(" stop\(stops.count == 1 ? "" : "s")")
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            if stops.isEmpty {
                if isLoading {
                    StopsListSkeleton()
                } else {
                    stopsEmptyState
                }
            } else {
                stopsContent
            }
        }
    }

    // MARK: - Sub-Views

    private var stopsEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
            Text("No stops for this direction")
                .font(.custom("Helvetica", size: 15))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    private var stopsContent: some View {
        VStack(spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                StopRowView(
                    stop: stop,
                    routeColor: routeColor
                )
                .opacity(stop.isPassed ? 0.55 : 1.0)
                .contentShape(Rectangle())
                .onTapGesture {
                    onStopTapped?(stop)
                }

                // Timeline connector between stops
                if index < stops.count - 1 {
                    HStack(spacing: 0) {
                        Spacer().frame(width: 27)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                stop.isPassed
                                    ? AppTheme.Colors.textSecondary.opacity(0.15)
                                    : routeColor.opacity(0.25)
                            )
                            .frame(width: 2, height: 8)
                        Spacer()
                    }
                    .padding(.leading, AppTheme.Layout.cardPadding)
                }
            }
        }
        .padding(.vertical, 4)
        .trackCardBackground(cornerRadius: AppTheme.Layout.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                .strokeBorder(routeColor.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

// MARK: - Stop Row View

/// A single stop row with dot indicator, name, transfers, accessibility, and ETA.
struct StopRowView: View {
    let stop: StopRowData
    let routeColor: Color

    private var dotColor: Color {
        stop.isCurrent ? routeColor :
        (stop.isPassed ? AppTheme.Colors.textSecondary.opacity(0.4) : routeColor)
    }

    private var isTerminal: Bool {
        stop.isFirst || stop.isLast
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Stop dot — timeline indicator
            ZStack {
                // Current stop: subtle halo
                if stop.isCurrent {
                    Circle()
                        .fill(routeColor.opacity(0.12))
                        .frame(width: 22, height: 22)
                }
                // Terminal stops: ring style
                if isTerminal && !stop.isCurrent {
                    Circle()
                        .strokeBorder(routeColor, lineWidth: 2)
                        .frame(width: 13, height: 13)
                    Circle()
                        .fill(routeColor)
                        .frame(width: 5, height: 5)
                } else {
                    Circle()
                        .fill(dotColor)
                        .frame(
                            width: stop.isCurrent ? 12 : 7,
                            height: stop.isCurrent ? 12 : 7
                        )
                    if stop.isCurrent {
                        Circle()
                            .fill(AppTheme.Colors.cardFloating)
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .frame(width: 22)

            // Name + badges
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(stop.name)
                        .font(.custom(
                            (stop.isCurrent || isTerminal) ? "Helvetica-Bold" : "Helvetica",
                            size: stop.isCurrent ? 14 : 13
                        ))
                        .foregroundColor(stop.isCurrent ? routeColor : AppTheme.Colors.textPrimary)
                        .lineLimit(1)

                    if stop.isCurrent {
                        Circle()
                            .fill(routeColor)
                            .frame(width: 5, height: 5)
                    }

                    if !stop.accessibilityOutages.isEmpty {
                        Image(systemName: stop.hasElevatorOutage
                              ? "arrow.up.arrow.down.circle.fill" : "stairs")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 18, height: 18)
                            .background(AppTheme.Colors.alertRed)
                            .clipShape(Circle())
                            .help(stop.accessibilityOutages.first ?? "Accessibility outage")
                    }
                }

                // Transfer badges — clean inline row
                if !stop.transfers.isEmpty {
                    transferBadgeRow
                }
            }

            Spacer(minLength: 4)

            // Arrival ETA column
            arrivalColumn
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(stop.isSelected ? routeColor.opacity(0.08) : Color.clear)
                .padding(.horizontal, 4)
        )
        .animation(.easeInOut(duration: 0.2), value: stop.isSelected)
    }

    /// Compact transfer badge row — subway circles and bus pills properly sized.
    private var transferBadgeRow: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))

            // Show up to 8 transfers inline, then "+N"
            let visible = Array(stop.transfers.prefix(8))
            let overflow = stop.transfers.count - visible.count

            ForEach(visible, id: \.self) { route in
                transferBadge(route)
            }

            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
            }
        }
    }

    /// Individual transfer badge — subway gets circles, buses get compact pills.
    @ViewBuilder
    private func transferBadge(_ route: String) -> some View {
        let subwayIDs: Set<String> = ["1","2","3","4","5","6","7","A","C","E","B","D","F","M","G","J","Z","L","N","Q","R","W","S","SI"]
        let isSubway = subwayIDs.contains(route.uppercased())
        if isSubway {
            RouteBadge(routeID: route, size: .custom(18, 10))
        } else {
            RouteBadge(routeID: route, size: .custom(16, 8), isBus: true)
        }
    }

    @ViewBuilder
    private var arrivalColumn: some View {
        if let minutes = stop.nextArrivalMinutes, !stop.nextArrivalIsScheduled || minutes >= 0 {
            if stop.nextArrivalIsAtStop {
                // ── At stop / Now ──
                Text("Now")
                    .font(.custom("Helvetica-Bold", size: 11))
                    .foregroundColor(AppTheme.Colors.successGreen)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppTheme.Colors.successGreen.opacity(0.1))
                    .clipShape(Capsule())
            } else {
                HStack(spacing: 3) {
                    if !stop.nextArrivalIsScheduled {
                        Circle()
                            .fill(AppTheme.Colors.successGreen)
                            .frame(width: 4, height: 4)
                    }
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(minutes)m")
                            .font(.custom("Helvetica-Bold", size: 12))
                            .foregroundColor(
                                stop.isPassed
                                ? AppTheme.Colors.textSecondary.opacity(0.35)
                                : (stop.nextArrivalIsScheduled
                                   ? AppTheme.Colors.textSecondary
                                   : routeColor)
                            )
                        if let ts = stop.nextArrivalTimestamp {
                            Text(Date(timeIntervalSince1970: Double(ts)), style: .time)
                                .font(.custom("Helvetica", size: 9))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(stop.isPassed ? 0.3 : 0.45))
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(
                            stop.isPassed
                            ? Color.clear
                            : (stop.nextArrivalIsScheduled
                               ? AppTheme.Colors.textSecondary.opacity(0.05)
                               : routeColor.opacity(0.07))
                        )
                )
            }
        } else {
            EmptyView()
        }
    }
}
