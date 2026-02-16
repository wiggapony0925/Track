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
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // MARK: Top Section (Banners on left, controls on right)
                VStack {
                    HStack(alignment: .top) {
                        // Left: Banners
                        VStack(alignment: .leading, spacing: 8) {
                            // Search pin indicator
                            if viewModel.isSearchPinActive {
                                searchPinBanner
                            }
                            
                            // Selected route indicator
                            if viewModel.selectedRouteId != nil {
                                selectedRouteBanner
                            }
                        }
                        
                        Spacer()
                        
                        // Right: Map controls (under compass area)
                        if sheetDetent != .large {
                            mapControlButtons
                                .padding(.top, 50) // Position below compass
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
        VStack(spacing: 0) {
            // 3D / 2D Toggle
            Button {
                toggle3DMode()
            } label: {
                Text(is3DMode ? "2D" : "3D")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel(is3DMode ? "Switch to 2D" : "Switch to 3D")
            
            Divider()
                .frame(width: 24)
            
            // Recenter / Location Button
            Button {
                centerMap()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Recenter on my location")
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
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
            
            let center = currentMapCenter ?? locationManager.currentLocation?.coordinate ?? viewModel.searchPinCoordinate ?? AppTheme.MapConfig.nycCenter
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
    
    // MARK: - Search Pin Banner
    
    private var searchPinBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.circle.fill")
                .foregroundColor(AppTheme.Colors.mtaBlue)
            Text("Searching from pin location")
                .font(.custom("Helvetica", size: 13))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            Button {
                Task {
                    await viewModel.clearSearchPin(userLocation: locationManager.currentLocation)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .accessibilityLabel("Clear search pin")
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius))
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
            sheetHeightFraction: 0.42
        )
    }
}
