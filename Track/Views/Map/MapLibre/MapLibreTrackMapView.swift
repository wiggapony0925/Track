//
//  MapLibreTrackMapView.swift
//  Track
//
//  Drop-in replacement for `TrackMapView` that renders the transit map
//  using MapLibre GL Native with OpenStreetMap vector tiles instead of
//  Apple MapKit.
//
//  Architecture:
//  ┌─────────────────────────────────────────────────────┐
//  │  MapLibreTrackMapView (this file)                   │
//  │  ├── MapLibreMapView (UIViewRepresentable)          │
//  │  │   └── MLNMapView (GPU-accelerated OSM tiles)     │
//  │  ├── MapLibreVehicleOverlay (bus/train markers)     │
//  │  ├── MapLibreRouteStopOverlay (route stop markers)  │
//  │  ├── MapLibreRouteLabelOverlay (trunk labels)       │
//  │  └── MapLibreSearchPinOverlay (drag-search dot)     │
//  └─────────────────────────────────────────────────────┘
//
//  The same bindings and data flow from HomeView → TrackMapView are
//  preserved so this is a zero-change swap at the call site.
//
//  Transit app inspiration:
//  Like the Transit app described in their technical blog, we use OSM
//  data as the base map and overlay our own transit polylines with
//  parallel offset rendering, z-ordered elevated/subway layers, and
//  transfer connectors between station complexes.
//

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

    /// Whether drag-to-search is currently active.
    var isDragSearchActive: Bool = false

    /// The settled drag-search coordinate.
    var dragSearchSettledCenter: CLLocationCoordinate2D?

    // MARK: - Environment

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - AppStorage (same as TrackMapView)

    @AppStorage("show_search_radius") private var showSearchRadius = false
    @AppStorage("near_you_radius_meters") private var nearYouRadius: Double = 2414
    @AppStorage("farther_away_radius_meters") private var fartherAwayRadius: Double = 4023
    @AppStorage("much_farther_away_radius_meters") private var muchFartherAwayRadius: Double = 8047

    // MARK: - Viewport Caching (same O(n) optimization as TrackMapView)

    @State private var _cachedTransferConnectors: [TransferConnector] = []
    @State private var _cachedVisibleLabels: [HomeViewModel.TrunkRouteLabel] = []
    @State private var _cachedVisibleStops: [DisplayedRouteStop] = []
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

    // MARK: - Computed Properties

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

    private static func decodeWalkingRoute(_ route: MKRoute?) -> [CLLocationCoordinate2D]? {
        guard let polyline = route?.polyline else { return nil }
        let count = polyline.pointCount
        guard count >= 2 else { return nil }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Base map (MapLibre GL with OSM tiles)
            MapLibreMapView(
                cameraPosition: $cameraPosition,
                currentMapCenter: $currentMapCenter,
                currentMapDistance: $currentMapDistance,
                showStations: $showStations,
                subwayPolylines: viewModel.flattenedSubwayPolylines,
                commuterRailPolylines: viewModel.flattenedCommuterRailPolylines,
                stations: viewModel.consolidatedStations,
                routeLabels: viewModel.trunkRouteLabels,
                routePolylines: viewModel.cachedRoutePolylines,
                inactivePolylines: viewModel.cachedInactivePolylines,
                routeColor: UIColor(selectedRouteColor),
                isBusRoute: viewModel.selectedGroupedRoute?.isBus == true,
                directionalSplit: viewModel.directionalSplit,
                walkingRouteCoords: cachedWalkingCoords,
                busVehicles: viewModel.filteredBusVehicles,
                trainVehicles: viewModel.filteredTrainVehicles,
                transferConnectors: _cachedTransferConnectors,
                hasActiveRoute: viewModel.routeShape != nil,
                reroutedRouteIDs: viewModel.mapSystem.reroutedRouteIDs,
                isDarkMode: colorScheme == .dark,
                selectedMode: viewModel.selectedMode,
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
                }
            )
            .equatable() // Bypass deep structural array equality check

            // SwiftUI overlays positioned via coordinate projection
            overlayStack
        }
        .onChange(of: currentMapDistance) { _, _ in refreshViewportCacheIfNeeded() }
        .onChange(of: viewModel.walkingRoute?.polyline.pointCount) { _, _ in
            cachedWalkingCoords = Self.decodeWalkingRoute(viewModel.walkingRoute)
        }
        .onAppear {
            cachedWalkingCoords = Self.decodeWalkingRoute(viewModel.walkingRoute)
        }
        .ignoresSafeArea()
    }

    // MARK: - Overlay Stack

    @ViewBuilder
    private var overlayStack: some View {
        // Route labels
        MapLibreRouteLabelOverlay(
            mapView: mapViewRef,
            labels: _cachedVisibleLabels,
            currentDistance: currentMapDistance,
            hasActiveRoute: viewModel.routeShape != nil,
            cameraChangeToken: cameraChangeToken
        )

        // Route stops (when a route is selected)
        if viewModel.routeShape != nil {
            MapLibreRouteStopOverlay(
                mapView: mapViewRef,
                stops: _cachedVisibleStops,
                isBusRoute: viewModel.selectedGroupedRoute?.isBus == true,
                selectedStopId: viewModel.selectedStopId,
                routeColor: selectedRouteColor,
                onStopTap: handleStopTap,
                cameraChangeToken: cameraChangeToken
            )
        }

        // Vehicle markers
        MapLibreVehicleOverlay(
            mapView: mapViewRef,
            busVehicles: viewModel.filteredBusVehicles,
            trainVehicles: viewModel.filteredTrainVehicles,
            tappedVehicleId: viewModel.tappedVehicleId,
            onVehicleTap: handleVehicleTap,
            cameraChangeToken: cameraChangeToken
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

    // MARK: - Viewport Cache (same logic as TrackMapView)

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
            _cachedVisibleLabels = computeVisibleRouteLabels(center: center, distance: d)
            _cachedVisibleStops = computeVisibleDirectionStops(center: center, distance: d)
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
            let count: Double = Double(platforms.count)
            let avgLat: Double = platforms.map(\.coordinate.latitude).reduce(0.0, +) / count
            let avgLon: Double = platforms.map(\.coordinate.longitude).reduce(0.0, +) / count
            let centerCoord: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            let centerLoc: CLLocation = CLLocation(latitude: avgLat, longitude: avgLon)
            for (i, platform) in platforms.enumerated() {
                let platformLoc: CLLocation = CLLocation(
                    latitude: platform.coordinate.latitude,
                    longitude: platform.coordinate.longitude
                )
                let dist: Double = platformLoc.distance(from: centerLoc)
                let connectorId: String = "xfer-\(complexID)-\(i)"
                connectors.append(TransferConnector(
                    id: connectorId,
                    coordinates: [platform.coordinate, centerCoord],
                    distanceMeters: dist
                ))
            }
        }
        return connectors
    }

    private func computeVisibleRouteLabels(
        center: CLLocationCoordinate2D, distance: Double
    ) -> [HomeViewModel.TrunkRouteLabel] {
        let metersPerDeg: Double = 111_000.0
        let latSpan: Double = (distance / metersPerDeg) * 1.5
        let cosLat: Double = cos(center.latitude * Double.pi / 180.0)
        let lonSpan: Double = (distance / (metersPerDeg * cosLat)) * 1.5
        return viewModel.trunkRouteLabels.filter { label in
            abs(label.coordinate.latitude - center.latitude) <= latSpan
                && abs(label.coordinate.longitude - center.longitude) <= lonSpan
        }
    }

    private func computeVisibleDirectionStops(
        center: CLLocationCoordinate2D, distance: Double
    ) -> [DisplayedRouteStop] {
        guard let shape = viewModel.routeShape else { return [] }
        let allStops = shape.stopsForDirection(
            index: viewModel.selectedDirectionIndex, name: viewModel.selectedDirectionName)
        let directionPolylines = shape.polylinesForDirection(
            index: viewModel.selectedDirectionIndex, name: viewModel.selectedDirectionName)
        let latSpan = (distance / 111_000) * 1.5
        let lonSpan = (distance / (111_000 * cos(center.latitude * .pi / 180))) * 1.5
        let visibleStops = allStops.filter { stop in
            abs(stop.lat - center.latitude) <= latSpan
                && abs(stop.lon - center.longitude) <= lonSpan
        }

        let maxDisplaySnapDistance: Double =
            viewModel.selectedGroupedRoute?.isBus == true ? 100.0 : 160.0

        return visibleStops.map { stop in
            let rawCoordinate = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
            let displayCoordinate = VehicleInterpolator
                .snap(
                    coordinate: rawCoordinate,
                    to: directionPolylines,
                    maxDistance: maxDisplaySnapDistance
                )?
                .coordinate ?? rawCoordinate

            return DisplayedRouteStop(
                stop: stop,
                displayCoordinate: displayCoordinate
            )
        }
    }

    // MARK: - Tap Handlers

    private func handleStopTap(_ stop: BusStop) {
        withAnimation {
            if viewModel.selectedStopId == stop.id {
                viewModel.selectedStopId = nil
                viewModel.isStopManuallySelected = false
                if let userLoc = locationManager.currentLocation {
                    Task { await viewModel.refreshWalkingState(userLocation: userLoc) }
                }
            } else {
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

// MARK: - Preview

#Preview {
    MapLibreTrackMapView(
        cameraPosition: .constant(.userLocation),
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        showStations: .constant(true),
        currentMapCenter: .constant(nil),
        currentMapDistance: .constant(nil)
    )
}
