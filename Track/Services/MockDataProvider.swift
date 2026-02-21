//
//  MockDataProvider.swift
//  Track
//
//  Provides realistic NYC transit mock data for Swift Student Challenge
//  offline mode. All data is hardcoded and requires no network access.
//
//  Mock location: 40.75306° N, 73.99944° W — Midtown Manhattan
//  (near Penn Station / Herald Square / Times Square corridor)
//

import Foundation
import CoreLocation

/// Generates realistic mock transit data for offline SSC evaluation.
/// Station coordinates, polylines, and routes are from the real Track API
/// (GTFS data), centered around Midtown Manhattan (40.75306, -73.99944).
enum MockDataProvider {

    /// The mock user location used in ChallengeMode.
    static let mockCoordinate = CLLocationCoordinate2D(latitude: 40.75306, longitude: -73.99944)

    // MARK: - Nearby Transit (Grouped)

    /// Mock grouped nearby transit data simulating live arrivals in Midtown Manhattan.
    /// Includes subway lines 1/2/3, A/C/E, 7, N/Q/R/W, B/D/F/M, L and buses M34/M42/M20.
    static func groupedNearbyTransit() -> [GroupedNearbyTransitResponse] {
        let now = Date()
        func ts(minutesFromNow m: Int) -> Int {
            Int(now.addingTimeInterval(Double(m) * 60).timeIntervalSince1970)
        }

        return [
            // ── 1/2/3 at 34 St-Penn Station (128) ──
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
                            NearbyTransitResponse(routeId: "1", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Van Cortlandt Park - 242 St", minutesAway: 1, status: "Approaching", mode: "subway", stopLat: 40.75037, stopLon: -73.99106, arrivalTs: ts(minutesFromNow: 1), vehicleId: "0101", tripId: "T001", stopId: "128N"),
                            NearbyTransitResponse(routeId: "1", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Van Cortlandt Park - 242 St", minutesAway: 6, status: "En Route", mode: "subway", stopLat: 40.75037, stopLon: -73.99106, arrivalTs: ts(minutesFromNow: 6), vehicleId: "0102", tripId: "T002", stopId: "128N"),
                            NearbyTransitResponse(routeId: "1", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Van Cortlandt Park - 242 St", minutesAway: 12, status: "En Route", mode: "subway", stopLat: 40.75037, stopLon: -73.99106, arrivalTs: ts(minutesFromNow: 12), vehicleId: "0106", tripId: "T020", stopId: "128N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "South Ferry",
                        arrivals: [
                            NearbyTransitResponse(routeId: "1", stopName: "34 St-Penn Station", direction: "Downtown", destination: "South Ferry", minutesAway: 3, status: "En Route", mode: "subway", stopLat: 40.75037, stopLon: -73.99106, arrivalTs: ts(minutesFromNow: 3), vehicleId: "0103", tripId: "T003", stopId: "128S"),
                            NearbyTransitResponse(routeId: "1", stopName: "34 St-Penn Station", direction: "Downtown", destination: "South Ferry", minutesAway: 9, status: "En Route", mode: "subway", stopLat: 40.75037, stopLon: -73.99106, arrivalTs: ts(minutesFromNow: 9), vehicleId: "0104", tripId: "T004", stopId: "128S")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "2",
                displayName: "2",
                mode: "subway",
                colorHex: "#EE352E",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "Wakefield - 241 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "2", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Wakefield - 241 St", minutesAway: 4, status: "En Route", mode: "subway", stopLat: 40.75037, stopLon: -73.99106, arrivalTs: ts(minutesFromNow: 4), vehicleId: "0201", tripId: "T021", stopId: "128N"),
                            NearbyTransitResponse(routeId: "2", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Wakefield - 241 St", minutesAway: 11, status: "En Route", mode: "subway", stopLat: 40.75037, stopLon: -73.99106, arrivalTs: ts(minutesFromNow: 11), vehicleId: "0202", tripId: "T022", stopId: "128N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "Flatbush Av - Brooklyn College",
                        arrivals: [
                            NearbyTransitResponse(routeId: "2", stopName: "34 St-Penn Station", direction: "Downtown", destination: "Flatbush Av - Brooklyn College", minutesAway: 5, status: "En Route", mode: "subway", stopLat: 40.75037, stopLon: -73.99106, arrivalTs: ts(minutesFromNow: 5), vehicleId: "0203", tripId: "T023", stopId: "128S")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "3",
                displayName: "3",
                mode: "subway",
                colorHex: "#EE352E",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "Harlem - 148 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "3", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Harlem - 148 St", minutesAway: 7, status: "En Route", mode: "subway", stopLat: 40.75037, stopLon: -73.99106, arrivalTs: ts(minutesFromNow: 7), vehicleId: "0301", tripId: "T024", stopId: "128N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "New Lots Av",
                        arrivals: [
                            NearbyTransitResponse(routeId: "3", stopName: "34 St-Penn Station", direction: "Downtown", destination: "New Lots Av", minutesAway: 8, status: "En Route", mode: "subway", stopLat: 40.75037, stopLon: -73.99106, arrivalTs: ts(minutesFromNow: 8), vehicleId: "0302", tripId: "T025", stopId: "128S")
                        ]
                    )
                ]
            ),

            // ── A/C/E at 34 St-Penn Station (A28) ──
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
                            NearbyTransitResponse(routeId: "A", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Inwood - 207 St", minutesAway: 2, status: "Approaching", mode: "subway", stopLat: 40.75229, stopLon: -73.99339, arrivalTs: ts(minutesFromNow: 2), vehicleId: "0A01", tripId: "T005", stopId: "A28N"),
                            NearbyTransitResponse(routeId: "A", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Inwood - 207 St", minutesAway: 10, status: "En Route", mode: "subway", stopLat: 40.75229, stopLon: -73.99339, arrivalTs: ts(minutesFromNow: 10), vehicleId: "0A02", tripId: "T006", stopId: "A28N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "Far Rockaway - Mott Av",
                        arrivals: [
                            NearbyTransitResponse(routeId: "A", stopName: "34 St-Penn Station", direction: "Downtown", destination: "Far Rockaway - Mott Av", minutesAway: 5, status: "En Route", mode: "subway", stopLat: 40.75229, stopLon: -73.99339, arrivalTs: ts(minutesFromNow: 5), vehicleId: "0A03", tripId: "T007", stopId: "A28S"),
                            NearbyTransitResponse(routeId: "A", stopName: "34 St-Penn Station", direction: "Downtown", destination: "Far Rockaway - Mott Av", minutesAway: 14, status: "En Route", mode: "subway", stopLat: 40.75229, stopLon: -73.99339, arrivalTs: ts(minutesFromNow: 14), vehicleId: "0A04", tripId: "T026", stopId: "A28S")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "C",
                displayName: "C",
                mode: "subway",
                colorHex: "#0039A6",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "168 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "C", stopName: "34 St-Penn Station", direction: "Uptown", destination: "168 St", minutesAway: 6, status: "En Route", mode: "subway", stopLat: 40.75229, stopLon: -73.99339, arrivalTs: ts(minutesFromNow: 6), vehicleId: "0C01", tripId: "T027", stopId: "A28N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "Euclid Av",
                        arrivals: [
                            NearbyTransitResponse(routeId: "C", stopName: "34 St-Penn Station", direction: "Downtown", destination: "Euclid Av", minutesAway: 8, status: "En Route", mode: "subway", stopLat: 40.75229, stopLon: -73.99339, arrivalTs: ts(minutesFromNow: 8), vehicleId: "0C02", tripId: "T028", stopId: "A28S")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "E",
                displayName: "E",
                mode: "subway",
                colorHex: "#0039A6",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "Jamaica Center - Parsons/Archer",
                        arrivals: [
                            NearbyTransitResponse(routeId: "E", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Jamaica Center - Parsons/Archer", minutesAway: 3, status: "En Route", mode: "subway", stopLat: 40.75229, stopLon: -73.99339, arrivalTs: ts(minutesFromNow: 3), vehicleId: "0E01", tripId: "T008", stopId: "A28N"),
                            NearbyTransitResponse(routeId: "E", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Jamaica Center - Parsons/Archer", minutesAway: 9, status: "En Route", mode: "subway", stopLat: 40.75229, stopLon: -73.99339, arrivalTs: ts(minutesFromNow: 9), vehicleId: "0E02", tripId: "T009", stopId: "A28N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "World Trade Center",
                        arrivals: [
                            NearbyTransitResponse(routeId: "E", stopName: "34 St-Penn Station", direction: "Downtown", destination: "World Trade Center", minutesAway: 4, status: "En Route", mode: "subway", stopLat: 40.75229, stopLon: -73.99339, arrivalTs: ts(minutesFromNow: 4), vehicleId: "0E03", tripId: "T010", stopId: "A28S")
                        ]
                    )
                ]
            ),

            // ── 7 at 34 St-Hudson Yards (726) ──
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
                            NearbyTransitResponse(routeId: "7", stopName: "34 St-Hudson Yards", direction: "Queens", destination: "Flushing - Main St", minutesAway: 2, status: "Approaching", mode: "subway", stopLat: 40.75588, stopLon: -74.00191, arrivalTs: ts(minutesFromNow: 2), vehicleId: "0701", tripId: "T011", stopId: "726N"),
                            NearbyTransitResponse(routeId: "7", stopName: "34 St-Hudson Yards", direction: "Queens", destination: "Flushing - Main St", minutesAway: 6, status: "En Route", mode: "subway", stopLat: 40.75588, stopLon: -74.00191, arrivalTs: ts(minutesFromNow: 6), vehicleId: "0702", tripId: "T012", stopId: "726N"),
                            NearbyTransitResponse(routeId: "7", stopName: "34 St-Hudson Yards", direction: "Queens", destination: "Flushing - Main St", minutesAway: 10, status: "En Route", mode: "subway", stopLat: 40.75588, stopLon: -74.00191, arrivalTs: ts(minutesFromNow: 10), vehicleId: "0705", tripId: "T029", stopId: "726N")
                        ]
                    )
                ]
            ),

            // ── B/D/F/M at 34 St-Herald Sq (D17) ──
            GroupedNearbyTransitResponse(
                routeId: "B",
                displayName: "B",
                mode: "subway",
                colorHex: "#FF6319",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "Bedford Park Blvd",
                        arrivals: [
                            NearbyTransitResponse(routeId: "B", stopName: "34 St-Herald Sq", direction: "Uptown", destination: "Bedford Park Blvd", minutesAway: 5, status: "En Route", mode: "subway", stopLat: 40.74972, stopLon: -73.98782, arrivalTs: ts(minutesFromNow: 5), vehicleId: "0B01", tripId: "T030", stopId: "D17N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "Brighton Beach",
                        arrivals: [
                            NearbyTransitResponse(routeId: "B", stopName: "34 St-Herald Sq", direction: "Downtown", destination: "Brighton Beach", minutesAway: 7, status: "En Route", mode: "subway", stopLat: 40.74972, stopLon: -73.98782, arrivalTs: ts(minutesFromNow: 7), vehicleId: "0B02", tripId: "T031", stopId: "D17S")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "D",
                displayName: "D",
                mode: "subway",
                colorHex: "#FF6319",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "Norwood - 205 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "D", stopName: "34 St-Herald Sq", direction: "Uptown", destination: "Norwood - 205 St", minutesAway: 4, status: "En Route", mode: "subway", stopLat: 40.74972, stopLon: -73.98782, arrivalTs: ts(minutesFromNow: 4), vehicleId: "0D01", tripId: "T032", stopId: "D17N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "Coney Island - Stillwell Av",
                        arrivals: [
                            NearbyTransitResponse(routeId: "D", stopName: "34 St-Herald Sq", direction: "Downtown", destination: "Coney Island - Stillwell Av", minutesAway: 6, status: "En Route", mode: "subway", stopLat: 40.74972, stopLon: -73.98782, arrivalTs: ts(minutesFromNow: 6), vehicleId: "0D02", tripId: "T033", stopId: "D17S")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "F",
                displayName: "F",
                mode: "subway",
                colorHex: "#FF6319",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "Jamaica - 179 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "F", stopName: "34 St-Herald Sq", direction: "Uptown", destination: "Jamaica - 179 St", minutesAway: 3, status: "Approaching", mode: "subway", stopLat: 40.74972, stopLon: -73.98782, arrivalTs: ts(minutesFromNow: 3), vehicleId: "0F01", tripId: "T034", stopId: "D17N"),
                            NearbyTransitResponse(routeId: "F", stopName: "34 St-Herald Sq", direction: "Uptown", destination: "Jamaica - 179 St", minutesAway: 9, status: "En Route", mode: "subway", stopLat: 40.74972, stopLon: -73.98782, arrivalTs: ts(minutesFromNow: 9), vehicleId: "0F02", tripId: "T035", stopId: "D17N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "Coney Island - Stillwell Av",
                        arrivals: [
                            NearbyTransitResponse(routeId: "F", stopName: "34 St-Herald Sq", direction: "Downtown", destination: "Coney Island - Stillwell Av", minutesAway: 5, status: "En Route", mode: "subway", stopLat: 40.74972, stopLon: -73.98782, arrivalTs: ts(minutesFromNow: 5), vehicleId: "0F03", tripId: "T036", stopId: "D17S")
                        ]
                    )
                ]
            ),

            // ── N/Q/R/W at 34 St-Herald Sq (R17) ──
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
                            NearbyTransitResponse(routeId: "N", stopName: "34 St-Herald Sq", direction: "Uptown", destination: "Astoria - Ditmars Blvd", minutesAway: 1, status: "Approaching", mode: "subway", stopLat: 40.74957, stopLon: -73.98795, arrivalTs: ts(minutesFromNow: 1), vehicleId: "0N01", tripId: "T013", stopId: "R17N"),
                            NearbyTransitResponse(routeId: "N", stopName: "34 St-Herald Sq", direction: "Uptown", destination: "Astoria - Ditmars Blvd", minutesAway: 8, status: "En Route", mode: "subway", stopLat: 40.74957, stopLon: -73.98795, arrivalTs: ts(minutesFromNow: 8), vehicleId: "0N02", tripId: "T014", stopId: "R17N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "Coney Island - Stillwell Av",
                        arrivals: [
                            NearbyTransitResponse(routeId: "N", stopName: "34 St-Herald Sq", direction: "Downtown", destination: "Coney Island - Stillwell Av", minutesAway: 4, status: "En Route", mode: "subway", stopLat: 40.74957, stopLon: -73.98795, arrivalTs: ts(minutesFromNow: 4), vehicleId: "0N03", tripId: "T015", stopId: "R17S")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "Q",
                displayName: "Q",
                mode: "subway",
                colorHex: "#FCCC0A",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "96 St (2nd Av)",
                        arrivals: [
                            NearbyTransitResponse(routeId: "Q", stopName: "34 St-Herald Sq", direction: "Uptown", destination: "96 St", minutesAway: 6, status: "En Route", mode: "subway", stopLat: 40.74957, stopLon: -73.98795, arrivalTs: ts(minutesFromNow: 6), vehicleId: "0Q01", tripId: "T037", stopId: "R17N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "Coney Island - Stillwell Av",
                        arrivals: [
                            NearbyTransitResponse(routeId: "Q", stopName: "34 St-Herald Sq", direction: "Downtown", destination: "Coney Island - Stillwell Av", minutesAway: 7, status: "En Route", mode: "subway", stopLat: 40.74957, stopLon: -73.98795, arrivalTs: ts(minutesFromNow: 7), vehicleId: "0Q02", tripId: "T038", stopId: "R17S")
                        ]
                    )
                ]
            ),
            GroupedNearbyTransitResponse(
                routeId: "R",
                displayName: "R",
                mode: "subway",
                colorHex: "#FCCC0A",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Uptown",
                        directionLabel: "Forest Hills - 71 Av",
                        arrivals: [
                            NearbyTransitResponse(routeId: "R", stopName: "34 St-Herald Sq", direction: "Uptown", destination: "Forest Hills - 71 Av", minutesAway: 3, status: "En Route", mode: "subway", stopLat: 40.74957, stopLon: -73.98795, arrivalTs: ts(minutesFromNow: 3), vehicleId: "0R01", tripId: "T039", stopId: "R17N")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "Downtown",
                        directionLabel: "Bay Ridge - 95 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "R", stopName: "34 St-Herald Sq", direction: "Downtown", destination: "Bay Ridge - 95 St", minutesAway: 5, status: "En Route", mode: "subway", stopLat: 40.74957, stopLon: -73.98795, arrivalTs: ts(minutesFromNow: 5), vehicleId: "0R02", tripId: "T040", stopId: "R17S")
                        ]
                    )
                ]
            ),

            // ── L at 8 Av (L01) ──
            GroupedNearbyTransitResponse(
                routeId: "L",
                displayName: "L",
                mode: "subway",
                colorHex: "#A7A9AC",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "Brooklyn",
                        directionLabel: "Canarsie - Rockaway Pkwy",
                        arrivals: [
                            NearbyTransitResponse(routeId: "L", stopName: "8 Av", direction: "Brooklyn", destination: "Canarsie - Rockaway Pkwy", minutesAway: 2, status: "Approaching", mode: "subway", stopLat: 40.73984, stopLon: -73.99959, arrivalTs: ts(minutesFromNow: 2), vehicleId: "0L01", tripId: "T041", stopId: "L01N"),
                            NearbyTransitResponse(routeId: "L", stopName: "8 Av", direction: "Brooklyn", destination: "Canarsie - Rockaway Pkwy", minutesAway: 5, status: "En Route", mode: "subway", stopLat: 40.73984, stopLon: -73.99959, arrivalTs: ts(minutesFromNow: 5), vehicleId: "0L02", tripId: "T042", stopId: "L01N"),
                            NearbyTransitResponse(routeId: "L", stopName: "8 Av", direction: "Brooklyn", destination: "Canarsie - Rockaway Pkwy", minutesAway: 8, status: "En Route", mode: "subway", stopLat: 40.73984, stopLon: -73.99959, arrivalTs: ts(minutesFromNow: 8), vehicleId: "0L03", tripId: "T043", stopId: "L01N")
                        ]
                    )
                ]
            ),

            // ── Bus: M34A SBS ──
            GroupedNearbyTransitResponse(
                routeId: "MTA NYCT_M34A-SBS",
                displayName: "M34A-SBS",
                mode: "bus",
                colorHex: "#0039A6",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "East",
                        directionLabel: "Waterside via 34 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "MTA NYCT_M34A-SBS", stopName: "W 34 ST/8 AV", direction: "East", destination: "Waterside via 34 St", minutesAway: 2, status: "Approaching", mode: "bus", stopLat: 40.75260, stopLon: -73.99930, arrivalTs: ts(minutesFromNow: 2), vehicleId: "B101", tripId: "BT01", stopId: "401517"),
                            NearbyTransitResponse(routeId: "MTA NYCT_M34A-SBS", stopName: "W 34 ST/8 AV", direction: "East", destination: "Waterside via 34 St", minutesAway: 10, status: "En Route", mode: "bus", stopLat: 40.75260, stopLon: -73.99930, arrivalTs: ts(minutesFromNow: 10), vehicleId: "B102", tripId: "BT02", stopId: "401517")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "West",
                        directionLabel: "Javits Center via 34 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "MTA NYCT_M34A-SBS", stopName: "W 34 ST/8 AV", direction: "West", destination: "Javits Center via 34 St", minutesAway: 7, status: "En Route", mode: "bus", stopLat: 40.75260, stopLon: -73.99930, arrivalTs: ts(minutesFromNow: 7), vehicleId: "B103", tripId: "BT03", stopId: "401518")
                        ]
                    )
                ]
            ),

            // ── Bus: M20 ──
            GroupedNearbyTransitResponse(
                routeId: "MTA NYCT_M20",
                displayName: "M20",
                mode: "bus",
                colorHex: "#0039A6",
                directions: [
                    DirectionArrivalsResponse(
                        direction: "South",
                        directionLabel: "South via 8 Av / Hudson St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "MTA NYCT_M20", stopName: "8 AV/W 35 ST", direction: "South", destination: "South via 8 Av / Hudson St", minutesAway: 4, status: "En Route", mode: "bus", stopLat: 40.75340, stopLon: -73.99970, arrivalTs: ts(minutesFromNow: 4), vehicleId: "B201", tripId: "BT04", stopId: "401540"),
                            NearbyTransitResponse(routeId: "MTA NYCT_M20", stopName: "8 AV/W 35 ST", direction: "South", destination: "South via 8 Av / Hudson St", minutesAway: 15, status: "En Route", mode: "bus", stopLat: 40.75340, stopLon: -73.99970, arrivalTs: ts(minutesFromNow: 15), vehicleId: "B202", tripId: "BT05", stopId: "401540")
                        ]
                    )
                ]
            ),

