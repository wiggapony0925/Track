// MapLibre GL-powered interactive map that draws a trip's transit leg
// polylines on top of the app's MapTiler vector tiles.  Each leg fetches
// its full route shape from the backend and clips it between the board/
// alight stops, then draws a colored line layer with casing + fill.
// Walk legs are rendered as dashed grey lines connecting consecutive
// transit segments.  Origin / destination markers use MLNPointAnnotation.
//
// Used as the interactive map in TripDetailSheet (full-screen cover).

import CoreLocation
import MapLibre
import SwiftUI

// MARK: - SwiftUI Wrapper

struct TripRouteMapView: View {
    let trip: TripPlan
    /// When true the map is fully interactive (pan / zoom / rotate).
    var isInteractive: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var legPolylines: [LegPolylineData] = []
    @State private var isLoading = true

    /// A resolved polyline segment for one trip leg.
    struct LegPolylineData: Identifiable {
        let id = UUID()
        let coordinates: [CLLocationCoordinate2D]
        let color: UIColor     // UIColor for MapLibre NSExpression
        let isWalk: Bool
    }

    var body: some View {
        TripRouteMapViewRepresentable(
            legPolylines: legPolylines,
            isDarkMode: colorScheme == .dark,
            isInteractive: isInteractive,
            originCoordinate: originCoordinate,
            destinationCoordinate: destinationCoordinate
        )
        .task { await loadAllShapes() }
    }

    // MARK: - Coordinates

    private var originCoordinate: CLLocationCoordinate2D? {
        legPolylines.first?.coordinates.first
    }

    private var destinationCoordinate: CLLocationCoordinate2D? {
        legPolylines.last?.coordinates.last
    }

    // MARK: - Shape Loading

    private func loadAllShapes() async {
        var segments: [LegPolylineData] = []

        await withTaskGroup(of: (Int, [CLLocationCoordinate2D]?, UIColor, Bool).self) { group in
            for (index, leg) in trip.legs.enumerated() {
                let color = legUIColor(for: leg)
                let isWalk = leg.mode == .walk || leg.mode == .transfer

                group.addTask {
                    if isWalk {
                        return (index, nil, color, true)
                    }
                    guard let routeId = leg.routeId, !routeId.isEmpty else {
                        return (index, nil, color, false)
                    }
                    do {
                        let shape = try await fetchShapeForLeg(leg)
                        let clipped = clipShape(
                            shape: shape,
                            boardStopId: leg.boardStopId,
                            alightStopId: leg.alightStopId
                        )
                        return (index, clipped.isEmpty ? nil : clipped, color, false)
                    } catch {
                        #if DEBUG
                        print("[TripRouteMap] Failed to fetch shape for \(routeId): \(error)")
                        #endif
                        return (index, nil, color, false)
                    }
                }
            }

            var results: [(Int, [CLLocationCoordinate2D]?, UIColor, Bool)] = []
            for await result in group {
                results.append(result)
            }
            results.sort { $0.0 < $1.0 }

            for (index, coords, color, isWalk) in results {
                if isWalk {
                    let walkCoords = resolveWalkCoords(
                        index: index,
                        results: results,
                        legs: trip.legs
                    )
                    if !walkCoords.isEmpty {
                        segments.append(LegPolylineData(
                            coordinates: walkCoords, color: color, isWalk: true
                        ))
                    }
                } else if let coords, !coords.isEmpty {
                    segments.append(LegPolylineData(
                        coordinates: coords, color: color, isWalk: false
                    ))
                }
            }
        }

        legPolylines = segments
        isLoading = false
    }

    /// Determines which API to call based on the leg's mode.
    private func fetchShapeForLeg(_ leg: TripLeg) async throws -> RouteShapeResponse {
        guard let routeId = leg.routeId else {
            throw URLError(.badURL)
        }
        switch leg.mode {
        case .subway:
            return try await TrackAPI.fetchSubwayShape(routeID: routeId)
        case .bus:
            return try await TrackAPI.fetchRouteShape(routeID: routeId)
        case .lirr:
            return try await TrackAPI.fetchLIRRShape(routeID: routeId)
        case .mnr:
            return try await TrackAPI.fetchMNRShape(routeID: routeId)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    /// Clips a full route shape to the segment between board and alight stops.
    nonisolated private func clipShape(
        shape: RouteShapeResponse,
        boardStopId: String?,
        alightStopId: String?
    ) -> [CLLocationCoordinate2D] {
        let allCoords = shape.decodedPolylines.flatMap { $0 }
        guard !allCoords.isEmpty else { return [] }

        guard let boardId = boardStopId,
              let alightId = alightStopId else {
            return allCoords
        }

        let boardStop = shape.stops.first { $0.id == boardId }
        let alightStop = shape.stops.first { $0.id == alightId }

        guard let boardCoord = boardStop.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }),
              let alightCoord = alightStop.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
        else {
            return allCoords
        }

        let boardIdx = nearestIndex(in: allCoords, to: boardCoord)
        let alightIdx = nearestIndex(in: allCoords, to: alightCoord)

        guard let bIdx = boardIdx, let aIdx = alightIdx else {
            return allCoords
        }

        let startIdx = min(bIdx, aIdx)
        let endIdx = max(bIdx, aIdx)

        guard startIdx < endIdx, endIdx < allCoords.count else {
            return allCoords
        }

        return Array(allCoords[startIdx...endIdx])
    }

