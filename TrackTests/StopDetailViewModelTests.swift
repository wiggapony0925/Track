import CoreLocation
import Foundation
import Testing
@testable import Track

@Suite("Stop detail selection semantics")
struct StopDetailSelectionTests {

    @Test("Bus stop selection preserves stop identity and served routes")
    func busSelectionPreservesIdentity() {
        let stop = BusStop(
            id: "MTA_550320",
            name: "10 AV/W 34 ST",
            lat: 40.7548,
            lon: -74.0021,
            direction: "northbound",
            routeIds: ["MTA NYCT_M11", "MTA NYCT_M34A-SBS"]
        )

        let selection = StopDetailSelection.bus(stop)

        #expect(selection.kind == .bus)
        #expect(selection.stopIDs == ["MTA_550320"])
        #expect(selection.servedRoutes.map(\.displayName) == ["M11", "M34A-SBS"])
    }

    @Test("Commuter rail station selection infers the correct mode")
    func commuterRailSelectionInfersMode() {
        let station = MapSystemViewModel.ConsolidatedStation(
            id: "LIRR_123",
            name: "Jamaica",
            coordinate: CLLocationCoordinate2D(latitude: 40.7006, longitude: -73.8080),
            routes: ["LIRR_1", "LIRR_4"],
            colorGroupCount: 1,
            trackBearing: 0,
            laneHeading: nil,
            laneOffset: 0,
            transferCorridorSpan: 0,
            structure: .atGrade,
            complexID: 9001,
            sourceStopIDs: Set(["LIRR_123"]),
            isTransfer: false
        )

        let selection = StopDetailSelection.station(station)

        #expect(selection.kind == .lirr)
        #expect(selection.servedRoutes.map(\.displayName) == ["Babylon Branch", "Ronkonkoma Branch"])
    }
}

@Suite("Stop detail departure shaping")
struct StopDetailDepartureShapingTests {

    private var elmhurstSelection: StopDetailSelection {
        StopDetailSelection(
            id: "subway-elmhurst",
            name: "Elmhurst Av",
            latitude: 40.742454,
            longitude: -73.882017,
            kind: .subway,
            routeIDs: ["E", "F"],
            stopIDs: ["G13N", "G13S"],
            directionLabel: nil
        )
    }

