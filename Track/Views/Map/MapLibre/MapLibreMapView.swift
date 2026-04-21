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

    private static func stationsRenderSignature(
        _ stations: [MapSystemViewModel.ConsolidatedStation]
    ) -> Int {
        stations.reduce(into: 0) { signature, station in
            signature ^= station.id.hashValue &* 16777619
            signature ^= station.complexID &* 257
            signature ^= station.routes.count &* 31
            signature ^= station.isTransfer ? 0x9e37_79b9 : 0
            signature ^= Int((Double(station.transferCorridorSpan) * 100).rounded()) &* 131
        }
    }
    
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
            && lhs.stationResnapGeneration == rhs.stationResnapGeneration
            && stationsRenderSignature(lhs.stations) == stationsRenderSignature(rhs.stations)
        let busCntEq: Bool = lhs.busVehicles.count == rhs.busVehicles.count
        let trainCntEq: Bool = lhs.trainVehicles.count == rhs.trainVehicles.count
        let routeCntEq: Bool = lhs.routePolylines.count == rhs.routePolylines.count
        let xferCntEq: Bool = lhs.transferConnectors.count == rhs.transferConnectors.count
        let bakedEq: Bool = lhs.bakedTileSet?.isValid == rhs.bakedTileSet?.isValid
        let bakedBusEq: Bool = lhs.bakedBusTileSet?.isValid == rhs.bakedBusTileSet?.isValid
        let radiusEq: Bool = lhs.showSearchRadius == rhs.showSearchRadius
            && lhs.searchRadiusNear == rhs.searchRadiusNear
            && lhs.searchRadiusFarther == rhs.searchRadiusFarther
            && lhs.searchRadiusMuch == rhs.searchRadiusMuch

        guard subwayEq, commuterEq, stationCntEq, busCntEq, trainCntEq, routeCntEq,
              xferCntEq, bakedEq, bakedBusEq, radiusEq else {
            return false
        }

        // Directional split: detect when the ahead/behind boundary moves (nearest stop
        // changes) so the map re-renders the behind-dimmed / ahead-full-color layers.
        // We compare segment counts + the split-point coordinate (last coord of the
        // behind segment) as a cheap but accurate proxy.
        let splitEq: Bool = {
            let lSplit = lhs.directionalSplit
            let rSplit = rhs.directionalSplit
            guard (lSplit == nil) == (rSplit == nil) else { return false }
            guard let l = lSplit, let r = rSplit else { return true }
            guard l.ahead.count == r.ahead.count,
                  l.behind.count == r.behind.count
            else { return false }
            // Use the last coordinate of the last "behind" segment as the
            // split-point fingerprint — this changes whenever nearestStop changes.
            if let lPt = l.behind.last?.last, let rPt = r.behind.last?.last {
                return lPt.latitude == rPt.latitude && lPt.longitude == rPt.longitude
            }
            return true
        }()
        let inactiveSplitEq: Bool = lhs.inactivePolylines.count == rhs.inactivePolylines.count
        guard splitEq, inactiveSplitEq else { return false }

        // Walking route — must be included so clearing the route on sheet dismiss
        // actually triggers updateUIView and removes the dotted line from the map.
        let walkingEq: Bool = (lhs.walkingRouteCoords?.count ?? 0)
            == (rhs.walkingRouteCoords?.count ?? 0)
        guard walkingEq else { return false }

        // Trip route overlay
        let tripEq: Bool = (lhs.tripRouteLegs?.count ?? 0) == (rhs.tripRouteLegs?.count ?? 0)
            && lhs.tripFitCamera == rhs.tripFitCamera
        guard tripEq else { return false }

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

    /// Generation counter — bumped when station coordinates are re-snapped
    /// to smoothed polylines.  Included in the station-dot hash so the
    /// GeoJSON layer rebuilds after coordinate changes.
    var stationResnapGeneration: Int = 0

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

    /// Pre-baked GeoJSON tile files for instant system map rendering.
    /// When available, MapLibre loads these files directly via its C++
    /// GeoJSON parser — no Swift `buildPolylineFeatures()` loop.
    var bakedTileSet: TransitTileBaker.BakedTileSet?

    /// Pre-baked GeoJSON tile files for the bus system map.
    /// When available in Bus mode, MapLibre loads bus route and stop
    /// GeoJSON directly for zero-lag rendering of the entire NYC bus network.
    var bakedBusTileSet: TransitTileBaker.BakedBusTileSet?

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

    /// Whether search radius rings should be drawn on the map.
    var showSearchRadius: Bool = false
    /// Near-you tier radius in meters.
    var searchRadiusNear: Double = 2414
    /// A-bit-farther tier radius in meters.
    var searchRadiusFarther: Double = 4023
    /// Much-farther tier radius in meters.
    var searchRadiusMuch: Double = 8047

    /// Callback to pass the MLNMapView reference back to the parent
    /// so SwiftUI overlays can project coordinates → screen points.
    var onMapViewReady: ((MLNMapView) -> Void)?

    /// Called on every camera frame (pan/zoom/rotate) so SwiftUI overlays
    /// can re-project coordinates. Without this, overlays only update when
    /// their data inputs change, causing markers to "stick" to the screen.
    var onCameraMove: (() -> Void)?

    /// Called when a baked bus stop dot is tapped on the map.
    /// Carries a lightweight `BusStop` built from the GeoJSON feature.
    var onBusStopTap: ((BusStop) -> Void)?

    /// Bridges real-time sheet height → contentInset.bottom (bypasses SwiftUI).
    /// Wired once in makeUIView; not included in Equatable check.
    var sheetHeightObserver: SheetHeightObserver?

    // MARK: - Trip Route Overlay (optional)

    /// When provided, renders multi-colored transit + walk polylines for a
    /// planned trip.  Used by TripRouteMapView (TripDetailSheet hero map).
    var tripRouteLegs: [TripRouteLegData]?

    /// Origin marker coordinate for trip route overlays.
    var tripOriginCoordinate: CLLocationCoordinate2D?

    /// Destination marker coordinate for trip route overlays.
    var tripDestinationCoordinate: CLLocationCoordinate2D?

    /// When true, the camera auto-fits to the trip route bounds on load.
    var tripFitCamera: Bool = false

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
        mapView.isRotateEnabled = false
        mapView.showsUserLocation = showUserLocation
        mapView.minimumZoomLevel = MapLibreStyleConfig.minZoom
        mapView.maximumZoomLevel = MapLibreStyleConfig.maxZoom

        // Render at native display refresh rate (60fps / 120fps ProMotion)
        // for buttery-smooth panning and pinch-zoom. The GPU-accelerated GL
        // pipeline handles this efficiently; SwiftUI overlays are separately
        // throttled to ~30fps via cameraChangeToken.
        mapView.preferredFramesPerSecond = .maximum

        // Attribution (required by OSM/MapTiler ToS)
        mapView.attributionButton.isHidden = true
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

        // Tap gesture recognizer for bus stop feature queries.
        // Station dots use SwiftUI overlays, but 13k bus stops would
        // be too heavy — instead we query MapLibre's rendered features.
        let tapGR = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMapTap(_:))
        )
        tapGR.numberOfTapsRequired = 1
        // Don't block built-in map gestures
        for existing in mapView.gestureRecognizers ?? [] {
            tapGR.require(toFail: existing)
        }
        mapView.addGestureRecognizer(tapGR)

        // Wire interactive sheet height → map content inset.
        // This closure fires on every drag frame (via SheetHeightObserver)
        // and sets contentInset directly in UIKit — zero SwiftUI re-renders.
        if let observer = sheetHeightObserver {
            observer.onHeightChanged = { [weak mapView] height in
                // Use animated:false to prevent MapLibre from internally
                // animating the camera center on every drag frame, which
                // causes the sheet to visually shake during interactive drags.
                mapView?.setContentInset(
                    UIEdgeInsets(top: 0, left: 0, bottom: height, right: 0),
                    animated: false,
                    completionHandler: nil
                )
            }
            // Apply current height immediately (sheet may already be visible)
            let initial = observer.currentHeight
            if initial > 0 {
                mapView.setContentInset(
                    UIEdgeInsets(top: 0, left: 0, bottom: initial, right: 0),
                    animated: false,
                    completionHandler: nil
                )
            }
        }

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
        // Skip when the user is actively gesturing or when the update was
        // triggered by our own binding write (shouldSyncCamera == false).
        // This prevents the "bounce" where a round-tripped binding value
        // triggers an animated setCenter that fights the user's gesture.
        if coordinator.shouldSyncCamera && !coordinator.userGestureInProgress {
            let state = MapLibreCameraState(from: cameraPosition)

            // Echo detection: if the binding value matches what we last
            // wrote, this updateUIView was triggered by our own async
            // binding write — not an external camera change. Skip.
            let isEcho: Bool
            if let last = coordinator.lastWrittenCamera {
                isEcho = (state == last)
            } else {
                isEcho = false
            }

            if !isEcho {
                let currentZoom: Double = mapView.zoomLevel
                let currentCenter: CLLocationCoordinate2D = mapView.centerCoordinate
                let zoomDiff: Double = abs(state.zoom - currentZoom)
                let latDiff: Double = abs(state.center.latitude - currentCenter.latitude)
                let lonDiff: Double = abs(state.center.longitude - currentCenter.longitude)
                // Wider thresholds to absorb floating-point drift from the
                // TrackCameraPosition ↔ MapLibreCameraState round-trip.
                let needsUpdate: Bool = zoomDiff > 0.5 || latDiff > 5e-4 || lonDiff > 5e-4

                if needsUpdate {
                    coordinator.pendingCameraSync?.cancel()
                    coordinator.pendingCameraSync = nil
                    coordinator.programmaticCameraInFlight = true
                    coordinator.lastWrittenCamera = nil  // Clear — this is external
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
        /// True while the user's finger(s) are actively on the map (pan/pinch/rotate).
        var userGestureInProgress = false
        /// The last camera state THIS coordinator wrote to the binding.
        /// Used to detect echoes: if updateUIView sees a value matching
        /// this, the change came from us (not an external source) — skip.
        var lastWrittenCamera: MapLibreCameraState?

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
        /// Pending camera sync work item — `fileprivate` so `updateUIView`
        /// can cancel stale syncs before applying a new programmatic camera.
        fileprivate var pendingCameraSync: DispatchWorkItem?
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
        private var lastRadiusHash: Int = -1
        private var lastBusHash: Int = -1
        private var lastTripRouteHash: Int = -1
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
            lastRadiusHash = -1
            lastTripRouteHash = -1
            lastDarkMode = nil
            lastRouteTintActive = false
            lastRouteTintColor = nil
        }

        /// Annotations added for trip route origin/destination markers.
        var tripRouteAnnotations: [MLNAnnotation] = []

        // MARK: - Delegate: Camera Changed

        func mapView(_ mapView: MLNMapView, regionWillChangeAnimated animated: Bool) {
            // Detect user-initiated gestures (the map passes animated=false
            // when the change comes from a user gesture, true for programmatic).
            if !animated {
                userGestureInProgress = true
            }
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            syncCameraToBinding(mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            userGestureInProgress = false
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
            // the work item checks programmaticCameraInFlight at execution
            // time to skip binding writes. See the DispatchWorkItem below.

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

                // Check programmaticCameraInFlight at EXECUTION time, not
                // capture time. This prevents stale work items created just
                // before a programmatic camera change from overwriting the
                // new target. Combined with the cancel in updateUIView, this
                // eliminates the "tap center twice" race condition.
                if !self.programmaticCameraInFlight {
                    let state = MapLibreCameraState(
                        center: center,
                        zoom: zoom,
                        pitch: pitch,
                        bearing: bearing
                    )
                    self.lastWrittenCamera = state
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
            guard let point = annotation as? MLNPointAnnotation,
                  let title = point.title,
                  title == "trip-origin" || title == "trip-destination"
            else {
                return nil  // All other annotations use GL layers or SwiftUI overlays
            }

            var view = mapView.dequeueReusableAnnotationView(
                withIdentifier: title
            )

            if view == nil {
                view = MLNAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: title
                )
                view?.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
                view?.isEnabled = false

                if title == "trip-origin" {
                    let outer = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
                    outer.backgroundColor = .white
                    outer.layer.cornerRadius = 12
                    outer.layer.shadowColor = UIColor.black.cgColor
                    outer.layer.shadowOpacity = 0.25
                    outer.layer.shadowOffset = CGSize(width: 0, height: 2)
                    outer.layer.shadowRadius = 4

                    let inner = UIView(frame: CGRect(x: 5, y: 5, width: 14, height: 14))
                    inner.backgroundColor = .systemBlue
                    inner.layer.cornerRadius = 7
                    outer.addSubview(inner)
                    view?.addSubview(outer)

                } else {
                    let circle = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
                    circle.backgroundColor = UIColor(AppTheme.Colors.successGreen)
                    circle.layer.cornerRadius = 12
                    circle.layer.shadowColor = UIColor(AppTheme.Colors.successGreen).cgColor
                    circle.layer.shadowOpacity = 0.4
                    circle.layer.shadowOffset = CGSize(width: 0, height: 2)
                    circle.layer.shadowRadius = 6

                    let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                    let img = UIImage(
                        systemName: "house.fill",
                        withConfiguration: config
                    )?.withTintColor(.white, renderingMode: .alwaysOriginal)
                    let iv = UIImageView(image: img)
                    iv.frame = CGRect(x: 5, y: 5, width: 14, height: 14)
                    iv.contentMode = .scaleAspectFit
                    circle.addSubview(iv)
                    view?.addSubview(circle)
                }
            }

            return view
        }

        // MARK: - Bus Stop Tap Handling

        /// Handles taps on the map to detect bus stop feature hits.
        /// Uses MapLibre's `visibleFeatures(at:)` to query the baked
        /// bus-stops-dots layer instead of SwiftUI overlays (13k stops
        /// would be too expensive as overlay views).
        @objc func handleMapTap(_ sender: UITapGestureRecognizer) {
            guard sender.state == .ended,
                  parent.selectedMode == .bus,
                  !parent.hasActiveRoute,
                  let mapView = sender.view as? MLNMapView else { return }

            let point = sender.location(in: mapView)
            // Expand tap area slightly for fat-finger tolerance
            let rect = CGRect(
                x: point.x - 22, y: point.y - 22,
                width: 44, height: 44
            )

            let features = mapView.visibleFeatures(
                in: rect,
                styleLayerIdentifiers: [MapLibreStyleConfig.layerBusStopsDots]
            )

            guard let hit = features.first,
                  let stopId = hit.attributes["stop_id"] as? String,
                  let name = hit.attributes["name"] as? String,
                  let pointFeature = hit as? MLNPointFeature else { return }

            let coord = pointFeature.coordinate
            let busStop = BusStop(
                id: stopId,
                name: name,
                lat: coord.latitude,
                lon: coord.longitude,
                direction: nil,
                routeIds: nil
            )
            parent.onBusStopTap?(busStop)
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
            updateSearchRadiusIfNeeded(
                mapView: mapView, style: style, representable: representable
            )
            updateBusMapIfNeeded(
                style: style,
                representable: representable
            )
            updateTripRouteIfNeeded(
                mapView: mapView,
                style: style,
                representable: representable
            )
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
            // Include baked tile availability — triggers re-render when
            // baked files become ready after initial cold-start launch.
            let f: Int = (representable.bakedTileSet?.isValid == true) ? 0x8000 : 0x0
            let subwayHash: Int = a ^ b ^ c ^ d ^ e ^ f
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
            let resnapGen: Int = representable.stationResnapGeneration
            let stationStyleSignature = MapLibreMapView.stationsRenderSignature(representable.stations)
            // Single-line dots do not need zoom-bucket rebuilds because
            // MapLibre applies their `line-offset` in the paint pipeline.
            // Transfer pills are point icons, so shared-corridor pills need
            // a small zoom bucket to keep their source coordinates visually
            // centred as the corridor lane spacing scales with zoom.
            let hasTransferLaneOffsets = representable.stations.contains {
                $0.isTransfer
                    && $0.laneHeading != nil
                    && abs($0.laneOffset) > 1e-6
            }
            let transferZoomBucket: Int = hasTransferLaneOffsets
                ? Int(floor(mapView.zoomLevel * 4.0))
                : 0
            let modeFlag: Int = representable.selectedMode.hashValue << 4
            let stationHash: Int = stationCount ^ activeFlag
                ^ (resnapGen << 20)
                ^ stationStyleSignature
                ^ (transferZoomBucket << 8)
                ^ modeFlag
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
            let modeFlag: Int = representable.selectedMode.hashValue << 8
            let transferHash: Int = connCount ^ activeFlag ^ modeFlag
            if transferHash != lastTransferHash {
                updateTransferConnectors(style: style, representable: representable)
                lastTransferHash = transferHash
            }
        }

        private func updateSearchRadiusIfNeeded(
            mapView: MLNMapView,
            style: MLNStyle,
            representable: MapLibreMapView
        ) {
            // Center on user location; fall back to map center.
            let center = mapView.userLocation?.coordinate ?? mapView.centerCoordinate
            // Coarse center hash (~100m granularity) so rings reposition
            // only when the user moves meaningfully, not every frame.
            let cHash = Int(center.latitude * 1000) ^ (Int(center.longitude * 1000) << 16)
            let hash = (representable.showSearchRadius ? 1 : 0)
                ^ Int(representable.searchRadiusNear) &* 31
                ^ Int(representable.searchRadiusFarther) &* 127
                ^ Int(representable.searchRadiusMuch) &* 8191
                ^ cHash
            guard hash != lastRadiusHash else { return }
            lastRadiusHash = hash

            MapLibreSearchRadiusManager.update(
                style: style,
                center: center,
                nearRadius: representable.searchRadiusNear,
                fartherRadius: representable.searchRadiusFarther,
                muchFartherRadius: representable.searchRadiusMuch,
                visible: representable.showSearchRadius
            )
        }

        private func updateBusMapIfNeeded(
            style: MLNStyle,
            representable: MapLibreMapView
        ) {
            let hasBusTiles: Int = (representable.bakedBusTileSet?.isValid == true) ? 1 : 0
            let modeHash: Int = representable.selectedMode.hashValue
            let activeRoute: Int = representable.hasActiveRoute ? 0x4 : 0x0
            let darkFlag: Int = representable.isDarkMode ? 0x8 : 0x0
            let busHash: Int = hasBusTiles ^ modeHash ^ activeRoute ^ darkFlag
            guard busHash != lastBusHash else { return }
            lastBusHash = busHash
            updateBusMapLayers(style: style, representable: representable)
        }

        // MARK: - System Map Layers (Subway + Commuter + Elevated)
        //
        // Following Transit's rendering pipeline:
        //   1. Casing layer (wider, white/dark) renders first →  border/shadow
        //   2. Fill layer (narrower, colored) renders on top → colored line
        //   3. Elevated gets an additional shadow layer underneath for depth
        //
        // All widths use `mgl_interpolate` for buttery-smooth zoom scaling.
        //
        // Fast path: When baked GeoJSON files are available and no reroute
        // alerts are active, we load the pre-serialized FeatureCollections
        // directly into MLNShapeSources via MapLibre's C++ JSON parser.
        // This skips all Swift-side feature building and is ~10x faster.

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
                case .nearby:
                    break // Show all train polylines at full opacity
                case .bus:
                    // Dim train lines so the bus network is the star.
                    // Not fully hidden — just soft enough that the bus
                    // layer reads as the primary system map.
                    subwayOpacity = NSExpression(forConstantValue: 0.18)
                    subwayCasingOpacity = NSExpression(forConstantValue: 0.08)
                    elevatedShadowOpacity = NSExpression(forConstantValue: 0.03)
                    commuterOpacity = NSExpression(forConstantValue: 0.12)
                    commuterCasingOpacity = NSExpression(forConstantValue: 0.04)
                }
            }

            // ── Decide baked vs dynamic path ──
            // Baked path: pre-serialized GeoJSON → MLNShape(data:) → C++ parser.
            // Dynamic path: Swift loops → MLNPolylineFeature → MLNShapeCollectionFeature.
            // Rerouted routes change elevated/subway classification so we must
            // fall back to dynamic building when MTA reroute alerts are active.
            let useBaked = representable.bakedTileSet?.isValid == true
                && representable.reroutedRouteIDs.isEmpty

            if useBaked, let tiles = representable.bakedTileSet {
                // ── BAKED FAST PATH ──
                // Load all 5 GeoJSON sources from disk. MapLibre's C++ JSON
                // parser handles coordinate arrays ~10x faster than building
                // MLNPolylineFeature objects one-by-one in Swift.
                loadBakedSource(style: style, sourceID: MapLibreStyleConfig.srcCommRail, url: tiles.commuterURL)
                loadBakedSource(style: style, sourceID: MapLibreStyleConfig.srcSubwayCasing, url: tiles.subwayCasingURL)
                loadBakedSource(style: style, sourceID: MapLibreStyleConfig.srcSubway, url: tiles.subwayFillURL)
                loadBakedSource(style: style, sourceID: MapLibreStyleConfig.srcElevated, url: tiles.elevatedFillURL)
                loadBakedSource(style: style, sourceID: MapLibreStyleConfig.srcElevatedCasing, url: tiles.elevatedCasingURL)
            } else {
                // ── DYNAMIC FALLBACK ──
                // Build features in Swift (reroute alerts active, or baked files not yet ready).

                // COMMUTER RAIL
                let commuterFeatures = buildPolylineFeatures(representable.commuterRailPolylines)
                if let shape = MLNShapeCollectionFeature(shapes: commuterFeatures) as MLNShape? {
                    loadOrCreateSource(style: style, sourceID: MapLibreStyleConfig.srcCommRail, shape: shape)
                }

                // SUBWAY
                let subwayOnly = representable.subwayPolylines.filter {
                    !isEffectivelyElevated($0, reroutedRouteIDs: representable.reroutedRouteIDs)
                }
                let subwayFeatures = buildPolylineFeatures(subwayOnly)
                let subwayCasingFeatures = buildCasingFeatures(
                    subwayOnly,
                    crossings: representable.crossings
                )
                if let shape = MLNShapeCollectionFeature(shapes: subwayCasingFeatures) as MLNShape? {
                    loadOrCreateSource(style: style, sourceID: MapLibreStyleConfig.srcSubwayCasing, shape: shape)
                }
                if let shape = MLNShapeCollectionFeature(shapes: subwayFeatures) as MLNShape? {
                    loadOrCreateSource(style: style, sourceID: MapLibreStyleConfig.srcSubway, shape: shape)
                }

                // ELEVATED
                let elevated = representable.subwayPolylines.filter {
                    isEffectivelyElevated($0, reroutedRouteIDs: representable.reroutedRouteIDs)
                }
                let elevatedFeatures = buildPolylineFeatures(elevated)
                let elevatedCasingFeatures = buildCasingFeatures(
                    elevated,
                    crossings: representable.crossings
                )
                if let shape = MLNShapeCollectionFeature(shapes: elevatedFeatures) as MLNShape? {
                    loadOrCreateSource(style: style, sourceID: MapLibreStyleConfig.srcElevated, shape: shape)
                }
                if let shape = MLNShapeCollectionFeature(shapes: elevatedCasingFeatures) as MLNShape? {
                    loadOrCreateSource(style: style, sourceID: MapLibreStyleConfig.srcElevatedCasing, shape: shape)
                }
            }

            // ── Layer styling (shared — same for baked & dynamic) ──
            // Sources are populated above; layers below use features: nil
            // so ensureLineLayer only creates/updates the layer styling.

        // ── COMMUTER RAIL (below subway) ──
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcCommRail,
                layerID: MapLibreStyleConfig.layerCommRailCasing,
                features: nil,
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

            // ── SUBWAY ──
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcSubwayCasing,
                layerID: MapLibreStyleConfig.layerSubwayCasing,
                features: nil,
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
                features: nil,
                width: MapLibreStyleConfig.subwayFillWidth,
                opacity: subwayOpacity,
                color: .dataDriven,
                cap: "round", join: "round",
                applyLaneOffset: true,
                sortByTrunkIndex: true
            )

            // ── ELEVATED ──
            ensureLineLayer(
                style: style,
                sourceID: MapLibreStyleConfig.srcElevated,
                layerID: MapLibreStyleConfig.layerElevatedShadow,
                features: nil,
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
                features: nil,
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

        // MARK: - Bus System Map Layers
        //
        // Renders the entire NYC bus network as pre-baked GeoJSON tiles.
        // Visible only in Bus mode — shows all ~330 bus routes and
        // ~16,000 bus stops as GL layers for zero-lag rendering.
        //
        // Layer stack:
        //   1. Bus route casing — subtle border for contrast
        //   2. Bus route fill — thin colored lines showing the bus network
        //   3. Bus stop dots — small circles at higher zoom levels

        func updateBusMapLayers(style: MLNStyle, representable: MapLibreMapView) {
            let mode = representable.selectedMode
            let isDark = representable.isDarkMode
            let hasActiveRoute = representable.hasActiveRoute

            // Bus layers only visible in Bus or Nearby mode (and no route selected)
            let busVisible = (mode == .bus) && !hasActiveRoute
            let busOpacity: Double = busVisible ? 1.0 : 0.0
            let busCasingOpacity: Double = busVisible ? (isDark ? 0.25 : 0.20) : 0.0
            let busStopOpacity: Double = busVisible ? 1.0 : 0.0

            // Load baked bus tile data if available
            if let busTiles = representable.bakedBusTileSet, busTiles.isValid {
                loadBakedSource(
                    style: style,
                    sourceID: MapLibreStyleConfig.srcBusRoutes,
                    url: busTiles.routesURL
                )
                loadBakedSource(
                    style: style,
                    sourceID: MapLibreStyleConfig.srcBusStops,
                    url: busTiles.stopsURL
                )
            } else {
                // No bus tiles available yet — ensure empty sources exist
                // so layers don't crash when referenced before baking completes.
                if style.source(withIdentifier: MapLibreStyleConfig.srcBusRoutes) == nil {
                    let emptyShape = MLNShapeCollectionFeature(shapes: [])
                    let src = MLNShapeSource(
                        identifier: MapLibreStyleConfig.srcBusRoutes,
                        shape: emptyShape,
                        options: nil
                    )
                    style.addSource(src)
                    sourcesCreated.insert(MapLibreStyleConfig.srcBusRoutes)
                }
                if style.source(withIdentifier: MapLibreStyleConfig.srcBusStops) == nil {
                    let emptyShape = MLNShapeCollectionFeature(shapes: [])
                    let src = MLNShapeSource(
                        identifier: MapLibreStyleConfig.srcBusStops,
                        shape: emptyShape,
                        options: nil
                    )
                    style.addSource(src)
                    sourcesCreated.insert(MapLibreStyleConfig.srcBusStops)
                }
            }

            // ── Bus route casing (subtle border) ──
            // Bus route color is data-driven: each GeoJSON feature has a
            // "color" property (e.g. "#0078C6") set by the service-type
            // classifier.  MapLibre parses CSS hex strings automatically.
            let busRouteColorExpr = NSExpression(forKeyPath: "color")

            if let existingCasing = style.layer(
                withIdentifier: MapLibreStyleConfig.layerBusRoutesCasing
            ) as? MLNLineStyleLayer {
                existingCasing.lineOpacity = NSExpression(forConstantValue: busCasingOpacity)
            } else if let source = style.source(
                withIdentifier: MapLibreStyleConfig.srcBusRoutes
            ) {
                let casing = MLNLineStyleLayer(
                    identifier: MapLibreStyleConfig.layerBusRoutesCasing,
                    source: source
                )
                casing.lineWidth = MapLibreStyleConfig.busRouteCasingWidth
                casing.lineOpacity = NSExpression(forConstantValue: busCasingOpacity)
                casing.lineColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor(white: 0.15, alpha: 1.0)
                        : UIColor(white: 0.92, alpha: 1.0)
                )
                casing.lineCap = NSExpression(forConstantValue: "round")
                casing.lineJoin = NSExpression(forConstantValue: "round")
                // Insert below subway layers
                if let commCasing = style.layer(
                    withIdentifier: MapLibreStyleConfig.layerCommRailCasing
                ) {
                    style.insertLayer(casing, below: commCasing)
                } else {
                    style.addLayer(casing)
                }
            }

            // ── Bus route fill (colored lines) ──
            if let existingFill = style.layer(
                withIdentifier: MapLibreStyleConfig.layerBusRoutesFill
            ) as? MLNLineStyleLayer {
                existingFill.lineOpacity = NSExpression(forConstantValue: busOpacity)
                existingFill.lineColor = busRouteColorExpr
            } else if let source = style.source(
                withIdentifier: MapLibreStyleConfig.srcBusRoutes
            ) {
                let fill = MLNLineStyleLayer(
                    identifier: MapLibreStyleConfig.layerBusRoutesFill,
                    source: source
                )
                fill.lineWidth = MapLibreStyleConfig.busRouteWidth
                fill.lineOpacity = NSExpression(forConstantValue: busOpacity)
                fill.lineColor = busRouteColorExpr
                fill.lineCap = NSExpression(forConstantValue: "round")
                fill.lineJoin = NSExpression(forConstantValue: "round")
                // Insert above casing
                if let casingLayer = style.layer(
                    withIdentifier: MapLibreStyleConfig.layerBusRoutesCasing
                ) {
                    style.insertLayer(fill, above: casingLayer)
                } else {
                    style.addLayer(fill)
                }
            }

            // ── Bus stop dots (small circles at higher zoom) ──
            if let existingDots = style.layer(
                withIdentifier: MapLibreStyleConfig.layerBusStopsDots
            ) as? MLNCircleStyleLayer {
                // Use the same zoom-interpolated fade expression as creation
                existingDots.circleOpacity = NSExpression(
                    forMLNInterpolating: .zoomLevelVariable,
                    curveType: .linear,
                    parameters: nil,
                    stops: NSExpression(forConstantValue: [
                        13: 0.0,
                        13.5: busStopOpacity * 0.5,
                        14: busStopOpacity,
                    ])
                )
            } else if let source = style.source(
                withIdentifier: MapLibreStyleConfig.srcBusStops
            ) {
                let dots = MLNCircleStyleLayer(
                    identifier: MapLibreStyleConfig.layerBusStopsDots,
                    source: source
                )
                dots.circleRadius = MapLibreStyleConfig.busStopDotRadius
                dots.circleColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor(red: 0.40, green: 0.65, blue: 1.0, alpha: 1.0)
                        : UIColor(red: 0.10, green: 0.45, blue: 0.91, alpha: 1.0)
                )
                dots.circleStrokeWidth = NSExpression(forConstantValue: 0.5)
                dots.circleStrokeColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor(white: 0.2, alpha: 0.8)
                        : UIColor.white
                )
                dots.circleOpacity = NSExpression(forConstantValue: busStopOpacity)
                dots.minimumZoomLevel = 13
                // Fade in smoothly from zoom 13
                dots.circleOpacity = NSExpression(
                    forMLNInterpolating: .zoomLevelVariable,
                    curveType: .linear,
                    parameters: nil,
                    stops: NSExpression(forConstantValue: [
                        13: 0.0,
                        13.5: busStopOpacity * 0.5,
                        14: busStopOpacity,
                    ])
                )
                // Insert above bus route fill
                if let fillLayer = style.layer(
                    withIdentifier: MapLibreStyleConfig.layerBusRoutesFill
                ) {
                    style.insertLayer(dots, above: fillLayer)
                } else {
                    style.addLayer(dots)
                }
            }
        }

        // MARK: - GL Station Dot Layers
        //
        // Premium station rendering pipeline:
        //
        // Layer stack (bottom to top):
        //   1. Single-line dots — rendered as micro line-segments with
        //      round caps + the SAME line-offset expression as trunk
        //      polylines.  Dots track the rendered lane perfectly at
        //      every zoom level — zero drift, zero jumping.
        //   2. Transfer pills — white capsule icons with dark outline that
        //      mark local shared-station footprints. Rotated perpendicular
        //      to the track bearing so the pill crosses the served lines.
        //      Width only expands when the local stop actually spans a
        //      shared parallel corridor.
        //   3. Station labels — semibold text with thick halo for readability
        //
        // All properties zoom-interpolated for buttery-smooth transitions.
        // Thousands of stations rendered at zero CPU cost (GL batches).

        /// Length (metres) of the micro line-segment used to render each
        /// single-line station dot.  Must be long enough for MapLibre's
        /// internal tile generation to preserve a non-zero-length line
        /// segment at all zoom levels (≥ zoom 11).  If the segment
        /// collapses to zero length in tile coordinates, the line
        /// direction becomes undefined, `line-offset` cannot compute a
        /// perpendicular, and the dot disappears or renders without
        /// offset.
        ///
        /// 5 m at zoom 14 ≈ 0.4 px (< 9 px lineWidth → perfect circle).
        /// 5 m at zoom 18 ≈ 6 px (20 px lineWidth → slight oval, barely
        /// noticeable under round caps that add 10 px each end).
        private static let stationDotSegmentMeters: Double = 5.0

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

        private static func metersPerPixel(
            at zoom: Double,
            latitude: Double
        ) -> Double {
            let earthCircumferenceMeters: Double = 40_075_016.686
            let latitudeScale = max(cos(latitude * .pi / 180.0), 0.01)
            return earthCircumferenceMeters * latitudeScale
                / (256.0 * pow(2.0, zoom))
        }

        static func visuallyOffsetTransferCoordinate(
            _ coordinate: CLLocationCoordinate2D,
            headingDegrees: Double?,
            laneOffset: CGFloat,
            zoom: Double
        ) -> CLLocationCoordinate2D {
            guard let headingDegrees,
                  abs(laneOffset) > 1e-6 else {
                return coordinate
            }

            let offsetPixels = Double(MapLibreStyleConfig.laneOffsetPixels(
                for: laneOffset,
                at: zoom
            ))
            guard abs(offsetPixels) > 1e-6 else { return coordinate }

            let offsetMeters = abs(offsetPixels) * metersPerPixel(
                at: zoom,
                latitude: coordinate.latitude
            )
            let perpendicularBearing = headingDegrees + (offsetPixels >= 0 ? -90.0 : 90.0)
            return Self.coordinate(
                from: coordinate,
                distanceMeters: offsetMeters,
                bearingDegrees: perpendicularBearing
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
            let zoom = mapView.zoomLevel
            // Single-line dots: micro line-segments with round caps.
            // The `lane_offset` property drives `line-offset` so each dot
            // tracks its trunk polyline perfectly at every zoom level.
            var dotSegmentFeatures: [MLNPolylineFeature] = []
            // Transfer pills + label anchor points: standard point features.
            var transferFeatures: [MLNPointFeature] = []
            // Label points for ALL stations (separate so the symbol layer
            // can place text at the geographic centroid regardless of
            // the dot's visual line-offset).
            var labelFeatures: [MLNPointFeature] = []
            dotSegmentFeatures.reserveCapacity(stations.count)
            labelFeatures.reserveCapacity(stations.count)

            let halfSeg = Self.stationDotSegmentMeters / 2.0

            for station in stations {
                let coord = station.coordinate
                let transferCoord: CLLocationCoordinate2D = station.isTransfer
                    ? Self.visuallyOffsetTransferCoordinate(
                        coord,
                        headingDegrees: station.laneHeading,
                        laneOffset: station.laneOffset,
                        zoom: zoom
                    )
                    : coord

                // Label point for every station (both single + transfer).
                let labelPt = MLNPointFeature()
                labelPt.coordinate = station.isTransfer ? transferCoord : coord
                labelPt.attributes = ["name": station.name]
                labelFeatures.append(labelPt)

                if station.isTransfer {
                    let feature = MLNPointFeature()
                    feature.coordinate = transferCoord
                    feature.attributes = [
                        "name": station.name,
                        "pillIcon": MapLibreStyleConfig.transferPillImageName(
                            colorGroupCount: station.colorGroupCount,
                            corridorSpan: station.transferCorridorSpan,
                            zoom: zoom
                        ),
                        "bearing": station.trackBearing,
                        "isTransfer": true,
                        "colorGroupCount": station.colorGroupCount,
                    ]
                    transferFeatures.append(feature)
                } else {
                    // Build a micro line-segment along the polyline heading.
                    // `line-offset` will push it perpendicular — the same
                    // expression used for trunk polylines — so the dot
                    // sits on the rendered lane at every zoom level.
                    let heading = station.laneHeading ?? station.trackBearing
                    let p0 = Self.coordinate(
                        from: coord,
                        distanceMeters: halfSeg,
                        bearingDegrees: heading
                    )
                    let p1 = Self.coordinate(
                        from: coord,
                        distanceMeters: halfSeg,
                        bearingDegrees: heading + 180.0
                    )
                    var coords = [p0, p1]
                    let seg = MLNPolylineFeature(
                        coordinates: &coords,
                        count: UInt(coords.count)
                    )
                    seg.attributes = [
                        "color": station.routes.first.map {
                            UIColor(AppTheme.SubwayColors.color(for: $0)).toHex()
                        } ?? "#999999",
                        "lane_offset": Double(station.laneOffset),
                        "isTransfer": false,
                    ]
                    dotSegmentFeatures.append(seg)
                }
            }

            let allFeatures: [MLNShape] =
                dotSegmentFeatures as [MLNShape]
                + transferFeatures as [MLNShape]
                + labelFeatures as [MLNShape]
            let shape = MLNShapeCollectionFeature(shapes: allFeatures)
            let sourceID = MapLibreStyleConfig.srcStations

            // Register pill images (re-registers on dark mode change too)
            MapLibreStyleConfig.registerTransferPillImages(style: style, isDark: isDark)

            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
            } else {
                // Zero simplification tolerance — station dot micro-segments
                // are short (5 m) and must survive MapLibre's internal tile
                // generation without being collapsed to zero-length lines.
                let source = MLNShapeSource(
                    identifier: sourceID,
                    shape: shape,
                    options: [.simplificationTolerance: 0.0]
                )
                style.addSource(source)
                sourcesCreated.insert(sourceID)

                // ── Remove legacy circle layer if present (migration) ──
                if style.layer(
                    withIdentifier: MapLibreStyleConfig.layerStationDotsSingle
                ) != nil {
                    style.removeLayer(
                        style.layer(
                            withIdentifier: MapLibreStyleConfig.layerStationDotsSingle
                        )!
                    )
                }

                // ── Station dot casing — subtle border ring ──
                // Rendered as a wider line beneath the fill to create
                // a stroke effect via the casing-over-fill pattern.
                let casingLayer = MLNLineStyleLayer(
                    identifier: MapLibreStyleConfig.layerStationDotCasing,
                    source: source
                )
                casingLayer.lineWidth = MapLibreStyleConfig.stationDotCasingLineWidth
                casingLayer.lineColor = NSExpression(
                    forConstantValue: isDark
                        ? UIColor(red: 0.85, green: 0.82, blue: 1.0, alpha: 0.50)
                        : UIColor(white: 0.25, alpha: 0.70)
                )
                casingLayer.lineCap = NSExpression(forConstantValue: "round")
                casingLayer.lineOffset = MapLibreStyleConfig.laneOffsetExpression
                casingLayer.predicate = NSPredicate(format: "isTransfer == NO")
                casingLayer.minimumZoomLevel = 11
                casingLayer.lineOpacity = NSExpression(
                    forMLNInterpolating: .zoomLevelVariable,
                    curveType: .linear,
                    parameters: nil,
                    stops: NSExpression(forConstantValue: [
                        11: 0.0, 11.5: 0.5, 12: 0.85, 13: 1.0,
                    ])
                )
                style.addLayer(casingLayer)

                // ── Station dot fill — route-colored circle ──
                let fillLayer = MLNLineStyleLayer(
                    identifier: MapLibreStyleConfig.layerStationDotFill,
                    source: source
                )
                fillLayer.lineWidth = MapLibreStyleConfig.stationDotLineWidth
                fillLayer.lineColor = NSExpression(forKeyPath: "color")
                fillLayer.lineCap = NSExpression(forConstantValue: "round")
                fillLayer.lineOffset = MapLibreStyleConfig.laneOffsetExpression
                fillLayer.predicate = NSPredicate(format: "isTransfer == NO")
                fillLayer.minimumZoomLevel = 11
                // Fade in smoothly from zoom 11 — reach full opacity by
                // zoom 12 for strong visibility on light basemaps.
                fillLayer.lineOpacity = NSExpression(
                    forMLNInterpolating: .zoomLevelVariable,
                    curveType: .linear,
                    parameters: nil,
                    stops: NSExpression(forConstantValue: [
                        11: 0.0, 11.5: 0.5, 12: 0.85, 13: 1.0,
                    ])
                )
                style.addLayer(fillLayer)

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
                    stops: NSExpression(forConstantValue: [
                        11: 0.0, 11.5: 0.5, 12: 0.85, 13: 1.0,
                    ])
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
            if let casing = style.layer(
                withIdentifier: MapLibreStyleConfig.layerStationDotCasing
            ) as? MLNLineStyleLayer {
                casing.lineColor = NSExpression(
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

            // ── Mode-based station dot opacity ──
            // In bus mode, dim train station dots so the bus network is the star.
            // In subway/nearby, keep station dots fully visible.
            // In LIRR/MNR, dim station dots slightly (commuter focus).
            let mode = representable.selectedMode
            let stationDimFactor: Double = {
                switch mode {
                case .bus: return 0.15
                case .lirr, .mnr: return 0.5
                case .subway, .nearby: return 1.0
                }
            }()

            // Scale the existing zoom-interpolated opacity by the dim factor
            let dotFadeStops: [Double: Double] = [
                11: 0.0, 11.5: 0.5 * stationDimFactor,
                12: 0.85 * stationDimFactor, 13: 1.0 * stationDimFactor,
            ]
            let dotFadeExpr = NSExpression(
                forMLNInterpolating: .zoomLevelVariable,
                curveType: .linear,
                parameters: nil,
                stops: NSExpression(forConstantValue: dotFadeStops)
            )

            if let dotCasing = style.layer(
                withIdentifier: MapLibreStyleConfig.layerStationDotCasing
            ) as? MLNLineStyleLayer {
                dotCasing.lineOpacity = dotFadeExpr
            }
            if let dotFill = style.layer(
                withIdentifier: MapLibreStyleConfig.layerStationDotFill
            ) as? MLNLineStyleLayer {
                dotFill.lineOpacity = dotFadeExpr
            }
            if let transfer = style.layer(
                withIdentifier: MapLibreStyleConfig.layerStationDotsTransfer
            ) as? MLNSymbolStyleLayer {
                transfer.iconOpacity = dotFadeExpr
            }
            if let labels = style.layer(
                withIdentifier: MapLibreStyleConfig.layerStationLabels
            ) as? MLNSymbolStyleLayer {
                let labelFadeStops: [Double: Double] = [
                    14: 0.0, 14.5: 1.0 * stationDimFactor,
                ]
                labels.textOpacity = NSExpression(
                    forMLNInterpolating: .zoomLevelVariable,
                    curveType: .linear,
                    parameters: nil,
                    stops: NSExpression(forConstantValue: labelFadeStops)
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

            // In bus mode, dim transfer connectors so the bus network dominates.
            let transferDim: Double = representable.selectedMode == .bus ? 0.15 : 1.0

            var features: [MLNPolylineFeature] = []
            for connector in representable.transferConnectors {
                guard connector.coordinates.count >= 2 else { continue }
                var coords = connector.coordinates
                let feature = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                let d = connector.distanceMeters
                // Shorter transfers (vertical, same complex) get slightly thicker,
                // longer walking transfers fade to a thinner, subtler line.
                let baseOpacity = max(0.25, 0.55 - (d / 150.0) * 0.3)
                feature.attributes = [
                    "width": max(1.2, 2.2 - (d / 150.0) * 1.0),
                    "opacity": baseOpacity * transferDim,
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

        // MARK: - Trip Route Overlay (planned trip polylines)

        /// Hash-gated update — only rebuild trip route layers when the leg
        /// data changes.  Called from `updateAllLayers`.
        private func updateTripRouteIfNeeded(
            mapView: MLNMapView,
            style: MLNStyle,
            representable: MapLibreMapView
        ) {
            let legCount = representable.tripRouteLegs?.count ?? 0
            let tripHash = legCount ^ (representable.tripFitCamera ? 0x100 : 0)
            guard tripHash != lastTripRouteHash else { return }
            lastTripRouteHash = tripHash
            updateTripRouteLayers(
                mapView: mapView,
                style: style,
                representable: representable
            )
        }

        private static let tripTransitSourceID = "trip-transit-src"
        private static let tripTransitCasingID = "trip-transit-casing"
        private static let tripTransitFillID   = "trip-transit-fill"
        private static let tripFullRouteSourceID = "trip-full-route-src"
        private static let tripFullRouteCasingID = "trip-full-route-casing"
        private static let tripFullRouteFillID   = "trip-full-route-fill"
        private static let tripWalkSourceID    = "trip-walk-src"
        private static let tripWalkLineID      = "trip-walk-line"
        private static let tripStopSourceID    = "trip-stop-src"
        private static let tripStopCasingID    = "trip-stop-casing"
        private static let tripStopFillID      = "trip-stop-fill"

        func updateTripRouteLayers(
            mapView: MLNMapView,
            style: MLNStyle,
            representable: MapLibreMapView
        ) {
            guard let legs = representable.tripRouteLegs, !legs.isEmpty else {
                clearSource(style: style, sourceID: Self.tripTransitSourceID)
                clearSource(style: style, sourceID: Self.tripFullRouteSourceID)
                clearSource(style: style, sourceID: Self.tripWalkSourceID)
                clearSource(style: style, sourceID: Self.tripStopSourceID)
                // Remove trip markers
                if !tripRouteAnnotations.isEmpty {
                    mapView.removeAnnotations(tripRouteAnnotations)
                    tripRouteAnnotations.removeAll()
                }
                return
            }

            // Full-route context lines are disabled — only the clipped
            // user segment is drawn, so always clear this source.
            clearSource(style: style, sourceID: Self.tripFullRouteSourceID)

            let isDark = representable.isDarkMode

            // ── Active transit segments (matching main-page route style) ──
            let transitSegs = legs.filter { !$0.isWalk }
            if !transitSegs.isEmpty {
                var features: [MLNPolylineFeature] = []
                for seg in transitSegs {
                    guard seg.coordinates.count >= 2 else { continue }
                    var mutable = seg.coordinates
                    let feature = MLNPolylineFeature(
                        coordinates: &mutable,
                        count: UInt(mutable.count)
                    )
                    feature.attributes = ["color": tripHexString(from: seg.color)]
                    features.append(feature)
                }

                let shape = MLNShapeCollectionFeature(shapes: features)

                if let existing = style.source(withIdentifier: Self.tripTransitSourceID) as? MLNShapeSource {
                    existing.shape = shape
                } else {
                    let source = MLNShapeSource(
                        identifier: Self.tripTransitSourceID,
                        shape: shape,
                        options: nil
                    )
                    style.addSource(source)
                    sourcesCreated.insert(Self.tripTransitSourceID)

                    // Casing layer — same width + blur as main page routes
                    let casing = MLNLineStyleLayer(
                        identifier: Self.tripTransitCasingID,
                        source: source
                    )
                    let casingUIColor = isDark
                        ? UIColor(white: 0.7, alpha: 0.8)
                        : UIColor.white.withAlphaComponent(0.8)
                    casing.lineColor = NSExpression(forConstantValue: casingUIColor)
                    casing.lineWidth = MapLibreStyleConfig.routeCasingWidth
                    casing.lineCap = NSExpression(forConstantValue: "round")
                    casing.lineJoin = NSExpression(forConstantValue: "round")
                    casing.lineBlur = MapLibreStyleConfig.routeCasingBlur
                    style.addLayer(casing)

                    // Fill layer — same width as main page routes
                    let fill = MLNLineStyleLayer(
                        identifier: Self.tripTransitFillID,
                        source: source
                    )
                    fill.lineColor = NSExpression(forKeyPath: "color")
                    fill.lineWidth = MapLibreStyleConfig.routeFillWidth
                    fill.lineCap = NSExpression(forConstantValue: "round")
                    fill.lineJoin = NSExpression(forConstantValue: "round")
                    fill.lineMiterLimit = NSExpression(forConstantValue: 1.05)
                    style.addLayer(fill)
                }
            } else {
                clearSource(style: style, sourceID: Self.tripTransitSourceID)
            }

            // ── Stop dots on transit segments (same style as main-page station dots) ──
            let allStopFeatures: [MLNPointFeature] = transitSegs.flatMap { seg -> [MLNPointFeature] in
                guard !seg.stopCoordinates.isEmpty else { return [] }
                let hex = tripHexString(from: seg.color)
                return seg.stopCoordinates.map { coord in
                    let feature = MLNPointFeature()
                    feature.coordinate = coord
                    feature.attributes = ["color": hex]
                    return feature
                }
            }

            if !allStopFeatures.isEmpty {
                let stopShape = MLNShapeCollectionFeature(shapes: allStopFeatures)

                let casingColor = isDark
                    ? UIColor(white: 0.12, alpha: 1.0)
                    : UIColor.white

                if let existing = style.source(withIdentifier: Self.tripStopSourceID) as? MLNShapeSource {
                    existing.shape = stopShape
                } else {
                    let source = MLNShapeSource(
                        identifier: Self.tripStopSourceID,
                        shape: stopShape,
                        options: nil
                    )
                    style.addSource(source)
                    sourcesCreated.insert(Self.tripStopSourceID)

                    // Casing circle (border ring)
                    let casing = MLNCircleStyleLayer(
                        identifier: Self.tripStopCasingID,
                        source: source
                    )
                    casing.circleRadius = MapLibreStyleConfig.stationDotRadius
                    casing.circleColor = NSExpression(forConstantValue: casingColor)
                    casing.circleStrokeWidth = NSExpression(forConstantValue: 0)
                    style.addLayer(casing)

                    // Fill circle (route-colored interior)
                    let fill = MLNCircleStyleLayer(
                        identifier: Self.tripStopFillID,
                        source: source
                    )
                    // Slightly smaller radius so the casing shows as a border
                    let innerRadiusStops: [Double: Double] = [
                        11: 1.4, 12: 2.2, 13: 2.8, 14: 3.4,
                        15: 4.2, 16: 5.5, 17: 6.8, 18: 8.0,
                    ]
                    fill.circleRadius = NSExpression(
                        forMLNInterpolating: .zoomLevelVariable,
                        curveType: .exponential,
                        parameters: NSExpression(forConstantValue: 1.4),
                        stops: NSExpression(forConstantValue: innerRadiusStops)
                    )
                    fill.circleColor = NSExpression(forKeyPath: "color")
                    fill.circleStrokeWidth = NSExpression(forConstantValue: 0)
                    style.addLayer(fill)
                }

                // Update casing color on dark-mode toggle
                if let casing = style.layer(withIdentifier: Self.tripStopCasingID) as? MLNCircleStyleLayer {
                    let casingUIColor = isDark
                        ? UIColor(white: 0.12, alpha: 1.0)
                        : UIColor.white
                    casing.circleColor = NSExpression(forConstantValue: casingUIColor)
                }
            } else {
                clearSource(style: style, sourceID: Self.tripStopSourceID)
            }

            // ── Walk polylines (same dot pattern as main-page walking route) ──
            let walkSegs = legs.filter(\.isWalk)
            if !walkSegs.isEmpty {
                var features: [MLNPolylineFeature] = []
                for seg in walkSegs {
                    guard seg.coordinates.count >= 2 else { continue }
                    var mutable = seg.coordinates
                    let feature = MLNPolylineFeature(
                        coordinates: &mutable,
                        count: UInt(mutable.count)
                    )
                    features.append(feature)
                }

                let shape = MLNShapeCollectionFeature(shapes: features)

                // Color computation matching main-page walking route
                let walkColor = isDark
                    ? UIColor.white
                    : UIColor.systemGray.withAlphaComponent(0.85)
                let glowColor = isDark
                    ? UIColor.systemGray.withAlphaComponent(0.30)
                    : UIColor.black.withAlphaComponent(0.12)

                if let existing = style.source(withIdentifier: Self.tripWalkSourceID) as? MLNShapeSource {
                    existing.shape = shape
                } else {
                    let source = MLNShapeSource(
                        identifier: Self.tripWalkSourceID,
                        shape: shape,
                        options: nil
                    )
                    style.addSource(source)
                    sourcesCreated.insert(Self.tripWalkSourceID)

                    // Glow layer (wider, translucent for depth)
                    let glow = MLNLineStyleLayer(
                        identifier: Self.tripWalkLineID + "-glow",
                        source: source
                    )
                    glow.lineColor = NSExpression(forConstantValue: glowColor)
                    glow.lineWidth = MapLibreStyleConfig.walkingRouteGlowWidth
                    glow.lineCap = NSExpression(forConstantValue: "round")
                    glow.lineJoin = NSExpression(forConstantValue: "round")
                    glow.lineMiterLimit = NSExpression(forConstantValue: 1.05)
                    glow.lineDashPattern = NSExpression(forConstantValue: [0, 3])
                    glow.lineBlur = NSExpression(forConstantValue: 1.5)
                    style.addLayer(glow)

                    // Dot layer (tight round dots)
                    let dots = MLNLineStyleLayer(
                        identifier: Self.tripWalkLineID,
                        source: source
                    )
                    dots.lineColor = NSExpression(forConstantValue: walkColor)
                    dots.lineWidth = MapLibreStyleConfig.walkingRouteWidth
                    dots.lineCap = NSExpression(forConstantValue: "round")
                    dots.lineJoin = NSExpression(forConstantValue: "round")
                    dots.lineMiterLimit = NSExpression(forConstantValue: 1.05)
                    dots.lineDashPattern = NSExpression(forConstantValue: [0, 3])
                    style.addLayer(dots)
                }

                // Update colors on re-render (dark mode toggle)
                if let glow = style.layer(withIdentifier: Self.tripWalkLineID + "-glow") as? MLNLineStyleLayer {
                    glow.lineColor = NSExpression(forConstantValue: glowColor)
                }
                if let dots = style.layer(withIdentifier: Self.tripWalkLineID) as? MLNLineStyleLayer {
                    dots.lineColor = NSExpression(forConstantValue: walkColor)
                }
            } else {
                clearSource(style: style, sourceID: Self.tripWalkSourceID)
            }

            // ── Origin / Destination annotations ──
            if !tripRouteAnnotations.isEmpty {
                mapView.removeAnnotations(tripRouteAnnotations)
                tripRouteAnnotations.removeAll()
            }

            if let origin = representable.tripOriginCoordinate {
                let pin = MLNPointAnnotation()
                pin.coordinate = origin
                pin.title = "trip-origin"
                mapView.addAnnotation(pin)
                tripRouteAnnotations.append(pin)
            }

            if let dest = representable.tripDestinationCoordinate {
                let pin = MLNPointAnnotation()
                pin.coordinate = dest
                pin.title = "trip-destination"
                mapView.addAnnotation(pin)
                tripRouteAnnotations.append(pin)
            }

            // ── Fit camera to trip bounds ──
            if representable.tripFitCamera {
                let allCoords = legs.flatMap(\.coordinates)
                guard allCoords.count >= 2 else { return }

                var minLat = allCoords[0].latitude
                var maxLat = allCoords[0].latitude
                var minLon = allCoords[0].longitude
                var maxLon = allCoords[0].longitude

                for c in allCoords {
                    minLat = min(minLat, c.latitude)
                    maxLat = max(maxLat, c.latitude)
                    minLon = min(minLon, c.longitude)
                    maxLon = max(maxLon, c.longitude)
                }

                let bounds = MLNCoordinateBounds(
                    sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
                    ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon)
                )

                let padding = UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40)
                mapView.setVisibleCoordinateBounds(
                    bounds,
                    edgePadding: padding,
                    animated: true,
                    completionHandler: nil
                )
            }
        }

        private func tripHexString(from color: UIColor) -> String {
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: nil)
            return String(
                format: "#%02X%02X%02X",
                Int(r * 255), Int(g * 255), Int(b * 255)
            )
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
                color: routeColor.withAlphaComponent(0.09),
                casingColor: (isDark ? UIColor(white: 0.7, alpha: 1) : UIColor.white)
                    .withAlphaComponent(0.09 * (isBus ? 0.55 : 0.85)),
                fillWidth: MapLibreStyleConfig.routeFillWidth,
                casingWidth: MapLibreStyleConfig.routeCasingWidth
            )

            // ── Active direction ──
            if let split = representable.directionalSplit {
                // Clear the non-split source so its old polyline doesn't ghost
                // on top of the new behind/ahead layers when switching routes.
                clearSource(style: style, sourceID: "route-active-source")
                // Bus behind segments get softer dimming so the route stays
                // readable — bus lines are thinner and less prominent than subway.
                let behindAlpha: CGFloat = isBus ? 0.18 : 0.12
                let behindCasingAlpha: CGFloat = isBus ? 0.12 : 0.14
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
                // Clear the split sources so old behind/ahead geometry doesn't
                // ghost when switching to a route with no directional split.
                clearSource(style: style, sourceID: "route-behind-source")
                clearSource(style: style, sourceID: "route-ahead-source")
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

        // MARK: - Helpers: Baked GeoJSON Source Loading

        /// Loads a pre-baked GeoJSON file into an MLNShapeSource.
        ///
        /// Uses `MLNShape(data:encoding:)` which invokes MapLibre's C++ JSON
        /// parser — roughly 10x faster than building MLNPolylineFeature arrays
        /// in Swift because it avoids Obj-C bridging and runs on the GL thread.
        @discardableResult
        private func loadBakedSource(
            style: MLNStyle,
            sourceID: String,
            url: URL
        ) -> Bool {
            guard let data = try? Data(contentsOf: url),
                  let shape = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
            else {
                print("⚠️ [BakedTiles] Failed to load \(url.lastPathComponent) for \(sourceID)")
                return false
            }
            loadOrCreateSource(style: style, sourceID: sourceID, shape: shape)
            return true
        }

        /// Creates or updates an MLNShapeSource with the given shape.
        private func loadOrCreateSource(
            style: MLNStyle,
            sourceID: String,
            shape: MLNShape
        ) {
            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
            } else {
                let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
                sourcesCreated.insert(sourceID)
            }
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
