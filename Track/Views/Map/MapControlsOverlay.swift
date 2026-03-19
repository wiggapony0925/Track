//
//  MapControlsOverlay.swift
//  Track
//
//  Floating overlay controls for the map including 3D toggle,
//  recenter button, search pin banner, and selected route banner.
//

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
    let sheetHeightFraction: CGFloat
    
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
                            .padding(.trailing, 60) // Leave room for control cluster
                            .padding(.leading, AppTheme.Layout.margin)
                            .padding(.top, 8)
                        Spacer()
                    }
                }
                
                // MARK: - Map Control Cluster (top-right, below compass)
                if sheetDetent != .large {
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
                foregroundColor: is3DMode ? AppTheme.Colors.textPrimary : AppTheme.Colors.textPrimary, // Changed color logic to match since background is gone
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
            return group.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: group.displayName)
        }
        return AppTheme.Colors.mtaBlue
    }
    
    // MARK: - Actions
    
    private func toggle3DMode() {
        withAnimation(MapCameraPresets.smoothAnimation) {
            is3DMode.toggle()
            
            let center = currentMapCenter ?? locationManager.currentLocation?.coordinate ?? AppTheme.MapConfig.nycCenter
            let distance = currentMapDistance ?? MapCameraPresets.defaultDistance
            
            cameraPosition = MapCameraPresets.center(on: center, distance: distance, is3D: is3DMode)
        }
    }
    
    private func centerMap() {
        // Dismiss drag-to-search and restore real location data
        onRecenter?()
        
        // Collapse the sheet to half-height to reveal the map
        withAnimation(MapCameraPresets.snapAnimation) {
            sheetDetent = .fraction(0.4)
        }

        // If a route is currently selected, re-invoke the fit algorithm
        // that shows both the user's location and the nearest stop — this
        // is the same camera that was applied on route-open.
        if viewModel.selectedRouteId != nil,
           let fitCamera = viewModel.cameraPositionFittingRoute(
               userLocation: locationManager.currentLocation,
               is3D: is3DMode,
               sheetFraction: sheetHeightFraction
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
    
    private var selectedRouteBanner: some View {
        HStack(spacing: 8) {
            let group = viewModel.selectedGroupedRoute
            
            // Mode-specific icon
            let iconName: String = {
                if group?.isBus == true { return "bus.fill" }
                if group?.isLIRR == true { return "train.side.front.car" }
                if group?.isMNR == true { return "train.side.rear.car" }
                return "tram.fill" // subway default
            }()
            
            ZStack {
                Circle()
                    .fill(selectedRouteColor)
                    .frame(width: 28, height: 28)
                    .shadow(color: selectedRouteColor.opacity(0.30), radius: 10, x: 0, y: 4)
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
            }
            
            if let routeId = viewModel.selectedRouteId {
                let name: String = {
                    if let g = group {
                        if g.isLIRR { return "LIRR \(g.displayName)" }
                        if g.isMNR { return "MNR \(g.displayName)" }
                    }
                    return stripMTAPrefix(routeId)
                }()

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)

                    if let firstStop = viewModel.routeShape?.stops.first?.name,
                       let lastStop = viewModel.routeShape?.stops.last?.name {
                        Text("\(firstStop) to \(lastStop)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(selectedRouteColor.opacity(0.84))
                            .lineLimit(1)
                    } else if viewModel.routeShape == nil {
                        // Shape hasn't loaded yet (still fetching or failed)
                        Text("Loading route…")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(selectedRouteColor.opacity(0.55))
                    } else {
                        let stopsCount = viewModel.routeShape?.stops.count ?? 0
                        Text("\(stopsCount) stops on route")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(selectedRouteColor.opacity(0.84))
                    }
                }
            }
            
            Spacer()
            
            if viewModel.selectedGroupedRoute?.isBus == true {
                Button {
                    Task { await viewModel.refreshBusVehicles() }
                } label: {
                    Circle()
                        .fill(AppTheme.Gradients.controlSurface)
                        .overlay {
                            Circle()
                                .stroke(selectedRouteColor.opacity(0.22), lineWidth: 1)
                        }
                        .overlay {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(selectedRouteColor)
                        }
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Refresh bus positions")
            }
            
            Button {
                viewModel.clearRoute()
            } label: {
                Circle()
                    .fill(AppTheme.Gradients.controlSurface)
                    .overlay {
                        Circle()
                            .stroke(AppTheme.Colors.borderSubtle, lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("Close route view")
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 10)
        .trackTintedChrome(tint: selectedRouteColor, cornerRadius: AppTheme.Layout.cornerRadius)
    }
}

#Preview {
    let vm: HomeViewModel = HomeViewModel()
    let lm: LocationManager = LocationManager()
    let camPos: TrackCameraPosition = .userLocation
    let cameraBinding: Binding<TrackCameraPosition> = .constant(camPos)
    let is3DBinding: Binding<Bool> = .constant(false)
    let fraction: PresentationDetent = .fraction(0.4)
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
            sheetHeightFraction: 0.42,
            onAlertsTapped: alertsClosure
        )
    }
}
