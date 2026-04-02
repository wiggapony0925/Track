// UIViewRepresentable bridge wrapping MapLibre GL Native's `MLNMapView`
// for SwiftUI. Uses OpenStreetMap vector tiles via MapTiler for the base map.
// Architecture:
// ┌──────────────────────────────────────────────┐
// │  SwiftUI (MapLibreTrackMapView)              │
// │    ↓ bindings                                │
// │  MapLibreMapView (UIViewRepresentable)       │
// │    ↓ manages                                 │
// │  MLNMapView (UIKit — GPU-accelerated GL)     │
// │    ↓ tile source                             │
// │  MapTiler / OpenStreetMap vector tiles        │
// └──────────────────────────────────────────────┘
// Performance Notes:
// - polyline/annotation updates are O(n) where n = number of features
// - Camera sync is O(1) per frame
// - Style layers use MapLibre's GPU pipeline (no CPU-side drawing)
// References:
// - MapLibre iOS: https://maplibre.org/maplibre-native/ios/latest/
// - MLNMapView: MLNMapView class in MapLibre Native

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
struct MapLibreMapView: UIViewRepresentable, Equatable {
    
    // MARK: - Equatable Fast-Path
    //
    // Severe CPU spike fix: When this view is re-evaluated 60x/sec during map pans,
    // SwiftUI performs a deep recursive structural equality check on all these massive
    // arrays (10,000+ points). This brings the framerate to a crawl.
    // Conforming to `Equatable` skips the automatic deep-equality structural walk
    // and returns identical if the data signatures (counts/ids) match.
    static func == (lhs: MapLibreMapView, rhs: MapLibreMapView) -> Bool {
        // Fast shallow checks. If counts match, assume data hasn't rebuilt.
        // Explicit Bool bindings help the type-checker resolve quickly.
        let camEq: Bool = lhs.cameraPosition == rhs.cameraPosition
        let stationsEq: Bool = lhs.showStations == rhs.showStations
        let darkEq: Bool = lhs.isDarkMode == rhs.isDarkMode
        let activeEq: Bool = lhs.hasActiveRoute == rhs.hasActiveRoute
        let busEq: Bool = lhs.isBusRoute == rhs.isBusRoute
        let colorEq: Bool = lhs.routeColor == rhs.routeColor
        let rerouteEq: Bool = lhs.reroutedRouteIDs == rhs.reroutedRouteIDs
        let modeEq: Bool = lhs.selectedMode == rhs.selectedMode

        guard camEq, stationsEq, darkEq, activeEq, busEq, colorEq, rerouteEq, modeEq else {
            return false
        }

        let subwayEq: Bool = lhs.subwayPolylines.count == rhs.subwayPolylines.count
        let commuterEq: Bool = lhs.commuterRailPolylines.count == rhs.commuterRailPolylines.count
        let stationCntEq: Bool = lhs.stations.count == rhs.stations.count
        let busCntEq: Bool = lhs.busVehicles.count == rhs.busVehicles.count
        let trainCntEq: Bool = lhs.trainVehicles.count == rhs.trainVehicles.count
        let routeCntEq: Bool = lhs.routePolylines.count == rhs.routePolylines.count
        let xferCntEq: Bool = lhs.transferConnectors.count == rhs.transferConnectors.count

        guard subwayEq, commuterEq, stationCntEq, busCntEq, trainCntEq, routeCntEq, xferCntEq else {
            return false
        }

        return true
    }

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

    /// Crossing points for casing-break rendering.
    var crossings: [CrossingPoint]

    /// Whether a route is currently selected (dims system map).
    var hasActiveRoute: Bool

    /// Route IDs currently rerouted (for z-order demotion).
    var reroutedRouteIDs: Set<String>

    /// Track user location.
    var showUserLocation: Bool = true

    /// Whether the system is in dark mode (drives MapTiler style selection).
    var isDarkMode: Bool
    
    /// Global transport mode filter (dims polylines that don't match the dashboard mode).
    var selectedMode: TransportMode

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
        mapView.automaticallyAdjustsContentInset = false
        mapView.showsUserLocation = showUserLocation
        mapView.minimumZoomLevel = MapLibreStyleConfig.minZoom
        mapView.maximumZoomLevel = MapLibreStyleConfig.maxZoom

        // Render at native display refresh rate (60fps / 120fps ProMotion)
        // for buttery-smooth panning and pinch-zoom. The GPU-accelerated GL
        // pipeline handles this efficiently; SwiftUI overlays are separately
        // throttled to ~30fps via cameraChangeToken.
        mapView.preferredFramesPerSecond = .maximum

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

