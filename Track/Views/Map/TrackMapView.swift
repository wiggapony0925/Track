//
//  TrackMapView.swift
//  Track
//
//  Extracted MapKit component from HomeView. Displays the interactive
//  transit map with user location, search pins, route polylines, station
//  markers, and live vehicle annotations.
//

import MapKit
import SwiftUI

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

    /// Whether drag-to-search is currently active.
    var isDragSearchActive: Bool = false

    /// The settled drag-search coordinate (set only after debounce completes).
    /// `nil` while the user is still panning — radius hides during the drag
    /// and reappears instantly once the search fires.
    var dragSearchSettledCenter: CLLocationCoordinate2D?

    // MARK: - AppStorage for radius overlay
    @AppStorage("show_search_radius") private var showSearchRadius = false
    @AppStorage("near_you_radius_meters") private var nearYouRadius: Double = 2414
    @AppStorage("farther_away_radius_meters") private var fartherAwayRadius: Double = 4023
    @AppStorage("much_farther_away_radius_meters") private var muchFartherAwayRadius: Double = 8047
    @AppStorage("subway_line_offset_meters") private var subwayLineSpread: Double = 12

    // MARK: - Computed Properties

    /// Subway line width for the system-map overview, derived from the
    /// "Line Spread" setting. The slider range is 4–30 m (conceptual spread
    /// in shared tunnels); we map that linearly to 1.0–5.0 pt on screen.
    /// Formula: 1.0 + (spread - 4) / (30 - 4) * (5 - 1)
    private var systemMapSubwayLineWidth: CGFloat {
        let clamped = min(max(subwayLineSpread, 4), 30)
        return 1.0 + CGFloat((clamped - 4) / 26.0) * 4.0
    }

    /// Color of the currently selected route, used for polylines and annotations.
    private var selectedRouteColor: Color {
        if let group = viewModel.selectedGroupedRoute, let hex = group.colorHex {
            return Color(hex: hex)
        }
        if let group = viewModel.selectedGroupedRoute {
            if group.isLIRR { return AppTheme.CommuterRailColors.lirrBlue }
            if group.isMNR { return AppTheme.CommuterRailColors.mnrBlue }
            return group.isBus
                ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: group.displayName)
        }
        return AppTheme.Colors.mtaBlue
    }

    /// Stroke style for bus route polylines — rounded caps for smooth joins.
    private var busRouteStrokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
    }

    /// Stroke style for subway/rail route polylines — solid with rounded ends.
    private static let subwayRouteStrokeStyle = StrokeStyle(
        lineWidth: 5, lineCap: .round, lineJoin: .round)

    var body: some View {
        Map(
            position: $cameraPosition,
            bounds: AppTheme.MapConfig.cameraBounds
        ) {

            // User location
            UserAnnotation()

            // Search radius circles
            // During drag-to-search the circles track the live map center
            // so they move in real-time with the user's pan gesture.
            // When not drag-searching, they stay at the user's GPS.
            if showSearchRadius {
                if isDragSearchActive, let center = currentMapCenter {
                    // Live-tracking: use the settled center if available,
                    // otherwise fall back to the current map center so the
                    // circles follow the pan in real-time with no delay.
                    let radiusCenter = dragSearchSettledCenter ?? center
                    SearchRadiusOverlay(
                        center: radiusCenter,
                        nearRadius: nearYouRadius,
                        fartherRadius: fartherAwayRadius,
                        muchFartherRadius: muchFartherAwayRadius
                    )
                } else if !isDragSearchActive, let location = locationManager.currentLocation {
                    // Default: radius around user's real location
                    SearchRadiusOverlay(
                        center: location.coordinate,
                        nearRadius: nearYouRadius,
                        fartherRadius: fartherAwayRadius,
                        muchFartherRadius: muchFartherAwayRadius
                    )
                }
            }

            // Bus stop annotations when in bus mode
            busStopAnnotations

            // Live bus vehicle positions on map
            busVehicleAnnotations

            // Live train positions
            trainVehicleAnnotations

            // Walking route indicator
            walkingRoutePolyline

            // Search pin — shows the drag-search center on the map
            // when a route detail is open. The SwiftUI DragSearchOverlay
            // hides when a route is selected, so this annotation provides
            // a persistent map-level marker at the explored location.
            searchPinAnnotation

            // Route polylines
            routePolylines

            // Route shape stops when a route is selected
            // (rendered after polylines so markers draw on top of the line)
            routeStopAnnotations

            // System map (default view)
            systemMapPolylines
        }
        .mapStyle(
            .standard(
                emphasis: .muted,
                // Hide Apple's built-in transit POI markers when a route is
                // selected — the app renders its own stop annotations in the
                // route color, so Apple's markers create visual clutter with
                // mismatched colors.
                pointsOfInterest: viewModel.selectedRouteId != nil
                    ? .excludingAll
                    : .including([.publicTransport]),
                showsTraffic: false
            )
        )
        .mapControls {
            // Only show compass when rotated, hide everything else
            MapCompass()
        }
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
        // Push the Apple Maps "Legal" link behind the bottom sheet
        .safeAreaPadding(.bottom, 350)
        .ignoresSafeArea()
    }

    // MARK: - Bus Stop Annotations

    @MapContentBuilder
    private var busStopAnnotations: some MapContent {
        EmptyMapContent()
    }

    // MARK: - Route Stop Annotations

    @MapContentBuilder
    private var routeStopAnnotations: some MapContent {
        if let shape = viewModel.routeShape {
            let isBusRoute = viewModel.selectedGroupedRoute?.isBus == true
            let directionStops = shape.stopsForDirection(index: viewModel.selectedDirectionIndex, name: viewModel.selectedDirectionName)

            ForEach(directionStops) { stop in
                let isSelected = stop.id == viewModel.selectedStopId
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon),
                    anchor: .center
                ) {
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
                .annotationTitles(.hidden)
            }
        }
    }

    // MARK: - Bus Vehicle Markers

    @MapContentBuilder
    private var busVehicleAnnotations: some MapContent {
        ForEach(viewModel.filteredBusVehicles) { vehicle in
            BusVehicleMarker(
                vehicle: vehicle,
                isHighlighted: viewModel.tappedVehicleId == vehicle.vehicleId,
                onTap: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        // Toggle: tap again to deselect
                        if viewModel.tappedVehicleId == vehicle.vehicleId {
                            viewModel.tappedVehicleId = nil
                        } else {
                            viewModel.tappedVehicleId = vehicle.vehicleId
                        }
                    }
                }
            )
        }
    }

    // MARK: - Train Vehicle Markers

    @MapContentBuilder
    private var trainVehicleAnnotations: some MapContent {
        ForEach(viewModel.filteredTrainVehicles) { train in
            let rid = train.routeId.lowercased()
            let vehicleKey = train.tripId ?? train.id
            let isHighlighted = viewModel.tappedVehicleId == vehicleKey
            let onTap = {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    // Toggle: tap again to deselect
                    if viewModel.tappedVehicleId == vehicleKey {
                        viewModel.tappedVehicleId = nil
                    } else {
                        viewModel.tappedVehicleId = vehicleKey
                    }
                }
            }
            if rid.contains("lirr") || rid.contains("lir") {
                LIRRMarker(train: train, isHighlighted: isHighlighted, onTap: onTap)
            } else if rid.contains("mnr") || rid.contains("metro") {
                MNRMarker(train: train, isHighlighted: isHighlighted, onTap: onTap)
            } else {
                SubwayTrainMarker(train: train, isHighlighted: isHighlighted, onTap: onTap)
            }
        }
    }

    // MARK: - Walking Route Polyline

    @MapContentBuilder
    private var walkingRoutePolyline: some MapContent {
        if let walkingRoute = viewModel.walkingRoute {
            MapPolyline(walkingRoute.polyline)
                .stroke(
                    Color.gray,
                    style: StrokeStyle(
                        lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [8, 8]))
        }
    }

    // MARK: - Search Pin Annotation

    /// Shows an Apple-style blue dot at the drag-search center when the
    /// search pin is active. Only visible when a route detail is open —
    /// the SwiftUI DragSearchOverlay already renders a center dot during
    /// active drag-to-search, so this annotation avoids doubling up.
    @MapContentBuilder
    private var searchPinAnnotation: some MapContent {
        // Only show when a route is selected (DragSearchOverlay hides during
        // route detail, so this map annotation takes over as the sole indicator).
        if viewModel.isSearchPinActive,
            viewModel.selectedRouteId != nil,
            let coord = viewModel.searchPinCoordinate
        {
            Annotation("Search area", coordinate: coord) {
                ZStack {
                    // Accuracy halo
                    Circle()
                        .fill(Color(red: 0.0, green: 0.48, blue: 1.0).opacity(0.12))
                        .frame(width: 36, height: 36)
                    // White border
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    // Blue fill
                    Circle()
                        .fill(Color(red: 0.0, green: 0.48, blue: 1.0))
                        .frame(width: 12, height: 12)
                }
            }
        }
    }

    // MARK: - Route Polylines

    @MapContentBuilder
    private var routePolylines: some MapContent {
        let polylines = viewModel.cachedRoutePolylines
        let inactivePolylines = viewModel.cachedInactivePolylines
        let isBus = viewModel.selectedGroupedRoute?.isBus == true
        let split = viewModel.directionalSplit

        // 1) Inactive directions — draw first (behind) at low opacity.
        //    Shows branches, short-turns, and alternate paths so users
        //    understand the full route structure.
        ForEach(Array(inactivePolylines.enumerated()), id: \.offset) { _, coords in
            if coords.count >= 2 {
                polylineStroke(
                    coords: coords,
                    color: selectedRouteColor.opacity(0.15),
                    casingOpacity: 0.15,
                    isBus: isBus)
            }
        }

        // 2) Active direction — full color or two-tone split
        if let split, !split.ahead.isEmpty || !split.behind.isEmpty {
            // Two-tone rendering: faded "behind" + full-color "ahead"
            // Each is an array of separate polyline segments to avoid
            // straight-line artifacts between disconnected route portions.
            ForEach(Array(split.behind.enumerated()), id: \.offset) { _, coords in
                if coords.count >= 2 {
                    polylineStroke(
                        coords: coords, color: selectedRouteColor.opacity(0.25),
                        casingOpacity: 0.3, isBus: isBus)
                }
            }
            ForEach(Array(split.ahead.enumerated()), id: \.offset) { _, coords in
                if coords.count >= 2 {
                    polylineStroke(
                        coords: coords, color: selectedRouteColor,
                        casingOpacity: 0.8, isBus: isBus)
                }
            }
        } else if !polylines.isEmpty {
            // No directional split — full color for all segments
            ForEach(Array(polylines.enumerated()), id: \.offset) { _, coords in
                polylineStroke(
                    coords: coords, color: selectedRouteColor,
                    casingOpacity: 0.8, isBus: isBus)
            }
        } else if let shape = viewModel.routeShape {
            // Fallback: connect stops when no polyline data
            let fallbackStops = shape.stopsForDirection(index: viewModel.selectedDirectionIndex, name: viewModel.selectedDirectionName)
            if fallbackStops.count >= 2 {
                let stopCoords = fallbackStops.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                }
                MapPolyline(coordinates: stopCoords)
                    .stroke(selectedRouteColor, style: busRouteStrokeStyle)
            }
        }
    }

    /// Reusable polyline stroke — draws white casing + colored line for subway/rail,
    /// or a single colored line for bus routes.
    @MapContentBuilder
    private func polylineStroke(
        coords: [CLLocationCoordinate2D], color: Color,
        casingOpacity: Double, isBus: Bool
    ) -> some MapContent {
        if isBus {
            MapPolyline(coordinates: coords)
                .stroke(color, style: busRouteStrokeStyle)
        } else {
            MapPolyline(coordinates: coords)
                .stroke(
                    .white.opacity(casingOpacity),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: coords)
                .stroke(color, style: Self.subwayRouteStrokeStyle)
        }
    }

    // MARK: - System Map Polylines

    /// Dashed stroke style for commuter rail routes - created once to avoid repeated allocations.
    private static let commuterRailStrokeStyle = StrokeStyle(
        lineWidth: 2.5, lineCap: .round, dash: [6, 4])

    /// Stations filtered to the visible map viewport.
    /// Avoids rendering hundreds of off-screen annotations, which is one of
    /// the biggest performance drains when stations are visible.
    private var visibleStations: [HomeViewModel.CachedSubwayStation] {
        guard let center = currentMapCenter, let distance = currentMapDistance else {
            return viewModel.cachedStations
        }
        // Convert camera distance to an approximate lat/lon span with generous padding
        // 1° latitude ≈ 111 km; use 1.5× to include stations just outside the viewport
        let latSpan = (distance / 111_000) * 1.5
        let lonSpan = (distance / (111_000 * cos(center.latitude * .pi / 180))) * 1.5
        let minLat = center.latitude - latSpan
        let maxLat = center.latitude + latSpan
        let minLon = center.longitude - lonSpan
        let maxLon = center.longitude + lonSpan

        return viewModel.cachedStations.filter { station in
            station.coordinate.latitude >= minLat
                && station.coordinate.latitude <= maxLat
                && station.coordinate.longitude >= minLon
                && station.coordinate.longitude <= maxLon
        }
    }

    @MapContentBuilder
    private var systemMapPolylines: some MapContent {
        if viewModel.routeShape == nil {
            // Subway lines - single flat ForEach with stable IDs for optimal performance
            // Line width is driven by the "Line Spread" setting (subway_line_offset_meters).
            ForEach(viewModel.flattenedSubwayPolylines) { polyline in
                MapPolyline(coordinates: polyline.coordinates)
                    .stroke(polyline.color, lineWidth: systemMapSubwayLineWidth)
            }

            // Commuter rail lines (LIRR and MNR) - single flat ForEach with stable IDs
            ForEach(viewModel.flattenedCommuterRailPolylines) { polyline in
                MapPolyline(coordinates: polyline.coordinates)
                    .stroke(polyline.color, style: Self.commuterRailStrokeStyle)
            }

            // Stations layer (only when zoomed in, filtered to visible viewport)
            if showStations {
                ForEach(visibleStations) { station in
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
