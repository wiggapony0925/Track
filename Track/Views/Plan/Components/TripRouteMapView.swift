// Interactive Apple Maps trip route preview used by Trip Detail and Go.

import CoreLocation
import MapKit
import SwiftUI

// MARK: - SwiftUI Wrapper

struct TripRouteMapView: View {
    let trip: TripPlan
    /// When true the map is fully interactive (pan / zoom / rotate).
    var isInteractive: Bool = true
    /// Exact planner endpoints, when the caller has them. These keep the
    /// first/final walk legs pinned to the selected address instead of the
    /// nearest transit stop.
    var originOverride: CLLocationCoordinate2D? = nil
    var destinationOverride: CLLocationCoordinate2D? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var legPolylines: [TripRouteLegData] = []
    @State private var isLoading = true
    @State private var selectedStop: BusStop?
    @State private var selectedStopAnchor: CGPoint?
    @State private var selectedStopDismissTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            TripRouteMapKitView(
                legs: legPolylines,
                originCoordinate: originCoordinate,
                destinationCoordinate: destinationCoordinate,
                isInteractive: isInteractive,
                isDarkMode: colorScheme == .dark,
                onStopTap: showStopBubble
            )

            GeometryReader { proxy in
                if let selectedStop {
                    TripStopNameBubble(stopName: selectedStop.name)
                        .position(bubblePosition(in: proxy.size))
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: selectedStop?.id)
        .task { await loadAllShapes() }
    }

    // MARK: - Coordinates

    private var originCoordinate: CLLocationCoordinate2D? {
        originOverride ?? trip.mapOriginCoordinate ?? legPolylines.first?.coordinates.first
    }

    private var destinationCoordinate: CLLocationCoordinate2D? {
        destinationOverride ?? trip.mapDestinationCoordinate ?? legPolylines.last?.coordinates.last
    }

    // MARK: - Shape Loading

    private func loadAllShapes() async {
        var segments: [TripRouteLegData] = []
        let originEndpoint = originOverride ?? trip.mapOriginCoordinate
        let destinationEndpoint = destinationOverride ?? trip.mapDestinationCoordinate

        await withTaskGroup(of: (Int, [CLLocationCoordinate2D]?, [[CLLocationCoordinate2D]]?, UIColor, Bool, [TripRouteStopData]).self) { group in
            for (index, leg) in trip.legs.enumerated() {
                let color = legUIColor(for: leg)
                let isWalk = leg.mode == .walk || leg.mode == .transfer

                group.addTask {
                    if isWalk {
                        return (index, nil, nil, color, true, [])
                    }
                    guard let routeId = leg.routeId, !routeId.isEmpty else {
                        return (index, nil, nil, color, false, [])
                    }
                    do {
                        let shape = try await fetchShapeForLeg(leg)
                        let routeSegment = routedSegmentCandidates(for: leg, shape: shape)
                        let clipped = clipShape(
                            polylines: routeSegment.polylines,
                            stops: routeSegment.stops,
                            boardStopId: leg.boardStopId,
                            alightStopId: leg.alightStopId,
                            boardStopName: leg.boardStopName,
                            alightStopName: leg.alightStopName,
                            maxEndpointDistanceMeters: leg.mode == .bus ? 180 : 320
                        )
                        let legStops = clipStopData(
                            stops: routeSegment.stops,
                            boardStopId: leg.boardStopId,
                            alightStopId: leg.alightStopId,
                            boardStopName: leg.boardStopName,
                            alightStopName: leg.alightStopName
                        )
                        // Draw the clipped segment as the active route and
                        // keep the matched direction shape as dimmed context.
                        return (
                            index,
                            clipped.isEmpty ? nil : clipped,
                            clipped.isEmpty ? nil : routeSegment.polylines,
                            color,
                            false,
                            legStops
                        )
                    } catch {
                        #if DEBUG
                        print("[TripRouteMap] Failed to fetch shape for \(routeId): \(error)")
                        #endif
                        return (index, nil, nil, color, false, [])
                    }
                }
            }

            var results: [(Int, [CLLocationCoordinate2D]?, [[CLLocationCoordinate2D]]?, UIColor, Bool, [TripRouteStopData])] = []
            for await result in group {
                results.append(result)
            }
            results.sort { $0.0 < $1.0 }

            for (index, coords, fullRouteCoords, color, isWalk, stopCoords) in results {
                if isWalk {
                    let fallbackWalkCoords = resolveWalkCoords(
                        index: index,
                        results: results,
                        legCount: results.count,
                        originEndpoint: originEndpoint,
                        destinationEndpoint: destinationEndpoint
                    )
                    let walkCoords = await walkingRouteCoordinates(
                        forFallbackEndpoints: fallbackWalkCoords,
                        expectedMeters: trip.legs[index].walkMeters
                    )
                    if !walkCoords.isEmpty {
                        segments.append(TripRouteLegData(
                            coordinates: walkCoords,
                            fullRouteCoordinates: nil,
                            color: color,
                            isWalk: true
                        ))
                    }
                } else if let coords, !coords.isEmpty {
                    segments.append(TripRouteLegData(
                        coordinates: coords,
                        fullRouteCoordinates: fullRouteCoords,
                        color: color,
                        isWalk: false,
                        isBusRoute: trip.legs[index].mode == .bus,
                        stops: stopCoords
                    ))
                }
            }
        }

        legPolylines = segments
        isLoading = false
    }