    nonisolated private func nearestIndex(
        in coords: [CLLocationCoordinate2D],
        to target: CLLocationCoordinate2D
    ) -> Int? {
        guard !coords.isEmpty else { return nil }
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, c) in coords.enumerated() {
            let dlat = c.latitude - target.latitude
            let dlon = c.longitude - target.longitude
            let dist = dlat * dlat + dlon * dlon
            if dist < bestDist {
                bestDist = dist
                bestIdx = i
            }
        }
        return bestIdx
    }

    private func resolveWalkCoords(
        index: Int,
        results: [(Int, [CLLocationCoordinate2D]?, UIColor, Bool)],
        legs: [TripLeg]
    ) -> [CLLocationCoordinate2D] {
        var startCoord: CLLocationCoordinate2D?
        var endCoord: CLLocationCoordinate2D?

        for i in stride(from: index - 1, through: 0, by: -1) {
            if let coords = results.first(where: { $0.0 == i })?.1, let last = coords.last {
                startCoord = last
                break
            }
        }

        for i in (index + 1)..<results.count {
            if let coords = results.first(where: { $0.0 == i })?.1, let first = coords.first {
                endCoord = first
                break
            }
        }

        if startCoord == nil, endCoord == nil { return [] }
        if let s = startCoord, endCoord == nil { return [s] }
        if startCoord == nil, let e = endCoord { return [e] }

        return [startCoord!, endCoord!]
    }

    // MARK: - Color Resolution (UIColor for MapLibre)

    private func legUIColor(for leg: TripLeg) -> UIColor {
        if leg.mode == .walk || leg.mode == .transfer {
            return UIColor(AppTheme.Colors.textTertiary)
        }
        if let hex = leg.routeColor, !hex.isEmpty {
            return UIColor(Color(hex: hex))
        }
        if let routeId = leg.routeId {
            let stripped = stripMTAAgencyPrefix(routeId)
            return UIColor(AppTheme.SubwayColors.color(for: stripped))
        }
        return UIColor(AppTheme.Colors.accent)
    }
}

// MARK: - UIViewRepresentable (MapLibre GL)

private struct TripRouteMapViewRepresentable: UIViewRepresentable {
    let legPolylines: [TripRouteMapView.LegPolylineData]
    let isDarkMode: Bool
    let isInteractive: Bool
    let originCoordinate: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D?

    // Source / layer IDs
    private static let transitSourceID = "trip-transit-src"
    private static let transitCasingID = "trip-transit-casing"
    private static let transitFillID   = "trip-transit-fill"
    private static let walkSourceID    = "trip-walk-src"
    private static let walkLineID      = "trip-walk-line"

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = MapLibreStyleConfig.styleURL(isDarkMode: isDarkMode)
            ?? MapLibreStyleConfig.osmRasterStyleJSON()

        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.automaticallyAdjustsContentInset = false
        mapView.minimumZoomLevel = MapLibreStyleConfig.minZoom
        mapView.maximumZoomLevel = MapLibreStyleConfig.maxZoom
        mapView.preferredFramesPerSecond = .maximum

        // Interaction
        mapView.isScrollEnabled = isInteractive
        mapView.isZoomEnabled = isInteractive
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false

        // Clean chrome
        mapView.attributionButton.isHidden = true
        mapView.logoView.isHidden = true
        mapView.compassView.compassVisibility = .adaptive

        // Default center (NYC)
        mapView.setCenter(
            CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            zoomLevel: 11,
            animated: false
        )

        mapView.delegate = context.coordinator
        context.coordinator.pendingPolylines = legPolylines
        context.coordinator.pendingOrigin = originCoordinate
        context.coordinator.pendingDestination = destinationCoordinate

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        // Update polylines when data arrives
        guard let style = mapView.style else {
            // Style not loaded yet — stash for didFinishLoadingStyle
            context.coordinator.pendingPolylines = legPolylines
            context.coordinator.pendingOrigin = originCoordinate
            context.coordinator.pendingDestination = destinationCoordinate
            return
        }