            // ── Bus: M42 ──
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
                            NearbyTransitResponse(routeId: "MTA NYCT_M42", stopName: "W 42 ST/8 AV", direction: "East", destination: "East via 42 St", minutesAway: 6, status: "En Route", mode: "bus", stopLat: 40.75730, stopLon: -73.99000, arrivalTs: ts(minutesFromNow: 6), vehicleId: "B301", tripId: "BT06", stopId: "400901")
                        ]
                    ),
                    DirectionArrivalsResponse(
                        direction: "West",
                        directionLabel: "West via 42 St",
                        arrivals: [
                            NearbyTransitResponse(routeId: "MTA NYCT_M42", stopName: "W 42 ST/8 AV", direction: "West", destination: "West via 42 St", minutesAway: 9, status: "En Route", mode: "bus", stopLat: 40.75730, stopLon: -73.99000, arrivalTs: ts(minutesFromNow: 9), vehicleId: "B302", tripId: "BT07", stopId: "400902")
                        ]
                    )
                ]
            ),
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

    /// Mock service alerts for subway, bus, LIRR, and MNR lines.
    static func alerts() -> [TransitAlert] {
        [
            TransitAlert(
                routeId: "A",
                title: "Planned Work: A/C Lines",
                description: "Uptown A and C trains are running express from 59 St-Columbus Circle to 125 St due to weekend maintenance. Allow extra travel time.",
                severity: "moderate",
                mode: "subway",
                updatedAt: Int(Date().timeIntervalSince1970),
                affectedRoutes: ["A", "C"]
            ),
            TransitAlert(
                routeId: "7",
                title: "Service Change: 7 Line",
                description: "7 trains are running with delays due to signal problems at Queensboro Plaza. Expect 5-10 minute delays in both directions.",
                severity: "severe",
                mode: "subway",
                updatedAt: Int(Date().timeIntervalSince1970) - 1800,
                affectedRoutes: ["7"]
            ),
            TransitAlert(
                routeId: "F",
                title: "Delays: F Train",
                description: "Southbound F trains are experiencing delays due to a train with mechanical problems at 34 St-Herald Sq.",
                severity: "moderate",
                mode: "subway",
                updatedAt: Int(Date().timeIntervalSince1970) - 600,
                affectedRoutes: ["F"]
            ),
            TransitAlert(
                routeId: "MTA NYCT_M34A-SBS",
                title: "Detour: M34A-SBS",
                description: "Due to road construction, M34A-SBS buses are detoured via 33 St between 7 Av and 8 Av. Allow additional travel time.",
                severity: "moderate",
                mode: "bus",
                updatedAt: Int(Date().timeIntervalSince1970) - 3600,
                affectedRoutes: ["MTA NYCT_M34A-SBS"]
            ),
            TransitAlert(
                routeId: "LIRR_9",
                title: "LIRR: Babylon Branch Delays",
                description: "Babylon branch trains are experiencing 10-15 minute delays due to switch problems east of Jamaica. Hempstead and Far Rockaway branches are also affected. Check schedules before traveling.",
                severity: "severe",
                mode: "lirr",
                updatedAt: Int(Date().timeIntervalSince1970) - 900,
                affectedRoutes: ["LIRR_9", "LIRR_8", "LIRR_7"]
            ),
            TransitAlert(
                routeId: "MNR_1",
                title: "Metro-North: Hudson Line Service Advisory",
                description: "Due to bridge maintenance near Croton-Harmon, some Hudson Line trains will be replaced with shuttle bus service between Croton-Harmon and Peekskill this evening after 9 PM.",
                severity: "moderate",
                mode: "mnr",
                updatedAt: Int(Date().timeIntervalSince1970) - 2400,
                affectedRoutes: ["MNR_1"]
            ),
            TransitAlert(
                routeId: "1",
                title: "Planned Work: 1/2/3 Lines — Weekend",
                description: "No 2 or 3 trains between 14 St and Chambers St this weekend. Take the 1 train or A/C trains as alternatives. Service resumes Monday at 5 AM.",
                severity: "moderate",
                mode: "subway",
                updatedAt: Int(Date().timeIntervalSince1970) - 5400,
                affectedRoutes: ["1", "2", "3"]
            ),
        ]
    }

    // MARK: - Subway Arrivals

    /// Mock subway arrivals for a given line.
    static func subwayArrivals(lineID: String) -> [TrainArrival] {
        let now = Date()
        // Map line IDs to their nearest station for the mock location
        let stationInfo: (id: String, name: String) = {
            switch lineID.uppercased() {
            case "1", "2", "3":     return ("128", "34 St-Penn Station")
            case "A", "C", "E":     return ("A28", "34 St-Penn Station")
            case "7":               return ("726", "34 St-Hudson Yards")
            case "B", "D", "F", "M": return ("D17", "34 St-Herald Sq")
            case "N", "Q", "R", "W": return ("R17", "34 St-Herald Sq")
            case "L":               return ("L01", "8 Av")
            default:                return ("128", "34 St-Penn Station")
            }
        }()

        let destinations: (up: String, down: String) = {
            switch lineID.uppercased() {
            case "1": return ("Van Cortlandt Park - 242 St", "South Ferry")
            case "2": return ("Wakefield - 241 St", "Flatbush Av - Brooklyn College")
            case "3": return ("Harlem - 148 St", "New Lots Av")
            case "A": return ("Inwood - 207 St", "Far Rockaway - Mott Av")
            case "C": return ("168 St", "Euclid Av")
            case "E": return ("Jamaica Center - Parsons/Archer", "World Trade Center")
            case "7": return ("Flushing - Main St", "34 St-Hudson Yards")
            case "B": return ("Bedford Park Blvd", "Brighton Beach")
            case "D": return ("Norwood - 205 St", "Coney Island - Stillwell Av")
            case "F": return ("Jamaica - 179 St", "Coney Island - Stillwell Av")
            case "M": return ("Middle Village - Metropolitan Av", "Bay Pkwy")
            case "N": return ("Astoria - Ditmars Blvd", "Coney Island - Stillwell Av")
            case "Q": return ("96 St", "Coney Island - Stillwell Av")
            case "R": return ("Forest Hills - 71 Av", "Bay Ridge - 95 St")
            case "W": return ("Astoria - Ditmars Blvd", "Whitehall St")
            case "L": return ("8 Av", "Canarsie - Rockaway Pkwy")
            default:  return ("Uptown", "Downtown")
            }
        }()

        return [
            TrainArrival(routeID: lineID, stationID: stationInfo.id, stationName: stationInfo.name, direction: "Uptown", scheduledTime: now.addingTimeInterval(120), estimatedTime: now.addingTimeInterval(120), minutesAway: 2, destination: destinations.up, status: "Approaching", tripId: "MOCK_\(lineID)_1"),
            TrainArrival(routeID: lineID, stationID: stationInfo.id, stationName: stationInfo.name, direction: "Uptown", scheduledTime: now.addingTimeInterval(420), estimatedTime: now.addingTimeInterval(420), minutesAway: 7, destination: destinations.up, status: "En Route", tripId: "MOCK_\(lineID)_2"),
            TrainArrival(routeID: lineID, stationID: stationInfo.id, stationName: stationInfo.name, direction: "Uptown", scheduledTime: now.addingTimeInterval(780), estimatedTime: now.addingTimeInterval(780), minutesAway: 13, destination: destinations.up, status: "En Route", tripId: "MOCK_\(lineID)_5"),
            TrainArrival(routeID: lineID, stationID: stationInfo.id, stationName: stationInfo.name, direction: "Downtown", scheduledTime: now.addingTimeInterval(240), estimatedTime: now.addingTimeInterval(240), minutesAway: 4, destination: destinations.down, status: "En Route", tripId: "MOCK_\(lineID)_3"),
            TrainArrival(routeID: lineID, stationID: stationInfo.id, stationName: stationInfo.name, direction: "Downtown", scheduledTime: now.addingTimeInterval(600), estimatedTime: now.addingTimeInterval(600), minutesAway: 10, destination: destinations.down, status: "En Route", tripId: "MOCK_\(lineID)_4"),
        ]
    }

    // MARK: - Accessibility

    /// Mock elevator/escalator outage data.
    static func accessibility() -> [ElevatorStatus] {
        [
            ElevatorStatus(station: "34 St-Penn Station", equipmentType: "Elevator", description: "Elevator EL320 out of service - 8th Av to mezzanine. Use 7th Av entrance.", outageSince: "2026-02-18T09:00:00"),
            ElevatorStatus(station: "34 St-Herald Sq", equipmentType: "Escalator", description: "Escalator ES105 out of service - B/D/F/M platform to mezzanine", outageSince: "2026-02-19T14:30:00"),
            ElevatorStatus(station: "Times Sq-42 St", equipmentType: "Elevator", description: "Elevator EL201 out of service - street to N/Q/R/W platform", outageSince: "2026-02-20T08:00:00")
        ]
    }

    // MARK: - Subway Stations

    /// All 496 subway stations from the Track API (/subway/stations/all).
    /// Each station includes its ID, name, coordinates, and serving routes.
    static func subwayStations() -> AllSubwayStationsResponse {
        AllSubwayStationsResponse(stations: [
            SubwayStation(id: "101", name: "Van Cortlandt Park-242 St", lat: 40.889248, lon: -73.898583, routes: ["1"]),
            SubwayStation(id: "103", name: "238 St", lat: 40.884667, lon: -73.90087, routes: ["1"]),
            SubwayStation(id: "104", name: "231 St", lat: 40.878856, lon: -73.904834, routes: ["1"]),
            SubwayStation(id: "106", name: "Marble Hill-225 St", lat: 40.874561, lon: -73.909831, routes: ["1"]),
            SubwayStation(id: "107", name: "215 St", lat: 40.869444, lon: -73.915279, routes: ["1"]),
            SubwayStation(id: "108", name: "207 St", lat: 40.864621, lon: -73.918822, routes: ["1"]),
            SubwayStation(id: "109", name: "Dyckman St", lat: 40.860531, lon: -73.925536, routes: ["1"]),
            SubwayStation(id: "110", name: "191 St", lat: 40.855225, lon: -73.929412, routes: ["1"]),
            SubwayStation(id: "111", name: "181 St", lat: 40.849505, lon: -73.933596, routes: ["1"]),
            SubwayStation(id: "112", name: "168 St-Washington Hts", lat: 40.840556, lon: -73.940133, routes: ["1"]),
            SubwayStation(id: "113", name: "157 St", lat: 40.834041, lon: -73.94489, routes: ["1"]),
            SubwayStation(id: "114", name: "145 St", lat: 40.826551, lon: -73.95036, routes: ["1"]),
            SubwayStation(id: "115", name: "137 St-City College", lat: 40.822008, lon: -73.953676, routes: ["1"]),
            SubwayStation(id: "116", name: "125 St", lat: 40.815581, lon: -73.958372, routes: ["1"]),
            SubwayStation(id: "117", name: "116 St-Columbia University", lat: 40.807722, lon: -73.96411, routes: ["1"]),
            SubwayStation(id: "118", name: "Cathedral Pkwy (110 St)", lat: 40.803967, lon: -73.966847, routes: ["1"]),
            SubwayStation(id: "119", name: "103 St", lat: 40.799446, lon: -73.968379, routes: ["1"]),
            SubwayStation(id: "120", name: "96 St", lat: 40.793919, lon: -73.972323, routes: ["1", "2", "3"]),
            SubwayStation(id: "121", name: "86 St", lat: 40.788644, lon: -73.976218, routes: ["1", "2"]),
            SubwayStation(id: "122", name: "79 St", lat: 40.783934, lon: -73.979917, routes: ["1", "2"]),
            SubwayStation(id: "123", name: "72 St", lat: 40.778453, lon: -73.98197, routes: ["1", "2", "3"]),
            SubwayStation(id: "124", name: "66 St-Lincoln Center", lat: 40.77344, lon: -73.982209, routes: ["1", "2"]),
            SubwayStation(id: "125", name: "59 St-Columbus Circle", lat: 40.768247, lon: -73.981929, routes: ["1", "2"]),
            SubwayStation(id: "126", name: "50 St", lat: 40.761728, lon: -73.983849, routes: ["1", "2"]),
            SubwayStation(id: "127", name: "Times Sq-42 St", lat: 40.75529, lon: -73.987495, routes: ["1", "2", "3"]),
            SubwayStation(id: "128", name: "34 St-Penn Station", lat: 40.750373, lon: -73.991057, routes: ["1", "2", "3"]),
            SubwayStation(id: "129", name: "28 St", lat: 40.747215, lon: -73.993365, routes: ["1", "2"]),
            SubwayStation(id: "130", name: "23 St", lat: 40.744081, lon: -73.995657, routes: ["1", "2"]),
            SubwayStation(id: "131", name: "18 St", lat: 40.74104, lon: -73.997871, routes: ["1", "2"]),
            SubwayStation(id: "132", name: "14 St", lat: 40.737826, lon: -74.000201, routes: ["1", "2", "3"]),
            SubwayStation(id: "133", name: "Christopher St-Stonewall", lat: 40.733422, lon: -74.002906, routes: ["1", "2"]),
            SubwayStation(id: "134", name: "Houston St", lat: 40.728251, lon: -74.005367, routes: ["1", "2"]),
            SubwayStation(id: "135", name: "Canal St", lat: 40.722854, lon: -74.006277, routes: ["1", "2"]),
            SubwayStation(id: "136", name: "Franklin St", lat: 40.719318, lon: -74.006886, routes: ["1", "2"]),
            SubwayStation(id: "137", name: "Chambers St", lat: 40.715478, lon: -74.009266, routes: ["1", "2", "3"]),
            SubwayStation(id: "138", name: "WTC Cortlandt", lat: 40.711835, lon: -74.012188, routes: ["1"]),
            SubwayStation(id: "139", name: "Rector St", lat: 40.707513, lon: -74.013783, routes: ["1"]),
            SubwayStation(id: "142", name: "South Ferry", lat: 40.702068, lon: -74.013664, routes: ["1"]),
            SubwayStation(id: "201", name: "Wakefield-241 St", lat: 40.903125, lon: -73.85062, routes: ["2"]),
            SubwayStation(id: "204", name: "Nereid Av", lat: 40.898379, lon: -73.854376, routes: ["2", "5"]),
            SubwayStation(id: "205", name: "233 St", lat: 40.893193, lon: -73.857473, routes: ["2", "5"]),
            SubwayStation(id: "206", name: "225 St", lat: 40.888022, lon: -73.860341, routes: ["2", "5"]),
            SubwayStation(id: "207", name: "219 St", lat: 40.883895, lon: -73.862633, routes: ["2", "5"]),
            SubwayStation(id: "208", name: "Gun Hill Rd", lat: 40.87785, lon: -73.866256, routes: ["2", "5"]),
            SubwayStation(id: "209", name: "Burke Av", lat: 40.871356, lon: -73.867164, routes: ["2", "5"]),
            SubwayStation(id: "210", name: "Allerton Av", lat: 40.865462, lon: -73.867352, routes: ["2", "5"]),
            SubwayStation(id: "211", name: "Pelham Pkwy", lat: 40.857192, lon: -73.867615, routes: ["2", "5"]),
            SubwayStation(id: "212", name: "Bronx Park East", lat: 40.848828, lon: -73.868457, routes: ["2", "5"]),
            SubwayStation(id: "213", name: "E 180 St", lat: 40.841894, lon: -73.873488, routes: ["2", "5"]),
            SubwayStation(id: "214", name: "West Farms Sq-E Tremont Av", lat: 40.840295, lon: -73.880049, routes: ["2", "5"]),
            SubwayStation(id: "215", name: "174 St", lat: 40.837288, lon: -73.887734, routes: ["2", "5"]),
            SubwayStation(id: "216", name: "Freeman St", lat: 40.829993, lon: -73.891865, routes: ["2", "5"]),
            SubwayStation(id: "217", name: "Simpson St", lat: 40.824073, lon: -73.893064, routes: ["2", "5"]),
            SubwayStation(id: "218", name: "Intervale Av", lat: 40.822181, lon: -73.896736, routes: ["2", "5"]),
            SubwayStation(id: "219", name: "Prospect Av", lat: 40.819585, lon: -73.90177, routes: ["2", "5"]),
            SubwayStation(id: "220", name: "Jackson Av", lat: 40.81649, lon: -73.907807, routes: ["2", "5"]),
            SubwayStation(id: "221", name: "3 Av-149 St", lat: 40.816109, lon: -73.917757, routes: ["2", "5"]),
            SubwayStation(id: "222", name: "149 St-Grand Concourse", lat: 40.81841, lon: -73.926718, routes: ["2", "5"]),
            SubwayStation(id: "224", name: "135 St", lat: 40.814229, lon: -73.94077, routes: ["2", "3"]),
            SubwayStation(id: "225", name: "125 St", lat: 40.807754, lon: -73.945495, routes: ["2", "3"]),
            SubwayStation(id: "226", name: "116 St", lat: 40.802098, lon: -73.949625, routes: ["2", "3"]),
            SubwayStation(id: "227", name: "110 St-Malcolm X Plaza", lat: 40.799075, lon: -73.951822, routes: ["2", "3"]),
            SubwayStation(id: "228", name: "Park Place", lat: 40.713051, lon: -74.008811, routes: ["2", "3"]),
            SubwayStation(id: "229", name: "Fulton St", lat: 40.709416, lon: -74.006571, routes: ["2", "3"]),
            SubwayStation(id: "230", name: "Wall St", lat: 40.706821, lon: -74.0091, routes: ["2", "3"]),
            SubwayStation(id: "231", name: "Clark St", lat: 40.697466, lon: -73.993086, routes: ["2", "3"]),
            SubwayStation(id: "232", name: "Borough Hall", lat: 40.693219, lon: -73.989998, routes: ["2", "3"]),
            SubwayStation(id: "233", name: "Hoyt St", lat: 40.690545, lon: -73.985065, routes: ["2", "3"]),
            SubwayStation(id: "234", name: "Nevins St", lat: 40.688246, lon: -73.980492, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "235", name: "Atlantic Av-Barclays Ctr", lat: 40.684359, lon: -73.977666, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "236", name: "Bergen St", lat: 40.680829, lon: -73.975098, routes: ["2", "3", "4"]),
            SubwayStation(id: "237", name: "Grand Army Plaza", lat: 40.675235, lon: -73.971046, routes: ["2", "3", "4"]),
            SubwayStation(id: "238", name: "Eastern Pkwy-Brooklyn Museum", lat: 40.671987, lon: -73.964375, routes: ["2", "3", "4"]),
            SubwayStation(id: "239", name: "Franklin Av-Medgar Evers College", lat: 40.670682, lon: -73.958131, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "241", name: "President St-Medgar Evers College", lat: 40.667883, lon: -73.950683, routes: ["2", "5"]),
            SubwayStation(id: "242", name: "Sterling St", lat: 40.662742, lon: -73.95085, routes: ["2", "5"]),
            SubwayStation(id: "243", name: "Winthrop St", lat: 40.656652, lon: -73.9502, routes: ["2", "5"]),
            SubwayStation(id: "244", name: "Church Av", lat: 40.650843, lon: -73.949575, routes: ["2", "5"]),
            SubwayStation(id: "245", name: "Beverly Rd", lat: 40.645098, lon: -73.948959, routes: ["2", "5"]),
            SubwayStation(id: "246", name: "Newkirk Av-Little Haiti", lat: 40.639967, lon: -73.948411, routes: ["2", "5"]),
            SubwayStation(id: "247", name: "Flatbush Av-Brooklyn College", lat: 40.632836, lon: -73.947642, routes: ["2", "5"]),
            SubwayStation(id: "248", name: "Nostrand Av", lat: 40.669847, lon: -73.950466, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "249", name: "Kingston Av", lat: 40.669399, lon: -73.942161, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "250", name: "Crown Hts-Utica Av", lat: 40.668897, lon: -73.932942, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "251", name: "Sutter Av-Rutland Rd", lat: 40.664717, lon: -73.92261, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "252", name: "Saratoga Av", lat: 40.661453, lon: -73.916327, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "253", name: "Rockaway Av", lat: 40.662549, lon: -73.908946, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "254", name: "Junius St", lat: 40.663515, lon: -73.902447, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "255", name: "Pennsylvania Av", lat: 40.664635, lon: -73.894895, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "256", name: "Van Siclen Av", lat: 40.665449, lon: -73.889395, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "257", name: "New Lots Av", lat: 40.666235, lon: -73.884079, routes: ["2", "3", "4", "5"]),
            SubwayStation(id: "401", name: "Woodlawn", lat: 40.886037, lon: -73.878751, routes: ["4"]),
            SubwayStation(id: "402", name: "Mosholu Pkwy", lat: 40.87975, lon: -73.884655, routes: ["4"]),
            SubwayStation(id: "405", name: "Bedford Park Blvd-Lehman College", lat: 40.873412, lon: -73.890064, routes: ["4"]),
            SubwayStation(id: "406", name: "Kingsbridge Rd", lat: 40.86776, lon: -73.897174, routes: ["4"]),
            SubwayStation(id: "407", name: "Fordham Rd", lat: 40.862803, lon: -73.901034, routes: ["4"]),
            SubwayStation(id: "408", name: "183 St", lat: 40.858407, lon: -73.903879, routes: ["4"]),
            SubwayStation(id: "409", name: "Burnside Av", lat: 40.853453, lon: -73.907684, routes: ["4"]),
            SubwayStation(id: "410", name: "176 St", lat: 40.84848, lon: -73.911794, routes: ["4"]),
            SubwayStation(id: "411", name: "Mt Eden Av", lat: 40.844434, lon: -73.914685, routes: ["4"]),
            SubwayStation(id: "412", name: "170 St", lat: 40.840075, lon: -73.917791, routes: ["4"]),
            SubwayStation(id: "413", name: "167 St", lat: 40.835537, lon: -73.9214, routes: ["4"]),
            SubwayStation(id: "414", name: "161 St-Yankee Stadium", lat: 40.827994, lon: -73.925831, routes: ["4"]),
            SubwayStation(id: "415", name: "149 St-Grand Concourse", lat: 40.818375, lon: -73.927351, routes: ["4"]),
            SubwayStation(id: "416", name: "138 St-Grand Concourse", lat: 40.813224, lon: -73.929849, routes: ["4", "5"]),
            SubwayStation(id: "621", name: "125 St", lat: 40.804138, lon: -73.937594, routes: ["4", "5", "6", "6X"]),
            SubwayStation(id: "622", name: "116 St", lat: 40.798629, lon: -73.941617, routes: ["4", "6", "6X"]),
            SubwayStation(id: "623", name: "110 St", lat: 40.79502, lon: -73.94425, routes: ["4", "6", "6X"]),
            SubwayStation(id: "624", name: "103 St", lat: 40.7906, lon: -73.947478, routes: ["4", "6", "6X"]),
            SubwayStation(id: "625", name: "96 St", lat: 40.785672, lon: -73.95107, routes: ["4", "6", "6X"]),
            SubwayStation(id: "626", name: "86 St", lat: 40.779492, lon: -73.955589, routes: ["4", "5", "6", "6X"]),
            SubwayStation(id: "627", name: "77 St", lat: 40.77362, lon: -73.959874, routes: ["4", "6", "6X"]),
            SubwayStation(id: "628", name: "68 St-Hunter College", lat: 40.768141, lon: -73.96387, routes: ["4", "6", "6X"]),
            SubwayStation(id: "629", name: "59 St", lat: 40.762526, lon: -73.967967, routes: ["4", "5", "6", "6X"]),
            SubwayStation(id: "630", name: "51 St", lat: 40.757107, lon: -73.97192, routes: ["4", "6", "6X"]),
            SubwayStation(id: "631", name: "Grand Central-42 St", lat: 40.751776, lon: -73.976848, routes: ["4", "5", "6", "6X"]),
            SubwayStation(id: "632", name: "33 St", lat: 40.746081, lon: -73.982076, routes: ["4", "6", "6X"]),
            SubwayStation(id: "633", name: "28 St", lat: 40.74307, lon: -73.984264, routes: ["4", "6", "6X"]),
            SubwayStation(id: "634", name: "23 St-Baruch College", lat: 40.739864, lon: -73.986599, routes: ["4", "6", "6X"]),
            SubwayStation(id: "635", name: "14 St-Union Sq", lat: 40.734673, lon: -73.989951, routes: ["4", "5", "6", "6X"]),
            SubwayStation(id: "636", name: "Astor Pl", lat: 40.730054, lon: -73.99107, routes: ["4", "6", "6X"]),
            SubwayStation(id: "637", name: "Bleecker St", lat: 40.725915, lon: -73.994659, routes: ["4", "6", "6X"]),
            SubwayStation(id: "638", name: "Spring St", lat: 40.722301, lon: -73.997141, routes: ["4", "6", "6X"]),
            SubwayStation(id: "639", name: "Canal St", lat: 40.718803, lon: -74.000193, routes: ["4", "6", "6X"]),
            SubwayStation(id: "640", name: "Brooklyn Bridge-City Hall", lat: 40.713065, lon: -74.004131, routes: ["4", "5", "6", "6X"]),
            SubwayStation(id: "418", name: "Fulton St", lat: 40.710368, lon: -74.009509, routes: ["4", "5"]),
            SubwayStation(id: "419", name: "Wall St", lat: 40.707557, lon: -74.011862, routes: ["4", "5"]),
            SubwayStation(id: "420", name: "Bowling Green", lat: 40.704817, lon: -74.014065, routes: ["4", "5"]),
            SubwayStation(id: "423", name: "Borough Hall", lat: 40.692404, lon: -73.990151, routes: ["4", "5"]),
            SubwayStation(id: "501", name: "Eastchester-Dyre Av", lat: 40.8883, lon: -73.830834, routes: ["5"]),
            SubwayStation(id: "502", name: "Baychester Av", lat: 40.878663, lon: -73.838591, routes: ["5"]),
            SubwayStation(id: "503", name: "Gun Hill Rd", lat: 40.869526, lon: -73.846384, routes: ["5"]),
            SubwayStation(id: "504", name: "Pelham Pkwy", lat: 40.858985, lon: -73.855359, routes: ["5"]),
            SubwayStation(id: "505", name: "Morris Park", lat: 40.854364, lon: -73.860495, routes: ["5"]),
            SubwayStation(id: "601", name: "Pelham Bay Park", lat: 40.852462, lon: -73.828121, routes: ["6", "6X"]),
            SubwayStation(id: "602", name: "Buhre Av", lat: 40.84681, lon: -73.832569, routes: ["6", "6X"]),
            SubwayStation(id: "603", name: "Middletown Rd", lat: 40.843863, lon: -73.836322, routes: ["6", "6X"]),
            SubwayStation(id: "604", name: "Westchester Sq-E Tremont Av", lat: 40.839892, lon: -73.842952, routes: ["6", "6X"]),
            SubwayStation(id: "606", name: "Zerega Av", lat: 40.836488, lon: -73.847036, routes: ["6", "6X"]),
            SubwayStation(id: "607", name: "Castle Hill Av", lat: 40.834255, lon: -73.851222, routes: ["6", "6X"]),
            SubwayStation(id: "608", name: "Parkchester", lat: 40.833226, lon: -73.860816, routes: ["6", "6X"]),
            SubwayStation(id: "609", name: "St Lawrence Av", lat: 40.831509, lon: -73.867618, routes: ["6"]),
            SubwayStation(id: "610", name: "Morrison Av-Soundview", lat: 40.829521, lon: -73.874516, routes: ["6"]),
            SubwayStation(id: "611", name: "Elder Av", lat: 40.828584, lon: -73.879159, routes: ["6"]),
            SubwayStation(id: "612", name: "Whitlock Av", lat: 40.826525, lon: -73.886283, routes: ["6"]),
            SubwayStation(id: "613", name: "Hunts Point Av", lat: 40.820948, lon: -73.890549, routes: ["6", "6X"]),
            SubwayStation(id: "614", name: "Longwood Av", lat: 40.816104, lon: -73.896435, routes: ["6"]),
            SubwayStation(id: "615", name: "E 149 St", lat: 40.812118, lon: -73.904098, routes: ["6"]),
            SubwayStation(id: "616", name: "E 143 St-St Mary's St", lat: 40.808719, lon: -73.907657, routes: ["6"]),
            SubwayStation(id: "617", name: "Cypress Av", lat: 40.805368, lon: -73.914042, routes: ["6"]),
            SubwayStation(id: "618", name: "Brook Av", lat: 40.807566, lon: -73.91924, routes: ["6"]),
            SubwayStation(id: "619", name: "3 Av-138 St", lat: 40.810476, lon: -73.926138, routes: ["6", "6X"]),
            SubwayStation(id: "701", name: "Flushing-Main St", lat: 40.7596, lon: -73.83003, routes: ["7", "7X"]),
            SubwayStation(id: "702", name: "Mets-Willets Point", lat: 40.754622, lon: -73.845625, routes: ["7", "7X"]),
            SubwayStation(id: "705", name: "111 St", lat: 40.75173, lon: -73.855334, routes: ["7"]),
            SubwayStation(id: "706", name: "103 St-Corona Plaza", lat: 40.749865, lon: -73.8627, routes: ["7"]),
            SubwayStation(id: "707", name: "Junction Blvd", lat: 40.749145, lon: -73.869527, routes: ["7", "7X"]),
            SubwayStation(id: "708", name: "90 St-Elmhurst Av", lat: 40.748408, lon: -73.876613, routes: ["7"]),
            SubwayStation(id: "709", name: "82 St-Jackson Hts", lat: 40.747659, lon: -73.883697, routes: ["7"]),
            SubwayStation(id: "710", name: "74 St-Broadway", lat: 40.746848, lon: -73.891394, routes: ["7", "7X"]),
            SubwayStation(id: "712", name: "61 St-Woodside", lat: 40.74563, lon: -73.902984, routes: ["7", "7X"]),
            SubwayStation(id: "714", name: "46 St-Bliss St", lat: 40.743132, lon: -73.918435, routes: ["7", "7X"]),
            SubwayStation(id: "715", name: "40 St-Lowery St", lat: 40.743781, lon: -73.924016, routes: ["7", "7X"]),
            SubwayStation(id: "716", name: "33 St-Rawson St", lat: 40.744587, lon: -73.930997, routes: ["7", "7X"]),
            SubwayStation(id: "718", name: "Queensboro Plaza", lat: 40.750582, lon: -73.940202, routes: ["7", "7X"]),
            SubwayStation(id: "719", name: "Court Sq", lat: 40.747023, lon: -73.945264, routes: ["7", "7X"]),
            SubwayStation(id: "720", name: "Hunters Point Av", lat: 40.742216, lon: -73.948916, routes: ["7", "7X"]),
            SubwayStation(id: "721", name: "Vernon Blvd-Jackson Av", lat: 40.742626, lon: -73.953581, routes: ["7", "7X"]),
            SubwayStation(id: "723", name: "Grand Central-42 St", lat: 40.751431, lon: -73.976041, routes: ["7", "7X"]),
            SubwayStation(id: "724", name: "5 Av", lat: 40.753821, lon: -73.981963, routes: ["7", "7X"]),
            SubwayStation(id: "725", name: "Times Sq-42 St", lat: 40.755477, lon: -73.987691, routes: ["7", "7X"]),
            SubwayStation(id: "726", name: "34 St-Hudson Yards", lat: 40.755882, lon: -74.00191, routes: ["7", "7X"]),
            SubwayStation(id: "713", name: "52 St", lat: 40.744149, lon: -73.912549, routes: ["7", "7X"]),
            SubwayStation(id: "711", name: "69 St", lat: 40.746325, lon: -73.896403, routes: ["7", "7X"]),
            SubwayStation(id: "901", name: "Grand Central-42 St", lat: 40.752769, lon: -73.979189, routes: ["GS"]),
            SubwayStation(id: "902", name: "Times Sq-42 St", lat: 40.755983, lon: -73.986229, routes: ["GS"]),
            SubwayStation(id: "A02", name: "Inwood-207 St", lat: 40.868072, lon: -73.919899, routes: ["A"]),
            SubwayStation(id: "A03", name: "Dyckman St", lat: 40.865491, lon: -73.927271, routes: ["A"]),
            SubwayStation(id: "A05", name: "190 St", lat: 40.859022, lon: -73.93418, routes: ["A"]),
            SubwayStation(id: "A06", name: "181 St", lat: 40.851695, lon: -73.937969, routes: ["A"]),
            SubwayStation(id: "A07", name: "175 St", lat: 40.847391, lon: -73.939704, routes: ["A"]),
            SubwayStation(id: "A09", name: "168 St", lat: 40.840719, lon: -73.939561, routes: ["A", "C"]),
            SubwayStation(id: "A10", name: "163 St-Amsterdam Av", lat: 40.836013, lon: -73.939892, routes: ["A", "C"]),
            SubwayStation(id: "A11", name: "155 St", lat: 40.830518, lon: -73.941514, routes: ["A", "C"]),
            SubwayStation(id: "A12", name: "145 St", lat: 40.824783, lon: -73.944216, routes: ["A", "C"]),
            SubwayStation(id: "A14", name: "135 St", lat: 40.817894, lon: -73.947649, routes: ["A", "B", "C"]),
            SubwayStation(id: "A15", name: "125 St", lat: 40.811109, lon: -73.952343, routes: ["A", "B", "C", "D"]),
            SubwayStation(id: "A16", name: "116 St", lat: 40.805085, lon: -73.954882, routes: ["A", "B", "C"]),
            SubwayStation(id: "A17", name: "Cathedral Pkwy (110 St)", lat: 40.800603, lon: -73.958161, routes: ["A", "B", "C"]),
            SubwayStation(id: "A18", name: "103 St", lat: 40.796092, lon: -73.961454, routes: ["A", "B", "C"]),
            SubwayStation(id: "A19", name: "96 St", lat: 40.791642, lon: -73.964696, routes: ["A", "B", "C"]),
            SubwayStation(id: "A20", name: "86 St", lat: 40.785868, lon: -73.968916, routes: ["A", "B", "C"]),
            SubwayStation(id: "A21", name: "81 St-Museum of Natural History", lat: 40.781433, lon: -73.972143, routes: ["A", "B", "C"]),
            SubwayStation(id: "A22", name: "72 St", lat: 40.775594, lon: -73.97641, routes: ["A", "B", "C"]),
            SubwayStation(id: "A24", name: "59 St-Columbus Circle", lat: 40.768296, lon: -73.981736, routes: ["A", "B", "C", "D"]),
            SubwayStation(id: "A25", name: "50 St", lat: 40.762456, lon: -73.985984, routes: ["A", "C", "E"]),
            SubwayStation(id: "A27", name: "42 St-Port Authority Bus Terminal", lat: 40.757308, lon: -73.989735, routes: ["A", "C", "E"]),
            SubwayStation(id: "A28", name: "34 St-Penn Station", lat: 40.752287, lon: -73.993391, routes: ["A", "C", "E"]),
            SubwayStation(id: "A30", name: "23 St", lat: 40.745906, lon: -73.998041, routes: ["A", "C", "E"]),
            SubwayStation(id: "A31", name: "14 St", lat: 40.740893, lon: -74.00169, routes: ["A", "C", "E"]),
            SubwayStation(id: "A32", name: "W 4 St-Wash Sq", lat: 40.732338, lon: -74.000495, routes: ["A", "C", "E"]),
            SubwayStation(id: "A33", name: "Spring St", lat: 40.726227, lon: -74.003739, routes: ["A", "C", "E"]),
            SubwayStation(id: "A34", name: "Canal St", lat: 40.720824, lon: -74.005229, routes: ["A", "C", "E"]),
            SubwayStation(id: "A36", name: "Chambers St", lat: 40.714111, lon: -74.008585, routes: ["A", "C"]),
            SubwayStation(id: "A38", name: "Fulton St", lat: 40.710197, lon: -74.007691, routes: ["A", "C"]),
            SubwayStation(id: "A40", name: "High St", lat: 40.699337, lon: -73.990531, routes: ["A", "C"]),
            SubwayStation(id: "A41", name: "Jay St-MetroTech", lat: 40.692338, lon: -73.987342, routes: ["A", "C", "F", "FX"]),
            SubwayStation(id: "A42", name: "Hoyt-Schermerhorn Sts", lat: 40.688484, lon: -73.985001, routes: ["A", "C", "G"]),
            SubwayStation(id: "A43", name: "Lafayette Av", lat: 40.686113, lon: -73.973946, routes: ["A", "C"]),
            SubwayStation(id: "A44", name: "Clinton-Washington Avs", lat: 40.683263, lon: -73.965838, routes: ["A", "C"]),
            SubwayStation(id: "A45", name: "Franklin Av", lat: 40.68138, lon: -73.956848, routes: ["A", "C"]),
            SubwayStation(id: "A46", name: "Nostrand Av", lat: 40.680438, lon: -73.950426, routes: ["A", "C"]),
            SubwayStation(id: "A47", name: "Kingston-Throop Avs", lat: 40.679921, lon: -73.940858, routes: ["A", "C"]),
            SubwayStation(id: "A48", name: "Utica Av", lat: 40.679364, lon: -73.930729, routes: ["A", "C"]),
            SubwayStation(id: "A49", name: "Ralph Av", lat: 40.678822, lon: -73.920786, routes: ["A", "C"]),
            SubwayStation(id: "A50", name: "Rockaway Av", lat: 40.67834, lon: -73.911946, routes: ["A", "C"]),
            SubwayStation(id: "A51", name: "Broadway Junction", lat: 40.678334, lon: -73.905316, routes: ["A", "C"]),
            SubwayStation(id: "A52", name: "Liberty Av", lat: 40.674542, lon: -73.896548, routes: ["A", "C"]),
            SubwayStation(id: "A53", name: "Van Siclen Av", lat: 40.67271, lon: -73.890358, routes: ["A", "C"]),
            SubwayStation(id: "A54", name: "Shepherd Av", lat: 40.67413, lon: -73.88075, routes: ["A", "C"]),
            SubwayStation(id: "A55", name: "Euclid Av", lat: 40.675377, lon: -73.872106, routes: ["A", "C"]),
            SubwayStation(id: "A57", name: "Grant Av", lat: 40.677044, lon: -73.86505, routes: ["A"]),
            SubwayStation(id: "A59", name: "80 St", lat: 40.679371, lon: -73.858992, routes: ["A"]),
            SubwayStation(id: "A60", name: "88 St", lat: 40.679843, lon: -73.85147, routes: ["A"]),
            SubwayStation(id: "A61", name: "Rockaway Blvd", lat: 40.680429, lon: -73.843853, routes: ["A"]),
            SubwayStation(id: "H02", name: "Aqueduct-N Conduit Av", lat: 40.668234, lon: -73.834058, routes: ["A"]),
            SubwayStation(id: "H03", name: "Howard Beach-JFK Airport", lat: 40.660476, lon: -73.830301, routes: ["A"]),
            SubwayStation(id: "H04", name: "Broad Channel", lat: 40.608382, lon: -73.815925, routes: ["A", "H"]),
            SubwayStation(id: "H06", name: "Beach 67 St", lat: 40.590927, lon: -73.796924, routes: ["A"]),
            SubwayStation(id: "H07", name: "Beach 60 St", lat: 40.592374, lon: -73.788522, routes: ["A"]),
            SubwayStation(id: "H08", name: "Beach 44 St", lat: 40.592943, lon: -73.776013, routes: ["A"]),
            SubwayStation(id: "H09", name: "Beach 36 St", lat: 40.595398, lon: -73.768175, routes: ["A"]),
            SubwayStation(id: "H10", name: "Beach 25 St", lat: 40.600066, lon: -73.761353, routes: ["A"]),
            SubwayStation(id: "H11", name: "Far Rockaway-Mott Av", lat: 40.603995, lon: -73.755405, routes: ["A"]),
            SubwayStation(id: "A63", name: "104 St", lat: 40.681711, lon: -73.837683, routes: ["A"]),
            SubwayStation(id: "A64", name: "111 St", lat: 40.684331, lon: -73.832163, routes: ["A"]),
            SubwayStation(id: "A65", name: "Ozone Park-Lefferts Blvd", lat: 40.685951, lon: -73.825798, routes: ["A"]),
            SubwayStation(id: "H12", name: "Beach 90 St", lat: 40.588034, lon: -73.813641, routes: ["A", "H"]),
            SubwayStation(id: "H13", name: "Beach 98 St", lat: 40.585307, lon: -73.820558, routes: ["A", "H"]),
            SubwayStation(id: "H14", name: "Beach 105 St", lat: 40.583209, lon: -73.827559, routes: ["A", "H"]),
            SubwayStation(id: "H15", name: "Rockaway Park-Beach 116 St", lat: 40.580903, lon: -73.835592, routes: ["A", "H"]),
            SubwayStation(id: "H01", name: "Aqueduct Racetrack", lat: 40.672097, lon: -73.835919, routes: ["A"]),
            SubwayStation(id: "D03", name: "Bedford Park Blvd", lat: 40.873244, lon: -73.887138, routes: ["B", "D"]),
            SubwayStation(id: "D04", name: "Kingsbridge Rd", lat: 40.866978, lon: -73.893509, routes: ["B", "D"]),
            SubwayStation(id: "D05", name: "Fordham Rd", lat: 40.861296, lon: -73.897749, routes: ["B", "D"]),
            SubwayStation(id: "D06", name: "182-183 Sts", lat: 40.856093, lon: -73.900741, routes: ["B", "D"]),
            SubwayStation(id: "D07", name: "Tremont Av", lat: 40.85041, lon: -73.905227, routes: ["B", "D"]),
            SubwayStation(id: "D08", name: "174-175 Sts", lat: 40.8459, lon: -73.910136, routes: ["B", "D"]),
            SubwayStation(id: "D09", name: "170 St", lat: 40.839306, lon: -73.9134, routes: ["B", "D"]),
            SubwayStation(id: "D10", name: "167 St", lat: 40.833771, lon: -73.91844, routes: ["B", "D"]),
            SubwayStation(id: "D11", name: "161 St-Yankee Stadium", lat: 40.827905, lon: -73.925651, routes: ["B", "D"]),
            SubwayStation(id: "D12", name: "155 St", lat: 40.830135, lon: -73.938209, routes: ["B", "D"]),
            SubwayStation(id: "D13", name: "145 St", lat: 40.824783, lon: -73.944216, routes: ["B", "D"]),
            SubwayStation(id: "D14", name: "7 Av", lat: 40.762862, lon: -73.981637, routes: ["B", "D", "E"]),
            SubwayStation(id: "D15", name: "47-50 Sts-Rockefeller Ctr", lat: 40.758663, lon: -73.981329, routes: ["B", "D", "F", "FX", "M"]),
            SubwayStation(id: "D16", name: "42 St-Bryant Pk", lat: 40.754222, lon: -73.984569, routes: ["B", "D", "F", "FX", "M"]),
            SubwayStation(id: "D17", name: "34 St-Herald Sq", lat: 40.749719, lon: -73.987823, routes: ["B", "D", "F", "FX", "M"]),
            SubwayStation(id: "D20", name: "W 4 St-Wash Sq", lat: 40.732338, lon: -74.000495, routes: ["B", "D", "F", "FX", "M"]),
            SubwayStation(id: "D21", name: "Broadway-Lafayette St", lat: 40.725297, lon: -73.996204, routes: ["B", "D", "F", "FX", "M"]),
            SubwayStation(id: "D22", name: "Grand St", lat: 40.718267, lon: -73.993753, routes: ["B", "D"]),
            SubwayStation(id: "R30", name: "DeKalb Av", lat: 40.690635, lon: -73.981824, routes: ["B", "D", "N", "Q", "R", "W"]),
            SubwayStation(id: "D24", name: "Atlantic Av-Barclays Ctr", lat: 40.68446, lon: -73.97689, routes: ["B", "Q"]),
            SubwayStation(id: "D26", name: "Prospect Park", lat: 40.661614, lon: -73.962246, routes: ["B", "FS", "Q"]),
            SubwayStation(id: "D28", name: "Church Av", lat: 40.650527, lon: -73.962982, routes: ["B", "Q"]),
            SubwayStation(id: "D31", name: "Newkirk Plaza", lat: 40.635082, lon: -73.962793, routes: ["B", "Q"]),
            SubwayStation(id: "D35", name: "Kings Hwy", lat: 40.60867, lon: -73.957734, routes: ["B", "Q"]),
            SubwayStation(id: "D39", name: "Sheepshead Bay", lat: 40.586896, lon: -73.954155, routes: ["B", "Q"]),
            SubwayStation(id: "D40", name: "Brighton Beach", lat: 40.577621, lon: -73.961376, routes: ["B", "Q"]),
            SubwayStation(id: "D25", name: "7 Av", lat: 40.67705, lon: -73.972367, routes: ["B", "Q"]),
            SubwayStation(id: "G05", name: "Jamaica Center-Parsons/Archer", lat: 40.702147, lon: -73.801109, routes: ["E", "J", "Z"]),
            SubwayStation(id: "G06", name: "Sutphin Blvd-Archer Av-JFK Airport", lat: 40.700486, lon: -73.807969, routes: ["E", "J", "Z"]),
            SubwayStation(id: "G07", name: "Jamaica-Van Wyck", lat: 40.702566, lon: -73.816859, routes: ["E"]),
            SubwayStation(id: "F05", name: "Briarwood", lat: 40.709179, lon: -73.820574, routes: ["E", "F", "FX"]),
            SubwayStation(id: "F06", name: "Kew Gardens-Union Tpke", lat: 40.714441, lon: -73.831008, routes: ["E", "F", "FX"]),
            SubwayStation(id: "F07", name: "75 Av", lat: 40.718331, lon: -73.837324, routes: ["E", "F", "FX"]),
            SubwayStation(id: "G08", name: "Forest Hills-71 Av", lat: 40.721691, lon: -73.844521, routes: ["E", "F", "FX", "M", "R"]),
            SubwayStation(id: "G09", name: "67 Av", lat: 40.726523, lon: -73.852719, routes: ["E", "F", "M", "R"]),
            SubwayStation(id: "G10", name: "63 Dr-Rego Park", lat: 40.729846, lon: -73.861604, routes: ["E", "F", "M", "R"]),
            SubwayStation(id: "G11", name: "Woodhaven Blvd", lat: 40.733106, lon: -73.869229, routes: ["E", "F", "M", "R"]),
            SubwayStation(id: "G12", name: "Grand Av-Newtown", lat: 40.737015, lon: -73.877223, routes: ["E", "F", "M", "R"]),
            SubwayStation(id: "G13", name: "Elmhurst Av", lat: 40.742454, lon: -73.882017, routes: ["E", "F", "M", "R"]),
            SubwayStation(id: "G14", name: "Jackson Hts-Roosevelt Av", lat: 40.746644, lon: -73.891338, routes: ["E", "F", "FX", "M", "R"]),
            SubwayStation(id: "G15", name: "65 St", lat: 40.749669, lon: -73.898453, routes: ["E", "F", "M", "R"]),
            SubwayStation(id: "G16", name: "Northern Blvd", lat: 40.752885, lon: -73.906006, routes: ["E", "F", "M", "R"]),
            SubwayStation(id: "G18", name: "46 St", lat: 40.756312, lon: -73.913333, routes: ["E", "F", "M", "R"]),
            SubwayStation(id: "G19", name: "Steinway St", lat: 40.756879, lon: -73.92074, routes: ["E", "F", "M", "R"]),
            SubwayStation(id: "G20", name: "36 St", lat: 40.752039, lon: -73.928781, routes: ["E", "F", "M", "R"]),
            SubwayStation(id: "G21", name: "Queens Plaza", lat: 40.748973, lon: -73.937243, routes: ["E", "F", "FX", "R"]),
            SubwayStation(id: "F09", name: "Court Sq-23 St", lat: 40.747846, lon: -73.946, routes: ["E", "F", "FX"]),
            SubwayStation(id: "F11", name: "Lexington Av/53 St", lat: 40.757552, lon: -73.969055, routes: ["E", "F", "FX"]),
            SubwayStation(id: "F12", name: "5 Av/53 St", lat: 40.760167, lon: -73.975224, routes: ["E", "F", "FX"]),
            SubwayStation(id: "E01", name: "World Trade Center", lat: 40.712582, lon: -74.009781, routes: ["E"]),
            SubwayStation(id: "F01", name: "Jamaica-179 St", lat: 40.712646, lon: -73.783817, routes: ["E", "F", "FX"]),
            SubwayStation(id: "F03", name: "Parsons Blvd", lat: 40.707564, lon: -73.803326, routes: ["E", "F", "FX"]),
            SubwayStation(id: "F04", name: "Sutphin Blvd", lat: 40.70546, lon: -73.810708, routes: ["E", "F", "FX"]),
            SubwayStation(id: "F02", name: "169 St", lat: 40.71047, lon: -73.793604, routes: ["E", "F", "FX"]),
            SubwayStation(id: "B04", name: "21 St-Queensbridge", lat: 40.754203, lon: -73.942836, routes: ["F", "M"]),
            SubwayStation(id: "B06", name: "Roosevelt Island", lat: 40.759145, lon: -73.95326, routes: ["F", "M"]),
            SubwayStation(id: "B08", name: "Lexington Av/63 St", lat: 40.764629, lon: -73.966113, routes: ["F", "M", "N", "Q", "R"]),
            SubwayStation(id: "B10", name: "57 St", lat: 40.763972, lon: -73.97745, routes: ["F", "M"]),
            SubwayStation(id: "D18", name: "23 St", lat: 40.742878, lon: -73.992821, routes: ["F", "FX", "M"]),
            SubwayStation(id: "D19", name: "14 St", lat: 40.738228, lon: -73.996209, routes: ["F", "FX", "M"]),
            SubwayStation(id: "F14", name: "2 Av", lat: 40.723402, lon: -73.989938, routes: ["F", "FX"]),
            SubwayStation(id: "F15", name: "Delancey St-Essex St", lat: 40.718611, lon: -73.988114, routes: ["F", "FX"]),
            SubwayStation(id: "F16", name: "East Broadway", lat: 40.713715, lon: -73.990173, routes: ["F", "FX"]),
            SubwayStation(id: "F18", name: "York St", lat: 40.701397, lon: -73.986751, routes: ["F", "FX"]),
            SubwayStation(id: "F20", name: "Bergen St", lat: 40.686145, lon: -73.990862, routes: ["F", "G"]),
            SubwayStation(id: "F21", name: "Carroll St", lat: 40.680303, lon: -73.995048, routes: ["F", "G"]),
            SubwayStation(id: "F22", name: "Smith-9 Sts", lat: 40.67358, lon: -73.995959, routes: ["F", "G"]),
            SubwayStation(id: "F23", name: "4 Av-9 St", lat: 40.670272, lon: -73.989779, routes: ["F", "G"]),
            SubwayStation(id: "F24", name: "7 Av", lat: 40.666271, lon: -73.980305, routes: ["F", "FX", "G"]),
            SubwayStation(id: "F25", name: "15 St-Prospect Park", lat: 40.660365, lon: -73.979493, routes: ["F", "G"]),
            SubwayStation(id: "F26", name: "Fort Hamilton Pkwy", lat: 40.650782, lon: -73.975776, routes: ["F", "G"]),
            SubwayStation(id: "F27", name: "Church Av", lat: 40.644041, lon: -73.979678, routes: ["F", "FX", "G"]),
            SubwayStation(id: "F29", name: "Ditmas Av", lat: 40.636119, lon: -73.978172, routes: ["F", "FX"]),
            SubwayStation(id: "F30", name: "18 Av", lat: 40.629755, lon: -73.976971, routes: ["F", "FX"]),
            SubwayStation(id: "F31", name: "Avenue I", lat: 40.625322, lon: -73.976127, routes: ["F", "FX"]),
            SubwayStation(id: "F32", name: "Bay Pkwy", lat: 40.620769, lon: -73.975264, routes: ["F", "FX"]),
            SubwayStation(id: "F33", name: "Avenue N", lat: 40.61514, lon: -73.974197, routes: ["F", "FX"]),
            SubwayStation(id: "F34", name: "Avenue P", lat: 40.608944, lon: -73.973022, routes: ["F", "FX"]),
            SubwayStation(id: "F35", name: "Kings Hwy", lat: 40.603217, lon: -73.972361, routes: ["F", "FX"]),
            SubwayStation(id: "F36", name: "Avenue U", lat: 40.596063, lon: -73.973357, routes: ["F", "FX"]),
            SubwayStation(id: "F38", name: "Avenue X", lat: 40.58962, lon: -73.97425, routes: ["F", "FX"]),
            SubwayStation(id: "F39", name: "Neptune Av", lat: 40.581011, lon: -73.974574, routes: ["F", "FX"]),
            SubwayStation(id: "D42", name: "W 8 St-NY Aquarium", lat: 40.576127, lon: -73.975939, routes: ["F", "FX", "Q"]),
            SubwayStation(id: "D43", name: "Coney Island-Stillwell Av", lat: 40.577422, lon: -73.981233, routes: ["D", "F", "FX", "N", "Q"]),
            SubwayStation(id: "S01", name: "Franklin Av", lat: 40.680596, lon: -73.955827, routes: ["FS"]),
            SubwayStation(id: "S03", name: "Park Pl", lat: 40.674772, lon: -73.957624, routes: ["FS"]),
            SubwayStation(id: "S04", name: "Botanic Garden", lat: 40.670343, lon: -73.959245, routes: ["FS"]),
            SubwayStation(id: "G22", name: "Court Sq", lat: 40.746554, lon: -73.943832, routes: ["G"]),
            SubwayStation(id: "G24", name: "21 St", lat: 40.744065, lon: -73.949724, routes: ["G"]),
            SubwayStation(id: "G26", name: "Greenpoint Av", lat: 40.731352, lon: -73.954449, routes: ["G"]),
            SubwayStation(id: "G28", name: "Nassau Av", lat: 40.724635, lon: -73.951277, routes: ["G"]),
            SubwayStation(id: "G29", name: "Metropolitan Av", lat: 40.712792, lon: -73.951418, routes: ["G"]),
            SubwayStation(id: "G30", name: "Broadway", lat: 40.706092, lon: -73.950308, routes: ["G"]),
            SubwayStation(id: "G31", name: "Flushing Av", lat: 40.700377, lon: -73.950234, routes: ["G"]),
            SubwayStation(id: "G32", name: "Myrtle-Willoughby Avs", lat: 40.694568, lon: -73.949046, routes: ["G"]),
            SubwayStation(id: "G33", name: "Bedford-Nostrand Avs", lat: 40.689627, lon: -73.953522, routes: ["G"]),
            SubwayStation(id: "G34", name: "Classon Av", lat: 40.688873, lon: -73.96007, routes: ["G"]),
            SubwayStation(id: "G35", name: "Clinton-Washington Avs", lat: 40.688089, lon: -73.966839, routes: ["G"]),
            SubwayStation(id: "G36", name: "Fulton St", lat: 40.687119, lon: -73.975375, routes: ["G"]),
            SubwayStation(id: "L29", name: "Canarsie-Rockaway Pkwy", lat: 40.646654, lon: -73.90185, routes: ["L"]),
            SubwayStation(id: "L28", name: "East 105 St", lat: 40.650573, lon: -73.899485, routes: ["L"]),
            SubwayStation(id: "L27", name: "New Lots Av", lat: 40.658733, lon: -73.899232, routes: ["L"]),
            SubwayStation(id: "L26", name: "Livonia Av", lat: 40.664038, lon: -73.900571, routes: ["L"]),
            SubwayStation(id: "L25", name: "Sutter Av", lat: 40.669367, lon: -73.901975, routes: ["L"]),
            SubwayStation(id: "L24", name: "Atlantic Av", lat: 40.675345, lon: -73.903097, routes: ["L"]),
            SubwayStation(id: "L22", name: "Broadway Junction", lat: 40.678856, lon: -73.90324, routes: ["L"]),
            SubwayStation(id: "L21", name: "Bushwick Av-Aberdeen St", lat: 40.682829, lon: -73.905249, routes: ["L"]),
            SubwayStation(id: "L20", name: "Wilson Av", lat: 40.688764, lon: -73.904046, routes: ["L"]),
            SubwayStation(id: "L19", name: "Halsey St", lat: 40.695602, lon: -73.904084, routes: ["L"]),
            SubwayStation(id: "L17", name: "Myrtle-Wyckoff Avs", lat: 40.699814, lon: -73.911586, routes: ["L"]),
            SubwayStation(id: "L16", name: "DeKalb Av", lat: 40.703811, lon: -73.918425, routes: ["L"]),
            SubwayStation(id: "L15", name: "Jefferson St", lat: 40.706607, lon: -73.922913, routes: ["L"]),
            SubwayStation(id: "L14", name: "Morgan Av", lat: 40.706152, lon: -73.933147, routes: ["L"]),
            SubwayStation(id: "L13", name: "Montrose Av", lat: 40.707739, lon: -73.93985, routes: ["L"]),
            SubwayStation(id: "L12", name: "Grand St", lat: 40.711926, lon: -73.94067, routes: ["L"]),
            SubwayStation(id: "L11", name: "Graham Av", lat: 40.714565, lon: -73.944053, routes: ["L"]),
            SubwayStation(id: "L10", name: "Lorimer St", lat: 40.714063, lon: -73.950275, routes: ["L"]),
            SubwayStation(id: "L08", name: "Bedford Av", lat: 40.717304, lon: -73.956872, routes: ["L"]),
            SubwayStation(id: "L06", name: "1 Av", lat: 40.730953, lon: -73.981628, routes: ["L"]),
            SubwayStation(id: "L05", name: "3 Av", lat: 40.732849, lon: -73.986122, routes: ["L"]),
            SubwayStation(id: "L03", name: "14 St-Union Sq", lat: 40.734789, lon: -73.99073, routes: ["L"]),
            SubwayStation(id: "L02", name: "6 Av", lat: 40.737335, lon: -73.996786, routes: ["L"]),
            SubwayStation(id: "L01", name: "8 Av", lat: 40.739777, lon: -74.002578, routes: ["L"]),
            SubwayStation(id: "M18", name: "Delancey St-Essex St", lat: 40.718315, lon: -73.987437, routes: ["J", "M", "Z"]),
            SubwayStation(id: "M16", name: "Marcy Av", lat: 40.708359, lon: -73.957757, routes: ["J", "M", "Z"]),
            SubwayStation(id: "M14", name: "Hewes St", lat: 40.70687, lon: -73.953431, routes: ["J", "M"]),
            SubwayStation(id: "M13", name: "Lorimer St", lat: 40.703869, lon: -73.947408, routes: ["J", "M"]),
            SubwayStation(id: "M12", name: "Flushing Av", lat: 40.70026, lon: -73.941126, routes: ["J", "M"]),
            SubwayStation(id: "M11", name: "Myrtle Av", lat: 40.697207, lon: -73.935657, routes: ["J", "M", "Z"]),
            SubwayStation(id: "M10", name: "Central Av", lat: 40.697857, lon: -73.927397, routes: ["M"]),
            SubwayStation(id: "M09", name: "Knickerbocker Av", lat: 40.698664, lon: -73.919711, routes: ["M"]),
            SubwayStation(id: "M08", name: "Myrtle-Wyckoff Avs", lat: 40.69943, lon: -73.912385, routes: ["M"]),
            SubwayStation(id: "M06", name: "Seneca Av", lat: 40.702762, lon: -73.90774, routes: ["M"]),
            SubwayStation(id: "M05", name: "Forest Av", lat: 40.704423, lon: -73.903077, routes: ["M"]),
            SubwayStation(id: "M04", name: "Fresh Pond Rd", lat: 40.706186, lon: -73.895877, routes: ["M"]),
            SubwayStation(id: "M01", name: "Middle Village-Metropolitan Av", lat: 40.711396, lon: -73.889601, routes: ["M"]),
            SubwayStation(id: "R01", name: "Astoria-Ditmars Blvd", lat: 40.775036, lon: -73.912034, routes: ["N", "W"]),
            SubwayStation(id: "R03", name: "Astoria Blvd", lat: 40.770258, lon: -73.917843, routes: ["N", "W"]),
            SubwayStation(id: "R04", name: "30 Av", lat: 40.766779, lon: -73.921479, routes: ["N", "W"]),
            SubwayStation(id: "R05", name: "Broadway", lat: 40.76182, lon: -73.925508, routes: ["N", "W"]),
            SubwayStation(id: "R06", name: "36 Av", lat: 40.756804, lon: -73.929575, routes: ["N", "W"]),
            SubwayStation(id: "R08", name: "39 Av-Dutch Kills", lat: 40.752882, lon: -73.932755, routes: ["N", "W"]),
            SubwayStation(id: "R09", name: "Queensboro Plaza", lat: 40.750582, lon: -73.940202, routes: ["N", "W"]),
            SubwayStation(id: "R11", name: "Lexington Av/59 St", lat: 40.76266, lon: -73.967258, routes: ["N", "R", "W"]),
            SubwayStation(id: "R13", name: "5 Av/59 St", lat: 40.764811, lon: -73.973347, routes: ["N", "R", "W"]),
            SubwayStation(id: "R14", name: "57 St-7 Av", lat: 40.764664, lon: -73.980658, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "R15", name: "49 St", lat: 40.759901, lon: -73.984139, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "R16", name: "Times Sq-42 St", lat: 40.754672, lon: -73.986754, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "R17", name: "34 St-Herald Sq", lat: 40.749567, lon: -73.98795, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "R18", name: "28 St", lat: 40.745494, lon: -73.988691, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "R19", name: "23 St", lat: 40.741303, lon: -73.989344, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "R20", name: "14 St-Union Sq", lat: 40.735736, lon: -73.990568, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "R21", name: "8 St-NYU", lat: 40.730328, lon: -73.992629, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "R22", name: "Prince St", lat: 40.724329, lon: -73.997702, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "R23", name: "Canal St", lat: 40.719527, lon: -74.001775, routes: ["N", "R", "W"]),
            SubwayStation(id: "R24", name: "City Hall", lat: 40.713282, lon: -74.006978, routes: ["N", "R", "W"]),
            SubwayStation(id: "R25", name: "Cortlandt St", lat: 40.710668, lon: -74.011029, routes: ["N", "R", "W"]),
            SubwayStation(id: "R26", name: "Rector St", lat: 40.70722, lon: -74.013342, routes: ["N", "R", "W"]),
            SubwayStation(id: "R27", name: "Whitehall St-South Ferry", lat: 40.703087, lon: -74.012994, routes: ["N", "R", "W"]),
            SubwayStation(id: "R28", name: "Court St", lat: 40.6941, lon: -73.991777, routes: ["N", "R", "W"]),
            SubwayStation(id: "R29", name: "Jay St-MetroTech", lat: 40.69218, lon: -73.985942, routes: ["N", "R", "W"]),
            SubwayStation(id: "R31", name: "Atlantic Av-Barclays Ctr", lat: 40.683666, lon: -73.97881, routes: ["D", "N", "R", "W"]),
            SubwayStation(id: "R32", name: "Union St", lat: 40.677316, lon: -73.98311, routes: ["D", "N", "R", "W"]),
            SubwayStation(id: "R33", name: "4 Av-9 St", lat: 40.670847, lon: -73.988302, routes: ["D", "N", "R", "W"]),
            SubwayStation(id: "R34", name: "Prospect Av", lat: 40.665414, lon: -73.992872, routes: ["D", "N", "R", "W"]),
            SubwayStation(id: "R35", name: "25 St", lat: 40.660397, lon: -73.998091, routes: ["D", "N", "R", "W"]),
            SubwayStation(id: "R36", name: "36 St", lat: 40.655144, lon: -74.003549, routes: ["D", "N", "R", "W"]),
            SubwayStation(id: "R39", name: "45 St", lat: 40.648939, lon: -74.010006, routes: ["N", "R", "W"]),
            SubwayStation(id: "R40", name: "53 St", lat: 40.645069, lon: -74.014034, routes: ["N", "R", "W"]),
            SubwayStation(id: "R41", name: "59 St", lat: 40.641362, lon: -74.017881, routes: ["N", "R", "W"]),
            SubwayStation(id: "N02", name: "8 Av", lat: 40.635064, lon: -74.011719, routes: ["N", "W"]),
            SubwayStation(id: "N03", name: "Fort Hamilton Pkwy", lat: 40.631386, lon: -74.005351, routes: ["N", "W"]),
            SubwayStation(id: "N04", name: "New Utrecht Av", lat: 40.624842, lon: -73.996353, routes: ["N", "W"]),
            SubwayStation(id: "N05", name: "18 Av", lat: 40.620671, lon: -73.990414, routes: ["N", "W"]),
            SubwayStation(id: "N06", name: "20 Av", lat: 40.61741, lon: -73.985026, routes: ["N", "W"]),
            SubwayStation(id: "N07", name: "Bay Pkwy", lat: 40.611815, lon: -73.981848, routes: ["N", "W"]),
            SubwayStation(id: "N08", name: "Kings Hwy", lat: 40.603923, lon: -73.980353, routes: ["N", "W"]),
            SubwayStation(id: "N09", name: "Avenue U", lat: 40.597473, lon: -73.979137, routes: ["N", "W"]),
            SubwayStation(id: "N10", name: "86 St", lat: 40.592721, lon: -73.97823, routes: ["N", "W"]),
            SubwayStation(id: "Q01", name: "Canal St", lat: 40.718383, lon: -74.00046, routes: ["N", "Q"]),
            SubwayStation(id: "Q05", name: "96 St", lat: 40.784318, lon: -73.947152, routes: ["N", "Q", "R"]),
            SubwayStation(id: "Q04", name: "86 St", lat: 40.777891, lon: -73.951787, routes: ["N", "Q"]),
            SubwayStation(id: "Q03", name: "72 St", lat: 40.768799, lon: -73.958424, routes: ["N", "Q", "R"]),
            SubwayStation(id: "B12", name: "9 Av", lat: 40.646292, lon: -73.994324, routes: ["D", "R", "W"]),
            SubwayStation(id: "B16", name: "62 St", lat: 40.626472, lon: -73.996895, routes: ["D", "R", "W"]),
            SubwayStation(id: "B21", name: "Bay Pkwy", lat: 40.601875, lon: -73.993728, routes: ["D", "R", "W"]),
            SubwayStation(id: "D27", name: "Parkside Av", lat: 40.655292, lon: -73.961495, routes: ["Q"]),
            SubwayStation(id: "D29", name: "Beverley Rd", lat: 40.644031, lon: -73.964492, routes: ["Q"]),
            SubwayStation(id: "D30", name: "Cortelyou Rd", lat: 40.640927, lon: -73.963891, routes: ["Q"]),
            SubwayStation(id: "D32", name: "Avenue H", lat: 40.62927, lon: -73.961639, routes: ["Q"]),
            SubwayStation(id: "D33", name: "Avenue J", lat: 40.625039, lon: -73.960803, routes: ["Q"]),
            SubwayStation(id: "D34", name: "Avenue M", lat: 40.617618, lon: -73.959399, routes: ["Q"]),
            SubwayStation(id: "D37", name: "Avenue U", lat: 40.5993, lon: -73.955929, routes: ["Q"]),
            SubwayStation(id: "D38", name: "Neck Rd", lat: 40.595246, lon: -73.955161, routes: ["Q"]),
            SubwayStation(id: "D41", name: "Ocean Pkwy", lat: 40.576312, lon: -73.968501, routes: ["Q"]),
            SubwayStation(id: "301", name: "Harlem-148 St", lat: 40.82388, lon: -73.93647, routes: ["3"]),
            SubwayStation(id: "302", name: "145 St", lat: 40.820421, lon: -73.936245, routes: ["3"]),
            SubwayStation(id: "D01", name: "Norwood-205 St", lat: 40.874811, lon: -73.878855, routes: ["D"]),
            SubwayStation(id: "B13", name: "Fort Hamilton Pkwy", lat: 40.640914, lon: -73.994304, routes: ["D"]),
            SubwayStation(id: "B14", name: "50 St", lat: 40.63626, lon: -73.994791, routes: ["D"]),
            SubwayStation(id: "B15", name: "55 St", lat: 40.631435, lon: -73.995476, routes: ["D"]),
            SubwayStation(id: "B17", name: "71 St", lat: 40.619589, lon: -73.998864, routes: ["D"]),
            SubwayStation(id: "B18", name: "79 St", lat: 40.613501, lon: -74.00061, routes: ["D"]),
            SubwayStation(id: "B19", name: "18 Av", lat: 40.607954, lon: -74.001736, routes: ["D"]),
            SubwayStation(id: "B20", name: "20 Av", lat: 40.604556, lon: -73.998168, routes: ["D"]),
            SubwayStation(id: "B22", name: "25 Av", lat: 40.597704, lon: -73.986829, routes: ["D"]),
            SubwayStation(id: "B23", name: "Bay 50 St", lat: 40.588841, lon: -73.983765, routes: ["D"]),
            SubwayStation(id: "J12", name: "121 St", lat: 40.700492, lon: -73.828294, routes: ["J", "Z"]),
            SubwayStation(id: "J13", name: "111 St", lat: 40.697418, lon: -73.836345, routes: ["J"]),
            SubwayStation(id: "J14", name: "104 St", lat: 40.695178, lon: -73.84433, routes: ["J", "Z"]),
            SubwayStation(id: "J15", name: "Woodhaven Blvd", lat: 40.693879, lon: -73.851576, routes: ["J", "Z"]),
            SubwayStation(id: "J16", name: "85 St-Forest Pkwy", lat: 40.692435, lon: -73.86001, routes: ["J"]),
            SubwayStation(id: "J17", name: "75 St-Elderts Ln", lat: 40.691324, lon: -73.867139, routes: ["J", "Z"]),
            SubwayStation(id: "J19", name: "Cypress Hills", lat: 40.689941, lon: -73.87255, routes: ["J"]),
            SubwayStation(id: "J20", name: "Crescent St", lat: 40.683194, lon: -73.873785, routes: ["J", "Z"]),
            SubwayStation(id: "J21", name: "Norwood Av", lat: 40.68141, lon: -73.880039, routes: ["J", "Z"]),
            SubwayStation(id: "J22", name: "Cleveland St", lat: 40.679947, lon: -73.884639, routes: ["J"]),
            SubwayStation(id: "J23", name: "Van Siclen Av", lat: 40.678024, lon: -73.891688, routes: ["J", "Z"]),
            SubwayStation(id: "J24", name: "Alabama Av", lat: 40.676992, lon: -73.898654, routes: ["J", "Z"]),
            SubwayStation(id: "J27", name: "Broadway Junction", lat: 40.679498, lon: -73.904512, routes: ["J", "Z"]),
            SubwayStation(id: "J28", name: "Chauncey St", lat: 40.682893, lon: -73.910456, routes: ["J", "Z"]),
            SubwayStation(id: "J29", name: "Halsey St", lat: 40.68637, lon: -73.916559, routes: ["J"]),
            SubwayStation(id: "J30", name: "Gates Av", lat: 40.68963, lon: -73.92227, routes: ["J", "Z"]),
            SubwayStation(id: "J31", name: "Kosciuszko St", lat: 40.693342, lon: -73.928814, routes: ["J"]),
            SubwayStation(id: "M19", name: "Bowery", lat: 40.72028, lon: -73.993915, routes: ["J", "Z"]),
            SubwayStation(id: "M20", name: "Canal St", lat: 40.718092, lon: -73.999892, routes: ["J", "Z"]),
            SubwayStation(id: "M21", name: "Chambers St", lat: 40.713243, lon: -74.003401, routes: ["J", "Z"]),
            SubwayStation(id: "M22", name: "Fulton St", lat: 40.710374, lon: -74.007582, routes: ["J", "Z"]),
            SubwayStation(id: "M23", name: "Broad St", lat: 40.706476, lon: -74.011056, routes: ["J", "Z"]),
            SubwayStation(id: "R42", name: "Bay Ridge Av", lat: 40.634967, lon: -74.023377, routes: ["R"]),
            SubwayStation(id: "R43", name: "77 St", lat: 40.629742, lon: -74.02551, routes: ["R"]),
            SubwayStation(id: "R44", name: "86 St", lat: 40.622687, lon: -74.028398, routes: ["R"]),
            SubwayStation(id: "R45", name: "Bay Ridge-95 St", lat: 40.616622, lon: -74.030876, routes: ["R"]),
            SubwayStation(id: "S31", name: "St George", lat: 40.643748, lon: -74.073643, routes: ["SI"]),
            SubwayStation(id: "S30", name: "Tompkinsville", lat: 40.636949, lon: -74.074835, routes: ["SI"]),
            SubwayStation(id: "S29", name: "Stapleton", lat: 40.627915, lon: -74.075162, routes: ["SI"]),
            SubwayStation(id: "S28", name: "Clifton", lat: 40.621319, lon: -74.071402, routes: ["SI"]),
            SubwayStation(id: "S27", name: "Grasmere", lat: 40.603117, lon: -74.084087, routes: ["SI"]),
            SubwayStation(id: "S26", name: "Old Town", lat: 40.596612, lon: -74.087368, routes: ["SI"]),
            SubwayStation(id: "S25", name: "Dongan Hills", lat: 40.588849, lon: -74.09609, routes: ["SI"]),
            SubwayStation(id: "S24", name: "Jefferson Av", lat: 40.583591, lon: -74.103338, routes: ["SI"]),
            SubwayStation(id: "S23", name: "Grant City", lat: 40.578965, lon: -74.109704, routes: ["SI"]),
            SubwayStation(id: "S22", name: "New Dorp", lat: 40.57348, lon: -74.11721, routes: ["SI"]),
            SubwayStation(id: "S21", name: "Oakwood Heights", lat: 40.56511, lon: -74.12632, routes: ["SI"]),
            SubwayStation(id: "S20", name: "Bay Terrace", lat: 40.5564, lon: -74.136907, routes: ["SI"]),
            SubwayStation(id: "S19", name: "Great Kills", lat: 40.551231, lon: -74.151399, routes: ["SI"]),
            SubwayStation(id: "S18", name: "Eltingville", lat: 40.544601, lon: -74.16457, routes: ["SI"]),
            SubwayStation(id: "S17", name: "Annadale", lat: 40.54046, lon: -74.178217, routes: ["SI"]),
            SubwayStation(id: "S16", name: "Huguenot", lat: 40.533674, lon: -74.191794, routes: ["SI"]),
            SubwayStation(id: "S15", name: "Prince's Bay", lat: 40.525507, lon: -74.200064, routes: ["SI"]),
            SubwayStation(id: "S14", name: "Pleasant Plains", lat: 40.52241, lon: -74.217847, routes: ["SI"]),
            SubwayStation(id: "S13", name: "Richmond Valley", lat: 40.519631, lon: -74.229141, routes: ["SI"]),
            SubwayStation(id: "S11", name: "Arthur Kill", lat: 40.516578, lon: -74.242096, routes: ["SI"]),
            SubwayStation(id: "S09", name: "Tottenville", lat: 40.512764, lon: -74.251961, routes: ["SI"]),
        ])
    }

    /// 23 stations within 1600m of mock location (40.75306, -73.99944).
    /// From /subway/stations/nearby?lat=40.75306&lon=-73.99944&radius=1600
    static func nearbySubwayStations() -> AllSubwayStationsResponse {
        AllSubwayStationsResponse(stations: [
            SubwayStation(id: "726", name: "34 St-Hudson Yards", lat: 40.755882, lon: -74.00191, routes: ["7", "7X"]),
            SubwayStation(id: "A28", name: "34 St-Penn Station", lat: 40.752287, lon: -73.993391, routes: ["A", "C", "E"]),
            SubwayStation(id: "128", name: "34 St-Penn Station", lat: 40.750373, lon: -73.991057, routes: ["1", "2", "3"]),
            SubwayStation(id: "A30", name: "23 St", lat: 40.745906, lon: -73.998041, routes: ["A", "C", "E"]),
            SubwayStation(id: "129", name: "28 St", lat: 40.747215, lon: -73.993365, routes: ["1", "2"]),
            SubwayStation(id: "A27", name: "42 St-Port Authority Bus Terminal", lat: 40.757308, lon: -73.989735, routes: ["A", "C", "E"]),
            SubwayStation(id: "725", name: "Times Sq-42 St", lat: 40.755477, lon: -73.987691, routes: ["7", "7X"]),
            SubwayStation(id: "127", name: "Times Sq-42 St", lat: 40.75529, lon: -73.987495, routes: ["1", "2", "3"]),
            SubwayStation(id: "R17", name: "34 St-Herald Sq", lat: 40.749567, lon: -73.98795, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "D17", name: "34 St-Herald Sq", lat: 40.749719, lon: -73.987823, routes: ["B", "D", "F", "FX", "M"]),
            SubwayStation(id: "130", name: "23 St", lat: 40.744081, lon: -73.995657, routes: ["1", "2"]),
            SubwayStation(id: "R16", name: "Times Sq-42 St", lat: 40.754672, lon: -73.986754, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "902", name: "Times Sq-42 St", lat: 40.755983, lon: -73.986229, routes: ["GS"]),
            SubwayStation(id: "R18", name: "28 St", lat: 40.745494, lon: -73.988691, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "D16", name: "42 St-Bryant Pk", lat: 40.754222, lon: -73.984569, routes: ["B", "D", "F", "FX", "M"]),
            SubwayStation(id: "D18", name: "23 St", lat: 40.742878, lon: -73.992821, routes: ["F", "FX", "M"]),
            SubwayStation(id: "131", name: "18 St", lat: 40.74104, lon: -73.997871, routes: ["1", "2"]),
            SubwayStation(id: "A31", name: "14 St", lat: 40.740893, lon: -74.00169, routes: ["A", "C", "E"]),
            SubwayStation(id: "724", name: "5 Av", lat: 40.753821, lon: -73.981963, routes: ["7", "7X"]),
            SubwayStation(id: "R15", name: "49 St", lat: 40.759901, lon: -73.984139, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "L01", name: "8 Av", lat: 40.739777, lon: -74.002578, routes: ["L"]),
            SubwayStation(id: "A25", name: "50 St", lat: 40.762456, lon: -73.985984, routes: ["A", "C", "E"]),
            SubwayStation(id: "R19", name: "23 St", lat: 40.741303, lon: -73.989344, routes: ["N", "Q", "R", "W"]),
        ])
    }

    // MARK: - Bus Stops

    /// Mock nearby bus stops around 34 St / 8 Av.
    static func nearbyBusStops() -> [BusStop] {
        [
            BusStop(id: "401517", name: "W 34 ST/8 AV", lat: 40.75260, lon: -73.99930, direction: "E", routeIds: ["MTA NYCT_M34A-SBS"]),
            BusStop(id: "401518", name: "W 34 ST/8 AV", lat: 40.75275, lon: -73.99945, direction: "W", routeIds: ["MTA NYCT_M34A-SBS"]),
            BusStop(id: "401540", name: "8 AV/W 35 ST", lat: 40.75340, lon: -73.99970, direction: "S", routeIds: ["MTA NYCT_M20"]),
            BusStop(id: "401541", name: "8 AV/W 33 ST", lat: 40.75180, lon: -73.99920, direction: "S", routeIds: ["MTA NYCT_M20"]),
            BusStop(id: "400901", name: "W 42 ST/8 AV", lat: 40.75730, lon: -73.99000, direction: "E", routeIds: ["MTA NYCT_M42"]),
            BusStop(id: "400902", name: "W 42 ST/8 AV", lat: 40.75735, lon: -73.99010, direction: "W", routeIds: ["MTA NYCT_M42"]),
        ]
    }

    // MARK: - Bus Arrivals

    /// Mock bus arrivals for a stop.
    static func busArrivals() -> [BusArrival] {
        let now = Date()
        return [
            BusArrival(routeId: "MTA NYCT_M34A-SBS", vehicleId: "B101", stopId: "401517", stopName: "W 34 ST/8 AV", statusText: "Approaching", status: "approaching", expectedArrival: now.addingTimeInterval(120), distanceMeters: 100, bearing: 90, directionRef: 0, destinationName: "Waterside via 34 St"),
            BusArrival(routeId: "MTA NYCT_M34A-SBS", vehicleId: "B102", stopId: "401517", stopName: "W 34 ST/8 AV", statusText: "4 stops away", status: "en_route", expectedArrival: now.addingTimeInterval(600), distanceMeters: 900, bearing: 90, directionRef: 0, destinationName: "Waterside via 34 St"),
            BusArrival(routeId: "MTA NYCT_M20", vehicleId: "B201", stopId: "401540", stopName: "8 AV/W 35 ST", statusText: "Approaching", status: "approaching", expectedArrival: now.addingTimeInterval(240), distanceMeters: 200, bearing: 180, directionRef: 0, destinationName: "South via 8 Av / Hudson St"),
            BusArrival(routeId: "MTA NYCT_M42", vehicleId: "B301", stopId: "400901", stopName: "W 42 ST/8 AV", statusText: "2 stops away", status: "en_route", expectedArrival: now.addingTimeInterval(360), distanceMeters: 400, bearing: 90, directionRef: 0, destinationName: "East via 42 St"),
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

    /// Mock LIRR arrivals from Penn Station.
    static func lirrArrivals() -> [TrainArrival] {
        let now = Date()
        return [
            TrainArrival(routeID: "LIRR_9", stationID: "Penn Station", stationName: "Penn Station", direction: "Eastbound", scheduledTime: now.addingTimeInterval(480), estimatedTime: now.addingTimeInterval(480), minutesAway: 8, destination: "Babylon", status: "On Time", tripId: "LIRR_T1"),
            TrainArrival(routeID: "LIRR_2", stationID: "Penn Station", stationName: "Penn Station", direction: "Eastbound", scheduledTime: now.addingTimeInterval(900), estimatedTime: now.addingTimeInterval(960), minutesAway: 16, destination: "Montauk", status: "Delayed", tripId: "LIRR_T2"),
            TrainArrival(routeID: "LIRR_10", stationID: "Penn Station", stationName: "Penn Station", direction: "Eastbound", scheduledTime: now.addingTimeInterval(1500), estimatedTime: now.addingTimeInterval(1500), minutesAway: 25, destination: "Ronkonkoma", status: "On Time", tripId: "LIRR_T3"),
            TrainArrival(routeID: "LIRR_1", stationID: "Penn Station", stationName: "Penn Station", direction: "Eastbound", scheduledTime: now.addingTimeInterval(1800), estimatedTime: now.addingTimeInterval(1800), minutesAway: 30, destination: "Long Beach", status: "On Time", tripId: "LIRR_T4"),
            TrainArrival(routeID: "LIRR_3", stationID: "Penn Station", stationName: "Penn Station", direction: "Eastbound", scheduledTime: now.addingTimeInterval(720), estimatedTime: now.addingTimeInterval(720), minutesAway: 12, destination: "Port Jefferson", status: "On Time", tripId: "LIRR_T5"),
            TrainArrival(routeID: "LIRR_8", stationID: "Penn Station", stationName: "Penn Station", direction: "Eastbound", scheduledTime: now.addingTimeInterval(1080), estimatedTime: now.addingTimeInterval(1140), minutesAway: 19, destination: "Hempstead", status: "Delayed", tripId: "LIRR_T6"),
            TrainArrival(routeID: "LIRR_7", stationID: "Penn Station", stationName: "Penn Station", direction: "Eastbound", scheduledTime: now.addingTimeInterval(2100), estimatedTime: now.addingTimeInterval(2100), minutesAway: 35, destination: "Far Rockaway", status: "On Time", tripId: "LIRR_T7"),
        ]
    }

    /// Mock MNR arrivals from Grand Central (nearby via shuttle/7 train).
    static func mnrArrivals() -> [TrainArrival] {
        let now = Date()
        return [
            TrainArrival(routeID: "MNR_1", stationID: "Grand Central", stationName: "Grand Central Terminal", direction: "Northbound", scheduledTime: now.addingTimeInterval(600), estimatedTime: now.addingTimeInterval(600), minutesAway: 10, destination: "White Plains", status: "On Time", tripId: "MNR_T1"),
            TrainArrival(routeID: "MNR_2", stationID: "Grand Central", stationName: "Grand Central Terminal", direction: "Northbound", scheduledTime: now.addingTimeInterval(1200), estimatedTime: now.addingTimeInterval(1200), minutesAway: 20, destination: "New Haven", status: "On Time", tripId: "MNR_T2"),
            TrainArrival(routeID: "MNR_4", stationID: "Grand Central", stationName: "Grand Central Terminal", direction: "Northbound", scheduledTime: now.addingTimeInterval(1680), estimatedTime: now.addingTimeInterval(1680), minutesAway: 28, destination: "Wassaic", status: "On Time", tripId: "MNR_T3"),
            TrainArrival(routeID: "MNR_1", stationID: "Grand Central", stationName: "Grand Central Terminal", direction: "Northbound", scheduledTime: now.addingTimeInterval(420), estimatedTime: now.addingTimeInterval(480), minutesAway: 8, destination: "Croton-Harmon", status: "Delayed", tripId: "MNR_T4"),
            TrainArrival(routeID: "MNR_2", stationID: "Grand Central", stationName: "Grand Central Terminal", direction: "Northbound", scheduledTime: now.addingTimeInterval(960), estimatedTime: now.addingTimeInterval(960), minutesAway: 16, destination: "Danbury", status: "On Time", tripId: "MNR_T5"),
            TrainArrival(routeID: "MNR_4", stationID: "Grand Central", stationName: "Grand Central Terminal", direction: "Northbound", scheduledTime: now.addingTimeInterval(2400), estimatedTime: now.addingTimeInterval(2400), minutesAway: 40, destination: "Southeast", status: "On Time", tripId: "MNR_T6"),
        ]
    }

    // MARK: - Default Favorites (for ChallengeMode)

    /// Pre-populated favorites so judges don't see an empty Favorites tab.
    static func defaultFavorites() -> [CloudFavorite] {
        let mockUserId = UUID()
        return [
            CloudFavorite(userId: mockUserId, routeId: "1", routeDisplayName: "1", stopId: "128N", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Van Cortlandt Park - 242 St", mode: "subway", stopLat: 40.75037, stopLon: -73.99106, displayOrder: 0),
            CloudFavorite(userId: mockUserId, routeId: "A", routeDisplayName: "A", stopId: "A28N", stopName: "34 St-Penn Station", direction: "Uptown", destination: "Inwood - 207 St", mode: "subway", stopLat: 40.75229, stopLon: -73.99339, displayOrder: 1),
            CloudFavorite(userId: mockUserId, routeId: "7", routeDisplayName: "7", stopId: "726N", stopName: "34 St-Hudson Yards", direction: "Queens", destination: "Flushing - Main St", mode: "subway", stopLat: 40.75588, stopLon: -74.00191, displayOrder: 2),
        ]
    }

    // MARK: - Subway Polylines (from real GTFS via /subway/shapes/all)

    /// Real GTFS polylines from the Track API, all 23 subway lines.
    /// Includes corridor offsets so co-located lines fan out visually.
    /// Total: ~9 KB of encoded polyline data.
    private static let subwayPolylines: [String: [String]] = [
        "1": ["}rlwFjxvbMgG`G{EZgb@gNcMcCyEcFu\\aWifAcKok@qXcaCq~AyQ{EoTgLsGqC}JGeHnAs`@[cVTqRuCcL}DaW{OqKwIm}@ol@iFsBsLy@cDaAwhJegG_DoE_HaWuAqCeo@ac@mZsa@yGwLif@{Zcc@{Q"],
        "2": ["ib_wF|zibM_bEtTg_@sA{AFo@zD{@vYwJht@_Ft]uKdJqtAr|@_U~s@mIpEwN`DcBjA}QneAcCfJyEfJaRbTqAPwC}@oYmWyKdJgG|Ni@p@oZsRadAyK}l@eY_cCy~A}OsEoReK}IaCsJy@eHnAs`@VySWaKaA}RiEeGeD{QcMqKwIk|@cl@{AqDDmDxLq`@XyBqFao@_BaEyzBazA}CqG[wDGwWb@sIfUisA[gD{A_Ht@kYo@}GuHgQ{EuLyb@idAgBs@y\\GeDc@oe@uUmBwBuJ}Qm@mDKmJgBwFkFqHPuAz@uEL}BuAaNaQiUaR}GgQ{HkeDwDm^gRiaBqu@_SuOoNmJ", "ytewFzn}aMh`@btEq@nCo]z]yGbFiBdBcBrAmG`vDkQptAkCzAgHfIqtAr|@_U~s@mIpEwN`DcBjA{T|mA_G`MyPdSeBr@kDaAaXwVy@UmKdJgG|Ns@p@eZsRqbAmKmCw@_j@yW{aCe}AaQgGoTgL}G_BsJy@eHnAs`@VcV]qRuCeJaC_YwQqKwIiz@ck@kCsCKkFxLq`@XyBqFao@_BaEyzBazAsCoFe@yEGwW\\qHlUktA[gD}AmIfAcRUeIi@qCuHgQ{EuLyb@idAgBs@y\\GeDc@oh@}XcKmRm@mDKmJgBwFkFqHPuAz@uEL}B}AuNoMkQyD}CqOiFgQ{HkeDwDm^gRiaBqu@_SuOoNmJ"],
        "3": ["ssewFrn}aMb_@jtEq@nCs\\`_@uH|DiBdB{@tAuH~uD_QnsA{BbDcI`HctAd}@iTdt@qJxDwN`D_AzAaS~dAcCfJyEfJwRpTaCMaCoA_XiVyKdJcFtOmAXiZkSueAuKok@qXoaC{}AmQqF}MsHyGoC}EOkJmBeHnAs`@jAcVqAqRuCwLqCmVgQqKwIa{@{i@eB{Cg@_DVqC|K}]j@gDyGwn@kAiF_gCqbBqGcFwDkAgAJaDpI"],
        "4": ["krewFjn}aMz]rtEq@nCw[d`@qIxCiBdBSxA}IzuDwPprAgBdF_J|FktAp}@oTnr@sH||@mEjXcEbN}e@rs@cBnAkC\\_Dm@kFeCqc@y^y@{@sDoT}HwHoJ}Acg@ob@wFkCgWcQiMeK{C}EkRkCwGT}Ao@obBofAu@qAkAyKkAoAa|Iy}Fyb@qa@qk@eQcE@gQ~D{DW}fAgi@{EoGakAmu@ma@}]sc@uUeq@af@kB_CqHyQsK}NeBmAgO_G}`@ye@cTcO"],
        "5": ["eqewFbn}aMt\\ztEq@nC{Zja@mJrBiBdBRzAeKxuDwPprAiAhG}JxEktAp}@gSzr@{Ip|@mEjXcD~N}f@vr@yCdBsCAmIiDsd@y]cEyVwCqDoEmDmIgAcg@ob@oG_BoVoRiMeKeDiDqAaAoO}BwGCuBT}aBahAq@sAqBkKc@uAu{Im~F{c@q_@gU}HcC|BqAMKkB~PagAJ{C}AmI^gRPaIi@qCyIoPwDmMmb@ycAaBaAk]IeDc@kh@yWgKqSm@mDs@eJ_A_GkFqHUaBbBiEL}BuAaNwM_RoCeCoIyCiJiGk~@elA{kDgrC_PwJ", "eb_wFp|ibMcbE`Sg_@sA{@f@oAzC{@vYoItt@gGh]uKdJktAp}@gSzr@{Ip|@mEjXcD~N}f@vr@uDhByEi@kFeCwd@_^_EsVwCqDoEmDmIgAcg@ob@oG_BoVoRiMeKeDiDqAaAoO}BwGCuBT}aBahAq@sAqBkKc@uAu{Im~F{c@q_@gU}HcC|BqAMKkB~PagAJ{C}AmI^gRPaIi@qCyIoPwDmMmb@ycAaBaAk]IeDc@kh@yWgKqSm@mDs@eJ_A_GkFqHUaBbBiEL}BuAaNwM_RoCeCoIyCiJiGk~@elA{kDgrC_PwJ", "eb_wFp|ibMcbE`Sg_@sA{@f@oAzC{@vYoItt@gGh]uKdJktAp}@gSzr@{Ip|@mEjXcD~N}f@vr@yCdBsDKmH_Dsd@y]cEyVwCqDoEmDmIgAcg@ob@oG_BoVoRiMeKeDiDqAaAoO}BwGCuBT}aBahAq@sAqBkKc@uAu{Im~F{c@q_@gU}HcC|BqAMKkB~PagAJ{C{A_Ht@kYo@}GyIoPwDmMyb@idAgBs@y\\GeDc@oe@uUmC{AuIyRm@mDs@eJ_A_GkFqHUaBbBiEL}BuAaNaQiUaR}GgQ{HkeDwDm^gRiaBqu@yDsC"],
        "6": ["swnwFx|tbMoEmDmIgAcg@ob@cGuB{VyQiMeKcDeEcRcDwGn@iBs@cbBegAu@qA}AqKy@wAm|Ie}FgW}VmA_EZyDnIkN~b@itAFyC_J}UaSsF}AgAqJ_QiHk^oi@ak@gDmN_GcK_FwCoU}BiCeBm@qCyBep@wYq|A{GimAmd@wl@wOk^cZua@aIyEyMcDoAuAoBoF"],
        "7": ["gcwwF|ntbM{OkKkBsBoAiFZ_Fb_@{kA@iIrDcNl}@itCpGci@wCaReEyLmBUwHzDoMqCkPgMs@_BPuCxHiS|Ys[jAkCtJsdBcJ{d@sBwSSsM}[wpGob@awBgK{]wBeRcG}V"],
        "A": ["}myvFfjdaMzNzZvPrQ~[bo@rBrHpFlgAe@v\\JtIfFr^`Enp@S`GeB~LsAzEyAbCsFtDobBbi@elH|mAqcCr~@}KnFcBtBQnD|BzU`Eb_BxBpKnLjS~@|CdXpmD_@|CuBdCoVrEeBt@uBnBu@rFiAbXJji@sM|nGyQnxAsSbr@@nDp@bNSdEeOrk@qA`Aw@j@}GeCuc@eAgD|@}AbA}BjFm@|W}EhWwElLcHjKab@vZqN`[q@tAmALeAc@cd@{\\kCIwQ?eCS_g@{NkKsF}NcJwCj@k\\pOqAJoA?ieL}rH_CeBeJdAeBYoEuEyJwHmIsFwu@oYuN{Hav@eTyLPmLKa^eE{Bn@aDjDwBTi`@gL_XkGqn@cc@_BcBiJySmNok@", "eniwFfbraMzAfTdJh[`JdTfBnIdFde@hEnaBvB~JnLjS~@|CbX|nDcAnDwB`AgUxEeBt@uBnBu@rFiAbXLph@eMllGiRx{AsSbr@@nDp@pOiAlIoM|e@_BfAcB\\cF}Buc@eAgD|@}AbA}BjFm@|W}EhWwElLcHjKab@vZqN`[q@tAmALeAc@cd@{\\kCIwQ?eCS_g@{NkKsF}NcJwCj@k\\pOqAJoA?ieL}rH_CeBeJdAeBYoEuEyJwHmIsFwu@oYuN{Hav@eTyLPmLKa^eE{Bn@aDjDwBTi`@gL_XkGqn@cc@_BcBiJySmNok@", "s}tvFl_taMoWwtAcWs|@}B{EmDsDsDmBaFk@wDb@abBzh@ijHhmAucCp~@sNtHu@lEzBjUdEn`BxBpKnLjS~@|CdXpmD_@|CuBdCoVrEeBt@uBnBu@rFiAbXJji@sM|nGyQnxAsSbr@@nDp@bNSdEeOrk@qA`Aw@j@}GeCuc@eAgD|@}AbA}BjFm@|W}EhWwElLcHjKab@vZqN~ZoAbBuBa@cd@{\\kCIwQ?eCS_g@{NkKsF}NcJwCj@k\\pOqAJoA?ieL}rH_CeBeJdAeBYoEuEyJwHmIsFwu@oYuN{Hav@eTyLPmLKa^eE{Bn@aDjDwBTi`@gL_XkGqn@cc@_BcBiJySmNok@"],
        "B": ["citvFrqlbMu@uFy@}Aoj@__@mFgAgM]uLZgmIr_A}HUk}@}Q}D?sd@rE_FhAusBzsAaCv@_YhCo@vAaFnPwAdByt@vXejBnz@uB^yBUwb@cQaFk@wBVkBrCaIj^sLxZwAxAsBS}LsEeyDofC{BUaBtAiJhX_Bv@sB[_hGm`EaCq@cJPeBYiFoD_J}ImIsFyv@eY}SsNyKiGoBiCy@kFZsr@r@yGfGmNpD_PZ_Gy@yC{AuAiQ{GoIuEa^q\\cGiEgHsCkUqF_EoB}CaDoK}O_FcF_i@s`@im@gZme@s]uDkEoGkLaJgH"],
        "C": ["clgwFtc{aMdSvlCcAnDkBpBsUhDeBt@qAfCyAzEiAbXt@th@kNtkGkRl|AoRrr@a@~Cp@bNSdEaGxVcGxS{@jBsB?yFiBsc@k@gDHwB`B{@tEuAtW}EhWwDhMcInJab@vZmMx[cBdAeC]{d@o[sBu@wQXuC@of@kPuK}EgOiIcCCa\\fP_Bh@kAs@ueLesHwBHaJa@eBYcGiCeIcKmIsFkv@_XaOyJau@wSmMdAeMeAaFw@"],
        "D": ["ehtvFfkpbMyDpBeLHyJkBeFWoCR}HzDeG~Hoz@xJ{z@~`BiCtB}Mf@qkCcg@ep@mEsTSmAg@gEwE}Aa@yBvAkk@liAmAn@uAg@ilA}nA}~@ct@us@oc@aCOiNnAoBz@sBnKoAvAyt@vXkkB`{@wBLgB]ab@{PaFk@wBVkBrCaIj^sLxZiB`BaCKqKyFqyDyeC{BUaBtAiJhX_Bv@sB[_hGm`EaCq@cJPeBYiFoD_J}ImIsFyv@eYka@mWeBsCo@qE\\ss@z@qG|FuMpD_PZ_Gy@yC{AuAiQ{GoIuEa^q\\cGiEcGeCoV_GeD{AcD{CgJmN{GmHmi@}`@al@iY}f@}^_DuDqIoNwJaHcPkGgBeDJ}E|Ki\\"],
        "E": ["stnwFb`vbMyb@{Z_C_@wQt@mCo@wf@sO_LgEsNwJmCRy[~PcDYsrCkjBgAwAWcCTgBpv@ubCzUs`@nHqQrBcKhJyy@UyFsIo\\wKeN_CgGWeGk@cc@}@wHkAuDg`@sWoA}Dn@uEp^ccAtx@qfC~HgPpBoG|GsJdZwLhBmDfBkD|Kuc@jJaXb\\ynAbDuFdHcKzCkFdTil@hNm_@hRs\\`IiRlMoe@~CmDz\\eQjW_KxDsEdCuMJeFyEuToIgj@", "stnwFb`vbMyb@{Z_C_@wQt@mCo@wf@sO_LgEsNwJmCRy[~PcDYsrCkjBgAwAWkBT_Cpv@ubCzUs`@nHqQrBcKdJ_y@QsGsIo\\qKeNcBiDm@wF}@oh@yHql@]mGPcInCeZe@kTn@iHfw@kcCxIoT`KgO~W}LdCuBlBaDrLee@lJaXb\\ynAbDuFdHcKzCkFdTil@hNm_@hRs\\`IiR~Lud@xCyDb[gPnCmDx@wCNiFc@eE}`@gvB_Kq`@oAwWaBsL"],
        "F": ["wgtvFnnpbMnD}@x@y@zAuO[eHkBsIeAgAgK^sRi@oGVud@eAo|AyKeiEtd@{U`Dwa@tDwCQ{BkAeBaCsEaMuCqB_Dm@{IRsTtCoBjBaI|O}ChBoBS_EsB_TuOuC]iBz@iA`BoVrn@{CbQmM`]aJpQgDdEmBdA_CP}Ao@yRaHeN_Kg{@mf@esA{D_Eh@}DrAoMlIsFzBqFdA_O~@gEo@sc@{QcDg@}B`AeA~BeRt|@_Mn[{@z@iARsBYoKcE{zEc`DiAuAiAoC]eD\\}FhAsEl~@wrChc@sdA`@qBUmD{C}GuAsFKge@aAcJeBmCm_@{XqA_Fn@gFr^oaAtx@qfCzG_QtCwF|GsJnYcN~BaCfBkDvJgd@~JyWt\\onAbCuGdIcJlD_FnRmm@lOu^hRs\\|G}RbNad@xCyDb[gPnCmDx@wCNiFc@eE}`@gvB_Kq`@oAwWaBsL", "wgtvFnnpbMnD}@x@y@zAuO[eHkBsIeAgAgK^sRi@oGVud@eAo|AyKeiEtd@{U`Dwa@tDwCQ{BkAeBaCsEaMuCqB_Dm@{IRsTtCoBjBaI|O}ChBoBS_EsB_TuOuC]iBz@iA`BoVrn@{CbQmM`]aJpQgDdEmBdA_CP}Ao@yRaHeN_Kg{@mf@esA{D_Eh@}DrAoMlIsFzBqFdA_O~@gEo@sc@{QcDg@}B`AeA~BeRt|@_Mn[{@z@iARsBYoKcEsyDihCk@gB?aBpB{Idd@}vAzUs`@nHqQrBcKdJ_y@QsGsIo\\sLmOsAoDcAeEUsh@yHql@]mGPcInCeZe@kTn@iHfw@kcCxIoT`KgO~W}LdCuBlBaDnKwe@~JyWt\\onAbCuGdIcJlD_FnRmm@lOu^hRs\\|G}RbNad@xCyDb[gPnCmDx@wCNiFc@eE}`@gvB_Kq`@oAwWaBsL"],
        "G": ["ghawF~cpbMcJz@yEq@_DmDsEaMuCqB_Dm@{IRsTtCoBjBaI|O}ChBoBS_EsB_TuO{A_@oBTuCrDwUhm@{CbQmNz^wGzMqE`GcDrAmDF_UeKmJqHkm@s^iBqCHeDxM{f@~@wJyS_vDs@wCmA_BeDe@qw@pJs^EcnA|KoEgA_KiJkDg@on@zXgl@bGsGL_LcAiDkBoBaCkP_`@cK_]"],
        "J": ["cnmwFngvbMwK_HwLaM{F_KwBeHwKiG{ZeU{K_IWsCxWyjArj@{pCrGeKzOsm@jfBmwD|mAmhCp@kByHg}@mRi|@uKim@cAk@}@Ao^`HeAg@}DgNoBwO_Fye@gAkPm@{\\mHgYkDoZEiYaAaKmBgHuHaO_L}UmBiL{ByYuB}JGcE|@eDdHqMjDuJnA}GMiEg@mHeFuZcCgHoIgj@"],
        "L": ["qxawFp}`bM_d@iUaCq@gCCo}B|_@aLqAsGAuRdEmMpHgIjAuIu@cF}Ae\\eX{Ca@aDnAaFtI}j@lmAs`@xu@ObEnGds@N~JbBnOStDm@|@aBp@{_@vDaR~HMxA|Bbj@?zI]`CopApbCgmAjxD"],
        "M": ["gmnwF~p~aM|JdCpKnJpAnBlUxwAzUbWn@rAtMrgCXjAdBlBFlAc{@njB{Obo@kGnJmk@hqCsL`i@gAbB}Bz@sOaAqC~@{@jBcJt`@}KdYkAbAmB`@cMiGg{Em_DaCsDo@sGfBuKh~@mrClc@}dA`@qBUmD{C}GaAuF_@ee@aAcJeBmCm_@{XoA}D\\_Fb_@ybAtx@qfCzG_QtCwF|GsJnYcN~BaCfBkDvJgd@lJcXj[_jAzDmJrMkS`JoU"],
        "N": ["wgtvFnnpbMmEHeMDcSaHkc@gJwHe@yiCfY}K`DgDhCqCrD_h@pbAgNrJyDdEcg@baAmIrRqLjo@wApD{A`AqAo@shDcoDc_Akt@_u@sb@oBuAiM|AcBtAeEvLeOtG}AtAw@ve@q@`BgDzA}@fCoMzr@sWxdAsB~HmAfByBr@sTtD{D|BeAMoEoCeYkPOyA`@mEc@uBer@{j@dAx@z@OfDwEgDvE{@NcA[}hAk}@at@gLyQgB{v@mGwZoG_IsEcs@qc@YmAn@kA`IiZA}I|b@_qAjm@mjBdC}DhJ_UCmBq@oBwMoQucB_pAuk@et@", "wgtvFnnpbMmEHeMDcSaHkc@gJwHe@yiCfY}K`DgDhCqCrD_h@pbAgNrJyDdEcg@baAmIrRiLrn@uAzD{AnA{Ao@qgDcnDo`Auu@ov@yd@}ObBkArAwCvJoAvAkt@fZkkBj{@gFdFgFzPoIjMkBZyjAi~@os@_LyQgB{v@mGwZoG_IsEcs@qc@YmAn@kA`IiZA}I|b@_qAjm@mjBdC}DhJ_UCmBq@oBwMoQucB_pAuk@et@", "wgtvFnnpbMmEHeMDcSaHkc@gJwHe@yiCfY}K`DgDhCqCrD_h@pbAgNrJyDdEcg@baAaJhTmL~n@}A`DmAf@iAo@qgDcnDo`Auu@gv@{c@ePdAkArAwCvJoAvAkt@fZskBp{@sEjE}EjPyIbNqAl@qAy@uiAy|@gs@{KyQgBiw@qG_`@uI_aAon@yBuBeAgCS{Cr@oFjKcUpQik@\\kFsAmF{AeBytB_uA"],
        "Q": ["ghtvFhkpbM~Df@~@gAxAiReEqWrAu^GgFqHql@kAkBuj@e]_EoB}Ma@mLnAinI`~@cHW{y@gQmHUoc@jEgEfBquBdsAaCv@wX|DyGrQwAdBkt@fZkkBj{@gFdF_FnPkIjM}Al@}AQuhA}}@ss@eK{QmAuv@aIq[wG{HaDm}@ul@gB{Bu@mCTyGnAcEpI_Q`Qui@n@sFk@oEeCoDytB_uA"],
        "R": ["{|{vF~czbMu}Bis@qrDmyDo`Auu@_v@yc@cAKqNtA_@dBcFtKeOtGi@fAq@hBmAxb@]bBkC~BkBzA}Lbs@mZdmAuBhC_BxBgUbCaFhCc`@oUaAuAhAyEc@uBa|BihBit@sJwQgBuv@aIq[wG{HaDur@ie@E}CdJsYAaJxa@sqAvh@s|AhAuBbBeApHGzAe@hGcGjAyDOaEqE_QqKyM_CgG_AaGCgc@eAiIwBsAs^cZoA}DJiFt_@obAtx@qfCvFwQxD_F|GsJxXoOtCuAfBkDpIyd@dLgWxZijAzDmJdN}RnI}U", "{|{vF~czbMu}Bis@qrDmyDo`Auu@wv@ad@}OpA_@dBcFtKeOtGo@jAyB~e@]bBkC~BkBzA}Lbs@oVheAwCnH{ArA_BzB_U`C{D|BcBVqDuDmYuPo@_BhAmEc@eBa|BihBit@sJwQgBuv@aIq[wG{HaDm}@ul@gB{Bu@mCTyGnAcEpI_Q`Qui@n@sFk@oEeCoDytB_uA"],
        "SI": ["wsgvFviedM{DeHoCwHmHy`@eIgWwP{xAqLer@oJosA}BeNmCgHmDeFsu@ss@gHgK_GmMaEiMaCsKsKe}@}CiOmE{Msc@qfAoMi]cB}HcBmVeB_KmImVcHqMyx@eeA_\\c[cHaI{aCurDmGoHmH{FaJoEoRoF_GeCam@{b@gl@cZ}EoE}FqK_FyCqECiFtBqXxQyP|AaKEmJ_DoD]wa@pEyR{CuGyD"],
        "W": ["ogwvF|zobM}`CxWoHbBgFzC_E~Eug@dbAuBvBsK|GqDdE_g@~`AaI`RqLjo@wApD{A`AqAo@shDcoDc_Akt@ut@ic@uBKwMl@_BzAqD~LsObGiAvAw@ve@eA~AyClBy@|BaNrr@{Z~mAkArCaCz@yTzC{D|BoAFeEeD{XcPm@uAt@yEc@uBa|BihBet@mKaRYov@uJwZoGkJ_Cwq@ef@YmAWoBhKeYA}It`@grAro@eiBdC}DdIsU^yAq@oBoNgP}bBgqAuk@et@"],
        "Z": ["{nmwFvhvbM_KgIwLaM_HgJsA}HwKiGs[}ScKgJWsCtVikAvk@kpCrGeKvNkn@ngBuvD|mAmhCHcBqGo}@mRi|@yLyl@_@{@}@Ag^tImA{A}DgNwCoOwDaf@gAkPuAs\\eGoYkDoZm@eYYeKmBgHyIeN{JyVmBiLcDqYmAeKGcEX}DhIyLjDuJf@eHXaEg@mHiGeZ_BwHoIgj@"],
    ]

    /// Subway line colors from MTA branding.
    private static let subwayColors: [String: String] = [
        "1": "#EE352E",
        "2": "#EE352E",
        "3": "#EE352E",
        "4": "#00933C",
        "5": "#00933C",
        "6": "#00933C",
        "7": "#B933AD",
        "A": "#0039A6",
        "B": "#FF6319",
        "C": "#0039A6",
        "D": "#FF6319",
        "E": "#0039A6",
        "F": "#FF6319",
        "G": "#6CBE45",
        "J": "#996633",
        "L": "#A7A9AC",
        "M": "#FF6319",
        "N": "#FCCC0A",
        "Q": "#FCCC0A",
        "R": "#FCCC0A",
        "SI": "#808183",
        "W": "#FCCC0A",
        "Z": "#996633",
    ]

    /// All subway line overlays for the full system map.
    static func allSubwayShapes() -> AllSubwayLinesResponse {
        AllSubwayLinesResponse(lines: subwayPolylines.map { routeId, polylines in
            SubwayLineOverlay(
                routeId: routeId,
                colorHex: subwayColors[routeId] ?? "#808183",
                polylines: polylines
            )
        })
    }

    /// Route shape for a single subway line.
    static func subwayShape(routeID: String) -> RouteShapeResponse {
        let polylines = subwayPolylines[routeID.uppercased()] ?? []
        let stations = subwayStations().stations.filter { $0.routes.contains(routeID.uppercased()) }
        let stops = stations.map { BusStop(id: $0.id, name: $0.name, lat: $0.lat, lon: $0.lon, direction: "", routeIds: $0.routes) }
        return RouteShapeResponse(
            routeId: routeID,
            polylines: polylines,
            stops: stops,
            directions: [],
            serviceType: nil
        )
    }

    /// Mock route shape for a single bus route.
    static func busRouteShape(routeID: String) -> RouteShapeResponse {
        let stops = nearbyBusStops().filter { $0.routeIds?.contains(routeID) ?? false }
        let coords = stops.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let polyline = coords.count >= 2 ? encodePolyline(coords) : ""
        return RouteShapeResponse(
            routeId: routeID,
            polylines: polyline.isEmpty ? [] : [polyline],
            stops: stops,
            directions: [],
            serviceType: nil
        )
    }

    // MARK: - LIRR Polylines

    /// Mock LIRR branch polylines for map overlay.
    static func allLIRRShapes() -> AllCommuterRailLinesResponse {
        AllCommuterRailLinesResponse(lines: [
            CommuterRailLineOverlay(routeId: "LIRR_9", name: "Babylon", colorHex: "#00985F", polylines: ["____F____M__H__W__A__I__C__T_E__H_^__O_X__["], mode: "lirr"),
            CommuterRailLineOverlay(routeId: "LIRR_2", name: "Montauk", colorHex: "#00985F", polylines: ["____F____M__H__W__A__I__C__T_E__H_^__O_X__[__I___@__Z___A"], mode: "lirr"),
            CommuterRailLineOverlay(routeId: "LIRR_10", name: "Ronkonkoma", colorHex: "#00985F", polylines: ["____F____M__H__W__G__]__@__R__A___@__C___@"], mode: "lirr"),
            CommuterRailLineOverlay(routeId: "LIRR_1", name: "Long Beach", colorHex: "#00985F", polylines: ["____F____M__H__W__A__I__E__O__L__L"], mode: "lirr"),
        ])
    }

    /// Mock route shape for a single LIRR branch.
    static func lirrShape(routeID: String) -> RouteShapeResponse {
        let branch = allLIRRShapes().lines.first { $0.routeId == routeID }
        return RouteShapeResponse(
            routeId: routeID,
            polylines: branch?.polylines ?? [],
            stops: [],
            directions: [],
            serviceType: nil
        )
    }

    // MARK: - MNR Polylines

    /// Mock Metro-North line polylines for map overlay.
    static func allMNRShapes() -> AllCommuterRailLinesResponse {
        AllCommuterRailLinesResponse(lines: [
            CommuterRailLineOverlay(routeId: "MNR_1", name: "Hudson", colorHex: "#009B3A", polylines: ["____F____M__M__D__P__H__V__C__W__@__[__R"], mode: "mnr"),
            CommuterRailLineOverlay(routeId: "MNR_2", name: "New Haven", colorHex: "#EE0034", polylines: ["____F____M__M__D__O__V__Z___@__W___A__V___@"], mode: "mnr"),
            CommuterRailLineOverlay(routeId: "MNR_4", name: "Harlem", colorHex: "#0039A6", polylines: ["____F____M__M__D__R__M___@__F___@__N___@___@"], mode: "mnr"),
        ])
    }

    /// Mock route shape for a single MNR line.
    static func mnrShape(routeID: String) -> RouteShapeResponse {
        let line = allMNRShapes().lines.first { $0.routeId == routeID }
        return RouteShapeResponse(
            routeId: routeID,
            polylines: line?.polylines ?? [],
            stops: [],
            directions: [],
            serviceType: nil
        )
    }
}
