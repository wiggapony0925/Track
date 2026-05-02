// Drop-in replacement for `TrackMapView` that renders the transit map
// using MapLibre GL Native with OpenStreetMap vector tiles instead of
// Apple MapKit.
// Architecture:
// ┌─────────────────────────────────────────────────────┐
// │  MapLibreTrackMapView (this file)                   │
// │  ├── MapLibreMapView (UIViewRepresentable)          │
// │  │   └── MLNMapView (GPU-accelerated OSM tiles)     │
// │  ├── MapLibreVehicleOverlay (bus/train markers)     │
// │  ├── MapLibreRouteStopOverlay (route stop markers)  │
// │  ├── MapLibreRouteLabelOverlay (trunk labels)       │
// │  └── MapLibreSearchPinOverlay (drag-search dot)     │
// └─────────────────────────────────────────────────────┘
// The same bindings and data flow from HomeView → TrackMapView are
// preserved so this is a zero-change swap at the call site.
// Transit app inspiration:
// Like the Transit app described in their technical blog, we use OSM
// data as the base map and overlay our own transit polylines with
// parallel offset rendering, z-ordered elevated/subway layers, and
// transfer connectors between station complexes.

import CoreLocation
import MapKit
import MapLibre
import SwiftUI

/// Main map view using MapLibre GL + OpenStreetMap tiles.
/// Drop-in replacement for `TrackMapView` with identical bindings.
struct MapLibreTrackMapView: View {
    // MARK: - Dependencies (same as TrackMapView)

    @Binding var cameraPosition: TrackCameraPosition
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    @Binding var showStations: Bool
    @Binding var currentMapCenter: CLLocationCoordinate2D?
    @Binding var currentMapDistance: Double?
    @Binding var userTrackingMode: TrackUserTrackingMode
    var onRouteStopTap: ((BusStop) -> Void)? = nil
    var onSystemStationTap: ((MapSystemViewModel.ConsolidatedStation) -> Void)? = nil
    var onBusStopTap: ((BusStop) -> Void)? = nil
    var onSavedPlaceTap: ((SavedLocation) -> Void)? = nil

    /// Notifies the parent that the user manually moved the map camera.
    var onUserCameraGesture: (() -> Void)? = nil

    /// Whether drag-to-search is currently active.
    var isDragSearchActive: Bool = false

    /// The settled drag-search coordinate.
    var dragSearchSettledCenter: CLLocationCoordinate2D?

    /// Bridges real-time sheet height → map contentInset (bypasses SwiftUI).
    var sheetHeightObserver: SheetHeightObserver?

    // MARK: - Environment

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - AppStorage (same as TrackMapView)

    @AppStorage("show_search_radius") private var showSearchRadius = false
    @AppStorage("near_you_radius_meters") private var nearYouRadius: Double = 2414
    @AppStorage("farther_away_radius_meters") private var fartherAwayRadius: Double = 4023
    @AppStorage("much_farther_away_radius_meters") private var muchFartherAwayRadius: Double = 8047

    // MARK: - Viewport Caching (same O(n) optimization as TrackMapView)

    @State private var _cachedTransferConnectors: [TransferConnector] = []
    @State private var _cachedVisibleStops: [DisplayedRouteStop] = []
    @State private var _cachedVisibleSystemStations: [MapSystemViewModel.ConsolidatedStation] = []
    @State private var _lastViewportCenter: CLLocationCoordinate2D?
    @State private var _lastViewportDistance: Double?


    // MARK: - MapLibre Reference

    /// Holds a reference to the MapLibre map view for overlays to use
    /// for coordinate projection. Updated by MapLibreMapView's coordinator.
    @State private var mapViewRef: MLNMapView?

    /// Incremented on throttled camera frames (~30fps) so SwiftUI
    /// re-evaluates overlay bodies and re-projects lat/lon → screen
    /// points during gestures.  Throttled to avoid 60fps SwiftUI body
    /// re-evaluation which causes frame drops.
    @State private var cameraChangeToken: UInt64 = 0

    /// Tracks the last time we actually bumped `cameraChangeToken`.
    /// Camera frames arriving within 33ms of the last bump are skipped,
    /// effectively throttling overlay projection to ~30fps.
    @State private var _lastCameraTokenTime: CFAbsoluteTime = 0