    private func showStopBubble(_ stop: BusStop, anchor: CGPoint? = nil) {
        selectedStopDismissTask?.cancel()
        selectedStop = stop
        selectedStopAnchor = anchor
        selectedStopDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            selectedStop = nil
            selectedStopAnchor = nil
        }
    }

    private func bubblePosition(in size: CGSize) -> CGPoint {
        let fallback = CGPoint(x: size.width / 2, y: 118)
        let anchor = selectedStopAnchor ?? fallback
        let x = min(max(anchor.x, 96), max(96, size.width - 96))
        let y = min(max(anchor.y - 46, 52), max(52, size.height - 52))
        return CGPoint(x: x, y: y)
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
        polylines: [[CLLocationCoordinate2D]],
        stops: [BusStop],
        boardStopId: String?,
        alightStopId: String?,
        boardStopName: String? = nil,
        alightStopName: String? = nil,
        maxEndpointDistanceMeters: CLLocationDistance = 350
    ) -> [CLLocationCoordinate2D] {
        TripRouteClipping.clipShape(
            polylines: polylines,
            stops: stops,
            boardStopId: boardStopId,
            alightStopId: alightStopId,
            boardStopName: boardStopName,
            alightStopName: alightStopName,
            maxEndpointDistanceMeters: maxEndpointDistanceMeters
        )
    }

    nonisolated private func routedSegmentCandidates(
        for leg: TripLeg,
        shape: RouteShapeResponse
    ) -> (polylines: [[CLLocationCoordinate2D]], stops: [BusStop]) {
        if let direction = bestDirection(for: leg, shape: shape) {
            return (
                direction.decodedPolylines.filter { $0.count >= 2 },
                direction.stops
            )
        }

        let matchedPolylines = shape.polylinesForDirection(
            index: 0,
            name: leg.headsign,
            fallbackToCombined: false
        ).filter { $0.count >= 2 }
        let matchedStops = shape.stopsForDirection(
            index: 0,
            name: leg.headsign,
            fallbackToCombined: false
        )
        guard !matchedPolylines.isEmpty, !matchedStops.isEmpty else {
            return ([], [])
        }
        return (matchedPolylines, matchedStops)
    }

    nonisolated private func bestDirection(
        for leg: TripLeg,
        shape: RouteShapeResponse
    ) -> DirectionShapeResponse? {
          guard !shape.directions.isEmpty else { return nil }

        struct Candidate {
            let direction: DirectionShapeResponse
            let forward: Bool
            let nameMatches: Bool
            let span: Int
            let endpointDistance: CLLocationDistance
        }

        let headsign = leg.headsign?.uppercased()
        let candidates: [Candidate] = shape.directions.compactMap { direction in
            guard let boardStop = TripRouteClipping.findStop(
                in: direction.stops,
                                id: leg.boardStopId,
                name: leg.boardStopName
            ),
                  let alightStop = TripRouteClipping.findStop(
                    in: direction.stops,
                                        id: leg.alightStopId,
                    name: leg.alightStopName
                  ),
                  let boardIndex = direction.stops.firstIndex(where: { $0.id == boardStop.id }),
                  let alightIndex = direction.stops.firstIndex(where: { $0.id == alightStop.id }),
                  boardIndex != alightIndex
            else { return nil }

            let directionHeadsign = direction.headsign.uppercased()
            let nameMatches = headsign.map {
                $0 == directionHeadsign || $0.contains(directionHeadsign) || directionHeadsign.contains($0)
            } ?? false

            return Candidate(
                direction: direction,
                forward: boardIndex < alightIndex,
                nameMatches: nameMatches,
                span: abs(alightIndex - boardIndex),
                endpointDistance: CLLocation(
                    latitude: boardStop.lat,
                    longitude: boardStop.lon
                ).distance(from: CLLocation(
                    latitude: alightStop.lat,
                    longitude: alightStop.lon
                ))
            )
        }

        return candidates.min { lhs, rhs in
            if lhs.forward != rhs.forward { return lhs.forward && !rhs.forward }
            if lhs.nameMatches != rhs.nameMatches { return lhs.nameMatches && !rhs.nameMatches }
            if lhs.span == rhs.span { return lhs.endpointDistance < rhs.endpointDistance }
            return lhs.span < rhs.span
        }?.direction
    }

    nonisolated private func clipStopData(
        stops: [BusStop],
        boardStopId: String?,
        alightStopId: String?,
        boardStopName: String? = nil,
        alightStopName: String? = nil
    ) -> [TripRouteStopData] {
        guard let boardStop = TripRouteClipping.findStop(
            in: stops,
            id: boardStopId,
            name: boardStopName
        ),
              let alightStop = TripRouteClipping.findStop(
                in: stops,
                id: alightStopId,
                name: alightStopName
              ),
              let boardIdx = stops.firstIndex(where: { $0.id == boardStop.id }),
              let alightIdx = stops.firstIndex(where: { $0.id == alightStop.id }),
              boardIdx != alightIdx
        else { return [] }

        let orderedStops: [BusStop]
        if boardIdx < alightIdx {
            orderedStops = Array(stops[boardIdx...alightIdx])
        } else {
            orderedStops = Array(stops[alightIdx...boardIdx].reversed())
        }

        return orderedStops.map { stop in
            TripRouteStopData(
                id: stop.id,
                name: stop.name,
                coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
            )
        }
    }

    private func resolveWalkCoords(
        index: Int,
        results: [(Int, [CLLocationCoordinate2D]?, [[CLLocationCoordinate2D]]?, UIColor, Bool, [TripRouteStopData])],
        legCount: Int,
        originEndpoint: CLLocationCoordinate2D?,
        destinationEndpoint: CLLocationCoordinate2D?
    ) -> [CLLocationCoordinate2D] {
        let inferred = TripRouteClipping.resolveWalkCoords(
            index: index,
            results: results.map { ($0.0, $0.1, $0.2, $0.3, $0.4) },
            legCount: legCount
        )

        var startCoord = nearestTransitEndpoint(
            from: results,
            before: index,
            preferAlight: true
        ) ?? inferred.first
        var endCoord = nearestTransitEndpoint(
            from: results,
            after: index,
            preferAlight: false
        ) ?? (inferred.count >= 2 ? inferred.last : nil)

        if index == 0 {
            startCoord = originEndpoint ?? startCoord
            if endCoord == nil { endCoord = inferred.first }
        }

        if index == legCount - 1 {
            if startCoord == nil { startCoord = inferred.first }
            endCoord = destinationEndpoint ?? endCoord
        }

        guard let startCoord, let endCoord else { return [] }
        let distance = CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
            .distance(from: CLLocation(latitude: endCoord.latitude, longitude: endCoord.longitude))
        guard distance >= 1 else { return [startCoord] }
        return [startCoord, endCoord]
    }

    private func nearestTransitEndpoint(
        from results: [(Int, [CLLocationCoordinate2D]?, [[CLLocationCoordinate2D]]?, UIColor, Bool, [TripRouteStopData])],
        before index: Int,
        preferAlight: Bool
    ) -> CLLocationCoordinate2D? {
        guard index > 0 else { return nil }
        for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
            guard let result = results.first(where: { $0.0 == candidateIndex }), !result.4 else {
                continue
            }
            if preferAlight, let stop = result.5.last { return stop.coordinate }
            if !preferAlight, let stop = result.5.first { return stop.coordinate }
            if preferAlight, let coordinate = result.1?.last { return coordinate }
            if !preferAlight, let coordinate = result.1?.first { return coordinate }
        }
        return nil
    }

    private func nearestTransitEndpoint(
        from results: [(Int, [CLLocationCoordinate2D]?, [[CLLocationCoordinate2D]]?, UIColor, Bool, [TripRouteStopData])],
        after index: Int,
        preferAlight: Bool
    ) -> CLLocationCoordinate2D? {
        let maxIndex = results.map(\.0).max() ?? index
        guard index < maxIndex else { return nil }
        for candidateIndex in (index + 1)...maxIndex {
            guard let result = results.first(where: { $0.0 == candidateIndex }), !result.4 else {
                continue
            }
            if preferAlight, let stop = result.5.last { return stop.coordinate }
            if !preferAlight, let stop = result.5.first { return stop.coordinate }
            if preferAlight, let coordinate = result.1?.last { return coordinate }
            if !preferAlight, let coordinate = result.1?.first { return coordinate }
        }
        return nil
    }

    private func walkingRouteCoordinates(
        forFallbackEndpoints fallback: [CLLocationCoordinate2D],
        expectedMeters: Double
    ) async -> [CLLocationCoordinate2D] {
        guard let start = fallback.first, let end = fallback.last else { return [] }
        guard fallback.count >= 2 else { return fallback }

        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        if expectedMeters > 0,
           distance > max(expectedMeters * 4, expectedMeters + 600) {
            #if DEBUG
            print("[TripRouteMap] Suppressed implausible walk leg: straight=\(Int(distance))m expected=\(Int(expectedMeters))m")
            #endif
            return []
        }
        guard distance >= 20, distance <= 5_000 else { return fallback }

        do {
            let route = try await fetchAppleWalkingRoute(from: start, to: end)
            let coordinates = Self.decode(route: route)
            return coordinates.count >= 2 ? coordinates : fallback
        } catch {
            #if DEBUG
            print("[TripRouteMap] Walking route fallback used: \(error)")
            #endif
            return fallback
        }
    }

    private func fetchAppleWalkingRoute(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) async throws -> MKRoute {
        let sourceItem = MKMapItem(
            location: CLLocation(latitude: start.latitude, longitude: start.longitude),
            address: nil
        )
        let destinationItem = MKMapItem(
            location: CLLocation(latitude: end.latitude, longitude: end.longitude),
            address: nil
        )

        let request = MKDirections.Request()
        request.source = sourceItem
        request.destination = destinationItem
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw URLError(.cannotFindHost) }
        return route
    }

    private static func decode(route: MKRoute) -> [CLLocationCoordinate2D] {
        let polyline = route.polyline
        let count = polyline.pointCount
        guard count >= 2 else { return [] }
        var coordinates = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid,
            count: count
        )
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: count))
        return coordinates.filter { CLLocationCoordinate2DIsValid($0) }
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

