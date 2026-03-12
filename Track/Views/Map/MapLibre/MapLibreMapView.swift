//
//  MapLibreMapView.swift
//  Track
//
//  UIViewRepresentable bridge wrapping MapLibre GL Native's `MLNMapView`
//  for SwiftUI. Uses OpenStreetMap vector tiles via MapTiler for the base
//  map, replacing Apple MapKit's `Map` view.
//
//  Architecture:
//  ┌──────────────────────────────────────────────┐
//  │  SwiftUI (MapLibreTrackMapView)              │
//  │    ↓ bindings                                │
//  │  MapLibreMapView (UIViewRepresentable)       │
//  │    ↓ manages                                 │
//  │  MLNMapView (UIKit — GPU-accelerated GL)     │
//  │    ↓ tile source                             │
//  │  MapTiler / OpenStreetMap vector tiles        │
//  └──────────────────────────────────────────────┘
//
//  Performance Notes:
//  - polyline/annotation updates are O(n) where n = number of features
//  - Camera sync is O(1) per frame
//  - Style layers use MapLibre's GPU pipeline (no CPU-side drawing)
//
//  References:
//  - MapLibre iOS: https://maplibre.org/maplibre-native/ios/latest/
//  - MLNMapView: MLNMapView class in MapLibre Native
//

import CoreLocation
import MapLibre
import SwiftUI
import UIKit

// MARK: - MapLibreMapView (UIViewRepresentable)

/// SwiftUI wrapper for MapLibre GL Native's `MLNMapView`.
///
/// This is the core bridge that replaces `Map { }` (SwiftUI MapKit).
/// It receives the same data the old `TrackMapView` used — polylines,
/// stations, vehicles — and renders them using MapLibre's GL pipeline
/// with OpenStreetMap tiles.
struct MapLibreMapView: UIViewRepresentable {

    // MARK: - Bindings (same interface as TrackMapView)

    /// Camera position — synced bidirectionally so sheets/dashboards
    /// that read `$cameraPosition` still work.
    @Binding var cameraPosition: TrackCameraPosition

    /// Current map center coordinate (reported back on camera move).
    @Binding var currentMapCenter: CLLocationCoordinate2D?

    /// Current camera distance in meters (reported back on camera move).
    @Binding var currentMapDistance: Double?

    /// Whether station annotations are visible (zoom-dependent).
    @Binding var showStations: Bool

    // MARK: - Data Inputs

    /// System map subway polylines (flattened for O(1) lookup per ID).
    var subwayPolylines: [MapSystemViewModel.FlattenedMapPolyline]

    /// System map commuter rail polylines.
    var commuterRailPolylines: [MapSystemViewModel.FlattenedMapPolyline]

    /// Consolidated station markers.
    var stations: [MapSystemViewModel.ConsolidatedStation]

    /// Route labels for trunk groups.
    var routeLabels: [HomeViewModel.TrunkRouteLabel]

    /// Active route polyline coordinates (when a route is selected).
    var routePolylines: [[CLLocationCoordinate2D]]

    /// Inactive direction polylines (dimmed).
    var inactivePolylines: [[CLLocationCoordinate2D]]

    /// Selected route color.
    var routeColor: UIColor

    /// Whether the selected route is a bus route.
    var isBusRoute: Bool

    /// Directional split (ahead/behind nearest stop).
    var directionalSplit: (ahead: [[CLLocationCoordinate2D]], behind: [[CLLocationCoordinate2D]])?

    /// Walking route coordinates (decoded from MKRoute polyline).
    var walkingRouteCoords: [CLLocationCoordinate2D]?

    /// Bus vehicle positions.
    var busVehicles: [BusVehicleResponse]

    /// Train vehicle positions.
    var trainVehicles: [TrainVehicle]

    /// Transfer connectors between station complexes.
    var transferConnectors: [TransferConnector]

    /// Whether a route is currently selected (dims system map).
    var hasActiveRoute: Bool

    /// Route IDs currently rerouted (for z-order demotion).
    var reroutedRouteIDs: Set<String>

    /// Track user location.
    var showUserLocation: Bool = true