    /// Cached walking route coordinates — decoded from MKPolyline once,
    /// not on every body re-evaluation (which fires 60x/sec during gestures).
    @State private var cachedWalkingCoords: [CLLocationCoordinate2D]?
    @State private var savedPlacesCache = SavedPlacesCache.shared
    @State private var savedPlacesRefreshToken: UInt64 = 0

    // MARK: - Computed Properties

    /// Maps bus routeId → its service-type color so vehicle markers on the map
    /// match the color shown in the Route Detail sheet (e.g. Q10 = purple, not blue).
    private var busRouteColorLookup: (String) -> Color {
        var map: [String: Color] = [:]
        for group in viewModel.nearbyGroupedBusArrivals {
            map[group.routeId] = AppTheme.BusColors.color(forServiceType: group.busServiceType)
        }
        // When the user has a route selected (e.g. from the Route Detail
        // sheet), every vehicle in `filteredBusVehicles` belongs to that
        // route — so prefer the already-resolved selectedRouteColor as
        // the fallback instead of generic mtaBlue.  Without this, a bus
        // whose routeId can't be found in `nearbyGroupedBusArrivals`
        // (e.g. opened from search, or out of nearby radius) renders blue
        // even when the route's true color is purple/green/etc.
        let fallback: Color = {
            if viewModel.selectedGroupedRoute?.isBus == true {
                return selectedRouteColor
            }
            return AppTheme.Colors.mtaBlue
        }()
        return { routeId in
            // BusVehicleResponse.routeId may be prefixed (e.g. "MTA NYCT_Q10")
            // while GroupedNearbyTransitResponse.routeId is the bare route ID.
            // Try exact match first, then strip the agency prefix.
            if let color = map[routeId] { return color }
            let stripped = routeId.components(separatedBy: "_").last ?? routeId
            return map[stripped] ?? fallback
        }
    }

    private var selectedRouteColor: Color {
        if let group = viewModel.selectedGroupedRoute, group.isBus {
            return AppTheme.BusColors.color(forServiceType: group.busServiceType)
        }
        if let group = viewModel.selectedGroupedRoute, let hex = group.colorHex {
            return Color(hex: hex)
        }
        if let group = viewModel.selectedGroupedRoute {
            if group.isLIRR { return AppTheme.CommuterRailColors.lirrBlue }
            if group.isMNR { return AppTheme.CommuterRailColors.mnrBlue }
            return group.isBus
                ? AppTheme.BusColors.color(forServiceType: group.busServiceType)
                : AppTheme.SubwayColors.color(for: group.displayName)
        }
        return AppTheme.Colors.mtaBlue
    }

    private static func decodeWalkingRoute(_ route: MKRoute?) -> [CLLocationCoordinate2D]? {
        guard let polyline = route?.polyline else { return nil }
        let count = polyline.pointCount
        guard count >= 2 else { return nil }
        var coords = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid,
            count: count
        )
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    // MARK: - Body