private struct TripRouteMapKitView: UIViewRepresentable {
    let legs: [TripRouteLegData]
    let originCoordinate: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D?
    let isInteractive: Bool
    let isDarkMode: Bool
    let onStopTap: (BusStop, CGPoint?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStopTap: onStopTap)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsTraffic = false
        mapView.pointOfInterestFilter = .excludingAll
        configure(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.onStopTap = onStopTap
        mapView.delegate = context.coordinator
        configure(mapView)

        let signature = renderSignature
        guard context.coordinator.renderSignature != signature else { return }
        context.coordinator.renderSignature = signature

        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        var visibleRect = MKMapRect.null

        for leg in legs {
            if let fullRouteCoordinates = leg.fullRouteCoordinates, !leg.isWalk {
                for coordinates in fullRouteCoordinates where coordinates.count >= 2 {
                    let overlay = TripRouteMapOverlay(
                        coordinates: coordinates,
                        color: leg.color,
                        style: .context
                    )
                    mapView.addOverlay(overlay, level: .aboveRoads)
                    visibleRect = visibleRect.union(overlay.boundingMapRect)
                }
            }

            guard leg.coordinates.count >= 2 else { continue }
            if leg.isWalk {
                let casing = TripRouteMapOverlay(
                    coordinates: leg.coordinates,
                    color: UIColor(AppTheme.Colors.textPrimary),
                    style: .walkCasing
                )
                let overlay = TripRouteMapOverlay(
                    coordinates: leg.coordinates,
                    color: UIColor(AppTheme.Colors.textPrimary),
                    style: .walk
                )
                mapView.addOverlay(casing, level: .aboveRoads)
                mapView.addOverlay(overlay, level: .aboveRoads)
                visibleRect = visibleRect.union(overlay.boundingMapRect)
            } else {
                let casing = TripRouteMapOverlay(
                    coordinates: leg.coordinates,
                    color: leg.color,
                    style: .casing(isBusRoute: leg.isBusRoute)
                )
                let active = TripRouteMapOverlay(
                    coordinates: leg.coordinates,
                    color: leg.color,
                    style: .active(isBusRoute: leg.isBusRoute)
                )
                mapView.addOverlay(casing, level: .aboveRoads)
                mapView.addOverlay(active, level: .aboveRoads)
                visibleRect = visibleRect.union(casing.boundingMapRect)
            }

            for stop in leg.stops {
                let annotation = TripStopMapAnnotation(stop: stop, color: leg.color)
                mapView.addAnnotation(annotation)
                visibleRect = visibleRect.union(rect(for: stop.coordinate))
            }
        }

        if let originCoordinate {
            mapView.addAnnotation(TripEndpointMapAnnotation(
                coordinate: originCoordinate,
                kind: .origin
            ))
            visibleRect = visibleRect.union(rect(for: originCoordinate))
        }
        if let destinationCoordinate {
            mapView.addAnnotation(TripEndpointMapAnnotation(
                coordinate: destinationCoordinate,
                kind: .destination
            ))
            visibleRect = visibleRect.union(rect(for: destinationCoordinate))
        }

        if !visibleRect.isNull {
            mapView.setVisibleMapRect(
                visibleRect,
                edgePadding: UIEdgeInsets(top: 140, left: 44, bottom: 280, right: 44),
                animated: false
            )
        }
    }

