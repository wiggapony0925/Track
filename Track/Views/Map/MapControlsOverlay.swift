// Floating overlay controls for the map including alert indicator,
// recenter button, and selected route banner.
// Redesigned with iOS 18 conventions: symbol effects, smooth
// spring animations, and a compact glassmorphic control island.

import CoreLocation
import SwiftUI

/// Floating controls overlay displayed above the map.
/// Contains alert indicator, recenter button, and route banner.
struct MapControlsOverlay: View {
    // MARK: - Dependencies

    let viewModel: HomeViewModel
    let locationManager: LocationManager
    @Binding var cameraPosition: TrackCameraPosition
    @Binding var sheetDetent: TrackSheetDetent
    let currentMapCenter: CLLocationCoordinate2D?
    let currentMapDistance: Double?

    /// Called when the user taps the recenter button — HomeView uses this
    /// to dismiss drag-to-search and snap back to the real GPS location.
    var onRecenter: (() -> Void)?

    /// Called when the user taps the alert bell — HomeView navigates to alerts page.
    var onAlertsTapped: (() -> Void)?

    /// Two-way binding to the `@AppStorage("drag_to_search")` flag in
    /// HomeView.  Lets the on-map toggle flip it without opening Settings.
    @Binding var dragToSearchEnabled: Bool

    /// Whether a drag-search session is currently active (overlay visible).
    var isDragSearchActive: Bool = false

    /// Called when the toggle button is tapped while a drag-search session
    /// is active — dismisses the session and recenters on the user.
    var onDismissDragSearch: (() -> Void)?

    // MARK: - Internal State

    /// Tracks whether the recenter button was just tapped for the
    /// symbol bounce effect.
    @State private var recenterBounce = false

    /// Pulsing alert badge animation.
    @State private var alertPulse = false