    var body: some View {
        let isSelectedBusRoute = viewModel.selectedGroupedRoute?.isBus == true
        let visibleSavedPlaces = savedPlacesCache.visibleMapPlaces

        ZStack {
            // Base map (MapLibre GL with OSM tiles)
            MapLibreMapView(
                cameraPosition: $cameraPosition,
                currentMapCenter: $currentMapCenter,
                currentMapDistance: $currentMapDistance,
                showStations: $showStations,
                userTrackingMode: $userTrackingMode,
                subwayPolylines: viewModel.flattenedSubwayPolylines,
                commuterRailPolylines: viewModel.flattenedCommuterRailPolylines,
                stations: viewModel.consolidatedStations,
                stationResnapGeneration: viewModel.mapSystem.stationResnapGeneration,
                routePolylines: viewModel.cachedRoutePolylines,
                routeStops: _cachedVisibleStops,
                selectedRouteStopID: viewModel.selectedStopId,
                inactivePolylines: [],
                routeColor: UIColor(selectedRouteColor),
                isBusRoute: isSelectedBusRoute,
                directionalSplit: viewModel.directionalSplit,
                locksCameraToFlatNorthUp: viewModel.routeShape != nil,
                walkingRouteCoords: cachedWalkingCoords,
                busVehicles: viewModel.filteredBusVehicles,
                trainVehicles: viewModel.filteredTrainVehicles,
                savedPlaces: visibleSavedPlaces,
                transferConnectors: _cachedTransferConnectors,
                crossings: viewModel.mapSystem.cachedCrossings,
                bakedTileSet: viewModel.mapSystem.bakedTileSet,
                bakedBusTileSet: viewModel.mapSystem.bakedBusTileSet,
                hasActiveRoute: viewModel.routeShape != nil,
                reroutedRouteIDs: viewModel.mapSystem.reroutedRouteIDs,
                isDarkMode: colorScheme == .dark,
                selectedMode: viewModel.selectedMode,
                showSearchRadius: showSearchRadius,
                searchRadiusNear: nearYouRadius,
                searchRadiusFarther: fartherAwayRadius,
                searchRadiusMuch: muchFartherAwayRadius,
                mapDimmingFactor: viewModel.goMode.mapDimmingFactor,
                onMapViewReady: { mapView in
                    self.mapViewRef = mapView
                },
                onCameraMove: {
                    // Throttle overlay projection to ~30fps (every 33ms).
                    // The underlying MLNMapView still renders at 60fps for
                    // smooth tile/polyline drawing — only SwiftUI overlay
                    // body re-evaluation is throttled.
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - _lastCameraTokenTime >= 0.033 {
                        _lastCameraTokenTime = now
                        cameraChangeToken &+= 1
                    }
                },
                onUserCameraGesture: onUserCameraGesture,
                onBusStopTap: onBusStopTap,
                onRouteStopTap: handleStopTap,
                onSavedPlaceTap: handleSavedPlaceTap,
                sheetHeightObserver: sheetHeightObserver,
                freezeSheetInsetWhileDragSearching: isDragSearchActive
            )
            .equatable() // Bypass deep structural array equality check

            // SwiftUI overlays positioned via coordinate projection
            overlayStack
        }
        .onChange(of: currentMapDistance) { _, _ in refreshViewportCacheIfNeeded() }
        .onChange(of: currentMapCenter?.latitude) { _, _ in refreshViewportCacheIfNeeded() }
        .onChange(of: currentMapCenter?.longitude) { _, _ in refreshViewportCacheIfNeeded() }
        .onChange(of: viewModel.selectedDirectionIndex) { _, _ in forceRefreshStopCache() }
        .onChange(of: viewModel.selectedDirectionName) { _, _ in forceRefreshStopCache() }
        .onChange(of: viewModel.selectedShapeDirectionId) { _, _ in forceRefreshStopCache() }
        .onChange(of: viewModel.routeShape?.routeId) { _, _ in forceRefreshStopCache() }
        .onChange(of: viewModel.nearestStopCoordinate?.latitude) { _, _ in forceRefreshStopCache() }
        .onChange(of: viewModel.nearestStopCoordinate?.longitude) { _, _ in forceRefreshStopCache() }
        .onChange(of: viewModel.selectedStopId) { _, _ in forceRefreshStopCache() }
        .onChange(of: viewModel.walkingRoute?.polyline.pointCount) { _, _ in
            cachedWalkingCoords = Self.decodeWalkingRoute(viewModel.walkingRoute)
        }
        .onAppear {
            cachedWalkingCoords = Self.decodeWalkingRoute(viewModel.walkingRoute)
        }
        .onReceive(NotificationCenter.default.publisher(for: .savedPlacesDidChange)) { _ in
            savedPlacesRefreshToken &+= 1
        }
        .ignoresSafeArea()
    }

    // MARK: - Overlay Stack

    @ViewBuilder
    private var overlayStack: some View {
        if viewModel.routeShape == nil,
           showStations,
           let onSystemStationTap
        {
            MapLibreSystemStationTapOverlay(
                mapView: mapViewRef,
                stations: _cachedVisibleSystemStations,
                onStationTap: onSystemStationTap,
                cameraChangeToken: cameraChangeToken
            )
        }

        // Vehicle markers
        MapLibreVehicleOverlay(
            mapView: mapViewRef,
            busVehicles: viewModel.filteredBusVehicles,
            trainVehicles: viewModel.filteredTrainVehicles,
            liveVehicleDetailsByKey: viewModel.liveVehicleDetailsByKey,
            tappedVehicleId: viewModel.tappedVehicleId,
            onVehicleTap: handleVehicleTap,
            cameraChangeToken: cameraChangeToken,
            busColorLookup: busRouteColorLookup
        )

        // Search pin
        MapLibreSearchPinOverlay(
            mapView: mapViewRef,
            coordinate: viewModel.searchPinCoordinate,
            isActive: viewModel.isSearchPinActive,
            hasSelectedRoute: viewModel.selectedRouteId != nil,
            cameraChangeToken: cameraChangeToken
        )
    }

