import CoreLocation
import Foundation
import Testing
@testable import Track

@Suite("Static nearby route display")
@MainActor
struct StaticNearbyDisplayTests {
    private func placeholderArrival(routeId: String, mode: String = "bus") -> NearbyTransitResponse {
        NearbyTransitResponse(
            routeId: routeId,
            stopName: "W 42 St/8 Av",
            direction: "Unknown",
            destination: nil,
            minutesAway: 99,
            status: "No Data",
            mode: mode,
            stopLat: 40.7570,
            stopLon: -73.9897,
            arrivalTs: nil,
            vehicleId: nil,
            tripId: nil,
            stopId: "STOP-\(routeId)",
            distanceM: 120
        )
    }

    private func expiredLiveArrival(
        routeId: String = "M11",
        mode: String = "bus"
    ) -> NearbyTransitResponse {
        NearbyTransitResponse(
            routeId: routeId,
            stopName: "W 42 St/8 Av",
            direction: "Northbound",
            destination: "Riverbank Park",
            minutesAway: 0,
            status: "OK",
            mode: mode,
            stopLat: 40.7570,
            stopLon: -73.9897,
            arrivalTs: Int(Date.now.timeIntervalSince1970) - 300,
            vehicleId: "V-\(routeId)",
            tripId: "T-\(routeId)",
            stopId: "STOP-\(routeId)",
            distanceM: 120,
            isRealTime: true
        )
    }

