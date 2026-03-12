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
import MapKit
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
    @Binding var cameraPosition: MapCameraPosition

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
    var transferConnectors: [TrackMapView.TransferConnector]

    /// Whether a route is currently selected (dims system map).
    var hasActiveRoute: Bool

    /// Route IDs currently rerouted (for z-order demotion).
    var reroutedRouteIDs: Set<String>

    /// Track user location.
    var showUserLocation: Bool = true

    /// Callback to pass the MLNMapView reference back to the parent
    /// so SwiftUI overlays can project coordinates → screen points.
    var onMapViewReady: ((MLNMapView) -> Void)?

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(
            frame: .zero,
            styleURL: MapLibreStyleConfig.defaultStyleURL
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

        // Update camera from binding (only if externally changed)
        if coordinator.shouldSyncCamera {
            let state = MapLibreCameraState(from: cameraPosition)
            // Only animate if significantly different from current position
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

        // Update layers after style loads
        if coordinator.styleLoaded {
            coordinator.updateSystemMapLayers(mapView: mapView, representable: self)
            coordinator.updateRouteLayers(mapView: mapView, representable: self)
            coordinator.updateWalkingRouteLayer(mapView: mapView, representable: self)
            coordinator.updateVehicleAnnotations(mapView: mapView, representable: self)
            coordinator.updateStationAnnotations(mapView: mapView, representable: self)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    /// Coordinates between SwiftUI state and the MapLibre GL view.
    /// Handles delegate callbacks, layer management, and annotation lifecycle.
    final class Coordinator: NSObject, MLNMapViewDelegate {

        private var parent: MapLibreMapView
        var styleLoaded = false
        var shouldSyncCamera = true

        // Track added source/layer IDs to avoid duplicates — O(1) lookup.
        private var addedSources: Set<String> = []
        private var addedLayers: Set<String> = []

        init(_ parent: MapLibreMapView) {
            self.parent = parent
        }

        // MARK: - Delegate: Style Loaded

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            // Initial layer setup
            updateSystemMapLayers(mapView: mapView, representable: parent)
            updateRouteLayer(mapView: mapView, representable: parent)
            updateVehicleAnnotations(mapView: mapView, representable: parent)
            updateStationAnnotations(mapView: mapView, representable: parent)
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
        private func syncCameraToBinding(_ mapView: MLNMapView) {
            shouldSyncCamera = false  // Prevent feedback loop

            let center = mapView.centerCoordinate
            let zoom = mapView.zoomLevel
            let distance = MapLibreCameraState.distanceFromZoom(zoom, at: center.latitude)

            parent.currentMapCenter = center
            parent.currentMapDistance = distance

            // Update camera position binding for downstream consumers
            let state = MapLibreCameraState(
                center: center,
                zoom: zoom,
                pitch: Double(mapView.camera.pitch),
                bearing: mapView.direction
            )
            parent.cameraPosition = state.toMapCameraPosition()

            // Station visibility based on zoom
            let zoomThreshold = AppSettings.shared.stationVisibilityZoomMeters
            let shouldShow = distance < zoomThreshold
            if shouldShow != parent.showStations {
                parent.showStations = shouldShow
            }
        }

        // MARK: - Delegate: Annotation Handling

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            // Vehicle and station annotations use SwiftUI overlays,
            // not MLNAnnotationView, for richer styling.
            return nil
        }

        // MARK: - System Map Layers

        /// Updates subway and commuter rail polyline layers on the map.
        ///
        /// Uses MapLibre's source/layer system:
        /// - One `MLNShapeSource` per layer type (subway, commuter, elevated)
        /// - One `MLNLineStyleLayer` per visual style
        ///
        /// Complexity: O(n) where n = total polyline segments.
        func updateSystemMapLayers(mapView: MLNMapView, representable: MapLibreMapView) {
            guard let style = mapView.style else { return }

            let opacity = representable.hasActiveRoute ? 0.08 : 1.0
            let commuterOpacity = representable.hasActiveRoute ? 0.06 : 0.35

            // Zoom-based line width (matches TrackMapView zoom tiers)
            let zoom = mapView.zoomLevel
            let lineWidth: CGFloat
            if zoom > 15 { lineWidth = 2.5 }
            else if zoom > 14 { lineWidth = 2.0 }
            else if zoom > 12 { lineWidth = 1.5 }
            else if zoom > 10 { lineWidth = 1.0 }
            else { lineWidth = 0.75 }

            // ── Subway lines ──
            updatePolylineLayer(
                style: style,
                sourceID: "subway-lines-source",
                layerID: "subway-lines-layer",
                polylines: representable.subwayPolylines.filter {
                    !isEffectivelyElevated($0, reroutedRouteIDs: representable.reroutedRouteIDs)
                },
                lineWidth: lineWidth,
                opacity: opacity,
                belowLayerID: nil
            )

            // ── Elevated lines (with casing for z-separation) ──
            let elevated = representable.subwayPolylines.filter {
                isEffectivelyElevated($0, reroutedRouteIDs: representable.reroutedRouteIDs)
            }
            updatePolylineLayer(
                style: style,
                sourceID: "elevated-casing-source",
                layerID: "elevated-casing-layer",
                polylines: elevated,
                lineWidth: lineWidth + 1.0,
                opacity: opacity * 0.25,
                colorOverride: UIColor.black,
                belowLayerID: nil
            )
            updatePolylineLayer(
                style: style,
                sourceID: "elevated-lines-source",
                layerID: "elevated-lines-layer",
                polylines: elevated,
                lineWidth: lineWidth,
                opacity: opacity,
                belowLayerID: nil
            )

            // ── Commuter rail ──
            updatePolylineLayer(
                style: style,
                sourceID: "commuter-lines-source",
                layerID: "commuter-lines-layer",
                polylines: representable.commuterRailPolylines,
                lineWidth: lineWidth,
                opacity: commuterOpacity,
                belowLayerID: nil
            )

            // ── Transfer connectors ──
            updateTransferConnectors(style: style, representable: representable)
        }

        /// Whether a polyline should render as elevated (same logic as TrackMapView).
        private func isEffectivelyElevated(
            _ polyline: MapSystemViewModel.FlattenedMapPolyline,
            reroutedRouteIDs: Set<String>
        ) -> Bool {
            guard polyline.isElevated else { return false }
            guard !reroutedRouteIDs.isEmpty else { return true }
            return !polyline.routeIds.allSatisfy { reroutedRouteIDs.contains($0.uppercased()) }
        }

        // MARK: - Polyline Layer Helper

        /// Adds or updates a polyline layer in the MapLibre style.
        ///
        /// Each polyline in the array becomes a `Feature` in a single
        /// `MLNShapeSource`, rendered by one `MLNLineStyleLayer`.
        /// Features carry a `color` property so the layer can data-drive
        /// the line color per-feature.
        ///
        /// Complexity: O(n) where n = number of polylines × avg coord count.
        private func updatePolylineLayer(
            style: MLNStyle,
            sourceID: String,
            layerID: String,
            polylines: [MapSystemViewModel.FlattenedMapPolyline],
            lineWidth: CGFloat,
            opacity: Double,
            colorOverride: UIColor? = nil,
            belowLayerID: String?
        ) {
            // Build GeoJSON features
            var features: [MLNPolylineFeature] = []
            features.reserveCapacity(polylines.count)

            for polyline in polylines {
                guard polyline.coordinates.count >= 2 else { continue }
                var coords = polyline.coordinates
                let feature = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                // Encode color as hex string for data-driven styling
                if colorOverride == nil {
                    feature.attributes = ["color": polyline.color.toHex()]
                }
                features.append(feature)
            }

            let shape = MLNShapeCollectionFeature(shapes: features)

            if let existingSource = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existingSource.shape = shape
            } else {
                let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
                addedSources.insert(sourceID)

                let layer = MLNLineStyleLayer(identifier: layerID, source: source)
                layer.lineWidth = NSExpression(forConstantValue: NSNumber(value: Float(lineWidth)))
                layer.lineOpacity = NSExpression(forConstantValue: NSNumber(value: Float(opacity)))
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")

                if let override = colorOverride {
                    layer.lineColor = NSExpression(forConstantValue: override)
                } else {
                    // Data-driven color from feature attributes
                    layer.lineColor = NSExpression(forKeyPath: "color")
                }

                if let below = belowLayerID, let belowLayer = style.layer(withIdentifier: below) {
                    style.insertLayer(layer, below: belowLayer)
                } else {
                    style.addLayer(layer)
                }
                addedLayers.insert(layerID)
            }

            // Update existing layer properties
            if let layer = style.layer(withIdentifier: layerID) as? MLNLineStyleLayer {
                layer.lineWidth = NSExpression(forConstantValue: NSNumber(value: Float(lineWidth)))
                layer.lineOpacity = NSExpression(forConstantValue: NSNumber(value: Float(opacity)))
            }
        }

        // MARK: - Transfer Connectors

        private func updateTransferConnectors(style: MLNStyle, representable: MapLibreMapView) {
            guard !representable.hasActiveRoute else {
                // Remove transfer connectors when route is active
                if let source = style.source(withIdentifier: "transfer-connectors-source") as? MLNShapeSource {
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
                let widthBase = max(1.0, 2.5 - (d / 120.0) * 1.5)
                let opacityBase = max(0.4, 0.8 - (d / 120.0) * 0.4)
                feature.attributes = [
                    "width": widthBase,
                    "opacity": opacityBase,
                ]
                features.append(feature)
            }

            let shape = MLNShapeCollectionFeature(shapes: features)
            let sourceID = "transfer-connectors-source"
            let layerID = "transfer-connectors-layer"

            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
            } else {
                let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)

                let layer = MLNLineStyleLayer(identifier: layerID, source: source)
                layer.lineColor = NSExpression(forConstantValue: UIColor.systemGray4)
                layer.lineWidth = NSExpression(forKeyPath: "width")
                layer.lineOpacity = NSExpression(forKeyPath: "opacity")
                layer.lineCap = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }
        }

        // MARK: - Route Layers (selected route polylines)

        func updateRouteLayer(mapView: MLNMapView, representable: MapLibreMapView) {
            updateRouteLayers(mapView: mapView, representable: representable)
        }

        func updateRouteLayers(mapView: MLNMapView, representable: MapLibreMapView) {
            guard let style = mapView.style else { return }

            let routeColor = representable.routeColor
            let isBus = representable.isBusRoute

            // Layer widths
            let fillWidth: CGFloat = 4.0
            let casingWidth: CGFloat = 6.0

            // ── Inactive direction polylines (behind, dimmed) ──
            buildRoutePolylineLayer(
                style: style,
                sourceID: "route-inactive-source",
                casingLayerID: "route-inactive-casing",
                fillLayerID: "route-inactive-fill",
                coordinates: representable.inactivePolylines,
                color: routeColor.withAlphaComponent(0.15),
                casingColor: UIColor.white.withAlphaComponent(0.15 * (isBus ? 0.6 : 1.0)),
                fillWidth: fillWidth,
                casingWidth: casingWidth
            )

            // ── Active direction ──
            if let split = representable.directionalSplit {
                // Behind (dimmed)
                buildRoutePolylineLayer(
                    style: style,
                    sourceID: "route-behind-source",
                    casingLayerID: "route-behind-casing",
                    fillLayerID: "route-behind-fill",
                    coordinates: split.behind,
                    color: routeColor.withAlphaComponent(0.25),
                    casingColor: UIColor.white.withAlphaComponent(0.3 * (isBus ? 0.6 : 1.0)),
                    fillWidth: fillWidth,
                    casingWidth: casingWidth
                )
                // Ahead (full color)
                buildRoutePolylineLayer(
                    style: style,
                    sourceID: "route-ahead-source",
                    casingLayerID: "route-ahead-casing",
                    fillLayerID: "route-ahead-fill",
                    coordinates: split.ahead,
                    color: routeColor,
                    casingColor: UIColor.white.withAlphaComponent(0.8 * (isBus ? 0.6 : 1.0)),
                    fillWidth: fillWidth,
                    casingWidth: casingWidth
                )
            } else if !representable.routePolylines.isEmpty {
                // No split — full color
                buildRoutePolylineLayer(
                    style: style,
                    sourceID: "route-active-source",
                    casingLayerID: "route-active-casing",
                    fillLayerID: "route-active-fill",
                    coordinates: representable.routePolylines,
                    color: routeColor,
                    casingColor: UIColor.white.withAlphaComponent(0.8 * (isBus ? 0.6 : 1.0)),
                    fillWidth: fillWidth,
                    casingWidth: casingWidth
                )
            } else {
                // Clear active route layers
                clearRouteLayer(style: style, sourceID: "route-active-source")
                clearRouteLayer(style: style, sourceID: "route-behind-source")
                clearRouteLayer(style: style, sourceID: "route-ahead-source")
            }
        }

        /// Builds a casing + fill polyline layer pair for route display.
        private func buildRoutePolylineLayer(
            style: MLNStyle,
            sourceID: String,
            casingLayerID: String,
            fillLayerID: String,
            coordinates: [[CLLocationCoordinate2D]],
            color: UIColor,
            casingColor: UIColor,
            fillWidth: CGFloat,
            casingWidth: CGFloat
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

                // Casing layer (wider, white/semi-transparent)
                let casing = MLNLineStyleLayer(identifier: casingLayerID, source: source)
                casing.lineColor = NSExpression(forConstantValue: casingColor)
                casing.lineWidth = NSExpression(forConstantValue: NSNumber(value: Float(casingWidth)))
                casing.lineCap = NSExpression(forConstantValue: "round")
                casing.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(casing)

                // Fill layer (narrower, colored)
                let fill = MLNLineStyleLayer(identifier: fillLayerID, source: source)
                fill.lineColor = NSExpression(forConstantValue: color)
                fill.lineWidth = NSExpression(forConstantValue: NSNumber(value: Float(fillWidth)))
                fill.lineCap = NSExpression(forConstantValue: "round")
                fill.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(fill)
            }

            // Update colors on existing layers
            if let casing = style.layer(withIdentifier: casingLayerID) as? MLNLineStyleLayer {
                casing.lineColor = NSExpression(forConstantValue: casingColor)
            }
            if let fill = style.layer(withIdentifier: fillLayerID) as? MLNLineStyleLayer {
                fill.lineColor = NSExpression(forConstantValue: color)
            }
        }

        private func clearRouteLayer(style: MLNStyle, sourceID: String) {
            if let source = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                source.shape = MLNShapeCollectionFeature(shapes: [])
            }
        }

        // MARK: - Walking Route Layer

        func updateWalkingRouteLayer(mapView: MLNMapView, representable: MapLibreMapView) {
            guard let style = mapView.style else { return }

            let sourceID = "walking-route-source"
            let glowLayerID = "walking-route-glow"
            let dashLayerID = "walking-route-dash"

            guard let coords = representable.walkingRouteCoords, coords.count >= 2 else {
                // Clear walking route
                if let source = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                    source.shape = MLNShapeCollectionFeature(shapes: [])
                }
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

                // Glow (route-colored, translucent, dotted)
                let glow = MLNLineStyleLayer(identifier: glowLayerID, source: source)
                glow.lineColor = NSExpression(forConstantValue: representable.routeColor.withAlphaComponent(0.25))
                glow.lineWidth = NSExpression(forConstantValue: NSNumber(value: 6.0))
                glow.lineCap = NSExpression(forConstantValue: "round")
                glow.lineJoin = NSExpression(forConstantValue: "round")
                glow.lineDashPattern = NSExpression(forConstantValue: [1, 10])
                style.addLayer(glow)

                // White dotted line on top
                let dash = MLNLineStyleLayer(identifier: dashLayerID, source: source)
                dash.lineColor = NSExpression(forConstantValue: UIColor.white)
                dash.lineWidth = NSExpression(forConstantValue: NSNumber(value: 3.0))
                dash.lineCap = NSExpression(forConstantValue: "round")
                dash.lineJoin = NSExpression(forConstantValue: "round")
                dash.lineDashPattern = NSExpression(forConstantValue: [1, 10])
                style.addLayer(dash)
            }
        }

        // MARK: - Vehicle Annotations

        /// Updates vehicle annotation positions on the map.
        ///
        /// Uses MapLibre point annotations (lightweight, GPU-batched)
        /// for vehicle positions. The SwiftUI overlay handles the
        /// custom marker views.
        func updateVehicleAnnotations(mapView: MLNMapView, representable: MapLibreMapView) {
            // Vehicle markers are rendered as SwiftUI overlay views
            // positioned using the map's coordinate-to-point conversion.
            // This avoids MapLibre annotation churn on every position update.
            // See MapLibreVehicleOverlay for the SwiftUI implementation.
        }

        // MARK: - Station Annotations

        func updateStationAnnotations(mapView: MLNMapView, representable: MapLibreMapView) {
            // Station capsules are complex SwiftUI views (multi-color pills,
            // pulse animations, etc.) that exceed what MLNAnnotationView can do.
            // They're rendered as a SwiftUI overlay using coordinate projection.
            // See MapLibreTrackMapView for the overlay implementation.
        }
    }
}

// MARK: - Color Extension (UIColor → Hex for GeoJSON)

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