    private func handleSavedPlaceTap(_ place: SavedLocation) {
        if let onSavedPlaceTap {
            onSavedPlaceTap(place)
            return
        }

        NotificationCenter.default.post(
            name: .quickDestination,
            object: PlanLocation.saved(place)
        )
        NotificationCenter.default.post(name: .switchToTab, object: AppTab.trips)
        HapticManager.impact(.medium)
    }

    // MARK: - Viewport Cache (same logic as TrackMapView)

    /// Force-refresh only the stop markers (e.g. when the nearest stop or
    /// selected stop changes, so behind/ahead dimming updates).
    private func forceRefreshStopCache() {
        guard viewModel.routeShape != nil else {
            _cachedVisibleStops = []
            return
        }
        let center = currentMapCenter ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let d = currentMapDistance ?? 0
        _cachedVisibleStops = computeVisibleDirectionStops(center: center, distance: d)
    }

    private func refreshViewportCacheIfNeeded() {
        guard let center = currentMapCenter, let d = currentMapDistance else { return }

        // Check if cache needs refresh
        let needsRefresh: Bool
        if let lastC = _lastViewportCenter, let lastD = _lastViewportDistance {
            let latDelta = abs(center.latitude - lastC.latitude)
            let lonDelta = abs(center.longitude - lastC.longitude)
            let distRatio = abs(d - lastD) / max(lastD, 1)
            let panThreshold = (d / 111_000) * 0.002
            needsRefresh = latDelta > panThreshold || lonDelta > panThreshold || distRatio > 0.10
        } else {
            needsRefresh = true
        }

        if needsRefresh {
            _lastViewportCenter = center
            _lastViewportDistance = d
            _cachedTransferConnectors = computeTransferConnectors(
                from: viewModel.consolidatedStations, center: center, distance: d
            )
            _cachedVisibleStops = computeVisibleDirectionStops(center: center, distance: d)
            _cachedVisibleSystemStations = computeVisibleSystemStations(center: center, distance: d)
        }
    }

    // MARK: - Viewport Computation

    private func computeTransferConnectors(
        from allStations: [MapSystemViewModel.ConsolidatedStation],
        center: CLLocationCoordinate2D,
        distance: Double
    ) -> [TransferConnector] {
        let maxZoomOut: Double = AppSettings.shared.stationMaxZoomOutMeters
        guard distance < maxZoomOut * 0.30 else { return [] }

        let metersPerDeg: Double = 111_000.0
        let latSpan: Double = (distance / metersPerDeg) * 1.5
        let cosLat: Double = cos(center.latitude * Double.pi / 180.0)
        let lonSpan: Double = (distance / (metersPerDeg * cosLat)) * 1.5
        let minLat: Double = center.latitude - latSpan
        let maxLat: Double = center.latitude + latSpan
        let minLon: Double = center.longitude - lonSpan
        let maxLon: Double = center.longitude + lonSpan

        let stations = allStations.filter { s in
            let lat: Double = s.coordinate.latitude
            let lon: Double = s.coordinate.longitude
            return lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
        }

        var byComplex: [Int: [MapSystemViewModel.ConsolidatedStation]] = [:]
        for station in stations {
            byComplex[station.complexID, default: []].append(station)
        }
        var connectors: [TransferConnector] = []
        for (complexID, platforms) in byComplex {
            guard platforms.count >= 2 else { continue }
            // Connect each pair of platforms with a smooth curved path
            // instead of radial spokes to the centroid.
            for i in 0..<platforms.count {
                for j in (i + 1)..<platforms.count {
                    let a = platforms[i].coordinate
                    let b = platforms[j].coordinate
                    let distMeters = CLLocation(latitude: a.latitude, longitude: a.longitude)
                        .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                    let connectorId: String = "xfer-\(complexID)-\(i)-\(j)"
                    let curvedCoords = Self.curvedPath(from: a, to: b, steps: 8)
                    connectors.append(TransferConnector(
                        id: connectorId,
                        coordinates: curvedCoords,
                        distanceMeters: distMeters
                    ))
                }
            }
        }
        return connectors
    }

