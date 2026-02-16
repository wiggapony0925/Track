//
//  MapControlsOverlay.swift
//  Track
//
//  Floating overlay controls for the map including 3D toggle,
//  recenter button, search pin banner, and selected route banner.
//

import SwiftUI
import MapKit

/// Floating controls overlay displayed above the map.
/// Contains 3D/2D toggle, recenter button, and context banners.
struct MapControlsOverlay: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    @Binding var cameraPosition: MapCameraPosition
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
                // MARK: Top Section (Banners on left, controls on right)
                VStack {
                    HStack(alignment: .top) {
                        // Left: Banners
                        VStack(alignment: .leading, spacing: 8) {
                            // Selected route indicator
                            if viewModel.selectedRouteId != nil {
                                selectedRouteBanner
                            }
                        }
                        
                        Spacer()
                        
                        // Right: Map controls (under compass area)
                        if sheetDetent != .large {
                            mapControlButtons
                                .padding(.top, 60) // Position below compass
                        }
                    }
                    .padding(.horizontal, AppTheme.Layout.margin)
                    .padding(.top, 8)
                    
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Map Control Buttons
    
    private var mapControlButtons: some View {
        VStack(spacing: 12) {
            // Service Alerts Bell
            Button {
                onAlertsTapped?()
                HapticManager.impact(.medium)
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(
                            viewModel.serviceAlerts.isEmpty
                                ? AppTheme.Colors.textPrimary
                                : AppTheme.Colors.warningYellow
                        )
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
                    
                    // Badge count
                    if !viewModel.serviceAlerts.isEmpty {
                        Text("\(min(viewModel.serviceAlerts.count, 99))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(
                                Circle().fill(
                                    viewModel.serviceAlerts.contains(where: { $0.severity == "severe" })
                                        ? AppTheme.Colors.alertRed
                                        : AppTheme.Colors.warningYellow
                                )
                            )
                            .offset(x: 4, y: -4)
                    }
                }
            }
            .accessibilityLabel("Service alerts, \(viewModel.serviceAlerts.count) active")
            
            // 3D / 2D Toggle
            Button {
                toggle3DMode()
            } label: {
                Image(systemName: is3DMode ? "square.stack.3d.up.slash" : "square.stack.3d.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(is3DMode ? AppTheme.Colors.mtaBlue : AppTheme.Colors.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
            }
            .accessibilityLabel(is3DMode ? "Switch to 2D" : "Switch to 3D")
            
            // Recenter / Location Button
            Button {
                centerMap()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
            }
            .accessibilityLabel("Recenter on my location")
        }
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
        withAnimation(.easeInOut(duration: 0.8)) {
            is3DMode.toggle()
            
            let center = currentMapCenter ?? locationManager.currentLocation?.coordinate ?? AppTheme.MapConfig.nycCenter
            let distance = currentMapDistance ?? AppTheme.MapConfig.userZoomDistance
            
            cameraPosition = .camera(MapCamera(
                centerCoordinate: center,
                distance: distance,
                heading: 0,
                pitch: is3DMode ? 60 : 0
            ))
        }
    }
    
    private func centerMap() {
        // Dismiss drag-to-search and restore real location data
        onRecenter?()
        
        // Collapse the sheet to half-height to reveal the map
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            sheetDetent = .fraction(0.4)
        }
        
        let userLocation = locationManager.currentLocation?.coordinate
        let finalTarget = userLocation ?? AppTheme.MapConfig.nycCenter
        
        withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: finalTarget,
                distance: AppTheme.MapConfig.userZoomDistance,
                heading: 0,
                pitch: is3DMode ? 60 : 0
            ))
        }
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
            cameraPosition: .constant(AppTheme.MapConfig.initialPosition),
            is3DMode: .constant(false),
            sheetDetent: .constant(.fraction(0.4)),
            currentMapCenter: nil,
            currentMapDistance: nil,
            sheetHeightFraction: 0.42,
            onAlertsTapped: {}
        )
    }
}
