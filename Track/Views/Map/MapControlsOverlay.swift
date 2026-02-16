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
            VStack {
                // MARK: Top Section (Banners)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
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
                }
                
                Spacer()
            }
            
            // MARK: Map Control Buttons (Right Side)
            if sheetDetent != .large {
                VStack(spacing: 12) {
                    // 3D / 2D Toggle
                    Button {
                        toggle3DMode()
                    } label: {
                        Text(is3DMode ? "2D" : "3D")
                            .font(.custom("Helvetica-Bold", size: 15))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                    }
                    .accessibilityLabel(is3DMode ? "Switch to 2D" : "Switch to 3D")
                    
                    // Recenter / Location Button
                    Button {
                        centerMap()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                            .frame(width: 44, height: 44)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                    }
                    .accessibilityLabel("Recenter on my location")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, AppTheme.Layout.margin)
                .padding(.bottom, geometry.size.height * sheetHeightFraction + 8)
                .transition(.opacity)
            }
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
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 8)
    }
    
    // MARK: - Selected Route Banner
    
    private var selectedRouteBanner: some View {
        HStack(spacing: 8) {
            let isSubway = viewModel.selectedGroupedRoute?.isBus == false
            
            ZStack {
                Circle()
                    .fill(selectedRouteColor)
                    .frame(width: 24, height: 24)
                Image(systemName: isSubway ? "tram.fill" : "bus.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
            }
            
            if let routeId = viewModel.selectedRouteId {
                let name = stripMTAPrefix(routeId)
                let stopsCount = viewModel.routeShape?.stops.count ?? 0
                
                if let firstStop = viewModel.routeShape?.stops.first?.name,
                   let lastStop = viewModel.routeShape?.stops.last?.name {
                    Text("\(name) — \(firstStop) to \(lastStop)")
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                } else {
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
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 4)
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