        addLayers(to: style, on: mapView, coordinator: context.coordinator)
    }

    // MARK: - Layer Building

    fileprivate func addLayers(
        to style: MLNStyle,
        on mapView: MLNMapView,
        coordinator: Coordinator
    ) {
        // ── Transit polylines (casing + fill, per-segment color) ──
        let transitSegs = legPolylines.filter { !$0.isWalk }
        if !transitSegs.isEmpty {
            var features: [MLNPolylineFeature] = []
            for seg in transitSegs {
                guard seg.coordinates.count >= 2 else { continue }
                var mutable = seg.coordinates
                let feature = MLNPolylineFeature(
                    coordinates: &mutable,
                    count: UInt(mutable.count)
                )
                // Store hex color for data-driven styling
                feature.attributes = ["color": hexString(from: seg.color)]
                features.append(feature)
            }

            let shape = MLNShapeCollectionFeature(shapes: features)

            if let existing = style.source(withIdentifier: Self.transitSourceID) as? MLNShapeSource {
                existing.shape = shape
            } else {
                let source = MLNShapeSource(
                    identifier: Self.transitSourceID,
                    shape: shape,
                    options: nil
                )
                style.addSource(source)

                // Casing layer (wider, blurred for glow)
                let casing = MLNLineStyleLayer(
                    identifier: Self.transitCasingID,
                    source: source
                )
                casing.lineColor = NSExpression(forKeyPath: "color")
                casing.lineWidth = MapLibreStyleConfig.routeCasingWidth
                casing.lineOpacity = NSExpression(forConstantValue: 0.3)
                casing.lineCap = NSExpression(forConstantValue: "round")
                casing.lineJoin = NSExpression(forConstantValue: "round")
                casing.lineBlur = MapLibreStyleConfig.routeCasingBlur
                style.addLayer(casing)

                // Fill layer (core colored line)
                let fill = MLNLineStyleLayer(
                    identifier: Self.transitFillID,
                    source: source
                )
                fill.lineColor = NSExpression(forKeyPath: "color")
                fill.lineWidth = MapLibreStyleConfig.routeFillWidth
                fill.lineCap = NSExpression(forConstantValue: "round")
                fill.lineJoin = NSExpression(forConstantValue: "round")
                fill.lineMiterLimit = NSExpression(forConstantValue: 1.05)
                style.addLayer(fill)
            }
        }

        // ── Walk polylines (dashed grey) ──
        let walkSegs = legPolylines.filter(\.isWalk)
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

            if let existing = style.source(withIdentifier: Self.walkSourceID) as? MLNShapeSource {
                existing.shape = shape
            } else {
                let source = MLNShapeSource(
                    identifier: Self.walkSourceID,
                    shape: shape,
                    options: nil
                )
                style.addSource(source)

                let walkLayer = MLNLineStyleLayer(
                    identifier: Self.walkLineID,
                    source: source
                )
                walkLayer.lineColor = NSExpression(
                    forConstantValue: UIColor.systemGray
                )
                walkLayer.lineWidth = NSExpression(forConstantValue: 4)
                walkLayer.lineCap = NSExpression(forConstantValue: "round")
                walkLayer.lineJoin = NSExpression(forConstantValue: "round")
                walkLayer.lineDashPattern = NSExpression(
                    forConstantValue: [2, 3]
                )
                walkLayer.lineOpacity = NSExpression(forConstantValue: 0.6)
                style.addLayer(walkLayer)
            }
        }

        // ── Origin / Destination annotations ──
        addMarkerAnnotations(on: mapView, coordinator: coordinator)

        // ── Fit camera to show entire trip ──
        fitCamera(on: mapView)
    }

    // MARK: - Marker Annotations

    private func addMarkerAnnotations(
        on mapView: MLNMapView,
        coordinator: Coordinator
    ) {
        // Remove old markers
        if !coordinator.addedAnnotations.isEmpty {
            mapView.removeAnnotations(coordinator.addedAnnotations)
            coordinator.addedAnnotations.removeAll()
        }

        if let origin = originCoordinate {
            let pin = MLNPointAnnotation()
            pin.coordinate = origin
            pin.title = "origin"
            mapView.addAnnotation(pin)
            coordinator.addedAnnotations.append(pin)
        }

        if let dest = destinationCoordinate {
            let pin = MLNPointAnnotation()
            pin.coordinate = dest
            pin.title = "destination"
            mapView.addAnnotation(pin)
            coordinator.addedAnnotations.append(pin)
        }
    }

    // MARK: - Camera Fitting

    private func fitCamera(on mapView: MLNMapView) {
        let allCoords = legPolylines.flatMap(\.coordinates)
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

    // MARK: - Helpers

    private func hexString(from color: UIColor) -> String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        return String(
            format: "#%02X%02X%02X",
            Int(r * 255), Int(g * 255), Int(b * 255)
        )
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var pendingPolylines: [TripRouteMapView.LegPolylineData] = []
        var pendingOrigin: CLLocationCoordinate2D?
        var pendingDestination: CLLocationCoordinate2D?
        var addedAnnotations: [MLNAnnotation] = []

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // When the style finishes loading, the parent's updateUIView
            // will fire and add layers.  But if polylines were already set
            // before the style loaded, we need to add them now.
            guard !pendingPolylines.isEmpty else { return }
            let rep = TripRouteMapViewRepresentable(
                legPolylines: pendingPolylines,
                isDarkMode: false, // doesn't matter for addLayers
                isInteractive: true,
                originCoordinate: pendingOrigin,
                destinationCoordinate: pendingDestination
            )
            rep.addLayers(to: style, on: mapView, coordinator: self)
        }

        // Custom annotation views for origin / destination dots
        func mapView(
            _ mapView: MLNMapView,
            viewFor annotation: MLNAnnotation
        ) -> MLNAnnotationView? {
            guard let point = annotation as? MLNPointAnnotation else {
                return nil
            }

            let reuseID = point.title ?? "marker"
            var view = mapView.dequeueReusableAnnotationView(
                withIdentifier: reuseID
            )

            if view == nil {
                view = MLNAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: reuseID
                )
                view?.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
                view?.isEnabled = false

                if reuseID == "origin" {
                    // Blue dot with white ring
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

                } else if reuseID == "destination" {
                    // Green circle with house icon
                    let circle = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
                    circle.backgroundColor = UIColor(AppTheme.Colors.successGreen)
                    circle.layer.cornerRadius = 12
                    circle.layer.shadowColor = UIColor(AppTheme.Colors.successGreen).cgColor
                    circle.layer.shadowOpacity = 0.4
                    circle.layer.shadowOffset = CGSize(width: 0, height: 2)
                    circle.layer.shadowRadius = 6

                    let config = UIImage.SymbolConfiguration(
                        pointSize: 11, weight: .bold
                    )
                    let houseImage = UIImage(
                        systemName: "house.fill",
                        withConfiguration: config
                    )?.withTintColor(.white, renderingMode: .alwaysOriginal)
                    let imageView = UIImageView(image: houseImage)
                    imageView.frame = CGRect(x: 5, y: 5, width: 14, height: 14)
                    imageView.contentMode = .scaleAspectFit
                    circle.addSubview(imageView)
                    view?.addSubview(circle)
                }
            }

            return view
        }
    }
}