    /// Whether the system is in dark mode (drives MapTiler style selection).
    var isDarkMode: Bool = false

    /// Callback to pass the MLNMapView reference back to the parent
    /// so SwiftUI overlays can project coordinates → screen points.
    var onMapViewReady: ((MLNMapView) -> Void)?

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> MLNMapView {
        // Use MapTiler vector tiles if API key is set, otherwise OSM raster fallback.
        // Dark mode selects dataviz-dark style; light mode selects pastel/muted.
        let styleURL: URL?
        if let mapTilerURL = MapLibreStyleConfig.styleURL(isDarkMode: isDarkMode) {
            styleURL = mapTilerURL
        } else {
            styleURL = MapLibreStyleConfig.osmRasterStyleJSON()
        }

        let mapView = MLNMapView(
            frame: .zero,
            styleURL: styleURL
        )

        // Core configuration
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.showsUserLocation = showUserLocation
        mapView.minimumZoomLevel = MapLibreStyleConfig.minZoom
        mapView.maximumZoomLevel = MapLibreStyleConfig.maxZoom

        // Attribution (required by OSM/MapTiler ToS)
        mapView.attributionButton.isHidden = false
        mapView.logoView.isHidden = true

        // Compass
        mapView.compassView.compassVisibility = .adaptive

        // Set initial camera from binding
        let state = MapLibreCameraState(from: cameraPosition)
        mapView.setCenter(state.center, zoomLevel: state.zoom, animated: false)
        mapView.direction = state.bearing
        let initialCamera = mapView.camera
        initialCamera.pitch = CGFloat(state.pitch)
        mapView.camera = initialCamera

        // Delegate
        mapView.delegate = context.coordinator

        // Pass reference back for overlay coordinate projection
        DispatchQueue.main.async {
            self.onMapViewReady?(mapView)
        }

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let coordinator = context.coordinator

        // ── Dark mode style switching ──
        // MapTiler provides both light (pastel) and dark (dataviz-dark) styles.
        // When colorScheme changes, swap the base map tiles seamlessly.
        if coordinator.currentStyleIsDark != isDarkMode {
            coordinator.currentStyleIsDark = isDarkMode
            let newURL = MapLibreStyleConfig.styleURL(isDarkMode: isDarkMode)
                ?? MapLibreStyleConfig.osmRasterStyleJSON()
            if let newURL {
                mapView.styleURL = newURL
                coordinator.styleLoaded = false
                coordinator.sourcesCreated.removeAll()
            }
        }

        // ── Camera sync (only if externally changed) ──
        if coordinator.shouldSyncCamera {
            let state = MapLibreCameraState(from: cameraPosition)
            let currentZoom = mapView.zoomLevel
            let currentCenter = mapView.centerCoordinate
            let needsUpdate =
                abs(state.zoom - currentZoom) > 0.1
                || abs(state.center.latitude - currentCenter.latitude) > 1e-5
                || abs(state.center.longitude - currentCenter.longitude) > 1e-5

            if needsUpdate {
                mapView.setCenter(state.center, zoomLevel: state.zoom, direction: state.bearing, animated: true)
                if abs(state.pitch - Double(mapView.camera.pitch)) > 1 {
                    let camera = mapView.camera
                    camera.pitch = CGFloat(state.pitch)
                    mapView.setCamera(camera, animated: true)
                }
            }
        }
        coordinator.shouldSyncCamera = true

        // ── Layer updates (all GL layers managed by coordinator) ──
        if coordinator.styleLoaded {
            coordinator.updateAllLayers(mapView: mapView, representable: self)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    /// Coordinates between SwiftUI state and the MapLibre GL view.
    /// Handles delegate callbacks, layer management, and annotation lifecycle.
    ///
    /// Following Transit app's approach: all transit lines, stations, and routes
    /// are rendered as MapLibre GL style layers (GPU-accelerated) rather than
    /// SwiftUI overlays or MapKit annotations. This unlocks:
    /// - Zoom-interpolated line widths (smooth scaling via `mgl_interpolate`)
    /// - Per-feature data-driven styling (color from GeoJSON attributes)
    /// - Native GL circle/symbol layers for station dots
    /// - Proper casing layers for the signature Transit-style line borders
    /// - Dark mode via MapTiler style switching
    final class Coordinator: NSObject, MLNMapViewDelegate {

        private var parent: MapLibreMapView
        var styleLoaded = false
        var shouldSyncCamera = true
        var currentStyleIsDark: Bool?

        /// Tracks created sources — cleared on style reload so layers get recreated.
        var sourcesCreated: Set<String> = []

        init(_ parent: MapLibreMapView) {
            self.parent = parent
        }

        // MARK: - Delegate: Style Loaded

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            sourcesCreated.removeAll()  // New style = all layers need recreation
            updateAllLayers(mapView: mapView, representable: parent)
        }

        // MARK: - Delegate: Camera Changed

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            syncCameraToBinding(mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            syncCameraToBinding(mapView)
        }

        /// Syncs current MapLibre camera state back to the SwiftUI bindings.
        /// O(1) — just reads camera properties and writes to bindings.
        /// Deferred to next run loop to avoid "modifying state during view update".
        private func syncCameraToBinding(_ mapView: MLNMapView) {
            shouldSyncCamera = false  // Prevent feedback loop

            let center = mapView.centerCoordinate
            let zoom = mapView.zoomLevel
            let distance = MapLibreCameraState.distanceFromZoom(zoom, at: center.latitude)
            let pitch = Double(mapView.camera.pitch)
            let bearing = mapView.direction

            let zoomThreshold = AppSettings.shared.stationVisibilityZoomMeters
            let shouldShow = distance < zoomThreshold

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.currentMapCenter = center
                self.parent.currentMapDistance = distance

                let state = MapLibreCameraState(
                    center: center,
                    zoom: zoom,
                    pitch: pitch,
                    bearing: bearing
                )
                self.parent.cameraPosition = state.toTrackCameraPosition()

                if shouldShow != self.parent.showStations {
                    self.parent.showStations = shouldShow
                }
            }
        }

        // MARK: - Delegate: Annotation Handling

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            return nil  // All annotations use GL layers or SwiftUI overlays
        }

