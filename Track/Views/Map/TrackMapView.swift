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

    // MARK: - Viewport Caching
    //
    // Instead of recomputing O(n) viewport-filtered arrays on EVERY
    // camera frame (60 fps during pan/zoom), we cache them and only
    // recompute when the camera moves a meaningful amount. This is the
    // single biggest performance win — eliminates per-frame trig on
    // 400+ stations and 100+ route labels.

    /// Cached stations visible in the current viewport.
    @State private var _cachedVisibleStations: [MapSystemViewModel.ConsolidatedStation] = []
    /// Cached transfer connectors between multi-platform complexes.
    @State private var _cachedTransferConnectors: [TransferConnector] = []
    /// Cached route labels visible in the current viewport.
    @State private var _cachedVisibleLabels: [HomeViewModel.TrunkRouteLabel] = []
    /// Cached direction stops visible in the current viewport.
    @State private var _cachedVisibleStops: [BusStop] = []
    /// Camera center when the viewport cache was last refreshed.
    @State private var _lastViewportCenter: CLLocationCoordinate2D?
    /// Camera distance when the viewport cache was last refreshed.
    @State private var _lastViewportDistance: Double?

    /// Discrete zoom tier passed to station annotations.
    /// Changes only when crossing a tier boundary, so station marker
    /// bodies don't re-evaluate on every pixel of zoom.
    @State private var _zoomTier: ZoomTier = .medium

    /// Discrete zoom tiers to avoid continuous re-renders of station markers.
    enum ZoomTier: CGFloat {
        case veryClose = 1.8
        case close     = 1.3
        case medium    = 1.0
        case far       = 0.7
        case distant   = 0.4
    }

    private static func zoomTier(for distance: Double?) -> ZoomTier {
        guard let d = distance else { return .medium }
        if d < 1_500 { return .veryClose }
        if d < 3_500 { return .close }
        if d < 8_000 { return .medium }
        if d < 25_000 { return .far }
        return .distant
    }

    // MARK: - Computed Properties

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
    private static let busRouteStrokeStyle = StrokeStyle(
        lineWidth: 4, lineCap: .round, lineJoin: .round)

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

            // Update discrete zoom tier (only triggers station re-render
            // when crossing a boundary, not every frame)
            let newTier = Self.zoomTier(for: d)
            if newTier != _zoomTier {
                _zoomTier = newTier
            }

            // Refresh viewport-cached arrays only when the camera moves
            // a meaningful amount — avoids O(n) filtering every frame.
            let center = context.camera.centerCoordinate
            let needsRefresh: Bool
            if let lastC = _lastViewportCenter, let lastD = _lastViewportDistance {
                let latDelta = abs(center.latitude - lastC.latitude)
                let lonDelta = abs(center.longitude - lastC.longitude)
                let distRatio = abs(d - lastD) / max(lastD, 1)
                // Refresh if panned > 0.2% of viewport or zoomed > 10%
                let panThreshold = (d / 111_000) * 0.002
                needsRefresh = latDelta > panThreshold || lonDelta > panThreshold || distRatio > 0.10
            } else {
                needsRefresh = true
            }
            if needsRefresh {
                _lastViewportCenter = center
                _lastViewportDistance = d
                _cachedVisibleStations = computeVisibleStations(center: center, distance: d)
                _cachedTransferConnectors = computeTransferConnectors(from: _cachedVisibleStations)
                _cachedVisibleLabels = computeVisibleRouteLabels(center: center, distance: d)
                _cachedVisibleStops = computeVisibleDirectionStops(center: center, distance: d)
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
    /// Computed on demand when the camera moves significantly, then cached.
    private func computeVisibleDirectionStops(
        center: CLLocationCoordinate2D, distance: Double
    ) -> [BusStop] {
        guard let shape = viewModel.routeShape else { return [] }
        let all = shape.stopsForDirection(
            index: viewModel.selectedDirectionIndex, name: viewModel.selectedDirectionName)
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
            let directionStops = _cachedVisibleStops

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
                    .stroke(selectedRouteColor, style: Self.busRouteStrokeStyle)
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
                .mapOverlayLevel(level: .aboveLabels)
            MapPolyline(coordinates: coords)
                .stroke(color, style: Self.busRouteStrokeStyle)
                .mapOverlayLevel(level: .aboveLabels)
        } else {
            MapPolyline(coordinates: coords)
                .stroke(
                    .white.opacity(casingOpacity),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                .mapOverlayLevel(level: .aboveLabels)
            MapPolyline(coordinates: coords)
                .stroke(color, style: Self.subwayRouteStrokeStyle)
                .mapOverlayLevel(level: .aboveLabels)
        }
    }

    // MARK: - System Map Polylines

    /// Stations filtered to the visible map viewport AND by zoom-based
    /// importance tier — Apple Maps' "generalization" approach.
    ///
    /// Uses consolidated (proximity-merged) stations so co-located stops
    /// like 74 St-Broadway (7/E/F/M/R) appear as a single capsule.
    /// Computed on camera move (debounced), then cached in `_cachedVisibleStations`.
    private func computeVisibleStations(
        center: CLLocationCoordinate2D, distance: Double
    ) -> [MapSystemViewModel.ConsolidatedStation] {
        let maxZoomOut = AppSettings.shared.stationMaxZoomOutMeters
        guard distance < maxZoomOut else { return [] }

        let latSpan = (distance / 111_000) * 1.5
        let lonSpan = (distance / (111_000 * cos(center.latitude * .pi / 180))) * 1.5
        let minLat = center.latitude - latSpan
        let maxLat = center.latitude + latSpan
        let minLon = center.longitude - lonSpan
        let maxLon = center.longitude + lonSpan

        let showAllStops = distance < maxZoomOut * 0.16
        let showTransfers = distance < maxZoomOut * 0.30
        let showMajorHubs = distance < maxZoomOut

        return viewModel.consolidatedStations.filter { station in
            guard station.coordinate.latitude >= minLat,
                  station.coordinate.latitude <= maxLat,
                  station.coordinate.longitude >= minLon,
                  station.coordinate.longitude <= maxLon
            else { return false }

            if showAllStops { return true }
            let groupCount = station.colorGroupCount
            if showMajorHubs && groupCount >= 3 { return true }
            if showTransfers && groupCount >= 2 { return true }
            return false
        }
    }

    // MARK: - Transfer Connectors

    /// A thin grey line connecting two platforms in the same station complex
    /// that are on different physical levels (e.g., elevated 7 ↔ underground E/F/M/R).
    struct TransferConnector: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        /// Straight-line distance in meters from the platform to the
        /// complex centroid.  Short distances (vertical transfers like
        /// 74 St) get a thicker, more opaque line; long walking
        /// transfers get thinner, fainter lines.
        let distanceMeters: Double
    }

    /// Builds transfer connector lines between visible stations that share
    /// the same `complexID` but have different station IDs (= different platforms).
    private func computeTransferConnectors(
        from stations: [MapSystemViewModel.ConsolidatedStation]
    ) -> [TransferConnector] {
        // Group visible stations by complexID
        var byComplex: [Int: [MapSystemViewModel.ConsolidatedStation]] = [:]
        for station in stations {
            byComplex[station.complexID, default: []].append(station)
        }

        var connectors: [TransferConnector] = []
        for (complexID, platforms) in byComplex {
            guard platforms.count >= 2 else { continue }
            // Connect all platforms to the centroid with a star pattern
            let avgLat = platforms.map(\.coordinate.latitude).reduce(0, +) / Double(platforms.count)
            let avgLon = platforms.map(\.coordinate.longitude).reduce(0, +) / Double(platforms.count)
            let center = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            let centerLoc = CLLocation(latitude: avgLat, longitude: avgLon)
            for (i, platform) in platforms.enumerated() {
                let dist = CLLocation(
                    latitude: platform.coordinate.latitude,
                    longitude: platform.coordinate.longitude
                ).distance(from: centerLoc)
                connectors.append(TransferConnector(
                    id: "xfer-\(complexID)-\(i)",
                    coordinates: [platform.coordinate, center],
                    distanceMeters: dist
                ))
            }
        }
        return connectors
    }

    /// Zoom-adaptive line width for system-map subway polylines.
    /// Thins at far zoom to match Apple Maps: crisp at street level,
    /// subtle threads at full-system overview.
    private var systemMapSubwayLineWidth: CGFloat {
        switch _zoomTier {
        case .veryClose: return 2.5
        case .close:     return 2.0
        case .medium:    return 1.5
        case .far:       return 1.0
        case .distant:   return 0.75
        }
    }

    /// Zoom-adaptive line width for commuter rail (LIRR / MNR).
    private var systemMapCommuterLineWidth: CGFloat {
        switch _zoomTier {
        case .veryClose: return 2.5
        case .close:     return 2.0
        case .medium:    return 1.5
        case .far:       return 1.0
        case .distant:   return 0.75
        }
    }

    /// Route labels filtered to the visible map viewport.
    /// Computed on camera move (debounced), then cached in `_cachedVisibleLabels`.
    private func computeVisibleRouteLabels(
        center: CLLocationCoordinate2D, distance: Double
    ) -> [HomeViewModel.TrunkRouteLabel] {
        let latSpan = (distance / 111_000) * 1.5
        let lonSpan = (distance / (111_000 * cos(center.latitude * .pi / 180))) * 1.5
        return viewModel.trunkRouteLabels.filter { label in
            abs(label.coordinate.latitude - center.latitude) <= latSpan
                && abs(label.coordinate.longitude - center.longitude) <= lonSpan
        }
    }

    /// Opacity for system-map subway polylines.
    /// Full color in overview; dimmed to 8% when a route detail is open
    /// so surrounding lines provide context without competing visually.
    private var systemMapSubwayOpacity: Double {
        viewModel.routeShape != nil ? 0.08 : 1.0
    }

    /// Opacity for system-map commuter rail polylines.
    private var systemMapCommuterOpacity: Double {
        viewModel.routeShape != nil ? 0.06 : 0.35
    }

    /// Subway polylines — a single pre-computed geometry set used at every
    /// zoom level.  Zoom adaptation is handled by `systemMapSubwayLineWidth`
    /// (rendering) rather than geometry swapping, matching Apple Maps.
    private var currentSubwayPolylines: [HomeViewModel.FlattenedMapPolyline] {
        viewModel.flattenedSubwayPolylines
    }

    /// Whether a polyline should render as elevated (Layer 2b with casing).
    ///
    /// A polyline is "effectively elevated" when:
    /// 1. `inferStructure` classified it as elevated/viaduct, AND
    /// 2. NONE of its routes are currently rerouted/suspended.
    ///
    /// During an active MTA reroute alert (e.g., "7 train running via
    /// E/F tunnel"), the polyline drops to subway-level (Layer 2) so
    /// the visual z-ordering reflects temporary physical reality.
    private func isEffectivelyElevated(
        _ polyline: HomeViewModel.FlattenedMapPolyline
    ) -> Bool {
        guard polyline.isElevated else { return false }
        let rerouted = viewModel.mapSystem.reroutedRouteIDs
        guard !rerouted.isEmpty else { return true }
        // Demote if ALL routes in this polyline are rerouted.
        // For mixed groups (rare), keep elevated if any route is operating normally.
        return !polyline.routeIds.allSatisfy { rerouted.contains($0.uppercased()) }
    }

    @MapContentBuilder
    private var systemMapPolylines: some MapContent {
        // ── Z-ordering (bottom → top) ──
        // 0. Transfer connectors — grey lines linking multi-platform complexes
        // 1. Station capsules — white fill peeks out around polylines
        // 2. Colored subway fills — the actual transit lines
        // 3. Commuter rail
        // 4. Route labels (close zoom only)
        //
        // No white "knockout" casing layer — MapKit's MapPolyline uses
        // stable IDs and deduplicates, so a second ForEach over the same
        // polyline array causes some items to render as white only.
        // The miter-joined corridor offsets already create a natural gap
        // between parallel lines (the base map shows through).

        // Layer 0: Transfer connectors (bottom-most)
        // Grey lines between platforms in the same station complex.
        // Thickness + opacity scale with distance:
        //   < 30 m  (vertical, e.g. 74 St)   → thick, opaque
        //   30–100 m (short walk, e.g. Fulton)→ medium
        //   > 100 m  (long walk, e.g. Lex/63) → thin, faint
        if viewModel.routeShape == nil {
            ForEach(_cachedTransferConnectors) { connector in
                let d = connector.distanceMeters
                // Interpolate: 0m → 2.5pt, 120m+ → 1.0pt
                let widthBase = max(1.0, 2.5 - (d / 120.0) * 1.5)
                // Opacity: 0m → 0.8, 120m+ → 0.4
                let opacityBase = max(0.4, 0.8 - (d / 120.0) * 0.4)
                MapPolyline(coordinates: connector.coordinates)
                    .stroke(
                        Color(.systemGray4).opacity(opacityBase),
                        style: StrokeStyle(
                            lineWidth: max(1.0, widthBase * _zoomTier.rawValue),
                            lineCap: .round))
            }
        }

        // Layer 1: Station capsules
        if viewModel.routeShape == nil {
            let imminent = viewModel.mapSystem.imminentArrivals
            ForEach(_cachedVisibleStations) { station in
                // Match any of this station's source GTFS stop IDs
                // against the imminent arrivals map.
                let pulseRouteId: String? = imminent.isEmpty ? nil :
                    station.sourceStopIDs.lazy.compactMap { imminent[$0] }.first

                Annotation(station.name, coordinate: station.coordinate) {
                    StationCapsuleView(
                        station: station,
                        zoomTier: _zoomTier,
                        imminentRouteId: pulseRouteId
                    )
                }
                .annotationTitles(showStations ? .automatic : .hidden)
            }
        }

        // Layer 2: Subway-level fills (underground lines render first)
        // A normally-elevated polyline is demoted here when ALL of its
        // routes are currently rerouted/suspended (live alert override).
        // `.aboveRoads` keeps underground lines behind map labels for a
        // clean, integrated appearance.
        ForEach(currentSubwayPolylines.filter { !isEffectivelyElevated($0) }) { polyline in
            MapPolyline(coordinates: polyline.coordinates)
                .stroke(
                    polyline.color.opacity(systemMapSubwayOpacity),
                    style: StrokeStyle(
                        lineWidth: systemMapSubwayLineWidth,
                        lineCap: .round, lineJoin: .round))
                .mapOverlayLevel(level: .aboveRoads)
        }

        // Layer 2b: Elevated fills (render ON TOP of subway lines)
        // At crossings (e.g., 7 over E/F/M/R at 74 St), the elevated
        // polyline visually passes over the underground one.
        //
        // Each elevated branch emits two siblings inside one ForEach
        // iteration: a thin dark casing followed by the colored fill.
        // This avoids the MapKit ForEach dedup issue (session 8).
        //
        // During active reroute/suspension alerts, affected polylines
        // drop out of this layer (drawn as subway-level in Layer 2).
        ForEach(currentSubwayPolylines.filter { isEffectivelyElevated($0) }) { polyline in
            // Casing (dark border — slightly wider)
            // `.aboveLabels` creates genuine z-separation from underground
            // lines, so elevated tracks visually cross OVER subway at
            // intersections like 74 St (7 over E/F/M/R).
            MapPolyline(coordinates: polyline.coordinates)
                .stroke(
                    Color.black.opacity(0.25 * systemMapSubwayOpacity),
                    style: StrokeStyle(
                        lineWidth: systemMapSubwayLineWidth + 1.0,
                        lineCap: .round, lineJoin: .round))
                .mapOverlayLevel(level: .aboveLabels)
            // Fill (route color)
            MapPolyline(coordinates: polyline.coordinates)
                .stroke(
                    polyline.color.opacity(systemMapSubwayOpacity),
                    style: StrokeStyle(
                        lineWidth: systemMapSubwayLineWidth,
                        lineCap: .round, lineJoin: .round))
                .mapOverlayLevel(level: .aboveLabels)
        }

        // Layer 3: Commuter rail (same ground level as subway)
        ForEach(viewModel.flattenedCommuterRailPolylines) { polyline in
            MapPolyline(coordinates: polyline.coordinates)
                .stroke(
                    polyline.color.opacity(systemMapCommuterOpacity),
                    style: StrokeStyle(
                        lineWidth: systemMapCommuterLineWidth,
                        lineCap: .round, lineJoin: .round))
                .mapOverlayLevel(level: .aboveRoads)
        }

        // Layer 4: Route labels — only in system-map mode at close zoom
        if viewModel.routeShape == nil {
            if let distance = currentMapDistance,
               distance < AppSettings.shared.stationMaxZoomOutMeters * 0.16 {
                ForEach(_cachedVisibleLabels) { label in
                    Annotation("", coordinate: label.coordinate, anchor: .center) {
                        TrunkRouteLabelView(
                            routeIds: label.routeIds,
                            color: label.color
                        )
                    }
                    .annotationTitles(.hidden)
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
