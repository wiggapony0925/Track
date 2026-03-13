//
//  MapLibreMapView.swift
//  Track
//
//  UIViewRepresentable bridge wrapping MapLibre GL Native's `MLNMapView`
//  for SwiftUI. Uses OpenStreetMap vector tiles via MapTiler for the base map.
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
/// This is the core bridge for rendering the Track map.
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

    /// Called on every camera frame (pan/zoom/rotate) so SwiftUI overlays
    /// can re-project coordinates. Without this, overlays only update when
    /// their data inputs change, causing markers to "stick" to the screen.
    var onCameraMove: (() -> Void)?

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
        coordinator.parent = self   // Keep coordinator in sync with latest struct

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
    /// SwiftUI overlays. This unlocks:
    /// - Zoom-interpolated line widths (smooth scaling via `mgl_interpolate`)
    /// - Per-feature data-driven styling (color from GeoJSON attributes)
    /// - Native GL circle/symbol layers for station dots
    /// - Proper casing layers for the signature Transit-style line borders
    /// - Dark mode via MapTiler style switching
    final class Coordinator: NSObject, MLNMapViewDelegate {

        var parent: MapLibreMapView
        var styleLoaded = false
        var shouldSyncCamera = true
        var currentStyleIsDark: Bool?

        /// Tracks created sources — cleared on style reload so layers get recreated.
        var sourcesCreated: Set<String> = []

        // MARK: - Dirty Flags (P0 perf optimization)
        //
        // `updateUIView` fires on EVERY SwiftUI re-eval — including 60fps
        // camera frames. Without dirty flags, `updateAllLayers` rebuilds
        // all GeoJSON features from scratch every 16ms (thousands of
        // pointless heap allocations). These hashes let us skip layers
        // whose input data hasn't changed since the last rebuild.

        private var lastSubwayHash: Int = -1
        private var lastStationHash: Int = -1
        private var lastRouteHash: Int = -1
        private var lastWalkingHash: Int = -1
        private var lastTransferHash: Int = -1
        private var lastDarkMode: Bool?

        /// Cached built shapes — avoid rebuilding GeoJSON when data is unchanged.
        private var cachedSubwayShape: MLNShapeCollectionFeature?
        private var cachedCommuterShape: MLNShapeCollectionFeature?
        private var cachedElevatedShape: MLNShapeCollectionFeature?
        private var cachedStationShape: MLNShapeCollectionFeature?

        init(_ parent: MapLibreMapView) {
            self.parent = parent
        }

        // MARK: - Delegate: Style Loaded

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            sourcesCreated.removeAll()  // New style = all layers need recreation
            invalidateAllDirtyFlags()   // Force full rebuild
            setup3DBuildings(style: style, isDarkMode: parent.isDarkMode)
            updateAllLayers(mapView: mapView, representable: parent)
        }

        /// Resets all dirty-flag hashes so the next `updateAllLayers` call
        /// rebuilds every layer. Called on style reload (dark ↔ light switch).
        private func invalidateAllDirtyFlags() {
            lastSubwayHash = -1
            lastStationHash = -1
            lastRouteHash = -1
            lastWalkingHash = -1
            lastTransferHash = -1
            lastDarkMode = nil
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

                // Notify parent so overlay projection refreshes every gesture frame
                self.parent.onCameraMove?()
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
        // smooth zoom-interpolated rendering.

        func updateAllLayers(mapView: MLNMapView, representable: MapLibreMapView) {
            guard let style = mapView.style else { return }

            let darkChanged = lastDarkMode != representable.isDarkMode
            lastDarkMode = representable.isDarkMode

            // Update 3D building colors on dark mode switch
            if darkChanged {
                setup3DBuildings(style: style, isDarkMode: representable.isDarkMode)
            }

            // System map hash: changes when polyline count, active state, or dark mode change.
            // Polyline data is essentially static per session — only changes on initial load
            // or dark mode toggle.
            let subwayHash = representable.subwayPolylines.count
                ^ (representable.commuterRailPolylines.count &* 31)
                ^ (representable.hasActiveRoute ? 0x1 : 0x0)
                ^ (representable.reroutedRouteIDs.count &* 127)
            if subwayHash != lastSubwayHash || darkChanged {
                updateSystemMapLayers(style: style, representable: representable)
                lastSubwayHash = subwayHash
            }

            // Station dots hash: changes when station count or active route state changes.
            let stationHash = representable.stations.count
                ^ (representable.hasActiveRoute ? 0x2 : 0x0)
            if stationHash != lastStationHash || darkChanged {
                updateStationDotLayers(style: style, representable: representable)
                lastStationHash = stationHash
            }

            // Route layers: change on route selection/deselection, directional split, walking route.
            // Include the first coordinate of ahead[0] so the hash changes when
            // the split point shifts (e.g. train approaches next stop).
            let splitContentHash: Int = {
                guard let split = representable.directionalSplit,
                      let firstAhead = split.ahead.first?.first else { return 0 }
                return Int(firstAhead.latitude * 1e4) ^ Int(firstAhead.longitude * 1e4)
            }()
            let routeHash = representable.routePolylines.count
                ^ (representable.inactivePolylines.count &* 31)
                ^ (representable.directionalSplit.map { $0.ahead.count ^ $0.behind.count } ?? 0)
                ^ splitContentHash
                ^ representable.routeColor.hash
            if routeHash != lastRouteHash || darkChanged {
                updateRouteLayers(style: style, representable: representable)
                lastRouteHash = routeHash
            }

            let walkingHash = (representable.walkingRouteCoords?.count ?? 0)
            if walkingHash != lastWalkingHash {
                updateWalkingRouteLayer(style: style, representable: representable)
                lastWalkingHash = walkingHash
            }

            let transferHash = representable.transferConnectors.count
                ^ (representable.hasActiveRoute ? 0x4 : 0x0)
            if transferHash != lastTransferHash {
                updateTransferConnectors(style: style, representable: representable)
                lastTransferHash = transferHash
            }
        }

        // MARK: - System Map Layers (Subway + Commuter + Elevated)
        //
        // Following Transit's rendering pipeline:
        //   1. Casing layer (wider, white/dark) renders first →  border/shadow
        //   2. Fill layer (narrower, colored) renders on top → colored line
        //   3. Elevated gets an additional shadow layer underneath for depth
        //
        // All widths use `mgl_interpolate` for buttery-smooth zoom scaling.

        func updateSystemMapLayers(style: MLNStyle, representable: MapLibreMapView) {
            let dimmed = representable.hasActiveRoute
            let subwayOpacity: Double = dimmed ? 0.10 : 1.0
            let commuterOpacity: Double = dimmed ? 0.08 : 0.65
            let casingOpacity: Double = dimmed ? 0.05 : 0.45
            let commuterCasingOpacity: Double = dimmed ? 0.03 : 0.20
            let isDark = representable.isDarkMode

            // ── COMMUTER RAIL (below subway) ──
            // Rendered as dashed lines (like real transit maps) to visually
            // distinguish commuter rail from heavier subway service.
            let commuterFeatures = buildPolylineFeatures(representable.commuterRailPolylines)
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcCommRail,
                layerID: MapLibreStyleConfig.layerCommRailCasing,
                features: commuterFeatures,
                width: MapLibreStyleConfig.commuterCasingWidth,
                opacity: commuterCasingOpacity,
                color: .constant(isDark ? UIColor.white.withAlphaComponent(0.15) : UIColor.white),
                cap: "butt", join: "round",
                dashPattern: [3, 2]
            )
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcCommRail,
                layerID: MapLibreStyleConfig.layerCommRailFill,
                features: nil,  // reuse source
                width: MapLibreStyleConfig.commuterFillWidth,
                opacity: commuterOpacity,
                color: .dataDriven,
                cap: "butt", join: "round",
                dashPattern: [3, 2]
            )

            // ── SUBWAY (standard underground/surface lines) ──
            let subwayOnly = representable.subwayPolylines.filter {
                !isEffectivelyElevated($0, reroutedRouteIDs: representable.reroutedRouteIDs)
            }
            let subwayFeatures = buildPolylineFeatures(subwayOnly)

            // Soft casing — semi-transparent white gives lines a "floating"
            // appearance above the base map (Uber/Lyft-grade polish).
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcSubway,
                layerID: MapLibreStyleConfig.layerSubwayCasing,
                features: subwayFeatures,
                width: MapLibreStyleConfig.subwayCasingWidth,
                opacity: casingOpacity,
                color: .constant(isDark ? UIColor.white.withAlphaComponent(0.25) : UIColor.white),
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

            // Shadow layer — offset down-right for a 3D depth illusion.
            // Slightly wider and softer than before for a premium look.
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcElevated,
                layerID: MapLibreStyleConfig.layerElevatedShadow,
                features: elevatedFeatures,
                width: MapLibreStyleConfig.elevatedCasingWidth,
                opacity: dimmed ? 0.02 : (isDark ? 0.20 : 0.12),
                color: .constant(UIColor.black),
                cap: "round", join: "round",
                translatePixels: CGPoint(x: 1.5, y: 3)
            )
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcElevated,
                layerID: MapLibreStyleConfig.layerElevatedCasing,
                features: nil,
                width: MapLibreStyleConfig.elevatedCasingWidth,
                opacity: casingOpacity,
                color: .constant(isDark ? UIColor.white.withAlphaComponent(0.30) : UIColor.white),
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
        // Premium station rendering pipeline:
        //
        // Layer stack (bottom to top):
        //   1. Shadow circles — subtle offset-translated dark circles beneath
        //      each station dot for a floating/embossed effect
        //   2. Single-line dots — route-colored fill with crisp white stroke
        //   3. Transfer dots — white fill with dark stroke (larger radius)
        //   4. Station labels — semibold text with thick halo for readability
        //
        // All properties zoom-interpolated for buttery-smooth transitions.
        // Thousands of stations rendered at zero CPU cost (GL batches).

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

                // ── Shadow layer — subtle depth effect beneath all dots ──
                let shadowLayer = MLNCircleStyleLayer(
                    identifier: MapLibreStyleConfig.layerStationDotsShadow,
                    source: source
                )
                shadowLayer.circleRadius = MapLibreStyleConfig.transferDotRadius
                shadowLayer.circleColor = NSExpression(
                    forConstantValue: UIColor.black.withAlphaComponent(0.0)
                )
                shadowLayer.circleBlur = NSExpression(forConstantValue: 0.8)
                shadowLayer.circleStrokeWidth = NSExpression(forConstantValue: 0)
                shadowLayer.circleTranslation = NSExpression(
                    forConstantValue: NSValue(cgVector: CGVector(dx: 0.5, dy: 1.0))
                )
                shadowLayer.circleOpacity = NSExpression(
                    format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
                    [12: 0.0, 13: 0.15, 16: 0.25]
                )
                shadowLayer.minimumZoomLevel = 12
                style.addLayer(shadowLayer)

                // ── Single-line station dots — route-colored fill ──
                let singleLayer = MLNCircleStyleLayer(
                    identifier: MapLibreStyleConfig.layerStationDotsSingle,
                    source: source
                )
                singleLayer.circleRadius = MapLibreStyleConfig.stationDotRadius
                singleLayer.circleColor = NSExpression(forKeyPath: "color")
                singleLayer.circleStrokeColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white.withAlphaComponent(0.5) : UIColor.white
                )
                singleLayer.circleStrokeWidth = MapLibreStyleConfig.stationDotStrokeWidth
                singleLayer.predicate = NSPredicate(format: "isTransfer == NO")
                singleLayer.minimumZoomLevel = 12
                // Fade in smoothly
                singleLayer.circleOpacity = NSExpression(
                    format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
                    [12: 0.0, 12.5: 1.0]
                )
                style.addLayer(singleLayer)

                // ── Transfer station dots — white fill + dark stroke ──
                let transferLayer = MLNCircleStyleLayer(
                    identifier: MapLibreStyleConfig.layerStationDotsTransfer,
                    source: source
                )
                transferLayer.circleRadius = MapLibreStyleConfig.transferDotRadius
                transferLayer.circleColor = NSExpression(
                    forConstantValue: isDark ? UIColor(white: 0.15, alpha: 1) : UIColor.white
                )
                transferLayer.circleStrokeColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white.withAlphaComponent(0.7) : UIColor(white: 0.15, alpha: 1)
                )
                transferLayer.circleStrokeWidth = MapLibreStyleConfig.stationDotStrokeWidth
                transferLayer.predicate = NSPredicate(format: "isTransfer == YES")
                transferLayer.minimumZoomLevel = 11
                // Fade in smoothly
                transferLayer.circleOpacity = NSExpression(
                    format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
                    [11: 0.0, 11.5: 1.0]
                )
                style.addLayer(transferLayer)

                // ── Station labels — crisp text with generous halo ──
                let labelLayer = MLNSymbolStyleLayer(
                    identifier: MapLibreStyleConfig.layerStationLabels,
                    source: source
                )
                labelLayer.text = NSExpression(forKeyPath: "name")
                labelLayer.textFontSize = MapLibreStyleConfig.stationLabelFontSize
                labelLayer.textColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white : UIColor(white: 0.12, alpha: 1)
                )
                labelLayer.textHaloColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor.black.withAlphaComponent(0.85)
                        : UIColor.white.withAlphaComponent(0.95)
                )
                labelLayer.textHaloWidth = NSExpression(forConstantValue: 2.0)
                labelLayer.textHaloBlur = NSExpression(forConstantValue: 0.5)
                labelLayer.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.3)))
                labelLayer.textAnchor = NSExpression(forConstantValue: "top")
                labelLayer.textFontNames = NSExpression(forConstantValue: ["Open Sans Semibold", "Arial Unicode MS Bold"])
                labelLayer.textLetterSpacing = NSExpression(forConstantValue: 0.02)
                labelLayer.minimumZoomLevel = 14
                // Fade in labels
                labelLayer.textOpacity = NSExpression(
                    format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
                    [14: 0.0, 14.5: 1.0]
                )
                labelLayer.textAllowsOverlap = NSExpression(
                    format: "mgl_step:from:stops:($zoomLevel, false, %@)",
                    [16: true]
                )
                style.addLayer(labelLayer)
            }

            // Update colors for dark/light mode on existing layers
            if let single = style.layer(withIdentifier: MapLibreStyleConfig.layerStationDotsSingle) as? MLNCircleStyleLayer {
                single.circleStrokeColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white.withAlphaComponent(0.5) : UIColor.white
                )
            }
            if let transfer = style.layer(withIdentifier: MapLibreStyleConfig.layerStationDotsTransfer) as? MLNCircleStyleLayer {
                transfer.circleColor = NSExpression(
                    forConstantValue: isDark ? UIColor(white: 0.15, alpha: 1) : UIColor.white
                )
                transfer.circleStrokeColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white.withAlphaComponent(0.7) : UIColor(white: 0.15, alpha: 1)
                )
            }
            if let labels = style.layer(withIdentifier: MapLibreStyleConfig.layerStationLabels) as? MLNSymbolStyleLayer {
                labels.textColor = NSExpression(
                    forConstantValue: isDark ? UIColor.white : UIColor(white: 0.12, alpha: 1)
                )
                labels.textHaloColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor.black.withAlphaComponent(0.85)
                        : UIColor.white.withAlphaComponent(0.95)
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
                casingColor: (isDark ? UIColor(white: 0.7, alpha: 1) : UIColor.white).withAlphaComponent(0.15 * (isBus ? 0.6 : 1.0)),
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
                    casingColor: (isDark ? UIColor(white: 0.7, alpha: 1) : UIColor.white).withAlphaComponent(0.3 * (isBus ? 0.6 : 1.0)),
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
                    casingColor: (isDark ? UIColor(white: 0.7, alpha: 1) : UIColor.white).withAlphaComponent(0.8 * (isBus ? 0.6 : 1.0)),
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
                    casingColor: (isDark ? UIColor(white: 0.7, alpha: 1) : UIColor.white).withAlphaComponent(0.8 * (isBus ? 0.6 : 1.0)),
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

        // MARK: - 3D Building Extrusions
        //
        // MapTiler vector tiles include a "building" source layer with
        // `render_height` and `render_min_height` attributes (meters).
        // We add an MLNFillExtrusionStyleLayer that reads those to
        // render extruded 3D buildings when the camera is pitched.
        // Placed below all transit layers so buildings never occlude routes.

        /// Whether 3D buildings have been added to the current style.
        private var buildings3DAdded = false

        /// Adds a 3D building extrusion layer using the MapTiler vector tile
        /// `building` source layer. Only needs to run once per style load.
        func setup3DBuildings(style: MLNStyle, isDarkMode: Bool) {
            // Remove existing layer if present (e.g. dark/light mode switch)
            if let existing = style.layer(withIdentifier: MapLibreStyleConfig.layerBuilding3D) {
                style.removeLayer(existing)
            }

            // MapTiler vector tiles expose "openmaptiles" as the source identifier.
            // The building footprints live in the "building" source-layer within it.
            guard let source = style.source(withIdentifier: "openmaptiles") else {
                // Fallback: try "maptiler_planet" (some MapTiler styles use this name)
                guard let altSource = style.source(withIdentifier: "maptiler_planet") else {
                    return  // Raster tile fallback — no vector building data available
                }
                addBuildingExtrusionLayer(style: style, source: altSource, isDarkMode: isDarkMode)
                return
            }
            addBuildingExtrusionLayer(style: style, source: source, isDarkMode: isDarkMode)
        }

        private func addBuildingExtrusionLayer(
            style: MLNStyle,
            source: MLNSource,
            isDarkMode: Bool
        ) {
            let layer = MLNFillExtrusionStyleLayer(
                identifier: MapLibreStyleConfig.layerBuilding3D,
                source: source
            )
            layer.sourceLayerIdentifier = "building"

            // Only extrude features that have height data
            layer.predicate = NSPredicate(format: "render_height > 0")

            // Heights from OSM building tags (in meters)
            layer.fillExtrusionHeight = NSExpression(forKeyPath: "render_height")
            layer.fillExtrusionBase = NSExpression(forKeyPath: "render_min_height")

            // Color & opacity — subtle enough to not compete with transit overlays
            let color = isDarkMode
                ? MapLibreStyleConfig.buildingColorDark
                : MapLibreStyleConfig.buildingColorLight
            layer.fillExtrusionColor = NSExpression(forConstantValue: color)
            layer.fillExtrusionOpacity = isDarkMode
                ? MapLibreStyleConfig.buildingOpacityDark
                : MapLibreStyleConfig.buildingOpacity

            // Slight translation for ambient shadow direction (sunlight from top-left)
            layer.fillExtrusionTranslation = NSExpression(
                forConstantValue: NSValue(cgVector: CGVector(dx: 0.5, dy: 1.0))
            )

            // Minimum zoom — no point rendering at city-wide zoom
            layer.minimumZoomLevel = Float(MapLibreStyleConfig.building3DMinZoom)

            // Insert below our transit layers — find the lowest transit layer
            // (commuter casing) and insert buildings right before it.
            if let commuterLayer = style.layer(withIdentifier: MapLibreStyleConfig.layerCommRailCasing) {
                style.insertLayer(layer, below: commuterLayer)
            } else {
                // Transit layers not yet added — just add; they'll be placed above later
                style.addLayer(layer)
            }

            buildings3DAdded = true
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
            translatePixels: CGPoint? = nil,
            dashPattern: [NSNumber]? = nil
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

                if let dash = dashPattern {
                    layer.lineDashPattern = NSExpression(forConstantValue: dash)
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