        // MARK: - Unified Layer Update
        //
        // Called from updateUIView and didFinishLoadingStyle.
        // Renders all transit data as MapLibre GL style layers for
        // smooth zoom-interpolated rendering — the key advantage
        // over MapKit's static MKPolyline.

        func updateAllLayers(mapView: MLNMapView, representable: MapLibreMapView) {
            guard let style = mapView.style else { return }

            updateSystemMapLayers(style: style, representable: representable)
            updateStationDotLayers(style: style, representable: representable)
            updateRouteLayers(style: style, representable: representable)
            updateWalkingRouteLayer(style: style, representable: representable)
            updateTransferConnectors(style: style, representable: representable)
        }

        // MARK: - System Map Layers (Subway + Commuter + Elevated)
        //
        // Following Transit's rendering pipeline:
        //   1. Casing layer (wider, white/dark) renders first →  border/shadow
        //   2. Fill layer (narrower, colored) renders on top → colored line
        //   3. Elevated gets an additional shadow layer underneath for depth
        //
        // All widths use `mgl_interpolate` for buttery-smooth zoom scaling —
        // the single biggest visual upgrade over MapKit.

        func updateSystemMapLayers(style: MLNStyle, representable: MapLibreMapView) {
            let dimmed = representable.hasActiveRoute
            let subwayOpacity: Double = dimmed ? 0.08 : 1.0
            let commuterOpacity: Double = dimmed ? 0.06 : 0.35
            let casingOpacity: Double = dimmed ? 0.04 : 0.6
            let commuterCasingOpacity: Double = dimmed ? 0.02 : 0.15
            let isDark = representable.isDarkMode

            // ── COMMUTER RAIL (below subway) ──
            let commuterFeatures = buildPolylineFeatures(representable.commuterRailPolylines)
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcCommRail,
                layerID: MapLibreStyleConfig.layerCommRailCasing,
                features: commuterFeatures,
                width: MapLibreStyleConfig.commuterCasingWidth,
                opacity: commuterCasingOpacity,
                color: .constant(isDark ? UIColor.white.withAlphaComponent(0.2) : UIColor.white),
                cap: "round", join: "round"
            )
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcCommRail,
                layerID: MapLibreStyleConfig.layerCommRailFill,
                features: nil,  // reuse source
                width: MapLibreStyleConfig.commuterFillWidth,
                opacity: commuterOpacity,
                color: .dataDriven,
                cap: "round", join: "round"
            )

            // ── SUBWAY (standard underground/surface lines) ──
            let subwayOnly = representable.subwayPolylines.filter {
                !isEffectivelyElevated($0, reroutedRouteIDs: representable.reroutedRouteIDs)
            }
            let subwayFeatures = buildPolylineFeatures(subwayOnly)

            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcSubway,
                layerID: MapLibreStyleConfig.layerSubwayCasing,
                features: subwayFeatures,
                width: MapLibreStyleConfig.subwayCasingWidth,
                opacity: casingOpacity,
                color: .constant(isDark ? UIColor.white.withAlphaComponent(0.3) : UIColor.white),
                cap: "round", join: "round"
            )
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcSubway,
                layerID: MapLibreStyleConfig.layerSubwayFill,
                features: nil,  // reuse source
                width: MapLibreStyleConfig.subwayFillWidth,
                opacity: subwayOpacity,
                color: .dataDriven,
                cap: "round", join: "round"
            )

            // ── ELEVATED (above subway, with shadow for depth) ──
            let elevated = representable.subwayPolylines.filter {
                isEffectivelyElevated($0, reroutedRouteIDs: representable.reroutedRouteIDs)
            }
            let elevatedFeatures = buildPolylineFeatures(elevated)

            // Shadow layer (dark, offset down for depth illusion)
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcElevated,
                layerID: MapLibreStyleConfig.layerElevatedShadow,
                features: elevatedFeatures,
                width: MapLibreStyleConfig.elevatedCasingWidth,
                opacity: dimmed ? 0.02 : (isDark ? 0.15 : 0.10),
                color: .constant(UIColor.black),
                cap: "round", join: "round",
                translatePixels: CGPoint(x: 1, y: 2)
            )
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcElevated,
                layerID: MapLibreStyleConfig.layerElevatedCasing,
                features: nil,
                width: MapLibreStyleConfig.elevatedCasingWidth,
                opacity: casingOpacity,
                color: .constant(isDark ? UIColor.white.withAlphaComponent(0.35) : UIColor.white),
                cap: "round", join: "round"
            )
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcElevated,
                layerID: MapLibreStyleConfig.layerElevatedFill,
                features: nil,
                width: MapLibreStyleConfig.elevatedFillWidth,
                opacity: subwayOpacity,
                color: .dataDriven,
                cap: "round", join: "round"
            )
        }

        // MARK: - GL Station Dot Layers
        //
        // Instead of SwiftUI overlay capsules (expensive per-frame projection),
        // render station dots as MapLibre GL circle layers. This means:
        // - Dots scale smoothly with zoom (no tier-based size jumps)
        // - Thousands of stations at zero CPU cost (GL batches circles)
        // - Transfer stations get a white-fill + dark-stroke circle
        // - Single-line stations get a route-colored dot
        //
        // The SwiftUI overlay still handles complex capsule views at
        // close zoom (labels, multi-color pills). These GL dots show
        // at overview zooms where individual station labels aren't readable.

        func updateStationDotLayers(style: MLNStyle, representable: MapLibreMapView) {
            guard !representable.hasActiveRoute else {
                // Hide system station dots when a route is selected
                if let src = style.source(withIdentifier: MapLibreStyleConfig.srcStations) as? MLNShapeSource {
                    src.shape = MLNShapeCollectionFeature(shapes: [])
                }
                return
            }

            let stations = representable.stations
            var singleFeatures: [MLNPointFeature] = []
            var transferFeatures: [MLNPointFeature] = []
            singleFeatures.reserveCapacity(stations.count)

            for station in stations {
                let feature = MLNPointFeature()
                feature.coordinate = station.coordinate
                feature.attributes = [
                    "name": station.name,
                    "color": station.routes.first.map {
                        UIColor(AppTheme.SubwayColors.color(for: $0)).toHex()
                    } ?? "#999999",
                    "isTransfer": station.isTransfer,
                    "colorGroupCount": station.colorGroupCount,
                ]
                if station.isTransfer {
                    transferFeatures.append(feature)
                } else {
                    singleFeatures.append(feature)
                }
            }

            let isDark = representable.isDarkMode
            let allFeatures = singleFeatures + transferFeatures
            let shape = MLNShapeCollectionFeature(shapes: allFeatures)
            let sourceID = MapLibreStyleConfig.srcStations

            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
            } else {
                let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
                sourcesCreated.insert(sourceID)

                // Single-line station dots — route-colored fill
                let singleLayer = MLNCircleStyleLayer(
                    identifier: MapLibreStyleConfig.layerStationDotsSingle,
                    source: source
                )
                singleLayer.circleRadius = MapLibreStyleConfig.stationDotRadius
                singleLayer.circleColor = NSExpression(forKeyPath: "color")
                singleLayer.circleStrokeColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white.withAlphaComponent(0.4) : UIColor.white
                )
                singleLayer.circleStrokeWidth = MapLibreStyleConfig.stationDotStrokeWidth
                // Filter: only non-transfer stations
                singleLayer.predicate = NSPredicate(format: "isTransfer == NO")
                // Show at zoom 12+
                singleLayer.minimumZoomLevel = 12
                style.addLayer(singleLayer)

                // Transfer station dots — white fill + dark stroke
                let transferLayer = MLNCircleStyleLayer(
                    identifier: MapLibreStyleConfig.layerStationDotsTransfer,
                    source: source
                )
                transferLayer.circleRadius = MapLibreStyleConfig.transferDotRadius
                transferLayer.circleColor = NSExpression(
                    forConstantValue: isDark ? UIColor(white: 0.2, alpha: 1) : UIColor.white
                )
                transferLayer.circleStrokeColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white.withAlphaComponent(0.6) : UIColor(white: 0.2, alpha: 1)
                )
                transferLayer.circleStrokeWidth = MapLibreStyleConfig.stationDotStrokeWidth
                // Filter: only transfers
                transferLayer.predicate = NSPredicate(format: "isTransfer == YES")
                transferLayer.minimumZoomLevel = 11
                style.addLayer(transferLayer)

                // Station labels — text at high zoom
                let labelLayer = MLNSymbolStyleLayer(
                    identifier: MapLibreStyleConfig.layerStationLabels,
                    source: source
                )
                labelLayer.text = NSExpression(forKeyPath: "name")
                labelLayer.textFontSize = MapLibreStyleConfig.stationLabelFontSize
                labelLayer.textColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white : UIColor(white: 0.15, alpha: 1)
                )
                labelLayer.textHaloColor = NSExpression(
                    forConstantValue: isDark ? UIColor.black.withAlphaComponent(0.8) : UIColor.white.withAlphaComponent(0.9)
                )
                labelLayer.textHaloWidth = NSExpression(forConstantValue: 1.5)
                labelLayer.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.2)))
                labelLayer.textAnchor = NSExpression(forConstantValue: "top")
                labelLayer.textFontNames = NSExpression(forConstantValue: ["Open Sans Semibold", "Arial Unicode MS Bold"])
                // Only show labels at close zoom (14+)
                labelLayer.minimumZoomLevel = 14
                // Allow text overlap at very close zoom to show all labels
                labelLayer.textAllowsOverlap = NSExpression(
                    format: "mgl_step:from:stops:($zoomLevel, false, %@)",
                    [16: true]
                )
                style.addLayer(labelLayer)
            }

            // Update stroke colors for dark/light mode on existing layers
            if let single = style.layer(withIdentifier: MapLibreStyleConfig.layerStationDotsSingle) as? MLNCircleStyleLayer {
                single.circleStrokeColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white.withAlphaComponent(0.4) : UIColor.white
                )
            }
            if let transfer = style.layer(withIdentifier: MapLibreStyleConfig.layerStationDotsTransfer) as? MLNCircleStyleLayer {
                transfer.circleColor = NSExpression(
                    forConstantValue: isDark ? UIColor(white: 0.2, alpha: 1) : UIColor.white
                )
                transfer.circleStrokeColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white.withAlphaComponent(0.6) : UIColor(white: 0.2, alpha: 1)
                )
            }
            if let labels = style.layer(withIdentifier: MapLibreStyleConfig.layerStationLabels) as? MLNSymbolStyleLayer {
                labels.textColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white : UIColor(white: 0.15, alpha: 1)
                )
                labels.textHaloColor = NSExpression(
                    forConstantValue: isDark ? UIColor.black.withAlphaComponent(0.8) : UIColor.white.withAlphaComponent(0.9)
                )
            }
        }

        // MARK: - Transfer Connectors

        private func updateTransferConnectors(style: MLNStyle, representable: MapLibreMapView) {
            let sourceID = MapLibreStyleConfig.srcTransferConn
            let layerID = MapLibreStyleConfig.layerTransferConn

            guard !representable.hasActiveRoute else {
                if let source = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                    source.shape = MLNShapeCollectionFeature(shapes: [])
                }
                return
            }

            var features: [MLNPolylineFeature] = []
            for connector in representable.transferConnectors {
                guard connector.coordinates.count >= 2 else { continue }
                var coords = connector.coordinates
                let feature = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                let d = connector.distanceMeters
                feature.attributes = [
                    "width": max(1.0, 2.5 - (d / 120.0) * 1.5),
                    "opacity": max(0.4, 0.8 - (d / 120.0) * 0.4),
                ]
                features.append(feature)
            }

            let shape = MLNShapeCollectionFeature(shapes: features)

            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
            } else {
                let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
                sourcesCreated.insert(sourceID)

                let layer = MLNLineStyleLayer(identifier: layerID, source: source)
                layer.lineColor = NSExpression(forConstantValue: UIColor.systemGray4)
                layer.lineWidth = NSExpression(forKeyPath: "width")
                layer.lineOpacity = NSExpression(forKeyPath: "opacity")
                layer.lineCap = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }
        }

        // MARK: - Route Layers (selected route)

        func updateRouteLayers(style: MLNStyle, representable: MapLibreMapView) {
            let routeColor = representable.routeColor
            let isBus = representable.isBusRoute
            let isDark = representable.isDarkMode

            // ── Inactive direction (behind, dimmed) ──
            buildRoutePolylineLayer(
                style: style,
                sourceID: "route-inactive-source",
                casingLayerID: "route-inactive-casing",
                fillLayerID: "route-inactive-fill",
                coordinates: representable.inactivePolylines,
                color: routeColor.withAlphaComponent(0.15),
                casingColor: (isDark ? UIColor.white : UIColor.white).withAlphaComponent(0.15 * (isBus ? 0.6 : 1.0)),
                fillWidth: MapLibreStyleConfig.routeFillWidth,
                casingWidth: MapLibreStyleConfig.routeCasingWidth
            )

            // ── Active direction ──
            if let split = representable.directionalSplit {
                buildRoutePolylineLayer(
                    style: style,
                    sourceID: "route-behind-source",
                    casingLayerID: "route-behind-casing",
                    fillLayerID: "route-behind-fill",
                    coordinates: split.behind,
                    color: routeColor.withAlphaComponent(0.25),
                    casingColor: (isDark ? UIColor.white : UIColor.white).withAlphaComponent(0.3 * (isBus ? 0.6 : 1.0)),
                    fillWidth: MapLibreStyleConfig.routeFillWidth,
                    casingWidth: MapLibreStyleConfig.routeCasingWidth
                )
                buildRoutePolylineLayer(
                    style: style,
                    sourceID: "route-ahead-source",
                    casingLayerID: "route-ahead-casing",
                    fillLayerID: "route-ahead-fill",
                    coordinates: split.ahead,
                    color: routeColor,
                    casingColor: (isDark ? UIColor.white : UIColor.white).withAlphaComponent(0.8 * (isBus ? 0.6 : 1.0)),
                    fillWidth: MapLibreStyleConfig.routeFillWidth,
                    casingWidth: MapLibreStyleConfig.routeCasingWidth
                )
            } else if !representable.routePolylines.isEmpty {
                buildRoutePolylineLayer(
                    style: style,
                    sourceID: "route-active-source",
                    casingLayerID: "route-active-casing",
                    fillLayerID: "route-active-fill",
                    coordinates: representable.routePolylines,
                    color: routeColor,
                    casingColor: (isDark ? UIColor.white : UIColor.white).withAlphaComponent(0.8 * (isBus ? 0.6 : 1.0)),
                    fillWidth: MapLibreStyleConfig.routeFillWidth,
                    casingWidth: MapLibreStyleConfig.routeCasingWidth
                )
            } else {
                clearSource(style: style, sourceID: "route-active-source")
                clearSource(style: style, sourceID: "route-behind-source")
                clearSource(style: style, sourceID: "route-ahead-source")
            }
        }

        // MARK: - Walking Route Layer

        func updateWalkingRouteLayer(style: MLNStyle, representable: MapLibreMapView) {
            let sourceID = "walking-route-source"
            let glowLayerID = "walking-route-glow"
            let dashLayerID = "walking-route-dash"

            guard let coords = representable.walkingRouteCoords, coords.count >= 2 else {
                clearSource(style: style, sourceID: sourceID)
                return
            }

            var mutableCoords = coords
            let feature = MLNPolylineFeature(coordinates: &mutableCoords, count: UInt(mutableCoords.count))
            let shape = MLNShapeCollectionFeature(shapes: [feature])

            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
            } else {
                let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
                sourcesCreated.insert(sourceID)

                let glow = MLNLineStyleLayer(identifier: glowLayerID, source: source)
                glow.lineColor = NSExpression(forConstantValue: representable.routeColor.withAlphaComponent(0.25))
                glow.lineWidth = MapLibreStyleConfig.walkingRouteGlowWidth
                glow.lineCap = NSExpression(forConstantValue: "round")
                glow.lineJoin = NSExpression(forConstantValue: "round")
                glow.lineDashPattern = NSExpression(forConstantValue: [1, 10])
                style.addLayer(glow)

                let dash = MLNLineStyleLayer(identifier: dashLayerID, source: source)
                dash.lineColor = NSExpression(forConstantValue: UIColor.white)
                dash.lineWidth = MapLibreStyleConfig.walkingRouteWidth
                dash.lineCap = NSExpression(forConstantValue: "round")
                dash.lineJoin = NSExpression(forConstantValue: "round")
                dash.lineDashPattern = NSExpression(forConstantValue: [1, 10])
                style.addLayer(dash)
            }
        }

        // MARK: - Helpers: Elevated Detection

        private func isEffectivelyElevated(
            _ polyline: MapSystemViewModel.FlattenedMapPolyline,
            reroutedRouteIDs: Set<String>
        ) -> Bool {
            guard polyline.isElevated else { return false }
            guard !reroutedRouteIDs.isEmpty else { return true }
            return !polyline.routeIds.allSatisfy { reroutedRouteIDs.contains($0.uppercased()) }
        }

        // MARK: - Helpers: Feature Building

        /// Builds GeoJSON polyline features with per-feature `color` attribute.
        private func buildPolylineFeatures(
            _ polylines: [MapSystemViewModel.FlattenedMapPolyline]
        ) -> [MLNPolylineFeature] {
            var features: [MLNPolylineFeature] = []
            features.reserveCapacity(polylines.count)
            for polyline in polylines {
                guard polyline.coordinates.count >= 2 else { continue }
                var coords = polyline.coordinates
                let feature = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                feature.attributes = ["color": polyline.color.toHex()]
                features.append(feature)
            }
            return features
        }

        // MARK: - Helpers: Layer Creation

        /// Color mode for ensureLineLayer.
        enum LineColorMode {
            case constant(UIColor)
            case dataDriven  // Uses `color` attribute from GeoJSON feature
        }

        /// Creates or updates a line style layer with zoom-interpolated width.
        /// If `features` is nil, reuses the existing source (multi-layer-per-source).
        private func ensureLineLayer(
            style: MLNStyle,
            sourceID: String,
            layerID: String,
            features: [MLNPolylineFeature]?,
            width: NSExpression,
            opacity: Double,
            color: LineColorMode,
            cap: String,
            join: String,
            translatePixels: CGPoint? = nil
        ) {
            // Update or create source
            if let features {
                let shape = MLNShapeCollectionFeature(shapes: features)
                if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                    existing.shape = shape
                } else {
                    let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                    style.addSource(source)
                    sourcesCreated.insert(sourceID)
                }
            }

            // Ensure layer exists
            if style.layer(withIdentifier: layerID) == nil {
                guard let source = style.source(withIdentifier: sourceID) else { return }
                let layer = MLNLineStyleLayer(identifier: layerID, source: source)
                layer.lineWidth = width
                layer.lineOpacity = NSExpression(forConstantValue: NSNumber(value: Float(opacity)))
                layer.lineCap = NSExpression(forConstantValue: cap)
                layer.lineJoin = NSExpression(forConstantValue: join)

                switch color {
                case .constant(let uiColor):
                    layer.lineColor = NSExpression(forConstantValue: uiColor)
                case .dataDriven:
                    layer.lineColor = NSExpression(forKeyPath: "color")
                }

                if let translate = translatePixels {
                    layer.lineTranslation = NSExpression(
                        forConstantValue: NSValue(cgVector: CGVector(dx: translate.x, dy: translate.y))
                    )
                }

                style.addLayer(layer)
            }

            // Update dynamic properties (opacity changes when route is selected/deselected)
            if let layer = style.layer(withIdentifier: layerID) as? MLNLineStyleLayer {
                layer.lineOpacity = NSExpression(forConstantValue: NSNumber(value: Float(opacity)))
                // Update constant colors (needed for dark mode switching)
                if case .constant(let uiColor) = color {
                    layer.lineColor = NSExpression(forConstantValue: uiColor)
                }
            }
        }

        /// Builds a casing + fill route polyline layer pair.
        private func buildRoutePolylineLayer(
            style: MLNStyle,
            sourceID: String,
            casingLayerID: String,
            fillLayerID: String,
            coordinates: [[CLLocationCoordinate2D]],
            color: UIColor,
            casingColor: UIColor,
            fillWidth: NSExpression,
            casingWidth: NSExpression
        ) {
            var features: [MLNPolylineFeature] = []
            for coords in coordinates {
                guard coords.count >= 2 else { continue }
                var mutable = coords
                let feature = MLNPolylineFeature(coordinates: &mutable, count: UInt(mutable.count))
                features.append(feature)
            }

            let shape = MLNShapeCollectionFeature(shapes: features)

            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
            } else {
                let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
                sourcesCreated.insert(sourceID)

                let casing = MLNLineStyleLayer(identifier: casingLayerID, source: source)
                casing.lineColor = NSExpression(forConstantValue: casingColor)
                casing.lineWidth = casingWidth
                casing.lineCap = NSExpression(forConstantValue: "round")
                casing.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(casing)

                let fill = MLNLineStyleLayer(identifier: fillLayerID, source: source)
                fill.lineColor = NSExpression(forConstantValue: color)
                fill.lineWidth = fillWidth
                fill.lineCap = NSExpression(forConstantValue: "round")
                fill.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(fill)
            }

            // Update colors (for route switches)
            if let casing = style.layer(withIdentifier: casingLayerID) as? MLNLineStyleLayer {
                casing.lineColor = NSExpression(forConstantValue: casingColor)
            }
            if let fill = style.layer(withIdentifier: fillLayerID) as? MLNLineStyleLayer {
                fill.lineColor = NSExpression(forConstantValue: color)
            }
        }

        /// Clears a source's shape (emptying all features from its layers).
        private func clearSource(style: MLNStyle, sourceID: String) {
            if let source = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                source.shape = MLNShapeCollectionFeature(shapes: [])
            }
        }
    }
}

// MARK: - Color Extensions (UIColor ↔ Hex for GeoJSON attributes)

private extension UIColor {
    func toHex() -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

private extension Color {
    func toHex() -> String {
        UIColor(self).toHex()
    }
}