        // ── Dark mode style switching (smooth crossfade) ──
        // MapTiler provides both light (pastel) and dark (dataviz-dark) styles.
        // When colorScheme changes we snapshot the current map into a UIImageView,
        // swap the tile URL underneath, then crossfade the snapshot out — no flicker.
        if coordinator.currentStyleIsDark != isDarkMode {
            coordinator.currentStyleIsDark = isDarkMode
            let newURL = MapLibreStyleConfig.styleURL(isDarkMode: isDarkMode)
                ?? MapLibreStyleConfig.osmRasterStyleJSON()
            if let newURL {
                // 1) Capture a raster snapshot of the outgoing style
                //    using UIKit's drawHierarchy (works for any UIView).
                let snapshotTag = 9999
                // Guard against rendering offscreen (causes console warnings
                // and wastes GPU time when the map view isn't in a window).
                let snapshot: UIImage?
                if mapView.window != nil {
                    let renderer = UIGraphicsImageRenderer(bounds: mapView.bounds)
                    snapshot = renderer.image { _ in
                        mapView.drawHierarchy(in: mapView.bounds, afterScreenUpdates: false)
                    }
                } else {
                    snapshot = nil
                }
                // Only show the crossfade overlay if we actually captured a snapshot
                if let snapshot {
                    let overlay = UIImageView(image: snapshot)
                    overlay.frame = mapView.bounds
                    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    overlay.contentMode = .scaleAspectFill
                    overlay.tag = snapshotTag
                    mapView.addSubview(overlay)
                }

                // 2) Load the new style behind the snapshot.
                mapView.styleURL = newURL
                coordinator.styleLoaded = false
                coordinator.sourcesCreated.removeAll()

                // 3) Crossfade the snapshot away once the new style loads.
                //    Fast fade so transitions feel instant.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let overlay = mapView.viewWithTag(snapshotTag) {
                        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                            overlay.alpha = 0
                        } completion: { _ in
                            overlay.removeFromSuperview()
                        }
                    }
                }
            }
        }

        // ── Route-colour tint (single-pass, merged into customizeBaseStyle) ──
        // When a route is selected/deselected or changes colour, re-run
        // customizeBaseStyle with the route colour baked in — one iteration,
        // instant, no separate tint pass.
        if coordinator.styleLoaded {
            let wantsTint = hasActiveRoute
            let tintChanged: Bool = {
                if wantsTint != coordinator.lastRouteTintActive { return true }
                if wantsTint,
                   !MapLibreStyleConfig.colorsEqualRGBA(
                    routeColor,
                    coordinator.lastRouteTintColor
                   ) { return true }
                return false
            }()

            if tintChanged {
                if let style = mapView.style {
                    MapLibreStyleConfig.customizeBaseStyle(
                        style,
                        isDarkMode: isDarkMode,
                        routeColor: wantsTint ? routeColor : nil
                    )
                }
                coordinator.lastRouteTintActive = wantsTint
                coordinator.lastRouteTintColor = wantsTint ? routeColor : nil
            }
        }

        // ── Camera sync (only if externally changed) ──
        if coordinator.shouldSyncCamera {
            let state = MapLibreCameraState(from: cameraPosition)
            let currentZoom: Double = mapView.zoomLevel
            let currentCenter: CLLocationCoordinate2D = mapView.centerCoordinate
            let zoomDiff: Double = abs(state.zoom - currentZoom)
            let latDiff: Double = abs(state.center.latitude - currentCenter.latitude)
            let lonDiff: Double = abs(state.center.longitude - currentCenter.longitude)
            let needsUpdate: Bool = zoomDiff > 0.1 || latDiff > 1e-5 || lonDiff > 1e-5

            if needsUpdate {
                // Mark programmatic animation in flight so syncCameraToBinding
                // doesn't overwrite cameraPosition with intermediate frames.
                coordinator.programmaticCameraInFlight = true
                mapView.setCenter(
                    state.center,
                    zoomLevel: state.zoom,
                    direction: state.bearing,
                    animated: true
                )
                let pitchDiff: Double = abs(state.pitch - Double(mapView.camera.pitch))
                if pitchDiff > 1.0 {
                    let camera = mapView.camera
                    camera.pitch = CGFloat(state.pitch)
                    mapView.setCamera(camera, animated: true)
                }
            }
        }
        coordinator.shouldSyncCamera = true

        // ── Layer updates (all GL layers managed by coordinator) ──
        // Gate on initialTilesRendered so transit lines don't pop in
        // before the basemap tiles are visible.
        if coordinator.styleLoaded && coordinator.initialTilesRendered {
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

        /// When true, a code-driven camera animation is in flight.
        /// `syncCameraToBinding` skips binding writes while this flag is set
        /// so intermediate animation frames don't overwrite the requested
        /// destination and cause the "triple-tap to center" bug.
        var programmaticCameraInFlight = false

        /// Tracks created sources — cleared on style reload so layers get recreated.
        var sourcesCreated: Set<String> = []

        // MARK: - Camera Sync Throttle
        //
        // `mapViewRegionIsChanging` fires every gesture frame (~60fps).
        // Writing 4 @Binding values per frame floods SwiftUI's attribute
        // graph and triggers "setting value during update" crashes.
        // Throttle to at most one sync per display frame (~16ms).
        private var pendingCameraSync: DispatchWorkItem?
        /// Timestamp of the last actually-executed camera sync write.
        /// Used to prevent multiple binding updates in a single run-loop
        /// pass (which causes "action tried to update multiple times per
        /// frame" warnings on `Optional<Double>` onChange handlers).
        private var _lastCameraSyncTime: CFAbsoluteTime = 0

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

        /// Route-colour tint tracking — detects when the tint should
        /// be applied, changed, or removed so we can trigger a crossfade.
        fileprivate var lastRouteTintActive: Bool = false
        fileprivate var lastRouteTintColor: UIColor?

        /// Cached built shapes — avoid rebuilding GeoJSON when data is unchanged.
        private var cachedSubwayShape: MLNShapeCollectionFeature?
        private var cachedCommuterShape: MLNShapeCollectionFeature?
        private var cachedElevatedShape: MLNShapeCollectionFeature?
        private var cachedStationShape: MLNShapeCollectionFeature?

        /// Prevents transit layers from rendering before basemap tiles are
        /// visible — avoids the "floating lines on blank background" flash
        /// that occurs because local GeoJSON renders instantly while remote
        /// tiles are still downloading from the CDN.
        var initialTilesRendered = false
        private var pendingLayerTimer: DispatchWorkItem?

        init(_ parent: MapLibreMapView) {
            self.parent = parent
        }

        // MARK: - Delegate: Style Loaded

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            sourcesCreated.removeAll()  // New style = all layers need recreation
            invalidateAllDirtyFlags()   // Force full rebuild

            // Strip POI clutter, recolour base-map layers, and bake in
            // the route-colour wash (if active) — all in one pass.
            MapLibreStyleConfig.customizeBaseStyle(
                style,
                isDarkMode: parent.isDarkMode,
                routeColor: parent.hasActiveRoute ? parent.routeColor : nil
            )

            // Track tint state so updateUIView doesn't repeat.
            lastRouteTintActive = parent.hasActiveRoute
            lastRouteTintColor = parent.hasActiveRoute ? parent.routeColor : nil

            setup3DBuildings(style: style, isDarkMode: parent.isDarkMode)

            if initialTilesRendered {
                // Subsequent style loads (e.g. dark ↔ light switch) —
                // basemap is already primed, add transit layers immediately.
                updateAllLayers(mapView: mapView, representable: parent)
            } else {
                // First load — defer transit layers until basemap tiles
                // render so lines don't float on a blank background.
                // Safety fallback: show layers after 0.6s even if tiles
                // haven't fully loaded (slow connection graceful degradation).
                pendingLayerTimer?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.initialTilesRendered else { return }
                    self.initialTilesRendered = true
                    self.updateAllLayers(
                        mapView: mapView,
                        representable: self.parent
                    )
                }
                pendingLayerTimer = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.6, execute: work
                )
            }
        }

        // MARK: - Delegate: Map Rendered

        func mapViewDidFinishRenderingMap(
            _ mapView: MLNMapView,
            fullyRendered: Bool
        ) {
            guard fullyRendered, !initialTilesRendered else { return }
            initialTilesRendered = true
            pendingLayerTimer?.cancel()
            if styleLoaded {
                updateAllLayers(mapView: mapView, representable: parent)
            }
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
            lastRouteTintActive = false
            lastRouteTintColor = nil
        }

        // MARK: - Delegate: Camera Changed

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            syncCameraToBinding(mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            // When a code-driven camera finishes, clear the in-flight flag
            // and do one final sync so bindings reflect the final position.
            if programmaticCameraInFlight {
                programmaticCameraInFlight = false
            }
            syncCameraToBinding(mapView, force: true)
        }

        /// Syncs current MapLibre camera state back to the SwiftUI bindings.
        /// O(1) — just reads camera properties and writes to bindings.
        /// Throttled: coalesces rapid gesture frames so SwiftUI processes
        /// at most one binding update per ~16ms display frame, preventing
        /// "setting value during update" AttributeGraph crashes.
        ///
        /// For `regionDidChangeAnimated` (final position), the throttle is
        /// bypassed to guarantee bindings always reflect the settled state.
        private func syncCameraToBinding(_ mapView: MLNMapView, force: Bool = false) {
            shouldSyncCamera = false  // Prevent feedback loop

            // During continuous gestures, enforce a minimum interval between
            // binding writes. This prevents the "onChange tried to update
            // multiple times per frame" warning that occurs when two
            // DispatchWorkItems execute in the same run-loop pass.
            let now = CFAbsoluteTimeGetCurrent()
            if !force && (now - _lastCameraSyncTime) < 0.015 {  // ~16ms
                return
            }

            // During code-driven animations (fly-to-center, fit-route, etc.)
            // skip binding writes so intermediate frames don't overwrite the
            // requested destination. We still read visible state for station
            // visibility etc. but DON'T touch cameraPosition.
            let isCodeDriven = programmaticCameraInFlight

            let center = mapView.centerCoordinate
            let zoom = mapView.zoomLevel
            let distance = MapLibreCameraState.distanceFromZoom(zoom, at: center.latitude)
            let pitch = Double(mapView.camera.pitch)
            let bearing = mapView.direction

            let zoomThreshold = AppSettings.shared.stationVisibilityZoomMeters
            let shouldShow = distance < zoomThreshold

            // Cancel any pending (not yet fired) sync — only the latest wins.
            pendingCameraSync?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self._lastCameraSyncTime = CFAbsoluteTimeGetCurrent()
                self.parent.currentMapCenter = center
                self.parent.currentMapDistance = distance

                // Only update the camera binding when the user is physically
                // interacting with the map (gestures). Programmatic camera
                // animations write intermediate positions that fight the
                // target, causing "tap center 3 times" bugs.
                if !isCodeDriven {
                    let state = MapLibreCameraState(
                        center: center,
                        zoom: zoom,
                        pitch: pitch,
                        bearing: bearing
                    )
                    self.parent.cameraPosition = state.toTrackCameraPosition()
                }

                if shouldShow != self.parent.showStations {
                    self.parent.showStations = shouldShow
                }

                // Notify parent so overlay projection refreshes every gesture frame
                self.parent.onCameraMove?()
            }
            pendingCameraSync = work
            DispatchQueue.main.async(execute: work)
        }

        // MARK: - Delegate: Annotation Handling

        func mapView(
            _ mapView: MLNMapView,
            viewFor annotation: MLNAnnotation
        ) -> MLNAnnotationView? {
            return nil  // All annotations use GL layers or SwiftUI overlays
        }

        // MARK: - Unified Layer Update
        //
        // Called from updateUIView and didFinishLoadingStyle.
        // Renders all transit data as MapLibre GL style layers for
        // smooth zoom-interpolated rendering.

        func updateAllLayers(mapView: MLNMapView, representable: MapLibreMapView) {
            guard let style = mapView.style else { return }

            let darkChanged: Bool = lastDarkMode != representable.isDarkMode
            lastDarkMode = representable.isDarkMode

            // Update 3D building colors on dark mode switch
            if darkChanged {
                setup3DBuildings(style: style, isDarkMode: representable.isDarkMode)
            }

            updateSystemMapIfNeeded(
                style: style,
                representable: representable,
                darkChanged: darkChanged
            )
            updateStationDotsIfNeeded(
                mapView: mapView,
                style: style,
                representable: representable,
                darkChanged: darkChanged
            )
            updateRouteIfNeeded(
                style: style,
                representable: representable,
                darkChanged: darkChanged
            )
            updateWalkingIfNeeded(style: style, representable: representable)
            updateTransferIfNeeded(style: style, representable: representable)
        }

        // MARK: - Hash-gated layer update helpers
        // Split out of updateAllLayers to keep each expression under the type-checker limit.

        private func updateSystemMapIfNeeded(
            style: MLNStyle,
            representable: MapLibreMapView,
            darkChanged: Bool
        ) {
            let a: Int = representable.subwayPolylines.count
            let b: Int = representable.commuterRailPolylines.count &* 31
            let c: Int = representable.hasActiveRoute ? 0x1 : 0x0
            let d: Int = representable.reroutedRouteIDs.count &* 127
            let e: Int = representable.selectedMode.hashValue
            let subwayHash: Int = a ^ b ^ c ^ d ^ e
            if subwayHash != lastSubwayHash || darkChanged {
                updateSystemMapLayers(style: style, representable: representable)
                lastSubwayHash = subwayHash
            }
        }

        private func updateStationDotsIfNeeded(
            mapView: MLNMapView,
            style: MLNStyle,
            representable: MapLibreMapView,
            darkChanged: Bool
        ) {
            let stationCount: Int = representable.stations.count
            let activeFlag: Int = representable.hasActiveRoute ? 0x2 : 0x0
            // Zoom bucket intentionally excluded — station dots/pills use
            // zoom-interpolated GL expressions (circleRadius, iconScale,
            // opacity) so the GPU handles smooth transitions natively.
            // Including zoomBucket was rebuilding the full GeoJSON (thousands
            // of point features) on every small pinch gesture, causing the
            // visible stutter/pause during zoom.
            let stationHash: Int = stationCount ^ activeFlag
            if stationHash != lastStationHash || darkChanged {
                updateStationDotLayers(
                    mapView: mapView,
                    style: style,
                    representable: representable
                )
                lastStationHash = stationHash
            }
        }

        private func updateRouteIfNeeded(
            style: MLNStyle,
            representable: MapLibreMapView,
            darkChanged: Bool
        ) {
            let splitContentHash: Int = computeSplitContentHash(representable)
            let splitDirHash: Int = representable.directionalSplit
                .map { $0.ahead.count ^ $0.behind.count } ?? 0
            let routeHash: Int = representable.routePolylines.count
                ^ (representable.inactivePolylines.count &* 31)
                ^ splitDirHash
                ^ splitContentHash
                ^ representable.routeColor.hash
            if routeHash != lastRouteHash || darkChanged {
                updateRouteLayers(style: style, representable: representable)
                lastRouteHash = routeHash
            }
        }

        private func computeSplitContentHash(_ representable: MapLibreMapView) -> Int {
            guard let split = representable.directionalSplit,
                  let firstAhead = split.ahead.first?.first else { return 0 }
            let latHash: Int = Int(firstAhead.latitude * 1e4)
            let lonHash: Int = Int(firstAhead.longitude * 1e4)
            return latHash ^ lonHash
        }

        private func updateWalkingIfNeeded(style: MLNStyle, representable: MapLibreMapView) {
            let walkingHash: Int = representable.walkingRouteCoords?.count ?? 0
            if walkingHash != lastWalkingHash {
                updateWalkingRouteLayer(style: style, representable: representable)
                lastWalkingHash = walkingHash
            }
        }

        private func updateTransferIfNeeded(style: MLNStyle, representable: MapLibreMapView) {
            let connCount: Int = representable.transferConnectors.count
            let activeFlag: Int = representable.hasActiveRoute ? 0x4 : 0x0
            let transferHash: Int = connCount ^ activeFlag
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
            let mode = representable.selectedMode

            // Default base opacities depending on dimmed state (active route selected)
            let isDark = representable.isDarkMode
            var subwayOpacity: NSExpression = NSExpression(forConstantValue: dimmed ? 0.10 : 1.0)
            var subwayCasingOpacity: NSExpression =
                NSExpression(forConstantValue: dimmed ? 0.05 : (isDark ? 0.45 : 0.55))
            
            var elevatedShadowOpacity: NSExpression = NSExpression(
                forConstantValue: dimmed ? 0.02 : (isDark ? 0.20 : 0.12)
            )
            
            var commuterOpacity: NSExpression = NSExpression(forConstantValue: dimmed ? 0.08 : 0.65)
            var commuterCasingOpacity: NSExpression =
                NSExpression(forConstantValue: dimmed ? 0.03 : 0.20)

            // Override with global mode filtering if no route is actively selected
            if !dimmed {
                switch mode {
                case .subway:
                    commuterOpacity = NSExpression(forConstantValue: 0.08)
                    commuterCasingOpacity = NSExpression(forConstantValue: 0.03)
                case .lirr:
                    subwayOpacity = NSExpression(forConstantValue: 0.10)
                    subwayCasingOpacity = NSExpression(forConstantValue: 0.05)
                    elevatedShadowOpacity = NSExpression(forConstantValue: 0.02)
                    
                    commuterOpacity = NSExpression(
                        forConditional: NSPredicate(format: "isLIRR == YES"),
                        trueExpression: NSExpression(forConstantValue: 0.65),
                        falseExpression: NSExpression(forConstantValue: 0.08)
                    )
                    commuterCasingOpacity = NSExpression(
                        forConditional: NSPredicate(format: "isLIRR == YES"),
                        trueExpression: NSExpression(forConstantValue: 0.20),
                        falseExpression: NSExpression(forConstantValue: 0.03)
                    )
                case .mnr:
                    subwayOpacity = NSExpression(forConstantValue: 0.10)
                    subwayCasingOpacity = NSExpression(forConstantValue: 0.05)
                    elevatedShadowOpacity = NSExpression(forConstantValue: 0.02)
                    
                    commuterOpacity = NSExpression(
                        forConditional: NSPredicate(format: "isMNR == YES"),
                        trueExpression: NSExpression(forConstantValue: 0.65),
                        falseExpression: NSExpression(forConstantValue: 0.08)
                    )
                    commuterCasingOpacity = NSExpression(
                        forConditional: NSPredicate(format: "isMNR == YES"),
                        trueExpression: NSExpression(forConstantValue: 0.20),
                        falseExpression: NSExpression(forConstantValue: 0.03)
                    )
                case .nearby, .bus:
                    break // Keep default opacities
                }
            }

        // ── COMMUTER RAIL (below subway) ──
            let commuterFeatures = buildPolylineFeatures(representable.commuterRailPolylines)
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcCommRail,
                layerID: MapLibreStyleConfig.layerCommRailCasing,
                features: commuterFeatures,
                width: MapLibreStyleConfig.commuterCasingWidth,
                opacity: commuterCasingOpacity,
                color: .constant(
                    isDark
                        ? UIColor(red: 0.75, green: 0.72, blue: 0.88, alpha: 0.18)
                        : UIColor(red: 0.70, green: 0.68, blue: 0.78, alpha: 0.25)
                ),
                cap: "butt", join: "round",
                dashPattern: [3, 2],
                blur: MapLibreStyleConfig.commuterCasingBlur
            )
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcCommRail,
                layerID: MapLibreStyleConfig.layerCommRailFill,
                features: nil,
                width: MapLibreStyleConfig.commuterFillWidth,
                opacity: commuterOpacity,
                color: .dataDriven,
                cap: "butt", join: "round",
                dashPattern: [3, 2]
            )

            // ── SUBWAY (shared source — lightweight, 2 GL layers) ──
            //
            // All subway polylines go into a single source with trunk_index
            // sorted features.  Parallel corridor separation is handled by
            // MapLibre's lineOffset (pixel-space). The multiplier tapers
            // down at close zoom, but no longer collapses to zero; station
            // markers inherit the same camera-aware shift so shared trunks
            // stay parallel without visually separating from their stops.
            let subwayOnly = representable.subwayPolylines.filter {
                !isEffectivelyElevated($0, reroutedRouteIDs: representable.reroutedRouteIDs)
            }
            let subwayFeatures = buildPolylineFeatures(subwayOnly)
            let subwayCasingFeatures = buildCasingFeatures(
                subwayOnly,
                crossings: representable.crossings
            )

            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcSubwayCasing,
                layerID: MapLibreStyleConfig.layerSubwayCasing,
                features: subwayCasingFeatures,
                width: MapLibreStyleConfig.subwayCasingWidth,
                opacity: subwayCasingOpacity,
                color: .constant(
                    isDark
                        ? UIColor(red: 0.78, green: 0.74, blue: 0.95, alpha: 0.28)
                        : UIColor(red: 0.82, green: 0.80, blue: 0.88, alpha: 0.35)
                ),
                cap: "round", join: "round",
                applyLaneOffset: true,
                sortByTrunkIndex: true,
                blur: MapLibreStyleConfig.subwayCasingBlur
            )
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcSubway,
                layerID: MapLibreStyleConfig.layerSubwayFill,
                features: subwayFeatures,
                width: MapLibreStyleConfig.subwayFillWidth,
                opacity: subwayOpacity,
                color: .dataDriven,
                cap: "round", join: "round",
                applyLaneOffset: true,
                sortByTrunkIndex: true
            )

            // ── ELEVATED (separate casing source for crossing breaks) ──
            let elevated = representable.subwayPolylines.filter {
                isEffectivelyElevated($0, reroutedRouteIDs: representable.reroutedRouteIDs)
            }
            let elevatedFeatures = buildPolylineFeatures(elevated)
            let elevatedCasingFeatures = buildCasingFeatures(
                elevated,
                crossings: representable.crossings
            )

            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcElevated,
                layerID: MapLibreStyleConfig.layerElevatedShadow,
                features: elevatedFeatures,
                width: MapLibreStyleConfig.elevatedCasingWidth,
                opacity: elevatedShadowOpacity,
                color: .constant(UIColor.black),
                cap: "round", join: "round",
                translatePixels: CGPoint(x: 1.5, y: 3),
                blur: MapLibreStyleConfig.elevatedShadowBlur
            )
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcElevatedCasing,
                layerID: MapLibreStyleConfig.layerElevatedCasing,
                features: elevatedCasingFeatures,
                width: MapLibreStyleConfig.elevatedCasingWidth,
                opacity: subwayCasingOpacity,
                color: .constant(
                    isDark
                        ? UIColor(red: 0.78, green: 0.74, blue: 0.95, alpha: 0.32)
                        : UIColor(red: 0.82, green: 0.80, blue: 0.88, alpha: 0.35)
                ),
                cap: "round", join: "round",
                applyLaneOffset: true,
                sortByTrunkIndex: true,
                blur: MapLibreStyleConfig.elevatedCasingBlur
            )
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcElevated,
                layerID: MapLibreStyleConfig.layerElevatedFill,
                features: nil,
                width: MapLibreStyleConfig.elevatedFillWidth,
                opacity: subwayOpacity,
                color: .dataDriven,
                cap: "round", join: "round",
                applyLaneOffset: true,
                sortByTrunkIndex: true
            )
        }

        // MARK: - GL Station Dot Layers
        //
        // Premium station rendering pipeline:
        //
        // Layer stack (bottom to top):
        //   1. Single-line dots — route-colored fill with crisp white stroke
        //      (visible only from zoom 12+, stays unobtrusive)
        //   2. Transfer pills — white capsule icons with dark outline that
        //      visually span across all lines sharing a station. Rotated
        //      perpendicular to the track bearing so the pill crosses the
        //      colored lines. Width scales with colorGroupCount.
        //   3. Station labels — semibold text with thick halo for readability
        //
        // All properties zoom-interpolated for buttery-smooth transitions.
        // Thousands of stations rendered at zero CPU cost (GL batches).

        private func displayedStationCoordinate(
            for station: MapSystemViewModel.ConsolidatedStation,
            on mapView: MLNMapView
        ) -> CLLocationCoordinate2D {
            station.coordinate
        }

        private func stationScreenOffsetNormal(
            coordinate: CLLocationCoordinate2D,
            heading: Double,
            mapView: MLNMapView
        ) -> CGVector? {
            // A tiny fixed sample works up close, but at overview zoom the
            // projected screen span can collapse toward 0 px and produce an
            // unstable normal. Grow the sample until we have a reliable on-
            // screen tangent, then derive the same screen-space side MapLibre
            // uses for positive lineOffset so dots sit on the rendered lane.
            let sampleDistances: [CLLocationDistance] = [18, 30, 48, 72, 108, 162, 243, 364]
            let preferredScreenSpan: CGFloat = 8.0
            let minimumReliableSpan: CGFloat = 1.5

            var bestNormal: CGVector?
            var bestSpan: CGFloat = 0

            for sampleMeters in sampleDistances {
                let backward = Self.coordinate(
                    from: coordinate,
                    distanceMeters: sampleMeters,
                    bearingDegrees: heading + 180
                )
                let forward = Self.coordinate(
                    from: coordinate,
                    distanceMeters: sampleMeters,
                    bearingDegrees: heading
                )

                let p0 = mapView.convert(backward, toPointTo: mapView)
                let p1 = mapView.convert(forward, toPointTo: mapView)
                let dx = p1.x - p0.x
                let dy = p1.y - p0.y
                let length = sqrt(dx * dx + dy * dy)
                guard length > 0.001 else { continue }

                let normal = CGVector(dx: -dy / length, dy: dx / length)
                if length > bestSpan {
                    bestSpan = length
                    bestNormal = normal
                }
                if length >= preferredScreenSpan {
                    return normal
                }
            }

            guard bestSpan >= minimumReliableSpan else { return nil }
            return bestNormal
        }

        private static func coordinate(
            from coordinate: CLLocationCoordinate2D,
            distanceMeters: CLLocationDistance,
            bearingDegrees: Double
        ) -> CLLocationCoordinate2D {
            let bearing = bearingDegrees * .pi / 180.0
            let metersPerDegreeLat: Double = 111_132.0
            let metersPerDegreeLon: Double =
                max(cos(coordinate.latitude * .pi / 180.0) * 111_320.0, 1.0)

            let dLat = cos(bearing) * distanceMeters / metersPerDegreeLat
            let dLon = sin(bearing) * distanceMeters / metersPerDegreeLon
            return CLLocationCoordinate2D(
                latitude: coordinate.latitude + dLat,
                longitude: coordinate.longitude + dLon
            )
        }

        func updateStationDotLayers(
            mapView: MLNMapView,
            style: MLNStyle,
            representable: MapLibreMapView
        ) {
            guard !representable.hasActiveRoute else {
                // Hide system station dots when a route is selected
                if let src = style.source(
                    withIdentifier: MapLibreStyleConfig.srcStations
                ) as? MLNShapeSource {
                    src.shape = MLNShapeCollectionFeature(shapes: [])
                }
                return
            }

            let stations = representable.stations
            let isDark = representable.isDarkMode
            var singleFeatures: [MLNPointFeature] = []
            var transferFeatures: [MLNPointFeature] = []
            singleFeatures.reserveCapacity(stations.count)

            for station in stations {
                let feature = MLNPointFeature()
                feature.coordinate = displayedStationCoordinate(for: station, on: mapView)
                if station.isTransfer {
                    feature.attributes = [
                        "name": station.name,
                        "pillIcon": MapLibreStyleConfig.transferPillImageName(
                            colorGroupCount: station.colorGroupCount
                        ),
                        "bearing": station.trackBearing,
                        "isTransfer": true,
                        "colorGroupCount": station.colorGroupCount,
                    ]
                    transferFeatures.append(feature)
                } else {
                    feature.attributes = [
                        "name": station.name,
                        "color": station.routes.first.map {
                            UIColor(AppTheme.SubwayColors.color(for: $0)).toHex()
                        } ?? "#999999",
                        "isTransfer": false,
                        "colorGroupCount": 1,
                    ]
                    singleFeatures.append(feature)
                }
            }

            let allFeatures = singleFeatures + transferFeatures
            let shape = MLNShapeCollectionFeature(shapes: allFeatures)
            let sourceID = MapLibreStyleConfig.srcStations

            // Register pill images (re-registers on dark mode change too)
            MapLibreStyleConfig.registerTransferPillImages(style: style, isDark: isDark)

            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
            } else {
                let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
                sourcesCreated.insert(sourceID)

                // ── Single-line station dots — small route-colored circles ──
                let singleLayer = MLNCircleStyleLayer(
                    identifier: MapLibreStyleConfig.layerStationDotsSingle,
                    source: source
                )
                singleLayer.circleRadius = MapLibreStyleConfig.stationDotRadius
                singleLayer.circleColor = NSExpression(forKeyPath: "color")
                singleLayer.circleStrokeColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor(red: 0.85, green: 0.82, blue: 1.0, alpha: 0.50)
                        : UIColor(white: 0.25, alpha: 0.70)
                )
                singleLayer.circleStrokeWidth = MapLibreStyleConfig.stationDotStrokeWidth
                singleLayer.predicate = NSPredicate(format: "isTransfer == NO")
                singleLayer.minimumZoomLevel = 11
                // Fade in smoothly from zoom 11 — reach full opacity by zoom 12
                // for strong visibility on light basemaps.
                singleLayer.circleOpacity = NSExpression(
                    forMLNInterpolating: .zoomLevelVariable,
                    curveType: .linear,
                    parameters: nil,
                    stops: NSExpression(forConstantValue: [11: 0.0, 11.5: 0.5, 12: 0.85, 13: 1.0])
                )
                singleLayer.circleStrokeOpacity = NSExpression(
                    forMLNInterpolating: .zoomLevelVariable,
                    curveType: .linear,
                    parameters: nil,
                    stops: NSExpression(forConstantValue: [11: 0.0, 11.5: 0.5, 12: 0.85, 13: 1.0])
                )
                style.addLayer(singleLayer)

                // ── Transfer station pills — capsule icons ──
                let transferLayer = MLNSymbolStyleLayer(
                    identifier: MapLibreStyleConfig.layerStationDotsTransfer,
                    source: source
                )
                transferLayer.iconImageName = NSExpression(forKeyPath: "pillIcon")
                transferLayer.iconScale = MapLibreStyleConfig.transferPillIconSize
                transferLayer.iconRotation = NSExpression(forKeyPath: "bearing")
                transferLayer.iconRotationAlignment = NSExpression(forConstantValue: "map")
                transferLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
                transferLayer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
                transferLayer.predicate = NSPredicate(format: "isTransfer == YES")
                transferLayer.minimumZoomLevel = 11
                // Fade in smoothly from zoom 11
                transferLayer.iconOpacity = NSExpression(
                    forMLNInterpolating: .zoomLevelVariable,
                    curveType: .linear,
                    parameters: nil,
                    stops: NSExpression(forConstantValue: [11: 0.0, 11.5: 0.5, 12: 0.85, 13: 1.0])
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
                    forConstantValue: isDark
                        ? UIColor(red: 0.94, green: 0.93, blue: 1.0, alpha: 1.0)
                        : UIColor(white: 0.10, alpha: 1)
                )
                labelLayer.textHaloColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 0.92)
                        : UIColor.white.withAlphaComponent(0.97)
                )
                labelLayer.textHaloWidth = NSExpression(forConstantValue: 2.5)
                labelLayer.textHaloBlur = NSExpression(forConstantValue: 0.3)
                labelLayer.textOffset = NSExpression(
                    forConstantValue: NSValue(
                        cgVector: CGVector(dx: 0, dy: 1.3)
                    )
                )
                labelLayer.textAnchor = NSExpression(forConstantValue: "top")
                labelLayer.textFontNames = NSExpression(
                    forConstantValue: [
                        "Open Sans Semibold",
                        "Arial Unicode MS Bold",
                    ]
                )
                labelLayer.textLetterSpacing = NSExpression(forConstantValue: 0.02)
                labelLayer.minimumZoomLevel = 14
                // Fade in labels
                labelLayer.textOpacity = NSExpression(
                    forMLNInterpolating: .zoomLevelVariable,
                    curveType: .linear,
                    parameters: nil,
                    stops: NSExpression(forConstantValue: [14: 0.0, 14.5: 1.0])
                )
                labelLayer.textAllowsOverlap = NSExpression(
                    forMLNStepping: .zoomLevelVariable,
                    from: NSExpression(forConstantValue: false),
                    stops: NSExpression(forConstantValue: [16: true])
                )
                style.addLayer(labelLayer)
            }

            // Update colors for dark/light mode on existing layers
            if let single = style.layer(
                withIdentifier: MapLibreStyleConfig.layerStationDotsSingle
            ) as? MLNCircleStyleLayer {
                single.circleStrokeColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor(red: 0.85, green: 0.82, blue: 1.0, alpha: 0.50)
                        : UIColor.white
                )
            }
            if let labels = style.layer(
                withIdentifier: MapLibreStyleConfig.layerStationLabels
            ) as? MLNSymbolStyleLayer {
                labels.textColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor(red: 0.94, green: 0.93, blue: 1.0, alpha: 1.0)
                        : UIColor(white: 0.10, alpha: 1)
                )
                labels.textHaloColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 0.92)
                        : UIColor.white.withAlphaComponent(0.97)
                )
            }
        }

        // MARK: - Transfer Connectors

        private func updateTransferConnectors(style: MLNStyle, representable: MapLibreMapView) {
            let sourceID = MapLibreStyleConfig.srcTransferConn
            let layerID = MapLibreStyleConfig.layerTransferConn
            let isDark = representable.isDarkMode

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
                // Shorter transfers (vertical, same complex) get slightly thicker,
                // longer walking transfers fade to a thinner, subtler line.
                feature.attributes = [
                    "width": max(1.2, 2.2 - (d / 150.0) * 1.0),
                    "opacity": max(0.25, 0.55 - (d / 150.0) * 0.3),
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
                // Softer color that blends into the map background
                layer.lineColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor(white: 0.55, alpha: 1)
                        : UIColor(white: 0.62, alpha: 1)
                )
                layer.lineWidth = NSExpression(forKeyPath: "width")
                layer.lineOpacity = NSExpression(forKeyPath: "opacity")
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                // Dash pattern: short dashes for a refined, non-solid look
                layer.lineDashPattern = NSExpression(forConstantValue: [2.0, 1.5])
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
                casingColor: (isDark ? UIColor(white: 0.7, alpha: 1) : UIColor.white)
                    .withAlphaComponent(0.15 * (isBus ? 0.6 : 1.0)),
                fillWidth: MapLibreStyleConfig.routeFillWidth,
                casingWidth: MapLibreStyleConfig.routeCasingWidth
            )

            // ── Active direction ──
            if let split = representable.directionalSplit {
                // Bus behind segments get softer dimming so the route stays
                // readable — bus lines are thinner and less prominent than subway.
                let behindAlpha: CGFloat = isBus ? 0.35 : 0.25
                let behindCasingAlpha: CGFloat = isBus ? 0.25 : 0.30
                buildRoutePolylineLayer(
                    style: style,
                    sourceID: "route-behind-source",
                    casingLayerID: "route-behind-casing",
                    fillLayerID: "route-behind-fill",
                    coordinates: split.behind,
                    color: routeColor.withAlphaComponent(behindAlpha),
                    casingColor: (isDark ? UIColor(white: 0.7, alpha: 1) : UIColor.white)
                        .withAlphaComponent(behindCasingAlpha * (isBus ? 0.6 : 1.0)),
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
                    casingColor: (isDark ? UIColor(white: 0.7, alpha: 1) : UIColor.white)
                        .withAlphaComponent(0.8 * (isBus ? 0.6 : 1.0)),
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
                    casingColor: (isDark ? UIColor(white: 0.7, alpha: 1) : UIColor.white)
                        .withAlphaComponent(0.8 * (isBus ? 0.6 : 1.0)),
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

            let routeColor = representable.routeColor
            let isDark = representable.isDarkMode
            // Tight round dots with a soft shadow glow — visible on both
            // light and dark tiles without overpowering the route line.
            let dotColor = isDark
                ? UIColor.white
                : routeColor.withAlphaComponent(0.85)
            let glowColor = isDark
                ? routeColor.withAlphaComponent(0.30)
                : UIColor.black.withAlphaComponent(0.12)

            var mutableCoords = coords
            let feature = MLNPolylineFeature(
                coordinates: &mutableCoords,
                count: UInt(mutableCoords.count)
            )
            let shape = MLNShapeCollectionFeature(shapes: [feature])

            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
            } else {
                let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
                sourcesCreated.insert(sourceID)

                let glow = MLNLineStyleLayer(identifier: glowLayerID, source: source)
                glow.lineColor = NSExpression(forConstantValue: glowColor)
                glow.lineWidth = MapLibreStyleConfig.walkingRouteGlowWidth
                glow.lineCap = NSExpression(forConstantValue: "round")
                glow.lineJoin = NSExpression(forConstantValue: "round")
                glow.lineMiterLimit = NSExpression(forConstantValue: 1.05)
                glow.lineDashPattern = NSExpression(forConstantValue: [0, 3])
                glow.lineBlur = NSExpression(forConstantValue: 1.5)
                style.addLayer(glow)

                let dash = MLNLineStyleLayer(identifier: dashLayerID, source: source)
                dash.lineColor = NSExpression(forConstantValue: dotColor)
                dash.lineWidth = MapLibreStyleConfig.walkingRouteWidth
                dash.lineCap = NSExpression(forConstantValue: "round")
                dash.lineJoin = NSExpression(forConstantValue: "round")
                dash.lineMiterLimit = NSExpression(forConstantValue: 1.05)
                dash.lineDashPattern = NSExpression(forConstantValue: [0, 3])
                style.addLayer(dash)
            }

            // Update colors on source change (route switch, dark mode toggle)
            if let glow = style.layer(withIdentifier: glowLayerID) as? MLNLineStyleLayer {
                glow.lineColor = NSExpression(forConstantValue: glowColor)
            }
            if let dash = style.layer(withIdentifier: dashLayerID) as? MLNLineStyleLayer {
                dash.lineColor = NSExpression(forConstantValue: dotColor)
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

            // Color & opacity — rich enough to add depth, subtle enough
            // to not compete with transit overlays
            let color = isDarkMode
                ? MapLibreStyleConfig.buildingColorDark
                : MapLibreStyleConfig.buildingColorLight
            layer.fillExtrusionColor = NSExpression(forConstantValue: color)
            layer.fillExtrusionOpacity = isDarkMode
                ? MapLibreStyleConfig.buildingOpacityDark
                : MapLibreStyleConfig.buildingOpacity

            // Translation for ambient shadow direction — slightly more
            // dramatic for a premium 3D cityscape feel (sunlight from top-left)
            layer.fillExtrusionTranslation = NSExpression(
                forConstantValue: NSValue(cgVector: CGVector(dx: 0.8, dy: 1.5))
            )

            // Minimum zoom — no point rendering at city-wide zoom
            layer.minimumZoomLevel = Float(MapLibreStyleConfig.building3DMinZoom)

            // Insert below our transit layers — find the lowest transit layer
            // (commuter casing) and insert buildings right before it.
            if let commuterLayer = style.layer(
                withIdentifier: MapLibreStyleConfig.layerCommRailCasing
            ) {
                style.insertLayer(layer, below: commuterLayer)
            } else {
                // Transit layers not yet added — just add; they'll be placed above later
                style.addLayer(layer)
            }

            buildings3DAdded = true
        }

        // MARK: - Helpers: Feature Building

        /// Builds GeoJSON polyline features with per-feature `color` and `lane_offset` attributes.
        private func buildPolylineFeatures(
            _ polylines: [MapSystemViewModel.FlattenedMapPolyline]
        ) -> [MLNPolylineFeature] {
            var features: [MLNPolylineFeature] = []
            features.reserveCapacity(polylines.count)
            for polyline in polylines {
                guard polyline.coordinates.count >= 2 else { continue }
                var coords = polyline.coordinates
                let feature = MLNPolylineFeature(
                    coordinates: &coords,
                    count: UInt(coords.count)
                )
                
                let isLIRR = polyline.routeIds.contains(
                    where: { $0.uppercased().hasPrefix("LIRR") }
                )
                let isMNR = polyline.routeIds.contains(where: { $0.uppercased().hasPrefix("MNR") })
                
                feature.attributes = [
                    "color": polyline.color.toHex(),
                    "trunk_index": NSNumber(value: polyline.trunkIndex),
                    "lane_offset": NSNumber(value: Double(polyline.laneOffset)),
                    "isLIRR": NSNumber(value: isLIRR),
                    "isMNR": NSNumber(value: isMNR)
                ]
                features.append(feature)
            }
            return features
        }

        /// Builds casing features with gaps at crossing points.
        ///
        /// For each polyline, if it passes near a crossing point where a
        /// HIGHER trunk_index crosses, the casing is split into two segments
        /// with a small gap.  This creates an over/under visual effect.
        private func buildCasingFeatures(
            _ polylines: [MapSystemViewModel.FlattenedMapPolyline],
            crossings: [CrossingPoint]
        ) -> [MLNPolylineFeature] {
            guard !crossings.isEmpty else {
                return buildPolylineFeatures(polylines)
            }

            var features: [MLNPolylineFeature] = []

            for polyline in polylines {
                guard polyline.coordinates.count >= 2 else { continue }

                let isLIRR = polyline.routeIds.contains(
                    where: { $0.uppercased().hasPrefix("LIRR") }
                )
                let isMNR = polyline.routeIds.contains(where: { $0.uppercased().hasPrefix("MNR") })
                let attrs: [String: Any] = [
                    "color": polyline.color.toHex(),
                    "trunk_index": NSNumber(value: polyline.trunkIndex),
                    "lane_offset": NSNumber(value: Double(polyline.laneOffset)),
                    "isLIRR": NSNumber(value: isLIRR),
                    "isMNR": NSNumber(value: isMNR)
                ]

                // Find crossing indices where this trunk is the LOWER one
                var breakIndices: [Int] = []
                let coords = polyline.coordinates

                for crossing in crossings {
                    guard crossing.trunkIndices.count >= 2 else { continue }
                    let myTrunk = polyline.trunkIndex
                    guard crossing.trunkIndices.contains(myTrunk) else { continue }
                    let otherTrunk = crossing.trunkIndices
                        .first(where: { $0 != myTrunk }) ?? myTrunk
                    // Only break the LOWER trunk's casing
                    guard myTrunk < otherTrunk else { continue }

                    // Find nearest vertex to crossing
                    let cLat = crossing.lat
                    let cLng = crossing.lng
                    var bestDist = Double.infinity
                    var bestIdx = -1

                    for i in coords.indices {
                        let dLat = coords[i].latitude - cLat
                        let dLng = coords[i].longitude - cLng
                        let dist = dLat * dLat + dLng * dLng
                        if dist < bestDist {
                            bestDist = dist
                            bestIdx = i
                        }
                    }

                    // ~50m threshold (in degrees²: 0.00045² ≈ 2e-7)
                    if bestDist < 2.0e-7 && bestIdx > 1 && bestIdx < coords.count - 2 {
                        breakIndices.append(bestIdx)
                    }
                }

                if breakIndices.isEmpty {
                    // No breaks — emit full polyline
                    var mutableCoords = coords
                    let feature = MLNPolylineFeature(
                        coordinates: &mutableCoords,
                        count: UInt(mutableCoords.count)
                    )
                    feature.attributes = attrs
                    features.append(feature)
                } else {
                    // Split polyline at break points with small gaps
                    let sorted = breakIndices.sorted()
                    let gapSize = 2  // skip 2 vertices each side of crossing
                    var segStart = 0

                    for breakIdx in sorted {
                        let segEnd = max(segStart, breakIdx - gapSize)
                        if segEnd > segStart + 1 {
                            var segment = Array(coords[segStart...segEnd])
                            let feature = MLNPolylineFeature(
                                coordinates: &segment,
                                count: UInt(segment.count)
                            )
                            feature.attributes = attrs
                            features.append(feature)
                        }
                        segStart = min(coords.count - 1, breakIdx + gapSize)
                    }

                    // Emit trailing segment
                    if segStart < coords.count - 1 {
                        var segment = Array(coords[segStart...])
                        let feature = MLNPolylineFeature(
                            coordinates: &segment,
                            count: UInt(segment.count)
                        )
                        feature.attributes = attrs
                        features.append(feature)
                    }
                }
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
            opacity: NSExpression,
            color: LineColorMode,
            cap: String,
            join: String,
            translatePixels: CGPoint? = nil,
            dashPattern: [NSNumber]? = nil,
            applyLaneOffset: Bool = false,
            sortByTrunkIndex: Bool = false,
            blur: NSExpression? = nil
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
                layer.lineOpacity = opacity
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
                        forConstantValue: NSValue(
                            cgVector: CGVector(
                                dx: translate.x,
                                dy: translate.y
                            )
                        )
                    )
                }

                if let dash = dashPattern {
                    layer.lineDashPattern = NSExpression(forConstantValue: dash)
                }

                // Dynamic parallel offset: keep each shared corridor lane
                // roughly one fill-width apart so the colored fills stay
                // parallel and touching instead of collapsing or gapping.
                if applyLaneOffset {
                    layer.lineOffset = MapLibreStyleConfig.laneOffsetExpression
                }

                // Deterministic z-ordering within the layer: features with
                // higher trunk_index render on top.  This produces consistent
                // over/under at line crossings (e.g. L crossing the G)
                // instead of arbitrary paint order.
                if sortByTrunkIndex {
                    layer.lineSortKey = NSExpression(forKeyPath: "trunk_index")
                }

                // Soft feathered edge — makes casings feel like they float
                // above the map (Transit app signature look).  Applied only
                // to casing layers via the blur parameter.
                if let blur {
                    layer.lineBlur = blur
                }

                // Tight miter limit prevents spike artifacts at acute joins.
                // Default MapLibre miter limit is 2.0; lowering to 1.05
                // means any join sharper than ~57° automatically rounds off.
                layer.lineMiterLimit = NSExpression(forConstantValue: 1.05)

                style.addLayer(layer)
            }

            // Update dynamic properties (opacity changes when route is selected/deselected)
            if let layer = style.layer(withIdentifier: layerID) as? MLNLineStyleLayer {
                layer.lineOpacity = opacity
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
                casing.lineMiterLimit = NSExpression(forConstantValue: 1.05)
                casing.lineBlur = MapLibreStyleConfig.routeCasingBlur
                style.addLayer(casing)

                let fill = MLNLineStyleLayer(identifier: fillLayerID, source: source)
                fill.lineColor = NSExpression(forConstantValue: color)
                fill.lineWidth = fillWidth
                fill.lineCap = NSExpression(forConstantValue: "round")
                fill.lineJoin = NSExpression(forConstantValue: "round")
                fill.lineMiterLimit = NSExpression(forConstantValue: 1.05)
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