    var body: some View {
        GeometryReader { _ in
            ZStack {
                // MARK: - Route Banner (top-left, below safe area)
                if viewModel.selectedRouteId != nil {
                    VStack {
                        selectedRouteBanner
                            .padding(.trailing, viewModel.isRouteDetailPresented ? AppTheme.Layout.margin : 60)
                            .padding(.leading, AppTheme.Layout.margin)
                            .padding(.top, 8)
                        Spacer()
                    }
                }

                // MARK: - Map Control Island (top-right, below compass)
                // Hidden when route detail sheet is fully open — the sheet
                // provides its own close, 3D, recenter, and favorite buttons.
                if sheetDetent != .large && !viewModel.isRouteDetailPresented {
                    VStack {
                        HStack(alignment: .top) {
                            // ── Drag Search Toggle (top-left) ──
                            if viewModel.selectedRouteId == nil {
                                DragSearchToggleButton(
                                    isEnabled: $dragToSearchEnabled,
                                    isDragSearchActive: isDragSearchActive,
                                    onDismissSession: onDismissDragSearch
                                )
                                .transition(
                                    .opacity.combined(
                                        with: .scale(scale: 0.85, anchor: .topLeading)
                                    )
                                )
                            }

                            Spacer()
                            mapControlIsland
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 52) // Clear the MapLibre compass
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .topTrailing)))
                }
            }
        }
    }

    // MARK: - Map Control Island

    /// Compact glassmorphic pill with alert and recenter controls.
    /// Uses SF Symbol effects and spring animations for polished feel.
    private var mapControlIsland: some View {
        VStack(spacing: 0) {
            // ── Alert Button ──
            controlButton(
                icon: alertIcon,
                tint: alertButtonTint,
                a11y: "Service alerts, \(viewModel.serviceAlerts.count) active"
            ) {
                onAlertsTapped?()
                HapticManager.impact(.medium)
            }

            controlDivider

            // ── Recenter Button ──
            controlButton(
                icon: "location.fill",
                tint: AppTheme.Colors.mtaBlue,
                a11y: "Recenter on my location"
            ) {
                centerMap()
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground.opacity(0.35))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            .white.opacity(0.16),
                            lineWidth: 0.5
                        )
                }
        }
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        // Alert badge — rendered outside the clipped shape.
        .overlay(alignment: .topTrailing) {
            alertBadge
        }
    }

    /// A single control button within the island.
    private func controlButton(
        icon: String,
        tint: Color,
        a11y: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IslandButtonStyle())
        .accessibilityLabel(a11y)
    }

    /// Hairline divider between island controls.
    private var controlDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 28, height: 0.5)
    }

    // MARK: - Alert Badge

    /// The SF Symbol name for the alert button — filled when alerts exist.
    private var alertIcon: String {
        viewModel.serviceAlerts.isEmpty
            ? "bell"
            : "bell.badge.fill"
    }

    /// Alert button tint — neutral when empty, colored when active.
    private var alertButtonTint: Color {
        if viewModel.serviceAlerts.isEmpty {
            return AppTheme.Colors.textSecondary
        }
        return hasSevereAlerts
            ? AppTheme.Colors.alertRed
            : AppTheme.Colors.warningYellow
    }

    /// Whether any service alert is severe.
    private var hasSevereAlerts: Bool {
        viewModel.serviceAlerts.contains { $0.severity == "severe" }
    }

    /// Floating count badge for active service alerts.
    @ViewBuilder
    private var alertBadge: some View {
        if !viewModel.serviceAlerts.isEmpty {
            let count = min(viewModel.serviceAlerts.count, 99)
            Text("\(count)")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, count > 9 ? 5 : 0)
                .frame(minWidth: 18, minHeight: 18)
                .background {
                    Capsule()
                        .fill(hasSevereAlerts
                              ? AppTheme.Colors.alertRed
                              : AppTheme.Colors.warningYellow)
                        .shadow(color: (hasSevereAlerts
                                        ? AppTheme.Colors.alertRed
                                        : AppTheme.Colors.warningYellow).opacity(0.4),
                                radius: 4, x: 0, y: 2)
                }
                .offset(x: 6, y: -6)
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: viewModel.serviceAlerts.count)
        }
    }

    // MARK: - Computed Properties

    /// Color of the currently selected route.
    private var selectedRouteColor: Color {
        if let group = viewModel.selectedGroupedRoute, group.isBus {
            return AppTheme.BusColors.color(forServiceType: group.busServiceType)
        }
        if let group = viewModel.selectedGroupedRoute, let hex = group.colorHex {
            return Color(hex: hex)
        }
        if let group = viewModel.selectedGroupedRoute {
            return group.isBus
                ? AppTheme.BusColors.color(forServiceType: group.busServiceType)
                : AppTheme.SubwayColors.color(for: group.displayName)
        }
        return AppTheme.Colors.mtaBlue
    }

    // MARK: - Actions

    private func centerMap() {
        // Dismiss drag-to-search and restore real location data.
        onRecenter?()

        // Collapse the sheet to reveal the map.
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            sheetDetent = SheetConstants.defaultDetent
        }

        // Determine the target camera — route-fit or user location.
        let targetCamera: TrackCameraPosition
        if viewModel.selectedRouteId != nil,
           let fitCamera = viewModel.cameraPositionFittingRoute(
               userLocation: locationManager.currentLocation,
               is3D: false
           ) {
            targetCamera = fitCamera
        } else {
            let userCoord = locationManager.currentLocation?.coordinate
            let finalTarget = userCoord ?? AppTheme.MapConfig.nycCenter
            targetCamera = MapCameraPresets.center(on: finalTarget, is3D: false)
        }

        // Apply camera with a single decisive animation — no competing
        // withAnimation blocks that could cause jitter.
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
            cameraPosition = targetCamera
        }

        HapticManager.impact(.light)
    }

    // MARK: - Selected Route Banner

    /// Live vehicle count for the currently filtered direction.
    private var bannerLiveCount: Int {
        if viewModel.selectedGroupedRoute?.isBus == true {
            return viewModel.filteredBusVehicles.count
        }
        return viewModel.filteredTrainVehicles.count
    }

    /// Route mode label for the banner — shows service type for buses.
    private var bannerModeLabel: String {
        guard let g = viewModel.selectedGroupedRoute else { return "" }
        if g.isLIRR { return "LIRR" }
        if g.isMNR { return "Metro-North" }
        if g.isBus {
            if let svc = g.busServiceType, svc != "Local" {
                return svc.uppercased()
            }
            return "BUS"
        }
        return "SUBWAY"
    }

    /// Terminal pair from direction headsigns (or first/last stops fallback).
    private var bannerTerminalPair: (String, String)? {
        if let shape = viewModel.routeShape, shape.directions.count >= 2 {
            let a = shape.directions[0].headsign
            let b = shape.directions[1].headsign
            if !a.isEmpty && !b.isEmpty && a != b {
                return (a, b)
            }
        }
        if let first = viewModel.routeShape?.stops.first?.name,
           let last = viewModel.routeShape?.stops.last?.name,
           first != last {
            return (first, last)
        }
        return nil
    }

    /// Route alerts matching the selected route.
    private var bannerRouteAlerts: [TransitAlert] {
        guard let g = viewModel.selectedGroupedRoute else { return [] }
        let byId = viewModel.serviceAlerts.matching(routeId: g.routeId, mode: g.mode)
        let byName = viewModel.serviceAlerts.matching(routeId: g.displayName, mode: g.mode)
        var seen = Set<String>()
        return (byId + byName).filter { seen.insert($0.id).inserted }
    }

    /// Severity color for the most urgent route alert.
    private var bannerAlertColor: Color {
        bannerRouteAlerts.contains { $0.severity == "severe" }
            ? AppTheme.Colors.alertRed
            : AppTheme.Colors.warningYellow
    }

    // MARK: - Route Banner View

    private var selectedRouteBanner: some View {
        VStack(spacing: 0) {
            // ── Route header ──
            HStack(spacing: 8) {
                if let group = viewModel.selectedGroupedRoute {
                    RouteBadge(
                        routeID: group.displayName.isEmpty
                            ? stripMTAPrefix(group.routeId)
                            : group.displayName,
                        size: .medium,
                        hexColor: group.colorHex,
                        mode: group.mode,
                        busServiceType: group.busServiceType
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(bannerModeLabel)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(selectedRouteColor)
                        .tracking(0.5)

                    if let pair = bannerTerminalPair {
                        HStack(spacing: 3) {
                            Text(pair.0)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                            Text(pair.1)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    } else if viewModel.routeShape == nil {
                        Text("Loading…")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                    }
                }

                Spacer(minLength: 4)

                // Live vehicle indicator
                if bannerLiveCount > 0 {
                    liveIndicator
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // ── Alert strip ──
            if let topAlert = bannerRouteAlerts.first {
                alertStrip(
                    title: topAlert.title,
                    color: bannerAlertColor,
                    extraCount: bannerRouteAlerts.count - 1
                )
            } else if let inlineAlert = viewModel.selectedGroupedRoute?.alerts.first {
                alertStrip(
                    title: inlineAlert.title,
                    color: AppTheme.Colors.warningYellow,
                    extraCount: 0
                )
            }
        }
        .trackOverlayGlass(
            tint: selectedRouteColor,
            cornerRadius: 16,
            tintOpacity: 0.04
        )
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        ))
    }

    /// Pulsing live-vehicle count with recording dot.
    private var liveIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(AppTheme.Colors.successGreen)
                .frame(width: 5, height: 5)
                .shadow(color: AppTheme.Colors.successGreen.opacity(0.5), radius: 3)
            Text("\(bannerLiveCount)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.successGreen)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(AppTheme.Colors.successGreen.opacity(0.12))
        }
    }

    /// Alert strip shown at the bottom of the route banner.
    private func alertStrip(title: String, color: Color, extraCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)

            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background {
                        Capsule().fill(.white.opacity(0.9))
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.gradient)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

// MARK: - Island Button Style

/// Press-down spring button style for the control island.
/// Provides a subtle scale-down + opacity shift on press.
private struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview {
    let vm = HomeViewModel()
    let lm = LocationManager()
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        MapControlsOverlay(
            viewModel: vm,
            locationManager: lm,
            cameraPosition: .constant(.userLocation),
            sheetDetent: .constant(SheetConstants.defaultDetent),
            currentMapCenter: nil,
            currentMapDistance: nil,
            onAlertsTapped: {},
            dragToSearchEnabled: .constant(true)
        )
    }
}
