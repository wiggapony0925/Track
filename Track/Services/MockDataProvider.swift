//
//  MockDataProvider.swift
//  Track
//
//  Provides realistic NYC transit mock data for Swift Student Challenge
//  offline mode. All data is hardcoded and requires no network access.
//

import Foundation
import CoreLocation

/// Generates realistic mock transit data for offline SSC evaluation.
enum MockDataProvider {

    // MARK: - Nearby Transit (Grouped)

    /// Mock grouped nearby transit data simulating live arrivals near Times Square.
    static func groupedNearbyTransit() -> [GroupedNearbyTransitResponse] {
        let now = Date()
        func ts(minutesFromNow m: Int) -> Int {
            Int(now.addingTimeInterval(Double(m) * 60).timeIntervalSince1970)
        }

        return [
            GroupedNearbyTransitResponse(
                routeId: "1",
                displayName: "1",
                mode: "subway",
                colorHex: "#EE352E",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "Van Cortlandt Park - 242 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "1", stopName: "Times Sq-42 St", direction: "Uptown", destination: "Van Cortlandt Park - 242 St", minutesAway: 2, status: "Approaching", mode: "subway", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 2), vehicleId: "0101", tripId: "T001", stopId: "127N"),
                            NearbyTransitResponse(routeId: "1", stopName: "Times Sq-42 St", direction: "Uptown", destination: "Van Cortlandt Park - 242 St", minutesAway: 8, status: "En Route", mode: "subway", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 8), vehicleId: "0102", tripId: "T002", stopId: "127N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "South Ferry",
                        arrivals: [
                            NearbyTransitResponse(routeId: "1", stopName: "Times Sq-42 St", direction: "Downtown", destination: "South Ferry", minutesAway: 4, status: "En Route", mode: "subway", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 4), vehicleId: "0103", tripId: "T003", stopId: "127S"),
                            NearbyTransitResponse(routeId: "1", stopName: "Times Sq-42 St", direction: "Downtown", destination: "South Ferry", minutesAway: 11, status: "En Route", mode: "subway", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 11), vehicleId: "0104", tripId: "T004", stopId: "127S")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "7",
                displayName: "7",
                mode: "subway",
                colorHex: "#B933AD",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Queens",
                        directionLabel: "Flushing - Main St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "7", stopName: "Times Sq-42 St", direction: "Queens", destination: "Flushing - Main St", minutesAway: 3, status: "Approaching", mode: "subway", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 3), vehicleId: "0701", tripId: "T005", stopId: "725N"),
                            NearbyTransitResponse(routeId: "7", stopName: "Times Sq-42 St", direction: "Queens", destination: "Flushing - Main St", minutesAway: 7, status: "En Route", mode: "subway", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 7), vehicleId: "0702", tripId: "T006", stopId: "725N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Manhattan",
                        directionLabel: "34 St - Hudson Yards",
                        arrivals: [
                            NearbyTransitResponse(routeId: "7", stopName: "Times Sq-42 St", direction: "Manhattan", destination: "34 St - Hudson Yards", minutesAway: 5, status: "En Route", mode: "subway", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 5), vehicleId: "0703", tripId: "T007", stopId: "725S")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "N",
                displayName: "N",
                mode: "subway",
                colorHex: "#FCCC0A",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "Astoria - Ditmars Blvd",
                        arrivals: [
                            NearbyTransitResponse(routeId: "N", stopName: "Times Sq-42 St", direction: "Uptown", destination: "Astoria - Ditmars Blvd", minutesAway: 1, status: "Approaching", mode: "subway", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 1), vehicleId: "0N01", tripId: "T008", stopId: "R17N"),
                            NearbyTransitResponse(routeId: "N", stopName: "Times Sq-42 St", direction: "Uptown", destination: "Astoria - Ditmars Blvd", minutesAway: 10, status: "En Route", mode: "subway", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 10), vehicleId: "0N02", tripId: "T009", stopId: "R17N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "Coney Island - Stillwell Av",
                        arrivals: [
                            NearbyTransitResponse(routeId: "N", stopName: "Times Sq-42 St", direction: "Downtown", destination: "Coney Island - Stillwell Av", minutesAway: 6, status: "En Route", mode: "subway", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 6), vehicleId: "0N03", tripId: "T010", stopId: "R17S")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "MTA NYCT_M42",
                displayName: "M42",
                mode: "bus",
                colorHex: "#0039A6",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "East",
                        directionLabel: "East via 42 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "MTA NYCT_M42", stopName: "W 42 St / 7 Av", direction: "East", destination: "East via 42 St", minutesAway: 3, status: "Approaching", mode: "bus", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 3), vehicleId: "B001", tripId: "BT01", stopId: "400901"),
                            NearbyTransitResponse(routeId: "MTA NYCT_M42", stopName: "W 42 St / 7 Av", direction: "East", destination: "East via 42 St", minutesAway: 12, status: "En Route", mode: "bus", stopLat: 40.7557, stopLon: -73.9870, arrivalTs: ts(minutesFromNow: 12), vehicleId: "B002", tripId: "BT02", stopId: "400901")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "A",
                displayName: "A",
                mode: "subway",
                colorHex: "#0039A6",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "Inwood - 207 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "A", stopName: "42 St - Port Authority", direction: "Uptown", destination: "Inwood - 207 St", minutesAway: 4, status: "En Route", mode: "subway", stopLat: 40.7571, stopLon: -73.9901, arrivalTs: ts(minutesFromNow: 4), vehicleId: "0A01", tripId: "T011", stopId: "A27N"),
                            NearbyTransitResponse(routeId: "A", stopName: "42 St - Port Authority", direction: "Uptown", destination: "Inwood - 207 St", minutesAway: 12, status: "En Route", mode: "subway", stopLat: 40.7571, stopLon: -73.9901, arrivalTs: ts(minutesFromNow: 12), vehicleId: "0A02", tripId: "T012", stopId: "A27N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "Far Rockaway - Mott Av",
                        arrivals: [
                            NearbyTransitResponse(routeId: "A", stopName: "42 St - Port Authority", direction: "Downtown", destination: "Far Rockaway - Mott Av", minutesAway: 6, status: "En Route", mode: "subway", stopLat: 40.7571, stopLon: -73.9901, arrivalTs: ts(minutesFromNow: 6), vehicleId: "0A03", tripId: "T013", stopId: "A27S")
                        ]
                    )
                ]
            )
        ]
    }

    // MARK: - Flat Nearby Transit

    /// Mock flat nearby transit arrivals.
    static func nearbyTransit() -> [NearbyTransitResponse] {
        groupedNearbyTransit().flatMap { group in
            group.directions.flatMap(\.arrivals)
        }
    }

    // MARK: - Service Alerts

    /// Mock service alerts for subway lines.
    static func alerts() -> [TransitAlert] {
        [
            TransitAlert(
                routeId: "A",
                title: "Planned Work: A Line",
                description: "Uptown A trains are running express from 59 St-Columbus Circle to 125 St. Expect delays.",
                severity: "moderate",
                mode: "subway",
                updatedAt: Int(Date().timeIntervalSince1970),
                affectedRoutes: ["A", "C"]
            ),
            TransitAlert(
                routeId: "7",
                title: "Service Change: 7 Line",
                description: "7 trains are running with delays due to signal problems at Queensboro Plaza.",
                severity: "severe",
                mode: "subway",
                updatedAt: Int(Date().timeIntervalSince1970) - 1800,
                affectedRoutes: ["7"]
            )
        ]
    }

    // MARK: - Subway Arrivals

    /// Mock subway arrivals for a given line.
    static func subwayArrivals(lineID: String) -> [TrainArrival] {
        let now = Date()
        return [
            TrainArrival(routeID: lineID, stationID: "127", stationName: "Times Sq-42 St", direction: "Uptown", scheduledTime: now.addingTimeInterval(120), estimatedTime: now.addingTimeInterval(120), minutesAway: 2, destination: "Uptown", status: "Approaching", tripId: "MOCK_T1"),
            TrainArrival(routeID: lineID, stationID: "127", stationName: "Times Sq-42 St", direction: "Uptown", scheduledTime: now.addingTimeInterval(480), estimatedTime: now.addingTimeInterval(480), minutesAway: 8, destination: "Uptown", status: "En Route", tripId: "MOCK_T2"),
            TrainArrival(routeID: lineID, stationID: "127", stationName: "Times Sq-42 St", direction: "Downtown", scheduledTime: now.addingTimeInterval(240), estimatedTime: now.addingTimeInterval(240), minutesAway: 4, destination: "Downtown", status: "En Route", tripId: "MOCK_T3"),
            TrainArrival(routeID: lineID, stationID: "127", stationName: "Times Sq-42 St", direction: "Downtown", scheduledTime: now.addingTimeInterval(660), estimatedTime: now.addingTimeInterval(660), minutesAway: 11, destination: "Downtown", status: "En Route", tripId: "MOCK_T4")
        ]
    }

    // MARK: - Accessibility

    /// Mock elevator/escalator outage data.
    static func accessibility() -> [ElevatorStatus] {
        [
            ElevatorStatus(station: "Times Sq-42 St", equipmentType: "Elevator", description: "Elevator EL201 out of service - street to mezzanine", outageSince: "2026-02-18T09:00:00"),
            ElevatorStatus(station: "34 St-Penn Station", equipmentType: "Escalator", description: "Escalator ES105 out of service - platform to mezzanine", outageSince: "2026-02-19T14:30:00")
        ]
    }

    // MARK: - Subway Stations

    /// Mock subway stations near Times Square.
    static func subwayStations() -> AllSubwayStationsResponse {
        AllSubwayStationsResponse(stations: [
            SubwayStation(id: "127", name: "Times Sq-42 St", lat: 40.7557, lon: -73.9870, routes: ["1", "2", "3", "7", "N", "Q", "R", "W", "S"]),
            SubwayStation(id: "A27", name: "42 St-Port Authority Bus Terminal", lat: 40.7571, lon: -73.9901, routes: ["A", "C", "E"]),
            SubwayStation(id: "R17", name: "49 St", lat: 40.7600, lon: -73.9842, routes: ["N", "R", "W"]),
            SubwayStation(id: "D20", name: "47-50 Sts-Rockefeller Ctr", lat: 40.7584, lon: -73.9812, routes: ["B", "D", "F", "M"]),
            SubwayStation(id: "R15", name: "34 St-Herald Sq", lat: 40.7497, lon: -73.9878, routes: ["B", "D", "F", "M", "N", "Q", "R", "W"]),
            SubwayStation(id: "128", name: "34 St-Penn Station", lat: 40.7506, lon: -73.9910, routes: ["1", "2", "3"]),
            SubwayStation(id: "A28", name: "34 St-Penn Station", lat: 40.7522, lon: -73.9932, routes: ["A", "C", "E"]),
            SubwayStation(id: "D21", name: "Grand Central-42 St", lat: 40.7527, lon: -73.9772, routes: ["4", "5", "6", "7", "S"])
        ])
    }

    // MARK: - Bus Stops

    /// Mock nearby bus stops.
    static func nearbyBusStops() -> [BusStop] {
        [
            BusStop(id: "400901", name: "W 42 ST/7 AV", lat: 40.7557, lon: -73.9870, direction: "E", routeIds: ["MTA NYCT_M42"]),
            BusStop(id: "400905", name: "W 42 ST/BROADWAY", lat: 40.7553, lon: -73.9860, direction: "E", routeIds: ["MTA NYCT_M42", "MTA NYCT_M104"]),
            BusStop(id: "401200", name: "7 AV/W 42 ST", lat: 40.7559, lon: -73.9873, direction: "S", routeIds: ["MTA NYCT_M20", "MTA NYCT_M104"])
        ]
    }

    // MARK: - Bus Arrivals

    /// Mock bus arrivals for a stop.
    static func busArrivals() -> [BusArrival] {
        let now = Date()
        return [
            BusArrival(routeId: "MTA NYCT_M42", vehicleId: "B001", stopId: "400901", stopName: "W 42 ST/7 AV", statusText: "Approaching", status: "approaching", expectedArrival: now.addingTimeInterval(180), distanceMeters: 150, bearing: 90, directionRef: 0, destinationName: "East via 42 St"),
            BusArrival(routeId: "MTA NYCT_M42", vehicleId: "B002", stopId: "400901", stopName: "W 42 ST/7 AV", statusText: "3 stops away", status: "en_route", expectedArrival: now.addingTimeInterval(720), distanceMeters: 800, bearing: 90, directionRef: 0, destinationName: "East via 42 St")
        ]
    }

    // MARK: - Delay Prediction

    /// Mock delay prediction.
    static func delayPrediction(minutesAway: Int) -> DelayPredictionResponse {
        DelayPredictionResponse(
            adjustedMinutes: minutesAway + 1,
            originalMinutes: minutesAway,
            delayFactor: 1.15,
            adjustmentReason: "Typical rush hour delay"
        )
    }

    // MARK: - LIRR / MNR Arrivals

    /// Mock LIRR arrivals.
    static func lirrArrivals() -> [TrainArrival] {
        let now = Date()
        return [
            TrainArrival(routeID: "LIRR_9", stationID: "Penn Station", stationName: "Penn Station", direction: "Eastbound", scheduledTime: now.addingTimeInterval(600), estimatedTime: now.addingTimeInterval(600), minutesAway: 10, destination: "Babylon", status: "On Time", tripId: "LIRR_T1"),
            TrainArrival(routeID: "LIRR_2", stationID: "Penn Station", stationName: "Penn Station", direction: "Eastbound", scheduledTime: now.addingTimeInterval(1200), estimatedTime: now.addingTimeInterval(1200), minutesAway: 20, destination: "Montauk", status: "On Time", tripId: "LIRR_T2")
        ]
    }

    /// Mock MNR arrivals.
    static func mnrArrivals() -> [TrainArrival] {
        let now = Date()
        return [
            TrainArrival(routeID: "MNR_1", stationID: "Grand Central", stationName: "Grand Central Terminal", direction: "Northbound", scheduledTime: now.addingTimeInterval(900), estimatedTime: now.addingTimeInterval(900), minutesAway: 15, destination: "White Plains", status: "On Time", tripId: "MNR_T1"),
            TrainArrival(routeID: "MNR_2", stationID: "Grand Central", stationName: "Grand Central Terminal", direction: "Northbound", scheduledTime: now.addingTimeInterval(1500), estimatedTime: now.addingTimeInterval(1500), minutesAway: 25, destination: "New Haven", status: "On Time", tripId: "MNR_T2")
        ]
    }
}