    @Test("Train arrivals are filtered to the tapped station footprint")
    func trainArrivalsStayLocalToTappedStation() {
        let arrivals = [
            makeTrainArrival(routeID: "E", stationID: "G13N", stationName: "Elmhurst Av", minutes: 2),
            makeTrainArrival(routeID: "F", stationID: "G13S", stationName: "Elmhurst Av", minutes: 5),
            makeTrainArrival(
                routeID: "E",
                stationID: "G14N",
                stationName: "Jackson Hts-Roosevelt Av",
                minutes: 1
            ),
        ]

        let filtered = StopDetailViewModel.filterTrainArrivals(arrivals, for: elmhurstSelection)

        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { ["G13N", "G13S"].contains($0.stationID) })
    }

    @Test("Train sections group matching destination arrivals into one row")
    func trainSectionsGroupByRouteAndDestination() {
        let arrivals = [
            makeTrainArrival(
                routeID: "E",
                stationID: "G13N",
                stationName: "Elmhurst Av",
                minutes: 0,
                destination: "World Trade Center"
            ),
            makeTrainArrival(
                routeID: "E",
                stationID: "G13N",
                stationName: "Elmhurst Av",
                minutes: 7,
                destination: "World Trade Center"
            ),
            makeTrainArrival(
                routeID: "F",
                stationID: "G13S",
                stationName: "Elmhurst Av",
                minutes: 9,
                destination: "Coney Island-Stillwell Av"
            ),
        ]

        let sections = StopDetailViewModel.buildTrainSections(from: arrivals, selection: elmhurstSelection)

        #expect(sections.count == 2)
        #expect(sections.first?.route.displayName == "E")
        #expect(sections.first?.rows.count == 1)
        #expect(sections.first?.rows.first?.times.map(\.label) == ["Now", "7 min"])
    }

    @Test("Bus sections merge arrivals with the same route and destination")
    func busSectionsMergeDestinationRows() {
        let selection = StopDetailSelection(
            id: "bus-stop",
            name: "10 AV/W 34 ST",
            latitude: 40.7548,
            longitude: -74.0021,
            kind: .bus,
            routeIDs: ["MTA NYCT_M11", "MTA NYCT_M34A-SBS"],
            stopIDs: ["MTA_550320"],
            directionLabel: "northbound"
        )

        let arrivals = [
            makeBusArrival(
                routeID: "MTA NYCT_M11",
                stopID: "MTA_550320",
                destination: "Riverbank 145 St via 10 Av",
                minutes: 4
            ),
            makeBusArrival(
                routeID: "MTA NYCT_M11",
                stopID: "MTA_550320",
                destination: "Riverbank 145 St via 10 Av",
                minutes: 13
            ),
            makeBusArrival(
                routeID: "MTA NYCT_M34A-SBS",
                stopID: "MTA_550320",
                destination: "Select Bus Pa Bus Trm via 34 St",
                minutes: 3
            ),
        ]

        let sections = StopDetailViewModel.buildBusSections(from: arrivals, selection: selection)
        let m11Section = sections.first { $0.route.displayName == "M11" }

        #expect(sections.count == 2)
        #expect(m11Section?.rows.count == 1)
        #expect(m11Section?.rows.first?.times.map(\.label) == ["4 min", "13 min"])
    }

    @Test("Accessibility advisories match the tapped stop name")
    func accessibilityAdvisoriesMatchStopName() {
        let advisories = [
            ElevatorStatus(
                station: "Elmhurst Av",
                equipmentType: "Elevator",
                description: "Uptown elevator unavailable",
                outageSince: "2026-04-06"
            ),
            ElevatorStatus(
                station: "Jackson Hts-Roosevelt Av",
                equipmentType: "Escalator",
                description: "Main mezzanine escalator unavailable",
                outageSince: nil
            ),
        ]

        let matches = StopDetailViewModel.matchingAccessibilityOutages(
            for: elmhurstSelection,
            from: advisories
        )

        #expect(matches.count == 1)
        #expect(matches.first?.station == "Elmhurst Av")
    }
}

private func makeTrainArrival(
    routeID: String,
    stationID: String,
    stationName: String,
    minutes: Int,
    destination: String = "World Trade Center",
    direction: String = "S",
    status: String = "in_transit"
) -> TrainArrival {
    let eta = Date().addingTimeInterval(TimeInterval(minutes * 60))
    return TrainArrival(
        id: "\(routeID)-\(stationID)-\(minutes)",
        routeID: routeID,
        stationID: stationID,
        stationName: stationName,
        stopLat: nil,
        stopLon: nil,
        direction: direction,
        scheduledTime: eta,
        estimatedTime: eta,
        minutesAway: minutes,
        destination: destination,
        status: status,
        tripId: nil,
        isCancelled: false
    )
}

private func makeBusArrival(
    routeID: String,
    stopID: String,
    destination: String,
    minutes: Int,
    realtime: Bool = true
) -> BusArrival {
    BusArrival(
        routeId: routeID,
        vehicleId: "\(routeID)-\(minutes)",
        stopId: stopID,
        stopName: "10 AV/W 34 ST",
        statusText: minutes == 0 ? "Approaching" : "\(minutes) min",
        status: realtime ? "in_transit" : "scheduled",
        expectedArrival: Date().addingTimeInterval(TimeInterval(minutes * 60)),
        distanceMeters: nil,
        bearing: nil,
        directionRef: 0,
        destinationName: destination,
        isRealtime: realtime
    )
}