    /// Generates a smooth quadratic Bezier curve between two coordinates.
    /// The control point is offset perpendicular to the line connecting
    /// `from` and `to`, producing a gentle arc.
    private static func curvedPath(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D,
        steps: Int
    ) -> [CLLocationCoordinate2D] {
        let midLat = (a.latitude + b.latitude) / 2.0
        let midLon = (a.longitude + b.longitude) / 2.0
        // Perpendicular offset for the control point — produces a subtle arc
        let dLat = b.latitude - a.latitude
        let dLon = b.longitude - a.longitude
        // Offset perpendicular to the line by ~20% of its length
        let offsetScale: Double = 0.20
        let ctrlLat = midLat + (-dLon) * offsetScale
        let ctrlLon = midLon + dLat * offsetScale

        var coords: [CLLocationCoordinate2D] = []
        coords.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let oneMinusT = 1.0 - t
            // Quadratic Bezier: P = (1-t)²·A + 2(1-t)t·C + t²·B
            let lat = oneMinusT * oneMinusT * a.latitude
                + 2.0 * oneMinusT * t * ctrlLat
                + t * t * b.latitude
            let lon = oneMinusT * oneMinusT * a.longitude
                + 2.0 * oneMinusT * t * ctrlLon
                + t * t * b.longitude
            coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return coords
    }

    private func computeVisibleDirectionStops(
        center: CLLocationCoordinate2D, distance: Double
    ) -> [DisplayedRouteStop] {
        guard let shape = viewModel.routeShape else { return [] }
        let rawStops = shape.stopsForDirection(
            index: viewModel.selectedDirectionIndex,
            name: viewModel.selectedDirectionName,
            shapeDirectionId: viewModel.selectedShapeDirectionId,
            fallbackToCombined: false
        )
        let matchedDirection = shape.matchedDirection(
            index: viewModel.selectedDirectionIndex,
            name: viewModel.selectedDirectionName,
            shapeDirectionId: viewModel.selectedShapeDirectionId
        )
        let isBusRoute = viewModel.selectedGroupedRoute?.isBus == true
        let allStops = HomeViewModel.stopsOrderedForSelectedTerminal(
            rawStops,
            directionName: viewModel.selectedDirectionName,
            shapeHeadsign: matchedDirection?.headsign
        )
        let directionPolylines: [[CLLocationCoordinate2D]]
        if isBusRoute {
            let rawDirectionPolylines = HomeViewModel.polylineCandidatesForSelectedDirection(
                shape: shape,
                index: viewModel.selectedDirectionIndex,
                name: viewModel.selectedDirectionName,
                shapeDirectionId: viewModel.selectedShapeDirectionId,
                hasDirectionData: !shape.directions.isEmpty,
                isBus: true
            )
            directionPolylines = HomeViewModel.filterPolylinesToDirectionStops(
                rawDirectionPolylines,
                stops: allStops,
                isBus: true
            )
        } else {
            directionPolylines = []
        }
        let usesLocalCoverageOnlyShape = isBusRoute
            && LocalRouteShapeProvider.isStopDerivedShape(shape)
        let visibleStops = allStops

        // Determine which stops are "behind" (already passed by the bus)
        // by finding the nearest stop's position in the ordered stop list.
        let behindStopIds: Set<String>
        let splitStopIndex: Int? = {
            if let selectedStopId = viewModel.selectedStopId, !selectedStopId.isEmpty {
                let normalizedSelected = normalizeStopId(selectedStopId)
                if let selectedIndex = allStops.firstIndex(where: {
                    $0.id == selectedStopId || normalizeStopId($0.id) == normalizedSelected
                }) {
                    if let nearestCoord = viewModel.nearestStopCoordinate {
                        let selected = allStops[selectedIndex]
                        let selectedLoc = CLLocation(latitude: selected.lat, longitude: selected.lon)
                        let nearestLoc = CLLocation(
                            latitude: nearestCoord.latitude,
                            longitude: nearestCoord.longitude
                        )
                        if selectedLoc.distance(from: nearestLoc) <= 45 {
                            return selectedIndex
                        }
                    } else {
                        return selectedIndex
                    }
                }
            }

            guard let nearestCoord = viewModel.nearestStopCoordinate else { return nil }
            let nearestLoc = CLLocation(
                latitude: nearestCoord.latitude,
                longitude: nearestCoord.longitude
            )
            // Find the index of the stop closest to nearestStopCoordinate
            var bestIdx = 0
            var bestDist: CLLocationDistance = .greatestFiniteMagnitude
            for (i, stop) in allStops.enumerated() {
                let d = CLLocation(
                    latitude: stop.lat,
                    longitude: stop.lon
                ).distance(from: nearestLoc)
                if d < bestDist { bestDist = d; bestIdx = i }
            }
            return bestIdx
        }()

        if let splitStopIndex {
            // All stops before the selected/nearest stop index are "behind".
            behindStopIds = Set(allStops.prefix(splitStopIndex).map(\.id))
        } else {
            behindStopIds = []
        }

        // Express-skipped stops — local-only stops greyed when express is selected
        let skippedIds = viewModel.isSelectedArrivalExpress
            ? viewModel.localOnlyStopIds
            : Set<String>()

        let maxDisplaySnapDistance: Double =
            viewModel.selectedGroupedRoute?.isBus == true ? 100.0 : 160.0
        return visibleStops.compactMap { stop in
            let rawCoordinate = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
            let snapped = isBusRoute
                ? VehicleInterpolator.snap(
                    coordinate: rawCoordinate,
                    to: directionPolylines,
                    maxDistance: maxDisplaySnapDistance
                )
                : nil
            if isBusRoute, !usesLocalCoverageOnlyShape, snapped == nil {
                return nil
            }
            let displayCoordinate = snapped?.coordinate ?? rawCoordinate

            return DisplayedRouteStop(
                stop: stop,
                displayCoordinate: displayCoordinate,
                isBehind: behindStopIds.contains(stop.id),
                isSkipped: skippedIds.contains(stop.id)
            )
        }
    }