    private func configure(_ mapView: MKMapView) {
        mapView.isScrollEnabled = isInteractive
        mapView.isZoomEnabled = isInteractive
        mapView.isRotateEnabled = isInteractive
        mapView.isPitchEnabled = false
        mapView.overrideUserInterfaceStyle = isDarkMode ? .dark : .light

        if #available(iOS 16.0, *) {
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
            configuration.pointOfInterestFilter = .excludingAll
            mapView.preferredConfiguration = configuration
        } else {
            mapView.mapType = .mutedStandard
        }
    }

    private var renderSignature: Int {
        var hasher = Hasher()
        hasher.combine(isDarkMode)
        hasher.combine(isInteractive)
        combine(originCoordinate, into: &hasher)
        combine(destinationCoordinate, into: &hasher)
        for leg in legs {
            hasher.combine(leg.id)
            hasher.combine(leg.isWalk)
            hasher.combine(leg.isBusRoute)
            hasher.combine(leg.color.description)
            hasher.combine(leg.coordinates.count)
            combine(leg.coordinates.first, into: &hasher)
            combine(leg.coordinates.last, into: &hasher)
            hasher.combine(leg.fullRouteCoordinates?.count ?? 0)
            hasher.combine(leg.stops.count)
            for stop in leg.stops {
                hasher.combine(stop.id)
                hasher.combine(stop.name)
                combine(stop.coordinate, into: &hasher)
            }
        }
        return hasher.finalize()
    }

    private func combine(_ coordinate: CLLocationCoordinate2D?, into hasher: inout Hasher) {
        guard let coordinate else {
            hasher.combine(0)
            return
        }
        hasher.combine(Int((coordinate.latitude * 1_000_000).rounded()))
        hasher.combine(Int((coordinate.longitude * 1_000_000).rounded()))
    }

    private func rect(for coordinate: CLLocationCoordinate2D) -> MKMapRect {
        let point = MKMapPoint(coordinate)
        return MKMapRect(x: point.x, y: point.y, width: 1, height: 1)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var renderSignature: Int?
        var onStopTap: (BusStop, CGPoint?) -> Void

        init(onStopTap: @escaping (BusStop, CGPoint?) -> Void) {
            self.onStopTap = onStopTap
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let routeOverlay = overlay as? TripRouteMapOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: routeOverlay.polyline)
            renderer.lineJoin = .round
            renderer.lineCap = .round

            switch routeOverlay.style {
            case .context:
                renderer.strokeColor = routeOverlay.color.withAlphaComponent(0.14)
                renderer.lineWidth = 2.2
            case .walkCasing:
                renderer.strokeColor = UIColor.systemBackground.withAlphaComponent(0.9)
                renderer.lineWidth = 6
                renderer.lineDashPattern = [0, 11]
            case .walk:
                renderer.strokeColor = routeOverlay.color.withAlphaComponent(0.72)
                renderer.lineWidth = 3.2
                renderer.lineDashPattern = [0, 11]
            case .casing(let isBusRoute):
                renderer.strokeColor = UIColor.systemBackground.withAlphaComponent(0.86)
                renderer.lineWidth = isBusRoute ? 7 : 8
            case .active(let isBusRoute):
                renderer.strokeColor = routeOverlay.color.withAlphaComponent(0.94)
                renderer.lineWidth = isBusRoute ? 4.2 : 5
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let stopAnnotation = annotation as? TripStopMapAnnotation {
                let identifier = "TripStopDot"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.canShowCallout = false
                view.displayPriority = .defaultHigh
                view.collisionMode = .circle
                view.image = Self.stopDotImage(color: stopAnnotation.color)
                return view
            }

            if let endpoint = annotation as? TripEndpointMapAnnotation {
                let identifier = "TripEndpointMarker"
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: identifier
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: identifier
                )
                view.annotation = annotation
                view.markerTintColor = endpoint.kind == .origin
                    ? UIColor(AppTheme.Colors.accent)
                    : UIColor.systemGreen
                view.glyphImage = UIImage(systemName: endpoint.kind.systemImage)
                view.canShowCallout = false
                view.displayPriority = .required
                return view
            }

            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? TripStopMapAnnotation else { return }
            let anchor = CGPoint(x: view.center.x, y: view.center.y - max(0, view.bounds.height / 2))
            onStopTap(annotation.busStop, anchor)
            mapView.deselectAnnotation(annotation, animated: true)
        }

        private static func stopDotImage(color: UIColor) -> UIImage {
            let size = CGSize(width: 24, height: 24)
            return UIGraphicsImageRenderer(size: size).image { context in
                UIColor.systemBackground.withAlphaComponent(0.95).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))

                color.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 6, y: 6, width: 12, height: 12))

                UIColor.black.withAlphaComponent(0.18).setStroke()
                context.cgContext.setLineWidth(1)
                context.cgContext.strokeEllipse(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17))
            }
        }
    }
}

