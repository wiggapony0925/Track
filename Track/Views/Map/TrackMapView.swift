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
    /// "Line Spread" setting. The slider range is 8–30 m (conceptual spread
    /// in shared tunnels); we map that linearly to 2.0–5.0 pt on screen.
    /// Minimum 2pt ensures lines stay visible and curvy even at thinnest.
    ///
    /// No zoom scaling — the corridor offset (~9 m) naturally separates
    /// parallel lines at close zoom and lets them merge at far zoom,
    /// which is identical to Apple Maps' behavior.
    private var systemMapSubwayLineWidth: CGFloat {
        let clamped = min(max(subwayLineSpread, 8), 30)
        return 2.0 + CGFloat((clamped - 8) / 22.0) * 3.0
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
        StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
    }

    /// Stroke style for subway/rail route polylines — solid with rounded ends.
    private static let subwayRouteStrokeStyle = StrokeStyle(
        lineWidth: 4, lineCap: .round, lineJoin: .round)

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

    /// Stops for the active direction filtered to the current map viewport.
    /// Avoids creating hundreds of off-screen Annotation nodes — each is a
    /// separate SwiftUI render tree with hit-testing overhead.
    private var visibleDirectionStops: [BusStop] {
        guard let shape = viewModel.routeShape else { return [] }
        let all = shape.stopsForDirection(
            index: viewModel.selectedDirectionIndex, name: viewModel.selectedDirectionName)
        guard let center = currentMapCenter, let distance = currentMapDistance else {
            return all
        }
        let latSpan = (distance / 111_000) * 1.5
        let lonSpan = (distance / (111_000 * cos(center.latitude * .pi / 180))) * 1.5
        return all.filter { stop in
            abs(stop.lat - center.latitude) <= latSpan
                && abs(stop.lon - center.longitude) <= lonSpan
        }
    }

    @MapContentBuilder
    private var routeStopAnnotations: some MapContent {
        if viewModel.routeShape != nil {
            let isBusRoute = viewModel.selectedGroupedRoute?.isBus == true
            let directionStops = visibleDirectionStops

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
                        let stopCoord = CLLocationCoordinate2D(
                            latitude: stop.lat, longitude: stop.lon)
                        withAnimation {
                            if viewModel.selectedStopId == stop.id {
                                // Deselect — revert to auto-nearest
                                viewModel.selectedStopId = nil
                                viewModel.isStopManuallySelected = false
                                if let userLoc = locationManager.currentLocation {
                                    Task {
                                        await viewModel.refreshWalkingState(
                                            userLocation: userLoc)
                                    }
                                }
                            } else {
                                viewModel.selectedStopId = stop.id
                                viewModel.isStopManuallySelected = true
                                // Update the split anchor so the behind/ahead
                                // polyline coloring follows the tapped stop.
                                viewModel.nearestStopCoordinate = stopCoord
                                // Redraw walking polyline to this stop
                                let origin = viewModel.referenceLocation?.coordinate
                                             ?? locationManager.currentLocation?.coordinate
                                if let from = origin {
                                    Task {
                                        await viewModel.fetchWalkingRoute(
                                            from: from, to: stopCoord)
                                    }
                                }
                            }
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
            // Soft route-colored glow layer underneath for depth
            MapPolyline(walkingRoute.polyline)
                .stroke(
                    selectedRouteColor.opacity(0.25),
                    style: StrokeStyle(
                        lineWidth: 6, lineCap: .round, lineJoin: .round, dash: [1, 10]))
            // White dotted line on top — Apple Maps style walk indicator
            MapPolyline(walkingRoute.polyline)
                .stroke(
                    Color.white,
                    style: StrokeStyle(
                        lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [1, 10]))
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
            // Subtle white casing for depth, then colored fill
            MapPolyline(coordinates: coords)
                .stroke(
                    .white.opacity(casingOpacity * 0.6),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: coords)
                .stroke(color, style: busRouteStrokeStyle)
        } else {
            MapPolyline(coordinates: coords)
                .stroke(
                    .white.opacity(casingOpacity),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: coords)
                .stroke(color, style: Self.subwayRouteStrokeStyle)
        }
    }

    // MARK: - System Map Polylines

    /// Stations filtered to the visible map viewport AND by zoom-based
    /// importance tier — Apple Maps' "generalization" approach.
    ///
    /// As you zoom out, Apple Maps systematically hides detail:
    /// - **> maxZoomOut**: No stations at all — just colored polylines.
    /// - **maxZoomOut × 0.3 – maxZoomOut**: Major transfer complexes only — 3+ color groups.
    /// - **maxZoomOut × 0.16 – maxZoomOut × 0.3**: + Transfer stations — 2+ color groups.
    /// - **< maxZoomOut × 0.16**: All stops visible.
    /// - **< 3.5 km**: Station NAME labels appear.
    private var visibleStations: [HomeViewModel.CachedSubwayStation] {
        guard let center = currentMapCenter, let distance = currentMapDistance else {
            return viewModel.cachedStations
        }

        let maxZoomOut = AppSettings.shared.stationMaxZoomOutMeters

        // At very high zoom-out (> max), hide ALL stations.
        // Apple Maps hides everything at this level — just colored polylines.
        guard distance < maxZoomOut else { return [] }

        // Viewport bounding box with generous padding
        let latSpan = (distance / 111_000) * 1.5
        let lonSpan = (distance / (111_000 * cos(center.latitude * .pi / 180))) * 1.5
        let minLat = center.latitude - latSpan
        let maxLat = center.latitude + latSpan
        let minLon = center.longitude - lonSpan
        let maxLon = center.longitude + lonSpan

        // Zoom-based importance thresholds derived from the user's max zoom-out setting
        let showAllStops = distance < maxZoomOut * 0.16     // ~8 km at default 50 km
        let showTransfers = distance < maxZoomOut * 0.30    // ~15 km at default 50 km
        let showMajorHubs = distance < maxZoomOut            // everything below ceiling

        return viewModel.cachedStations.filter { station in
            // 1) Must be in viewport
            guard station.coordinate.latitude >= minLat,
                  station.coordinate.latitude <= maxLat,
                  station.coordinate.longitude >= minLon,
                  station.coordinate.longitude <= maxLon
            else { return false }

            // 2) Importance filter based on zoom
            if showAllStops { return true }

            let groupCount = Self.colorGroupCount(for: station)
            if showMajorHubs && groupCount >= 3 { return true }
            if showTransfers && groupCount >= 2 { return true }
            return false
        }
    }

    /// Counts distinct MTA trunk-color groups for a station.
    /// Static helper so it can be used in the computed property without
    /// capturing `self` in a closure.
    private static func colorGroupCount(
        for station: HomeViewModel.CachedSubwayStation
    ) -> Int {
        var groups = Set<Int>()
        for route in station.routes {
            groups.insert(trunkGroupIndex(for: route))
        }
        return max(groups.count, 1)
    }

    /// Maps a route ID to its MTA trunk-color group index.
    /// Must match `MapSystemViewModel.trunkGroups` ordering.
    private static func trunkGroupIndex(for routeId: String) -> Int {
        let r = routeId.uppercased()
        switch r {
        case "1", "2", "3":                return 0
        case "4", "5", "6", "6X":          return 1
        case "7", "7X":                    return 2
        case "A", "C", "E":               return 3
        case "B", "D", "F", "FX", "M":    return 4
        case "G":                          return 5
        case "J", "Z":                    return 6
        case "L":                          return 7
        case "N", "Q", "R", "W":          return 8
        case "S":                          return 9
        case "SI":                         return 10
        default:                           return 99
        }
    }

    /// Stroke style for system-map subway casing — white outline for depth.
    private var systemMapSubwayCasingStyle: StrokeStyle {
        StrokeStyle(
            lineWidth: systemMapSubwayLineWidth + 2,
            lineCap: .round,
            lineJoin: .round)
    }

    /// Stroke style for system-map subway fill — colored inner line.
    private var systemMapSubwayFillStyle: StrokeStyle {
        StrokeStyle(
            lineWidth: systemMapSubwayLineWidth,
            lineCap: .round,
            lineJoin: .round)
    }

    /// Route labels filtered to the visible map viewport.
    /// Same approach as station viewport filtering — avoids creating
    /// hundreds of off-screen annotation nodes.
    private var visibleRouteLabels: [HomeViewModel.TrunkRouteLabel] {
        guard let center = currentMapCenter, let distance = currentMapDistance else {
            return viewModel.trunkRouteLabels
        }
        let latSpan = (distance / 111_000) * 1.5
        let lonSpan = (distance / (111_000 * cos(center.latitude * .pi / 180))) * 1.5
        return viewModel.trunkRouteLabels.filter { label in
            abs(label.coordinate.latitude - center.latitude) <= latSpan
                && abs(label.coordinate.longitude - center.longitude) <= lonSpan
        }
    }

    @MapContentBuilder
    private var systemMapPolylines: some MapContent {
        if viewModel.routeShape == nil {
            // ── Polylines: ALWAYS visible at every zoom level ──
            // Single stroke per polyline — no white casing.
            // Removing casing halves the MapPolyline overlay count,
            // dramatically improving scroll/zoom responsiveness.
            ForEach(viewModel.flattenedSubwayPolylines) { polyline in
                MapPolyline(coordinates: polyline.coordinates)
                    .stroke(polyline.color, style: systemMapSubwayFillStyle)
            }

            ForEach(viewModel.flattenedCommuterRailPolylines) { polyline in
                MapPolyline(coordinates: polyline.coordinates)
                    .stroke(
                        polyline.color.opacity(0.35),
                        style: StrokeStyle(
                            lineWidth: max(systemMapSubwayLineWidth - 1, 1),
                            lineCap: .round, lineJoin: .round)
                    )
            }

            // ── Route bullet labels: visible at neighborhood zoom ──
            // These are the colored circles with route letters (A C E, N Q R W)
            // placed at intervals along the trunk polyline.
            // Apple Maps shows these at medium zoom — close enough to read the
            // tiny badges. Viewport-filtered to avoid off-screen annotation cost.
            if let distance = currentMapDistance,
               distance < AppSettings.shared.stationMaxZoomOutMeters * 0.16 {
                ForEach(visibleRouteLabels) { label in
                    Annotation("", coordinate: label.coordinate, anchor: .center) {
                        TrunkRouteLabelView(
                            routeIds: label.routeIds,
                            color: label.color
                        )
                    }
                    .annotationTitles(.hidden)
                }
            }

            // ── Stations: progressive zoom visibility (Apple Maps style) ──
            // `visibleStations` handles viewport clipping AND importance tiers:
            //   • > maxZoomOut: NO stations (just polylines)
            //   • 30–100% of maxZoomOut: major hubs only (3+ color groups)
            //   • 16–30% of maxZoomOut: + transfer stations (2+ groups)
            //   • < 16% of maxZoomOut: all stops
            // Station NAME labels only appear < 3.5 km (via `showStations`).
            ForEach(visibleStations) { station in
                Annotation(station.name, coordinate: station.coordinate) {
                    SubwayStationMarker(
                        station: station,
                        cameraDistance: currentMapDistance
                    )
                }
                .annotationTitles(showStations ? .automatic : .hidden)
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