    private func computeVisibleSystemStations(
        center: CLLocationCoordinate2D,
        distance: Double
    ) -> [MapSystemViewModel.ConsolidatedStation] {
        let zoomThreshold = AppSettings.shared.stationVisibilityZoomMeters
        guard distance < zoomThreshold else { return [] }

        let latSpan = (distance / 111_000) * 1.5
        let lonSpan = (distance / (111_000 * cos(center.latitude * .pi / 180))) * 1.5

        return viewModel.consolidatedStations.filter { station in
            abs(station.coordinate.latitude - center.latitude) <= latSpan
                && abs(station.coordinate.longitude - center.longitude) <= lonSpan
        }
    }

    // MARK: - Tap Handlers

    private func handleStopTap(_ stop: BusStop) {
        withAnimation {
            if viewModel.selectedStopId != stop.id {
                viewModel.selectedStopId = stop.id
                viewModel.isStopManuallySelected = true
                let stopCoord = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
                viewModel.nearestStopCoordinate = stopCoord
                let origin = viewModel.referenceLocation?.coordinate
                    ?? locationManager.currentLocation?.coordinate
                if let from = origin {
                    Task { await viewModel.fetchWalkingRoute(from: from, to: stopCoord) }
                }
            }
        }

        onRouteStopTap?(stop)
    }

    private func handleVehicleTap(_ vehicleId: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if viewModel.tappedVehicleId == vehicleId {
                viewModel.tappedVehicleId = nil
            } else {
                viewModel.tappedVehicleId = vehicleId
            }
        }
    }
}

private struct MapLibreSystemStationTapOverlay: View {
    let mapView: MLNMapView?
    let stations: [MapSystemViewModel.ConsolidatedStation]
    let onStationTap: (MapSystemViewModel.ConsolidatedStation) -> Void
    let cameraChangeToken: UInt64

    var body: some View {
        let zoom = mapView?.zoomLevel ?? 0

        GeometryReader { _ in
            ZStack {
                ForEach(stations) { station in
                    stationTapTarget(for: station, zoom: zoom)
                }
            }
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func stationTapTarget(
        for station: MapSystemViewModel.ConsolidatedStation,
        zoom: Double
    ) -> some View {
        let heading = station.laneHeading ?? station.trackBearing
        let displayCoordinate = MapLibreMapView.Coordinator.visuallyOffsetTransferCoordinate(
            station.coordinate,
            headingDegrees: heading,
            laneOffset: station.laneOffset,
            zoom: zoom
        )

        if let point = projectToScreen(displayCoordinate, mapView: mapView, margin: 40) {
            let width: CGFloat = station.isTransfer ? 46 : 30
            let height: CGFloat = station.isTransfer ? 30 : 30

            Capsule()
                .fill(Color.white)
                .opacity(0.001)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .position(point)
                .onTapGesture {
                    onStationTap(station)
                }
        }
    }
}

// MARK: - Preview

#Preview {
    MapLibreTrackMapView(
        cameraPosition: .constant(.userLocation),
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        showStations: .constant(true),
        currentMapCenter: .constant(nil),
        currentMapDistance: .constant(nil),
        userTrackingMode: .constant(.none)
    )
}
