// Floating overlay controls for the map including 3D toggle,
// recenter button, search pin banner, and selected route banner.

import CoreLocation
import SwiftUI

/// Floating controls overlay displayed above the map.
/// Contains 3D/2D toggle, recenter button, and context banners.
struct MapControlsOverlay: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    @Binding var cameraPosition: TrackCameraPosition
    @Binding var is3DMode: Bool
    @Binding var sheetDetent: PresentationDetent
    let currentMapCenter: CLLocationCoordinate2D?
    let currentMapDistance: Double?
    
    /// Called when the user taps the recenter button — HomeView uses this
    /// to dismiss drag-to-search and snap back to the real GPS location.
    var onRecenter: (() -> Void)?
    
    /// Called when the user taps the alert bell — HomeView navigates to alerts page.
    var onAlertsTapped: (() -> Void)?
    
    var body: some View {
        GeometryReader { geometry in
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
                
                // MARK: - Map Control Cluster (top-right, below compass)
                // Hidden when route detail sheet is open — the sheet's own
                // action rail provides close, 3D, recenter, and favorite buttons.
                if sheetDetent != .large && !viewModel.isRouteDetailPresented {
                    VStack {
                        HStack {
                            Spacer()
                            mapControlCluster
                        }
                        .padding(.trailing, 12)
                        .padding(.top, 52) // Clear the MapLibre compass
                        Spacer()
                    }
                }
            }
        }
    }
    
    // MARK: - Map Control Cluster
    
    /// Unified control pill: alert indicator, 3D toggle, and recenter
    /// grouped inside a single frosted-glass capsule for a clean look.
    private var mapControlCluster: some View {
        VStack(spacing: 8) {
            mapControlButton(
                icon: "exclamationmark.triangle.fill",
                foregroundColor: viewModel.serviceAlerts.isEmpty
                    ? AppTheme.Colors.textPrimary
                    : AppTheme.Colors.warningYellow,
                accessibilityLabel: "Service alerts, \(viewModel.serviceAlerts.count) active"
            ) {
                onAlertsTapped?()
                HapticManager.impact(.medium)
            }

            mapControlButton(
                icon: is3DMode ? "view.2d" : "view.3d",
                // Color logic matches since background is gone
                foregroundColor: AppTheme.Colors.textPrimary,
                accessibilityLabel: is3DMode ? "Switch to 2D" : "Switch to 3D"
            ) {
                toggle3DMode()
            }

            mapControlButton(
                icon: "location.fill",
                foregroundColor: AppTheme.Colors.mtaBlue,
                accessibilityLabel: "Recenter on my location"
            ) {
                centerMap()
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .trackTintedChrome(tint: AppTheme.Colors.mtaBlue, cornerRadius: 18)
        // Badge rendered OUTSIDE the clip shape so it's fully visible
        .overlay(alignment: .topTrailing) {
            if !viewModel.serviceAlerts.isEmpty {
                Text("\(min(viewModel.serviceAlerts.count, 99))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(
                        Circle().fill(
                            viewModel.serviceAlerts.contains(where: { $0.severity == "severe" })
                                ? AppTheme.Colors.alertRed
                                : AppTheme.Colors.warningYellow
                        )
                    )
                    .offset(x: 6, y: -6)
            }
        }
    }

    private func mapControlButton(
        icon: String,
        foregroundColor: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(accessibilityLabel)
    }
    
    // MARK: - Computed Properties
    
    /// Color of the currently selected route
    private var selectedRouteColor: Color {
        if let group = viewModel.selectedGroupedRoute, let hex = group.colorHex {
            return Color(hex: hex)
        }
        if let group = viewModel.selectedGroupedRoute {
            return group.isBus
                ? AppTheme.Colors.mtaBlue
                : AppTheme.SubwayColors.color(for: group.displayName)
        }
        return AppTheme.Colors.mtaBlue
    }
    
    // MARK: - Actions
    
    private func toggle3DMode() {
        withAnimation(MapCameraPresets.smoothAnimation) {
            is3DMode.toggle()
            
            let center = currentMapCenter
                ?? locationManager.currentLocation?.coordinate
                ?? AppTheme.MapConfig.nycCenter
            let distance = currentMapDistance ?? MapCameraPresets.defaultDistance
            
            cameraPosition = MapCameraPresets.center(on: center, distance: distance, is3D: is3DMode)
        }
    }
    
    private func centerMap() {
        // Dismiss drag-to-search and restore real location data
        onRecenter?()
        
        // Collapse the sheet to half-height to reveal the map
        withAnimation(MapCameraPresets.snapAnimation) {
            sheetDetent = SheetConstants.defaultDetent
        }

        // If a route is currently selected, re-invoke the fit algorithm
        // that shows both the user's location and the nearest stop — this
        // is the same camera that was applied on route-open.
        if viewModel.selectedRouteId != nil,
           let fitCamera = viewModel.cameraPositionFittingRoute(
               userLocation: locationManager.currentLocation,
               is3D: is3DMode
           ) {
            withAnimation(MapCameraPresets.flyAnimation) {
                cameraPosition = fitCamera
            }
        } else {
            let userLocation = locationManager.currentLocation?.coordinate
            let finalTarget = userLocation ?? AppTheme.MapConfig.nycCenter
            
            withAnimation(MapCameraPresets.flyAnimation) {
                cameraPosition = MapCameraPresets.center(on: finalTarget, is3D: is3DMode)
            }
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

    /// Route mode label for the banner.
    private var bannerModeLabel: String {
        guard let g = viewModel.selectedGroupedRoute else { return "" }
        if g.isLIRR { return "LIRR" }
        if g.isMNR { return "Metro-North" }
        return g.isBus ? "BUS" : "SUBWAY"
    }

    /// Terminal pair from direction headsigns (or first/last stops fallback).
    private var bannerTerminalPair: (String, String)? {
        // Try direction headsigns first (always reliable)
        if let shape = viewModel.routeShape, shape.directions.count >= 2 {
            let a = shape.directions[0].headsign
            let b = shape.directions[1].headsign
            if !a.isEmpty && !b.isEmpty && a != b {
                return (a, b)
            }
        }
        // Fallback to first/last stop in the combined stops list
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

    /// Severity color for the most urgent alert.
    private var bannerAlertColor: Color {
        bannerRouteAlerts.contains(where: { $0.severity == "severe" })
            ? AppTheme.Colors.alertRed
            : AppTheme.Colors.warningYellow
    }

    private var selectedRouteBanner: some View {
        VStack(spacing: 0) {
            // ── Compact route pill ──
            HStack(spacing: 8) {
                if let group = viewModel.selectedGroupedRoute {
                    RouteBadge(
                        routeID: group.displayName.isEmpty
                            ? stripMTAPrefix(group.routeId)
                            : group.displayName,
                        size: .medium,
                        hexColor: group.colorHex,
                        mode: group.mode
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    // Mode label
                    Text(bannerModeLabel)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundColor(selectedRouteColor)
                        .tracking(0.5)

                    // Terminal names — arrow separator
                    if let pair = bannerTerminalPair {
                        HStack(spacing: 3) {
                            Text(pair.0)
                                .lineLimit(1)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(AppTheme.Colors.textTertiary)
                            Text(pair.1)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    } else if viewModel.routeShape == nil {
                        Text("Loading…")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                    }
                }

                Spacer(minLength: 4)

                // Live count — trailing
                if bannerLiveCount > 0 {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(AppTheme.Colors.successGreen)
                            .frame(width: 5, height: 5)
                        Text("\(bannerLiveCount) live")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.successGreen)
                    }
                }

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // ── Alert strip ──
            if let topAlert = bannerRouteAlerts.first {
                alertStripContent(
                    title: topAlert.title,
                    color: bannerAlertColor,
                    extraCount: bannerRouteAlerts.count - 1
                )
            } else if let inlineAlert = viewModel.selectedGroupedRoute?.alerts.first {
                alertStripContent(
                    title: inlineAlert.title,
                    color: AppTheme.Colors.warningYellow,
                    extraCount: 0
                )
            }
        }
        .trackOverlayGlass(
            tint: selectedRouteColor,
            cornerRadius: 18,
            tintOpacity: 0.04
        )
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        ))
    }

    /// Reusable alert strip row for the banner footer.
    private func alertStripContent(title: String, color: Color, extraCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)

            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.9)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.9))
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }
}

#Preview {
    let vm: HomeViewModel = HomeViewModel()
    let lm: LocationManager = LocationManager()
    let camPos: TrackCameraPosition = .userLocation
    let cameraBinding: Binding<TrackCameraPosition> = .constant(camPos)
    let is3DBinding: Binding<Bool> = .constant(false)
    let fraction: PresentationDetent = SheetConstants.defaultDetent
    let detentBinding: Binding<PresentationDetent> = .constant(fraction)
    let alertsClosure: () -> Void = {}
    ZStack {
        Color.gray.opacity(0.3)
        MapControlsOverlay(
            viewModel: vm,
            locationManager: lm,
            cameraPosition: cameraBinding,
            is3DMode: is3DBinding,
            sheetDetent: detentBinding,
            currentMapCenter: nil,
            currentMapDistance: nil,
            onAlertsTapped: alertsClosure
        )
    }
}
