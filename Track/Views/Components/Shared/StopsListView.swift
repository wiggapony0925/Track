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
                .opacity(stop.isPassed ? 0.4 : 1.0)
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
                                    ? AppTheme.Colors.textSecondary.opacity(0.12)
                                    : routeColor.opacity(0.2)
                            )
                            .frame(width: 2.5, height: 14)
                        Spacer()
                    }
                    .padding(.leading, AppTheme.Layout.cardPadding)
                }
            }
        }
        .padding(.vertical, 6)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
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
        HStack(alignment: .center, spacing: 12) {
            // Stop dot — timeline indicator
            ZStack {
                // Current stop: large pulse halo
                if stop.isCurrent {
                    Circle()
                        .fill(routeColor.opacity(0.15))
                        .frame(width: 24, height: 24)
                }
                // Terminal stops: ring style
                if isTerminal && !stop.isCurrent {
                    Circle()
                        .strokeBorder(routeColor, lineWidth: 2.5)
                        .frame(width: 15, height: 15)
                    Circle()
                        .fill(routeColor)
                        .frame(width: 7, height: 7)
                } else {
                    Circle()
                        .fill(dotColor)
                        .frame(
                            width: stop.isCurrent ? 14 : 9,
                            height: stop.isCurrent ? 14 : 9
                        )
                    if stop.isCurrent {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .frame(width: 24)

            // Name + badges
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(stop.name)
                        .font(.custom(
                            (stop.isCurrent || isTerminal) ? "Helvetica-Bold" : "Helvetica",
                            size: stop.isCurrent ? 15 : 14
                        ))
                        .foregroundColor(stop.isCurrent ? routeColor : AppTheme.Colors.textPrimary)
                        .lineLimit(1)

                    if stop.isCurrent {
                        Text("HERE")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(routeColor)
                            .clipShape(Capsule())
                    }

                    if !stop.accessibilityOutages.isEmpty {
                        Image(systemName: stop.hasElevatorOutage
                              ? "arrow.up.arrow.down.circle.fill" : "stairs")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(AppTheme.Colors.alertRed)
                            .clipShape(Circle())
                            .help(stop.accessibilityOutages.first ?? "Accessibility outage")
                    }
                }

                // Transfer badges
                if !stop.transfers.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.swap")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))

                            ForEach(stop.transfers, id: \.self) { route in
                                RouteBadge(routeID: route, size: .custom(22, 11))
                            }
                        }
                    }
                }
            }

            Spacer()

            // Arrival ETA column — pill style
            arrivalColumn
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(stop.isSelected ? routeColor.opacity(0.08) : Color.clear)
                .padding(.horizontal, 4)
        )
        .animation(.easeInOut(duration: 0.2), value: stop.isSelected)
    }

    @ViewBuilder
    private var arrivalColumn: some View {
        if let minutes = stop.nextArrivalMinutes, !stop.nextArrivalIsScheduled || minutes >= 0 {
            if stop.nextArrivalIsAtStop {
                // ── At stop / Now ──
                Text("Now")
                    .font(.custom("Helvetica-Bold", size: 12))
                    .foregroundColor(AppTheme.Colors.successGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.Colors.successGreen.opacity(0.1))
                    .clipShape(Capsule())
            } else {
                HStack(spacing: 4) {
                    if !stop.nextArrivalIsScheduled {
                        Circle()
                            .fill(AppTheme.Colors.successGreen)
                            .frame(width: 5, height: 5)
                    }
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(minutes)m")
                            .font(.custom("Helvetica-Bold", size: 13))
                            .foregroundColor(
                                stop.isPassed
                                ? AppTheme.Colors.textSecondary.opacity(0.35)
                                : (stop.nextArrivalIsScheduled
                                   ? AppTheme.Colors.textSecondary
                                   : routeColor)
                            )
                        if let ts = stop.nextArrivalTimestamp {
                            Text(Date(timeIntervalSince1970: Double(ts)), style: .time)
                                .font(.custom("Helvetica", size: 10))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(stop.isPassed ? 0.3 : 0.5))
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(
                            stop.isPassed
                            ? Color.clear
                            : (stop.nextArrivalIsScheduled
                               ? AppTheme.Colors.textSecondary.opacity(0.06)
                               : routeColor.opacity(0.08))
                        )
                )
            }
        } else {
            EmptyView()
        }
    }
}
