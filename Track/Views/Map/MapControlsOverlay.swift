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
        VStack(spacing: 0) {
            // Service Alerts Button
            Button {
                onAlertsTapped?()
                HapticManager.impact(.medium)
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(
                        viewModel.serviceAlerts.isEmpty
                            ? AppTheme.Colors.textPrimary
                            : AppTheme.Colors.warningYellow
                    )
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Service alerts, \(viewModel.serviceAlerts.count) active")
            
            controlDivider
            
            // 3D / 2D Toggle
            Button {
                toggle3DMode()
            } label: {
                Image(systemName: is3DMode ? "view.2d" : "view.3d")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(is3DMode ? AppTheme.Colors.mtaBlue : AppTheme.Colors.textPrimary)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel(is3DMode ? "Switch to 2D" : "Switch to 3D")
            
            controlDivider
            
            // Recenter / Location Button
            Button {
                centerMap()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Recenter on my location")
        }
        .padding(.top, 4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
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
    
    /// Thin divider between buttons inside the control cluster.
    private var controlDivider: some View {
        Rectangle()
            .fill(AppTheme.Colors.textSecondary.opacity(0.2))
            .frame(width: 30, height: 0.5)
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
                    .frame(width: 24, height: 24)
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .bold))
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
                
                if let firstStop = viewModel.routeShape?.stops.first?.name,
                   let lastStop = viewModel.routeShape?.stops.last?.name {
                    Text("\(name) — \(firstStop) to \(lastStop)")
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                } else {
                    let stopsCount = viewModel.routeShape?.stops.count ?? 0
                    Text("\(name) — \(stopsCount) stops")
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                }
            }
            
            Spacer()
            
            if viewModel.selectedGroupedRoute?.isBus == true {
                Button {
                    Task { await viewModel.refreshBusVehicles() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(selectedRouteColor)
                }
                .accessibilityLabel("Refresh bus positions")
            }
            
            Button {
                viewModel.clearRoute()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .accessibilityLabel("Close route view")
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius))
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
        MapControlsOverlay(
            viewModel: HomeViewModel(),
            locationManager: LocationManager(),
            cameraPosition: .constant(.userLocation),
            is3DMode: .constant(false),
            sheetDetent: .constant(.fraction(0.4)),
            currentMapCenter: nil,
            currentMapDistance: nil,
            sheetHeightFraction: 0.42,
            onAlertsTapped: {}
        )
    }
}
