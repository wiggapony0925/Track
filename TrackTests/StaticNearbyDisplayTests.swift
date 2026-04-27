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
}