    private func staticGroup(routeId: String = "M11", mode: String = "bus") -> GroupedNearbyTransitResponse {
        GroupedNearbyTransitResponse(
            routeId: routeId,
            displayName: routeId,
            mode: mode,
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Unknown",
                    directionLabel: nil,
                    arrivals: [placeholderArrival(routeId: routeId, mode: mode)]
                )
            ]
        )
    }

    private func expiredLiveGroup(
        routeId: String = "M11",
        mode: String = "bus"
    ) -> GroupedNearbyTransitResponse {
        GroupedNearbyTransitResponse(
            routeId: routeId,
            displayName: routeId,
            mode: mode,
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Northbound",
                    directionLabel: "Riverbank Park",
                    arrivals: [expiredLiveArrival(routeId: routeId, mode: mode)]
                )
            ]
        )
    }

    @Test func staticPlaceholderGroupsAppearInActiveBuckets() {
        let viewModel = HomeViewModel()
        viewModel.isShowingStaticNearbyRoutes = true
        viewModel.groupedTransit = [staticGroup()]

        #expect(viewModel.filteredGroupedTransit.map(\.routeId) == ["M11"])
        #expect(viewModel.filteredNearbyGroupedBusArrivals.map(\.routeId) == ["M11"])
    }

    @Test func liveModeStillMovesPlaceholderGroupsToInactive() {
        let viewModel = HomeViewModel()
        viewModel.groupedTransit = [staticGroup()]
        viewModel.rebuildGhostRoutes()

        #expect(viewModel.filteredGroupedTransit.isEmpty)
        #expect(viewModel.ghostRoutes.map(\.routeId) == ["M11"])
    }

    @Test func staticModeDoesNotDuplicatePlaceholderGroupsAsGhosts() {
        let viewModel = HomeViewModel()
        viewModel.isShowingStaticNearbyRoutes = true
        viewModel.groupedTransit = [staticGroup()]
        viewModel.rebuildGhostRoutes()

        #expect(viewModel.filteredGroupedTransit.map(\.routeId) == ["M11"])
        #expect(viewModel.ghostRoutes.isEmpty)
    }

    @Test func offlineNearbyFallbackBuildsAllLocalDirections() {
        let route = LocalRoute(
            routeID: "M11",
            shortName: "M11",
            longName: nil,
            colorHex: nil,
            mode: "bus"
        )
        let northStop = LocalStop(
            stopID: "M11-N",
            name: "W 42 St/8 Av",
            latitude: 40.7570,
            longitude: -73.9897,
            mode: "bus",
            parentStation: nil
        )
        let southStop = LocalStop(
            stopID: "M11-S",
            name: "9 Av/W 42 St",
            latitude: 40.7580,
            longitude: -73.9900,
            mode: "bus",
            parentStation: nil
        )
        let northTerminal = LocalStop(
            stopID: "M11-N-T",
            name: "Riverbank Park",
            latitude: 40.8250,
            longitude: -73.9550,
            mode: "bus",
            parentStation: nil
        )
        let southTerminal = LocalStop(
            stopID: "M11-S-T",
            name: "West Village Abingdon Sq",
            latitude: 40.7370,
            longitude: -74.0050,
            mode: "bus",
            parentStation: nil
        )
        let routeStops = [
            LocalRouteStop(route: route, stop: northStop, directionID: 0),
            LocalRouteStop(route: route, stop: northTerminal, directionID: 0),
            LocalRouteStop(route: route, stop: southStop, directionID: 1),
            LocalRouteStop(route: route, stop: southTerminal, directionID: 1)
        ]

        let directions = OfflineNearbyFallback.buildLocalDirections(
            route: route,
            nearbyStops: [northStop, southStop],
            distances: [northStop.stopID: 80, southStop.stopID: 95],
            routeStops: routeStops,
            estimatedWaitMinutes: nil
        )

        #expect(directions.map(\.directionId) == ["0", "1"])
        #expect(directions.map(\.direction) == ["To Riverbank Park", "To West Village Abingdon Sq"])
        #expect(directions.flatMap(\.arrivals).map(\.stopId) == ["M11-N", "M11-S"])
    }

    @Test func liveDragSearchPreservesStaticMissingDirections() {
        let staticTwoWay = GroupedNearbyTransitResponse(
            routeId: "M11",
            displayName: "M11",
            mode: "bus",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Outbound",
                    directionLabel: "Outbound",
                    directionId: "0",
                    arrivals: [placeholderArrival(routeId: "M11")]
                ),
                DirectionArrivalsResponse(
                    direction: "Inbound",
                    directionLabel: "Inbound",
                    directionId: "1",
                    arrivals: [placeholderArrival(routeId: "M11")]
                )
            ]
        )
        let liveOneWay = GroupedNearbyTransitResponse(
            routeId: "M11",
            displayName: "M11",
            mode: "bus",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Riverbank Park",
                    directionLabel: "Riverbank Park",
                    directionId: "0",
                    arrivals: [expiredLiveArrival(routeId: "M11")]
                )
            ]
        )

        let merged = HomeViewModel.preservingMissingDirections(
            from: staticTwoWay,
            in: liveOneWay
        )

        #expect(merged.directions.map(\.directionId) == ["0", "1"])
        #expect(merged.directions[0].direction == "Riverbank Park")
        #expect(merged.directions[1].direction == "Inbound")
    }

    @Test func liveDragSearchKeepsBetterStaticDirectionLabels() {
        let staticTwoWay = GroupedNearbyTransitResponse(
            routeId: "M11",
            displayName: "M11",
            mode: "bus",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "To Riverbank Park",
                    directionLabel: "To Riverbank Park",
                    directionId: "0",
                    arrivals: [placeholderArrival(routeId: "M11")]
                ),
                DirectionArrivalsResponse(
                    direction: "To West Village Abingdon Sq",
                    directionLabel: "To West Village Abingdon Sq",
                    directionId: "1",
                    arrivals: [placeholderArrival(routeId: "M11")]
                )
            ]
        )
        let liveRenamed = GroupedNearbyTransitResponse(
            routeId: "M11",
            displayName: "M11",
            mode: "bus",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Outbound",
                    directionLabel: "Outbound",
                    directionId: "0",
                    arrivals: [expiredLiveArrival(routeId: "M11")]
                ),
                DirectionArrivalsResponse(
                    direction: "Inbound",
                    directionLabel: "Inbound",
                    directionId: "1",
                    arrivals: [expiredLiveArrival(routeId: "M11")]
                )
            ]
        )

        let merged = HomeViewModel.preservingMissingDirections(
            from: staticTwoWay,
            in: liveRenamed
        )

        #expect(merged.directions.map(\.direction) == [
            "To Riverbank Park",
            "To West Village Abingdon Sq"
        ])
        #expect(merged.directions.flatMap(\.arrivals).allSatisfy { !$0.isPlaceholder })
    }

    @Test func liveTrainRefreshDoesNotPreserveOfflineDirectionTabs() {
        let offlineSubway = GroupedNearbyTransitResponse(
            routeId: "7",
            displayName: "7",
            mode: "subway",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "To 34 St-Hudson Yards",
                    directionLabel: "To 34 St-Hudson Yards",
                    directionId: "1",
                    arrivals: [placeholderArrival(routeId: "7", mode: "subway")]
                ),
                DirectionArrivalsResponse(
                    direction: "To Dover Plains",
                    directionLabel: "To Dover Plains",
                    directionId: "0",
                    arrivals: [placeholderArrival(routeId: "7", mode: "subway")]
                )
            ]
        )
        let liveSubway = GroupedNearbyTransitResponse(
            routeId: "7",
            displayName: "7",
            mode: "subway",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Flushing-Main St",
                    directionLabel: "Northbound → Flushing-Main St",
                    directionId: "N",
                    arrivals: [
                        NearbyTransitResponse(
                            routeId: "7",
                            stopName: "Times Sq-42 St",
                            direction: "Flushing-Main St",
                            destination: "Flushing-Main St",
                            minutesAway: 2,
                            status: "On Time",
                            mode: "subway",
                            stopLat: 40.7553,
                            stopLon: -73.9870,
                            arrivalTs: Int(Date.now.timeIntervalSince1970) + 120,
                            vehicleId: nil,
                            tripId: "080350_7..N",
                            stopId: "726N",
                            distanceM: 94.6,
                            isRealTime: true
                        )
                    ]
                )
            ]
        )

        let merged = HomeViewModel.preservingMissingDirections(
            from: offlineSubway,
            in: liveSubway
        )

        #expect(merged.directions.map(\.direction) == ["Flushing-Main St"])
        #expect(!merged.directions.map(\.direction).contains("To Dover Plains"))
    }

    @Test func expiredCachedGroupsStayVisibleDuringRefresh() {
        let viewModel = HomeViewModel()
        viewModel.groupedTransit = [expiredLiveGroup()]
        viewModel.isRefreshing = true
        viewModel.showStaleRows = false

        #expect(viewModel.filteredGroupedTransit.map(\.routeId) == ["M11"])
    }

    @Test func expiredCachedGroupsHideAfterRefreshFinishes() {
        let viewModel = HomeViewModel()
        viewModel.groupedTransit = [expiredLiveGroup()]
        viewModel.isRefreshing = false
        viewModel.showStaleRows = false

        #expect(viewModel.filteredGroupedTransit.isEmpty)
    }

    @Test func stopOnlyBusShapeIsNotRenderableGeometry() {
        let stops = [
            BusStop(id: "Q26-1", name: "15 Av/115 St", lat: 40.785, lon: -73.845, direction: "0"),
            BusStop(id: "Q26-2", name: "110 St/14 Av", lat: 40.790, lon: -73.835, direction: "0")
        ]
        let shape = RouteShapeResponse(
            routeId: "Q26",
            polylines: [],
            stops: stops,
            directions: [
                DirectionShapeResponse(
                    directionId: 0,
                    headsign: "To 110 ST/14 AV",
                    polylines: [],
                    stops: stops
                )
            ],
            serviceType: nil
        )

        #expect(LocalRouteShapeProvider.isStopDerivedShape(shape))
        #expect(!LocalRouteShapeProvider.hasRenderableGeometry(shape))
    }

    @Test func encodedBusShapeIsRenderableGeometry() {
        let stops = [
            BusStop(id: "Q26-1", name: "15 Av/115 St", lat: 40.785, lon: -73.845, direction: "0"),
            BusStop(id: "Q26-2", name: "110 St/14 Av", lat: 40.790, lon: -73.835, direction: "0")
        ]
        let coordinates = [
            CLLocationCoordinate2D(latitude: 40.785, longitude: -73.845),
            CLLocationCoordinate2D(latitude: 40.786, longitude: -73.842),
            CLLocationCoordinate2D(latitude: 40.790, longitude: -73.835)
        ]
        let encoded = encodePolyline(coordinates)
        let shape = RouteShapeResponse(
            routeId: "Q26",
            polylines: [encoded],
            stops: stops,
            directions: [
                DirectionShapeResponse(
                    directionId: 0,
                    headsign: "To 110 ST/14 AV",
                    polylines: [encoded],
                    stops: stops
                )
            ],
            serviceType: nil
        )

        #expect(!LocalRouteShapeProvider.isStopDerivedShape(shape))
        #expect(LocalRouteShapeProvider.hasRenderableGeometry(shape))
    }

    @Test func routeLevelGeometryBackfillsEmptyDirectionPolylines() {
        let stops = [
            BusStop(id: "Q26-1", name: "15 Av/115 St", lat: 40.785, lon: -73.845, direction: "0"),
            BusStop(id: "Q26-2", name: "110 St/14 Av", lat: 40.790, lon: -73.835, direction: "0")
        ]
        let encoded = encodePolyline([
            CLLocationCoordinate2D(latitude: 40.785, longitude: -73.845),
            CLLocationCoordinate2D(latitude: 40.790, longitude: -73.835)
        ])
        let shape = RouteShapeResponse(
            routeId: "Q26",
            polylines: [encoded],
            stops: stops,
            directions: [
                DirectionShapeResponse(
                    directionId: 0,
                    headsign: "To 110 ST/14 AV",
                    polylines: [],
                    stops: stops
                )
            ],
            serviceType: nil
        )

        let candidates = HomeViewModel.polylineCandidatesForSelectedDirection(
            shape: shape,
            index: 0,
            name: "To 110 ST/14 AV",
            shapeDirectionId: 0,
            hasDirectionData: true,
            isBus: true
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.count == 2)
    }

    @Test func genericNumericDirectionLabelsAreFallbacks() {
        #expect(DirectionConstants.isFallbackDirection("Direction 0"))
        #expect(DirectionConstants.isFallbackDirection("Direction 1"))
        #expect(directionLabel("Direction 0") == "Outbound")
        #expect(shortDirectionLabel("Direction 1") == "Inbound")

        let direction = DirectionArrivalsResponse(
            direction: "S",
            directionLabel: nil,
            directionId: nil,
            arrivals: []
        )
        let label = ArrivalHelpers.resolveDirectionLabel(
            for: direction,
            shapeHeadsign: "Direction 0",
            shapeLastStopName: nil,
            skipBackendLabel: true,
            useShortCompass: true
        )

        #expect(label == "↓ South")
    }

    @Test func branchedTrainOpacitySplitUsesStopOrderPerSegment() {
        let stops = [
            BusStop(id: "trunk-0", name: "Start", lat: 0.0, lon: 0.0, direction: nil),
            BusStop(id: "trunk-1", name: "Junction", lat: 0.0, lon: 1.0, direction: nil),
            BusStop(id: "branch-a", name: "Branch A", lat: 1.0, lon: 2.0, direction: nil),
            BusStop(id: "branch-b", name: "Branch B", lat: -1.0, lon: 2.0, direction: nil)
        ]
        let trunk = [
            CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 0.0, longitude: 1.0)
        ]
        let branchA = [
            CLLocationCoordinate2D(latitude: 0.0, longitude: 1.0),
            CLLocationCoordinate2D(latitude: 1.0, longitude: 2.0)
        ]
        let branchB = [
            CLLocationCoordinate2D(latitude: 0.0, longitude: 1.0),
            CLLocationCoordinate2D(latitude: -1.0, longitude: 2.0)
        ]

        let split = HomeViewModel.splitRoutePolylinesByStopOrder(
            [trunk, branchA, branchB],
            directionStops: stops,
            splitStopIndex: 1,
            isBus: false
        )

        #expect(split.behind.count == 1)
        #expect(split.ahead.count == 2)
    }

    @Test func reversedTrainDirectionFlipsOpacitySplit() {
        let forwardStops = [
            BusStop(id: "0", name: "First", lat: 0.0, lon: 0.0, direction: nil),
            BusStop(id: "1", name: "Middle", lat: 0.0, lon: 1.0, direction: nil),
            BusStop(id: "2", name: "Last", lat: 0.0, lon: 2.0, direction: nil)
        ]
        let forwardLine = [
            CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 0.0, longitude: 1.0),
            CLLocationCoordinate2D(latitude: 0.0, longitude: 2.0)
        ]
        let reversedStops = Array(forwardStops.reversed())
        let reversedLine = Array(forwardLine.reversed())

        let forward = HomeViewModel.splitRoutePolylinesByStopOrder(
            [forwardLine],
            directionStops: forwardStops,
            splitStopIndex: 1,
            isBus: false
        )
        let reversed = HomeViewModel.splitRoutePolylinesByStopOrder(
            [reversedLine],
            directionStops: reversedStops,
            splitStopIndex: 1,
            isBus: false
        )

        #expect(forward.behind.first?.first?.longitude == 0.0)
        #expect(forward.ahead.first?.last?.longitude == 2.0)
        #expect(reversed.behind.first?.first?.longitude == 2.0)
        #expect(reversed.ahead.first?.last?.longitude == 0.0)
    }

    @Test func subwayStopsReverseWhenHeadsignMatchesFirstTerminal() {
        let stops = [
            BusStop(id: "Q", name: "Queens Plaza", lat: 40.748, lon: -73.937, direction: nil),
            BusStop(id: "S", name: "Steinway St", lat: 40.756, lon: -73.920, direction: nil),
            BusStop(id: "C", name: "Coney Island-Stillwell Av", lat: 40.577, lon: -73.981, direction: nil)
        ]

        let ordered = HomeViewModel.stopsOrderedForSelectedTerminal(
            stops,
            directionName: "To Queens Plaza",
            shapeHeadsign: nil
        )

        #expect(ordered.first?.name == "Coney Island-Stillwell Av")
        #expect(ordered.last?.name == "Queens Plaza")
    }
}