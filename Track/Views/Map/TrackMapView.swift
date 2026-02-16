//
//  TrackMapView.swift
//  Track
//
//  Extracted MapKit component from HomeView. Displays the interactive
//  transit map with user location, search pins, route polylines, station
//  markers, and live vehicle annotations.
//

import SwiftUI
import MapKit

/// Main map view displaying transit information, routes, and live vehicles.
/// This component encapsulates all MapKit-related rendering logic.
struct TrackMapView: View {
    // MARK: - Dependencies
    
    @Binding var cameraPosition: MapCameraPosition
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    @Binding var showStations: Bool
    @Binding var currentMapCenter: CLLocationCoordinate2D?
    @Binding var currentMapDistance: Double?
    
    // MARK: - Computed Properties
    
    /// Color of the currently selected route, used for polylines and annotations.
    private var selectedRouteColor: Color {
        if let group = viewModel.selectedGroupedRoute, let hex = group.colorHex {
            return Color(hex: hex)
        }
        if let group = viewModel.selectedGroupedRoute {
            if group.isLIRR { return AppTheme.CommuterRailColors.lirrBlue }
            if group.isMNR { return AppTheme.CommuterRailColors.mnrBlue }
            return group.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: group.displayName)
        }
        return AppTheme.Colors.mtaBlue
    }
    
    /// Dashed stroke style for bus route polylines — visually distinct from subway solid lines.
    private var busRouteStrokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
    }
    
    var body: some View {
        Map(position: $cameraPosition,
            bounds: AppTheme.MapConfig.cameraBounds) {
            
            // User location
            UserAnnotation()
            
            // Draggable search pin
            searchPinAnnotation
            
            // Bus stop annotations when in bus mode
            busStopAnnotations
            
            // Route shape stops when a route is selected
            routeStopAnnotations
            
            // Live bus vehicle positions on map
            busVehicleAnnotations
            
            // Live train positions
            trainVehicleAnnotations
            
            // Walking route indicator
            walkingRoutePolyline
            
            // Route polylines
            routePolylines
            
            // System map (default view)
            systemMapPolylines
        }
        .mapStyle(.standard(
            emphasis: .muted,
            pointsOfInterest: .including([.publicTransport]),
            showsTraffic: false
        ))
        .onMapCameraChange(frequency: .continuous) { context in
            // Track camera state for smooth mode switching
            currentMapCenter = context.camera.centerCoordinate
            currentMapDistance = context.camera.distance
            
            // Show stations only when zoomed in past the configured threshold
            let zoomThreshold = AppSettings.shared.stationVisibilityZoomMeters
            let d = context.camera.distance
            if (d < zoomThreshold) != showStations {
                showStations = d < zoomThreshold
            }
        }
        .ignoresSafeArea()
    }
    
    // MARK: - Search Pin
    
    @MapContentBuilder
    private var searchPinAnnotation: some MapContent {
        if viewModel.isSearchPinActive, let pin = viewModel.searchPinCoordinate {
            Annotation("Search here", coordinate: pin) {
                SearchPinAnnotation()
            }
        }
    }
    
    // MARK: - Bus Stop Annotations
    
    @MapContentBuilder
    private var busStopAnnotations: some MapContent {
        if viewModel.selectedMode == .bus {
            ForEach(viewModel.nearbyBusStops) { stop in
                Annotation(stop.name, coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)) {
                    BusStopAnnotation(stopName: stop.name)
                        .onTapGesture {
                            Task {
                                await viewModel.fetchBusArrivals(for: stop)
                            }
                        }
                }
            }
        }
    }
    
    // MARK: - Route Stop Annotations
    
    @MapContentBuilder
    private var routeStopAnnotations: some MapContent {
        if let shape = viewModel.routeShape {
            let isBusRoute = viewModel.selectedGroupedRoute?.isBus == true
            let hasDirections = (viewModel.selectedGroupedRoute?.directions.count ?? 0) > 1
            
            // Use direction-specific stops when the user has picked a direction
            let directionStops = hasDirections
                ? shape.stopsForDirection(viewModel.selectedDirectionIndex)
                : shape.stops
            
            ForEach(directionStops) { stop in
                let isSelected = stop.id == viewModel.selectedStopId
                Annotation(stop.name, coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)) {
                    RouteStopMarker(
                        isBusRoute: isBusRoute,
                        isSelected: isSelected,
                        routeColor: selectedRouteColor,
                        stopName: stop.name
                    )
                    .onTapGesture {
                        withAnimation {
                            viewModel.selectedStopId = stop.id
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Bus Vehicle Annotations
    
    @MapContentBuilder
    private var busVehicleAnnotations: some MapContent {
        ForEach(viewModel.busVehicles) { vehicle in
            let isHighlighted = vehicle.vehicleId == viewModel.highlightedVehicleId
            Annotation(
                vehicle.nextStop ?? vehicle.displayRouteName,
                coordinate: CLLocationCoordinate2D(latitude: vehicle.lat, longitude: vehicle.lon)
            ) {
                BusVehicleAnnotation(
                    routeName: vehicle.displayRouteName,
                    bearing: vehicle.bearing,
                    isHighlighted: isHighlighted
                )
                .zIndex(isHighlighted ? 100 : 1)
            }
        }
    }
    
    // MARK: - Train Vehicle Annotations
    
    @MapContentBuilder
    private var trainVehicleAnnotations: some MapContent {
        ForEach(viewModel.trainVehicles) { train in
            let isHighlighted = train.tripId == viewModel.highlightedVehicleId
            Annotation(train.nextStationName ?? train.routeId, coordinate: CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)) {
                Group {
                    if train.routeId.contains("LIRR") || train.routeId.lowercased().contains("lir") {
                        LIRRAnnotationView(routeId: train.routeId, isHighlighted: isHighlighted)
                    } else if train.routeId.contains("MNR") || train.routeId.lowercased().contains("mnr") || train.routeId.lowercased().contains("metro") {
                        MNRAnnotationView(routeId: train.routeId, isHighlighted: isHighlighted)
                    } else if train.routeId.lowercased().contains("amtrak") || train.routeId.lowercased().contains("amt") {
                        AmtrakAnnotationView(routeId: train.routeId, isHighlighted: isHighlighted)
                    } else {
                        TrainAnnotation(routeId: train.routeId, direction: train.direction, isHighlighted: isHighlighted)
                    }
                }
                .rotationEffect(.degrees(train.bearing ?? 0))
                .zIndex(isHighlighted ? 100 : 1)
            }
        }
    }
    
    // MARK: - Walking Route Polyline
    
    @MapContentBuilder
    private var walkingRoutePolyline: some MapContent {
        if let walkingRoute = viewModel.walkingRoute {
            MapPolyline(walkingRoute.polyline)
                .stroke(Color.gray, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [8, 8]))
        }
    }
    
    // MARK: - Route Polylines
    
    /// Returns the polylines for the currently selected direction.
    /// Uses the backend's per-direction data when available; falls back to
    /// the midpoint-split heuristic for legacy responses without direction data.
    private func filteredPolylines(from polylines: [[CLLocationCoordinate2D]]) -> [[CLLocationCoordinate2D]] {
        guard let group = viewModel.selectedGroupedRoute,
              group.directions.count > 1 else {
            // Single direction — show everything
            return polylines
        }
        
        let directionIndex = viewModel.selectedDirectionIndex
        
        // Prefer the backend's per-direction shape data
        if let shape = viewModel.routeShape, !shape.directions.isEmpty {
            return shape.polylinesForDirection(directionIndex)
        }
        
        // Legacy fallback: split in half (first half = direction 0, second = direction 1)
        guard polylines.count >= 2 else { return polylines }
        let midpoint = polylines.count / 2
        if directionIndex == 0 {
            return Array(polylines.prefix(midpoint))
        } else {
            return Array(polylines.suffix(from: midpoint))
        }
    }
    
    @MapContentBuilder
    private var routePolylines: some MapContent {
        if let shape = viewModel.routeShape {
            let isBusRoute = viewModel.selectedGroupedRoute?.isBus == true
            let allPolylines = shape.decodedPolylines
            
            // Filter to selected direction for ALL modes when direction data exists
            let hasDirections = (viewModel.selectedGroupedRoute?.directions.count ?? 0) > 1
            let polylines = hasDirections ? filteredPolylines(from: allPolylines) : allPolylines
            
            if !polylines.isEmpty {
                ForEach(Array(polylines.enumerated()), id: \.offset) { _, coords in
                    if isBusRoute {
                        MapPolyline(coordinates: coords)
                            .stroke(selectedRouteColor, style: busRouteStrokeStyle)
                    } else {
                        MapPolyline(coordinates: coords)
                            .stroke(selectedRouteColor, lineWidth: 4)
                    }
                }
            } else if !shape.stops.isEmpty {
                let stopCoords = shape.stops.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                }
                MapPolyline(coordinates: stopCoords)
                    .stroke(selectedRouteColor, style: busRouteStrokeStyle)
            }
        }
    }
    
    // MARK: - System Map Polylines
    
    /// Dashed stroke style for commuter rail routes - created once to avoid repeated allocations.
    private static let commuterRailStrokeStyle = StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4])
    
    @MapContentBuilder
    private var systemMapPolylines: some MapContent {
        if viewModel.routeShape == nil {
            // Subway lines - single flat ForEach with stable IDs for optimal performance
            ForEach(viewModel.flattenedSubwayPolylines) { polyline in
                MapPolyline(coordinates: polyline.coordinates)
                    .stroke(polyline.color, lineWidth: polyline.lineWidth)
            }
            
            // Commuter rail lines (LIRR and MNR) - single flat ForEach with stable IDs
            ForEach(viewModel.flattenedCommuterRailPolylines) { polyline in
                MapPolyline(coordinates: polyline.coordinates)
                    .stroke(polyline.color, style: Self.commuterRailStrokeStyle)
            }
            
            // Stations layer (only when zoomed in)
            if showStations {
                ForEach(viewModel.cachedStations) { station in
                    Annotation(station.name, coordinate: station.coordinate) {
                        SubwayStationMarker(station: station)
                    }
                }
            }
        }
    }
}


#Preview {
    TrackMapView(
        cameraPosition: .constant(AppTheme.MapConfig.initialPosition),
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        showStations: .constant(true),
        currentMapCenter: .constant(nil),
        currentMapDistance: .constant(nil)
    )
}