private enum TripRouteMapOverlayStyle {
    case context
    case walkCasing
    case casing(isBusRoute: Bool)
    case active(isBusRoute: Bool)
    case walk
}

private final class TripRouteMapOverlay: NSObject, MKOverlay {
    let polyline: MKPolyline
    let color: UIColor
    let style: TripRouteMapOverlayStyle

    var coordinate: CLLocationCoordinate2D { polyline.coordinate }
    var boundingMapRect: MKMapRect { polyline.boundingMapRect }

    init(coordinates: [CLLocationCoordinate2D], color: UIColor, style: TripRouteMapOverlayStyle) {
        var validCoordinates = coordinates.filter { CLLocationCoordinate2DIsValid($0) }
        self.polyline = MKPolyline(coordinates: &validCoordinates, count: validCoordinates.count)
        self.color = color
        self.style = style
        super.init()
    }
}

private final class TripStopMapAnnotation: NSObject, MKAnnotation {
    let id: String
    let title: String?
    let coordinate: CLLocationCoordinate2D
    let color: UIColor

    var busStop: BusStop {
        BusStop(
            id: id,
            name: title ?? "Stop",
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            direction: nil,
            routeIds: []
        )
    }

    init(stop: TripRouteStopData, color: UIColor) {
        self.id = stop.id
        self.title = stop.name
        self.coordinate = stop.coordinate
        self.color = color
        super.init()
    }
}

private final class TripEndpointMapAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case origin
        case destination

        var systemImage: String {
            switch self {
            case .origin: return "figure.walk"
            case .destination: return "flag.checkered"
            }
        }
    }

    let coordinate: CLLocationCoordinate2D
    let kind: Kind
    let title: String?

    init(coordinate: CLLocationCoordinate2D, kind: Kind) {
        self.coordinate = coordinate
        self.kind = kind
        self.title = kind == .origin ? "Start" : "Destination"
        super.init()
    }
}

private struct TripStopNameBubble: View {
    let stopName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppTheme.Colors.accent)

            Text(stopName)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.Colors.cardElevated.opacity(0.96))
                .shadow(color: AppTheme.Colors.shadow.opacity(0.38), radius: 14, y: 6)
        )
        .overlay(alignment: .bottom) {
            TrianglePointer()
                .fill(AppTheme.Colors.cardElevated.opacity(0.96))
                .frame(width: 16, height: 8)
                .offset(y: 7)
        }
        .padding(.horizontal, 22)
    }
}

private struct TrianglePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
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
