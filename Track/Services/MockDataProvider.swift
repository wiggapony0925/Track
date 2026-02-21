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
/// All coordinates and station names are real NYC MTA data centered
/// around Midtown Manhattan (40.75306, -73.99944).
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

    /// Mock service alerts for subway lines.
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
            )
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

    /// Mock subway stations near the mock location (40.75306, -73.99944).
    /// Uses real GTFS coordinates from MTA data.
    static func subwayStations() -> AllSubwayStationsResponse {
        AllSubwayStationsResponse(stations: [
            // Closest stations (within ~400m)
            SubwayStation(id: "726", name: "34 St-Hudson Yards", lat: 40.75588, lon: -74.00191, routes: ["7"]),
            SubwayStation(id: "A28", name: "34 St-Penn Station", lat: 40.75229, lon: -73.99339, routes: ["A", "C", "E"]),
            SubwayStation(id: "128", name: "34 St-Penn Station", lat: 40.75037, lon: -73.99106, routes: ["1", "2", "3"]),
            // Within ~800m
            SubwayStation(id: "A30", name: "23 St", lat: 40.74591, lon: -73.99804, routes: ["C", "E"]),
            SubwayStation(id: "129", name: "28 St", lat: 40.74721, lon: -73.99336, routes: ["1"]),
            // Within ~1000m
            SubwayStation(id: "A27", name: "42 St-Port Authority Bus Terminal", lat: 40.75731, lon: -73.98973, routes: ["A", "C", "E"]),
            SubwayStation(id: "725", name: "Times Sq-42 St", lat: 40.75548, lon: -73.98769, routes: ["7"]),
            SubwayStation(id: "127", name: "Times Sq-42 St", lat: 40.75529, lon: -73.98749, routes: ["1", "2", "3", "N", "Q", "R", "W", "S"]),
            SubwayStation(id: "R17", name: "34 St-Herald Sq", lat: 40.74957, lon: -73.98795, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "D17", name: "34 St-Herald Sq", lat: 40.74972, lon: -73.98782, routes: ["B", "D", "F", "M"]),
            SubwayStation(id: "130", name: "23 St", lat: 40.74408, lon: -73.99566, routes: ["1"]),
            SubwayStation(id: "R16", name: "Times Sq-42 St", lat: 40.75467, lon: -73.98675, routes: ["N", "Q", "R", "W"]),
            SubwayStation(id: "902", name: "Times Sq-42 St", lat: 40.75598, lon: -73.98623, routes: ["S"]),
            // Within ~1600m
            SubwayStation(id: "L01", name: "8 Av", lat: 40.73984, lon: -73.99959, routes: ["L"]),
            SubwayStation(id: "R18", name: "28 St", lat: 40.74549, lon: -73.98869, routes: ["R", "W"]),
            SubwayStation(id: "R19", name: "23 St", lat: 40.74191, lon: -73.98965, routes: ["N", "R", "W"]),
            SubwayStation(id: "D18", name: "23 St", lat: 40.74301, lon: -73.99282, routes: ["F", "M"]),
            SubwayStation(id: "D16", name: "42 St-Bryant Pk", lat: 40.75410, lon: -73.98435, routes: ["B", "D", "F", "M"]),
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
        ]
    }

    /// Mock MNR arrivals from Grand Central (nearby via shuttle/7 train).
    static func mnrArrivals() -> [TrainArrival] {
        let now = Date()
        return [
            TrainArrival(routeID: "MNR_1", stationID: "Grand Central", stationName: "Grand Central Terminal", direction: "Northbound", scheduledTime: now.addingTimeInterval(600), estimatedTime: now.addingTimeInterval(600), minutesAway: 10, destination: "White Plains", status: "On Time", tripId: "MNR_T1"),
            TrainArrival(routeID: "MNR_2", stationID: "Grand Central", stationName: "Grand Central Terminal", direction: "Northbound", scheduledTime: now.addingTimeInterval(1200), estimatedTime: now.addingTimeInterval(1200), minutesAway: 20, destination: "New Haven", status: "On Time", tripId: "MNR_T2"),
            TrainArrival(routeID: "MNR_4", stationID: "Grand Central", stationName: "Grand Central Terminal", direction: "Northbound", scheduledTime: now.addingTimeInterval(1680), estimatedTime: now.addingTimeInterval(1680), minutesAway: 28, destination: "Wassaic", status: "On Time", tripId: "MNR_T3"),
        ]
    }
}