#Preview {
    TripRouteMapView(
        trip: TripPlan(
            departureTime: Date(),
            arrivalTime: Date().addingTimeInterval(3660),
            totalDurationMinutes: 61,
            legs: [
                TripLeg(
                    mode: .bus, routeId: "MTA NYCT_Q9", routeName: "Q9",
                    routeColor: "#D42781", headsign: "Springfield Blvd",
                    boardStopName: "125th St / Jamaica Ave",
                    alightStopName: "Hillside Ave",
                    departureTime: Date(),
                    arrivalTime: Date().addingTimeInterval(1200),
                    numStops: 8, durationMinutes: 20
                ),
                TripLeg(
                    mode: .walk, routeId: nil, routeName: nil,
                    routeColor: nil, headsign: nil,
                    boardStopName: "Hillside Ave",
                    alightStopName: "Parsons Blvd Station",
                    departureTime: Date().addingTimeInterval(1200),
                    arrivalTime: Date().addingTimeInterval(1380),
                    numStops: 0, durationMinutes: 3
                ),
                TripLeg(
                    mode: .subway, routeId: "E", routeName: "E Train",
                    routeColor: "#0062CF", headsign: "World Trade Center",
                    boardStopName: "Parsons Blvd",
                    alightStopName: "34 St-Penn Station",
                    departureTime: Date().addingTimeInterval(1500),
                    arrivalTime: Date().addingTimeInterval(3360),
                    numStops: 12, durationMinutes: 31
                ),
            ],
            totalWalkMeters: 400,
            numTransfers: 1
        )
    )
    .frame(height: 350)
    .preferredColorScheme(.dark)
}
