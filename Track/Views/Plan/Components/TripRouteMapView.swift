// MapLibre GL-powered interactive map that draws a trip's transit leg
// polylines on top of the app's MapTiler vector tiles.  Each leg fetches
// its full route shape from the backend and clips it between the board/
// alight stops, then draws colored line layers via the SHARED MapLibreMapView.
//
// This is a thin wrapper around the app's main map renderer — no duplicate
// MLNMapView or GL pipeline.  The trip-route-specific layers (transit casing
// + fill, walk dashes, origin/destination markers) are handled by
// MapLibreMapView's `tripRouteLegs` property.
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
    @State private var legPolylines: [TripRouteLegData] = []
    @State private var isLoading = true

    // Dummy bindings — the trip map doesn't need camera sync
    @State private var cameraPosition: TrackCameraPosition = .automatic
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var mapDistance: Double?
    @State private var showStations = false

    var body: some View {
        MapLibreMapView(
            cameraPosition: $cameraPosition,
            currentMapCenter: $mapCenter,
            currentMapDistance: $mapDistance,
            showStations: $showStations,
            subwayPolylines: [],
            commuterRailPolylines: [],
            stations: [],
            routePolylines: [],
            inactivePolylines: [],
            routeColor: .clear,
            isBusRoute: false,
            busVehicles: [],
            trainVehicles: [],
            transferConnectors: [],
            crossings: [],
            hasActiveRoute: false,
            reroutedRouteIDs: [],
            isDarkMode: colorScheme == .dark,
            selectedMode: .subway,
            tripRouteLegs: legPolylines,
            tripOriginCoordinate: originCoordinate,
            tripDestinationCoordinate: destinationCoordinate,
            tripFitCamera: !legPolylines.isEmpty
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
        var segments: [TripRouteLegData] = []

        await withTaskGroup(of: (Int, [CLLocationCoordinate2D]?, [CLLocationCoordinate2D]?, UIColor, Bool).self) { group in
            for (index, leg) in trip.legs.enumerated() {
                let color = legUIColor(for: leg)
                let isWalk = leg.mode == .walk || leg.mode == .transfer

                group.addTask {
                    if isWalk {
                        return (index, nil, nil, color, true)
                    }
                    guard let routeId = leg.routeId, !routeId.isEmpty else {
                        return (index, nil, nil, color, false)
                    }
                    do {
                        let shape = try await fetchShapeForLeg(leg)
                        let fullCoords = shape.decodedPolylines.flatMap { $0 }
                        let clipped = clipShape(
                            shape: shape,
                            boardStopId: leg.boardStopId,
                            alightStopId: leg.alightStopId
                        )
                        return (
                            index,
                            clipped.isEmpty ? nil : clipped,
                            fullCoords.count >= 2 ? fullCoords : nil,
                            color,
                            false
                        )
                    } catch {
                        #if DEBUG
                        print("[TripRouteMap] Failed to fetch shape for \(routeId): \(error)")
                        #endif
                        return (index, nil, nil, color, false)
                    }
                }
            }

            var results: [(Int, [CLLocationCoordinate2D]?, [CLLocationCoordinate2D]?, UIColor, Bool)] = []
            for await result in group {
                results.append(result)
            }
            results.sort { $0.0 < $1.0 }

            for (index, coords, fullCoords, color, isWalk) in results {
                if isWalk {
                    let walkCoords = resolveWalkCoords(
                        index: index,
                        results: results,
                        legs: trip.legs
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
                        fullRouteCoordinates: fullCoords,
                        color: color,
                        isWalk: false
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
        results: [(Int, [CLLocationCoordinate2D]?, [CLLocationCoordinate2D]?, UIColor, Bool)],
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
