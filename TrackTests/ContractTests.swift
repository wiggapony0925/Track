//
//  ContractTests.swift
//  TrackTests
//
//  Contract tests that verify iOS Codable structs can decode realistic
//  backend JSON payloads.  Each test builds a JSON dictionary matching
//  the backend's Pydantic model output and decodes it through
//  JSONDecoder — catching field renames, type changes, and missing keys
//  BEFORE they reach production.
//
//  These tests do NOT hit the network.  They test the decode contract
//  between models.py and Track/Models/*.swift.
//

import Foundation
import Testing
@testable import Track

// MARK: - JSON Helpers

private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .useDefaultKeys  // We use CodingKeys, not auto-snake
    d.dateDecodingStrategy = .iso8601
    return d
}()

private func jsonData(_ dict: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: dict)
}

// MARK: - 1. TransitArrivalResponse (TrackArrival)

@Suite("Contract: TransitArrivalResponse")
struct TransitArrivalContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "route_id": "A",
            "station": "A27N",
            "station_name": "59 St-Columbus Circle",
            "direction": "N",
            "destination": "Inwood-207 St",
            "minutes_away": 5,
            "status": "On Time",
            "trip_id": "091400_A..N03R",
            "arrival_ts": 1711200000,
            "is_cancelled": false,
        ]
        let result = try decoder.decode(TransitArrivalResponse.self, from: jsonData(json))
        #expect(result.routeId == "A")
        #expect(result.station == "A27N")
        #expect(result.stationName == "59 St-Columbus Circle")
        #expect(result.direction == "N")
        #expect(result.destination == "Inwood-207 St")
        #expect(result.minutesAway == 5)
        #expect(result.status == "On Time")
        #expect(result.tripId == "091400_A..N03R")
        #expect(result.arrivalTs == 1711200000)
        #expect(result.isCancelled == false)
    }

    @Test func decodesMinimalPayload() throws {
        /// Backend sends defaults — iOS must handle them.
        let json: [String: Any] = [
            "route_id": "",
            "station": "X01",
            "station_name": "",
            "direction": "S",
            "minutes_away": 0,
            "status": "On Time",
            "arrival_ts": 0,
            "is_cancelled": false,
        ]
        let result = try decoder.decode(TransitArrivalResponse.self, from: jsonData(json))
        #expect(result.routeId == "")
        #expect(result.stationName == "")
        #expect(result.arrivalTs == 0)
    }

    @Test func decodesNullOptionals() throws {
        let json: [String: Any?] = [
            "route_id": "L",
            "station": "L01",
            "station_name": "8 Av",
            "direction": "E",
            "destination": nil,
            "minutes_away": 3,
            "status": "On Time",
            "trip_id": nil,
            "arrival_ts": nil,
            "is_cancelled": false,
        ]
        let result = try decoder.decode(TransitArrivalResponse.self, from: jsonData(json as [String: Any]))
        #expect(result.destination == nil)
        #expect(result.tripId == nil)
        #expect(result.arrivalTs == nil)
    }

    @Test func decodesStopLatLon() throws {
        /// Backend now sends stop_lat/stop_lon — iOS decodes them.
        let json: [String: Any] = [
            "route_id": "A",
            "station": "A27N",
            "station_name": "59 St",
            "direction": "N",
            "minutes_away": 5,
            "status": "On Time",
            "arrival_ts": 1711200000,
            "is_cancelled": false,
            "stop_lat": 40.7681,
            "stop_lon": -73.9819,
        ]
        let result = try decoder.decode(TransitArrivalResponse.self, from: jsonData(json))
        #expect(result.stopLat == 40.7681)
        #expect(result.stopLon == -73.9819)
    }

    @Test func toleratesMissingStopLatLon() throws {
        /// Backend may send null stop_lat/stop_lon — iOS defaults to nil.
        let json: [String: Any] = [
            "route_id": "A",
            "station": "A27N",
            "station_name": "59 St",
            "direction": "N",
            "minutes_away": 5,
            "status": "On Time",
            "arrival_ts": 1711200000,
            "is_cancelled": false,
        ]
        let result = try decoder.decode(TransitArrivalResponse.self, from: jsonData(json))
        #expect(result.stopLat == nil)
        #expect(result.stopLon == nil)
    }

    @Test func decodesAsArray() throws {
        /// Endpoint returns [TrackArrival]
        let json: [[String: Any]] = [
            [
                "route_id": "A", "station": "A27N", "station_name": "59 St",
                "direction": "N", "minutes_away": 3, "status": "On Time",
                "arrival_ts": 1711200000, "is_cancelled": false,
            ],
            [
                "route_id": "A", "station": "A28S", "station_name": "Fulton St",
                "direction": "S", "minutes_away": 7, "status": "On Time",
                "arrival_ts": 1711200240, "is_cancelled": false,
            ],
        ]
        let results = try decoder.decode([TransitArrivalResponse].self, from: jsonData(json))
        #expect(results.count == 2)
    }

    @Test func toleratesExtraBackendFields() throws {
        /// If backend adds new fields, iOS must not crash.
        let json: [String: Any] = [
            "route_id": "A",
            "station": "A27N",
            "station_name": "59 St",
            "direction": "N",
            "minutes_away": 5,
            "status": "On Time",
            "arrival_ts": 1711200000,
            "is_cancelled": false,
            "some_future_field": "value",
            "another_new_int": 42,
        ]
        let result = try decoder.decode(TransitArrivalResponse.self, from: jsonData(json))
        #expect(result.routeId == "A")
    }
}

// MARK: - 2. NearbyTransitResponse (NearbyTransitArrival)

@Suite("Contract: NearbyTransitResponse")
struct NearbyTransitContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "route_id": "A",
            "stop_name": "Fulton St",
            "direction": "N",
            "destination": "Inwood-207 St",
            "minutes_away": 3,
            "arrival_ts": 1711200000,
            "status": "On Time",
            "mode": "subway",
            "stop_lat": 40.71,
            "stop_lon": -74.0,
            "stop_id": "A28N",
            "vehicle_id": NSNull(),
            "trip_id": "trip_1",
            "distance_m": 150.5,
            "is_real_time": true,
            "is_cancelled": false,
        ]
        let result = try decoder.decode(NearbyTransitResponse.self, from: jsonData(json))
        #expect(result.routeId == "A")
        #expect(result.stopName == "Fulton St")
        #expect(result.mode == "subway")
        #expect(result.isRealTime == true)
        #expect(result.isCancelled == false)
        #expect(result.distanceM == 150.5)
    }

    @Test func decodesMinimalPayload() throws {
        let json: [String: Any] = [
            "route_id": "A",
            "stop_name": "Fulton St",
            "direction": "N",
            "minutes_away": 5,
            "status": "On Time",
            "mode": "subway",
            "is_real_time": false,
            "is_cancelled": false,
        ]
        let result = try decoder.decode(NearbyTransitResponse.self, from: jsonData(json))
        #expect(result.destination == nil)
        #expect(result.arrivalTs == nil)
        #expect(result.stopLat == nil)
        #expect(result.stopLon == nil)
        #expect(result.vehicleId == nil)
        #expect(result.tripId == nil)
        #expect(result.distanceM == nil)
    }

    @Test func decodesBusArrival() throws {
        let json: [String: Any] = [
            "route_id": "MTA NYCT_B63",
            "stop_name": "Atlantic Av / 4 Av",
            "direction": "0",
            "destination": "BAY RIDGE via 5 AV",
            "minutes_away": 7,
            "arrival_ts": 1711200500,
            "status": "2 stops away",
            "mode": "bus",
            "stop_lat": 40.68,
            "stop_lon": -73.97,
            "stop_id": "MTA_300456",
            "vehicle_id": "MTABC_5678",
            "trip_id": NSNull(),
            "distance_m": 400.0,
            "is_real_time": true,
            "is_cancelled": false,
        ]
        let result = try decoder.decode(NearbyTransitResponse.self, from: jsonData(json))
        #expect(result.isBus == true)
        #expect(result.vehicleId == "MTABC_5678")
    }

    @Test func decodesLIRRArrival() throws {
        let json: [String: Any] = [
            "route_id": "LIRR_10",
            "stop_name": "Jamaica",
            "direction": "Inbound",
            "destination": "Penn Station",
            "minutes_away": 12,
            "arrival_ts": 1711200800,
            "status": "On Time",
            "mode": "lirr",
            "stop_lat": 40.70,
            "stop_lon": -73.81,
            "stop_id": "102",
            "is_real_time": false,
            "is_cancelled": false,
        ]
        let result = try decoder.decode(NearbyTransitResponse.self, from: jsonData(json))
        #expect(result.isLIRR == true)
        #expect(result.isCommuterRail == true)
    }
}

// MARK: - 3. GroupedNearbyTransitResponse (GroupedNearbyTransit)

@Suite("Contract: GroupedNearbyTransitResponse")
struct GroupedNearbyTransitContractTests {

    private static func makeArrival() -> [String: Any] {
        [
            "route_id": "A",
            "stop_name": "Fulton St",
            "direction": "N",
            "destination": "Inwood-207 St",
            "minutes_away": 3,
            "arrival_ts": 1711200000,
            "status": "On Time",
            "mode": "subway",
            "stop_lat": 40.71,
            "stop_lon": -74.0,
            "stop_id": "A28N",
            "vehicle_id": NSNull(),
            "trip_id": "trip_1",
            "distance_m": NSNull(),
            "is_real_time": true,
            "is_cancelled": false,
        ]
    }

    @Test func decodesFullGroupedResponse() throws {
        let json: [String: Any] = [
            "route_id": "A",
            "display_name": "A",
            "mode": "subway",
            "color_hex": "#0039A6",
            "directions": [
                [
                    "direction": "N",
                    "direction_label": "Inwood-207 St",
                    "arrivals": [Self.makeArrival()],
                ] as [String: Any],
                [
                    "direction": "S",
                    "direction_label": "Far Rockaway",
                    "arrivals": [] as [[String: Any]],
                ] as [String: Any],
            ],
            "sorting_key": "subway_01",
            "alerts": [
                [
                    "title": "A/C/E Delays",
                    "severity": "severe",
                    "affected_routes": ["A", "C", "E"],
                    "alert_type": "Delays",
                    "sort_order": 26,
                ] as [String: Any],
            ],
        ]

        let result = try decoder.decode(GroupedNearbyTransitResponse.self, from: jsonData(json))
        #expect(result.routeId == "A")
        #expect(result.displayName == "A")
        #expect(result.mode == "subway")
        #expect(result.colorHex == "#0039A6")
        #expect(result.directions.count == 2)
        #expect(result.sortingKey == "subway_01")
        #expect(result.alerts.count == 1)
        #expect(result.alerts[0].title == "A/C/E Delays")
        #expect(result.alerts[0].sortOrder == 26)
    }

    @Test func decodesMinimalGroupedResponse() throws {
        let json: [String: Any] = [
            "route_id": "X",
            "display_name": "X",
            "mode": "bus",
            "color_hex": NSNull(),
            "directions": [] as [[String: Any]],
            "sorting_key": "",
            "alerts": [] as [[String: Any]],
        ]
        let result = try decoder.decode(GroupedNearbyTransitResponse.self, from: jsonData(json))
        #expect(result.colorHex == nil)
        #expect(result.directions.isEmpty)
        #expect(result.alerts.isEmpty)
    }

    @Test func decodesDirectionLabelNull() throws {
        /// direction_label can be "" or null from backend
        let json: [String: Any] = [
            "direction": "N",
            "direction_label": NSNull(),
            "arrivals": [] as [[String: Any]],
        ]
        let result = try decoder.decode(DirectionArrivalsResponse.self, from: jsonData(json))
        #expect(result.directionLabel == nil)
    }

    @Test func decodesInlineAlert() throws {
        let json: [String: Any] = [
            "title": "Delays",
            "severity": "severe",
            "affected_routes": ["A", "C"],
            "alert_type": "Delays",
            "sort_order": 26,
        ]
        let result = try decoder.decode(InlineAlertResponse.self, from: jsonData(json))
        #expect(result.title == "Delays")
        #expect(result.affectedRoutes == ["A", "C"])
        #expect(result.sortOrder == 26)
    }

    @Test func decodesInlineAlertMinimal() throws {
        /// alert_type can be null, sort_order can be missing (defaults to 0)
        let json: [String: Any] = [
            "title": "Test",
            "severity": "warning",
        ]
        let result = try decoder.decode(InlineAlertResponse.self, from: jsonData(json))
        #expect(result.alertType == nil)
        #expect(result.affectedRoutes.isEmpty)
        #expect(result.sortOrder == 0)
    }

    @Test func decodesAsArray() throws {
        let group: [String: Any] = [
            "route_id": "A",
            "display_name": "A",
            "mode": "subway",
            "color_hex": "#0039A6",
            "directions": [] as [[String: Any]],
            "sorting_key": "",
            "alerts": [] as [[String: Any]],
        ]
        let results = try decoder.decode([GroupedNearbyTransitResponse].self, from: jsonData([group]))
        #expect(results.count == 1)
    }
}

// MARK: - 4. TransitAlert

@Suite("Contract: TransitAlert")
struct TransitAlertContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "route_id": "A",
            "title": "A/C/E Delays",
            "description": "Delays on the A, C, E lines.",
            "severity": "severe",
            "mode": "subway",
            "updated_at": 1711200000,
            "affected_routes": ["A", "C", "E"],
            "alert_type": "Delays",
            "sort_order": 26,
            "display_before_active": 3600,
            "active_period_end": 1711300000,
        ]
        let result = try decoder.decode(TransitAlert.self, from: jsonData(json))
        #expect(result.routeId == "A")
        #expect(result.title == "A/C/E Delays")
        #expect(result.severity == "severe")
        #expect(result.mode == "subway")
        #expect(result.sortOrder == 26)
        #expect(result.displayBeforeActive == 3600)
        #expect(result.activePeriodEnd == 1711300000)
        #expect(result.affectedRoutes == ["A", "C", "E"])
    }

    @Test func decodesMinimalPayload() throws {
        let json: [String: Any] = [
            "title": "Test Alert",
            "description": "A test",
            "severity": "warning",
        ]
        let result = try decoder.decode(TransitAlert.self, from: jsonData(json))
        #expect(result.routeId == nil)
        #expect(result.mode == "subway")  // default
        #expect(result.affectedRoutes.isEmpty)
        #expect(result.sortOrder == 0)
        #expect(result.alertType == nil)
    }

    @Test func decodesNullOptionals() throws {
        let json: [String: Any?] = [
            "route_id": nil,
            "title": "Test",
            "description": "D",
            "severity": "warning",
            "mode": "bus",
            "updated_at": nil,
            "affected_routes": ["B63"],
            "alert_type": nil,
            "sort_order": 0,
            "display_before_active": nil,
            "active_period_end": nil,
        ]
        let result = try decoder.decode(TransitAlert.self, from: jsonData(json as [String: Any]))
        #expect(result.routeId == nil)
        #expect(result.updatedAt == nil)
        #expect(result.alertType == nil)
    }
}

// MARK: - 5. ElevatorStatus

@Suite("Contract: ElevatorStatus")
struct ElevatorStatusContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "station": "Fulton St",
            "equipment_type": "Elevator",
            "description": "Out of service since 3/15",
            "outage_since": "2026-03-15",
        ]
        let result = try decoder.decode(ElevatorStatus.self, from: jsonData(json))
        #expect(result.station == "Fulton St")
        #expect(result.equipmentType == "Elevator")
        #expect(result.outageSince == "2026-03-15")
    }

    @Test func decodesNullOutage() throws {
        let json: [String: Any] = [
            "station": "S",
            "equipment_type": "Escalator",
            "description": "D",
            "outage_since": NSNull(),
        ]
        let result = try decoder.decode(ElevatorStatus.self, from: jsonData(json))
        #expect(result.outageSince == nil)
    }
}

// MARK: - 6. BusStop

@Suite("Contract: BusStop")
struct BusStopContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "id": "MTA_500249",
            "name": "Hillside Av / 169 St",
            "lat": 40.7091,
            "lon": -73.7906,
            "direction": "SW",
            "route_ids": ["MTA NYCT_Q43", "MTA NYCT_Q36"],
        ]
        let result = try decoder.decode(BusStop.self, from: jsonData(json))
        #expect(result.id == "MTA_500249")
        #expect(result.routeIds == ["MTA NYCT_Q43", "MTA NYCT_Q36"])
    }

    @Test func decodesMinimalPayload() throws {
        let json: [String: Any] = [
            "id": "S1",
            "name": "Stop",
            "lat": 40.0,
            "lon": -74.0,
        ]
        let result = try decoder.decode(BusStop.self, from: jsonData(json))
        #expect(result.direction == nil)
        #expect(result.routeIds == nil)
    }
}

// MARK: - 7. BusArrival

@Suite("Contract: BusArrival")
struct BusArrivalContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "route_id": "MTA NYCT_B63",
            "vehicle_id": "MTABC_5678",
            "stop_id": "MTA_300456",
            "stop_name": "Atlantic Av / 4 Av",
            "status_text": "2 stops away",
            "status": "Live",
            "expected_arrival": "2026-03-23T14:30:00Z",
            "distance_meters": 450.0,
            "bearing": 180.0,
            "direction_ref": 0,
            "destination_name": "BAY RIDGE via 5 AV",
        ]
        let result = try decoder.decode(BusArrival.self, from: jsonData(json))
        #expect(result.routeId == "MTA NYCT_B63")
        #expect(result.vehicleId == "MTABC_5678")
        #expect(result.directionRef == 0)
        #expect(result.destinationName == "BAY RIDGE via 5 AV")
        #expect(result.expectedArrival != nil)
    }

    @Test func decodesMinimalPayload() throws {
        let json: [String: Any] = [
            "route_id": "R",
            "vehicle_id": "V",
            "stop_id": "S",
            "status_text": "nearby",
            "status": "Live",
        ]
        let result = try decoder.decode(BusArrival.self, from: jsonData(json))
        #expect(result.stopName == nil)
        #expect(result.expectedArrival == nil)
        #expect(result.distanceMeters == nil)
        #expect(result.bearing == nil)
        #expect(result.directionRef == nil)
        #expect(result.destinationName == nil)
    }

    @Test func toleratesExtraBackendFields() throws {
        /// Backend sends aimed_arrival, schedule_deviation_s
        /// that iOS BusArrival does NOT have CodingKeys for.
        /// JSONDecoder must silently ignore them.
        let json: [String: Any] = [
            "route_id": "R",
            "vehicle_id": "V",
            "stop_id": "S",
            "status_text": "nearby",
            "status": "Live",
            "aimed_arrival": "2026-03-23T14:25:00Z",
            "schedule_deviation_s": 120,
            "is_realtime": true,
        ]
        let result = try decoder.decode(BusArrival.self, from: jsonData(json))
        #expect(result.routeId == "R")
        #expect(result.isRealtime == true)
    }

    @Test func decodesIsRealtime() throws {
        /// iOS BusArrival now decodes is_realtime.
        let json: [String: Any] = [
            "route_id": "R",
            "vehicle_id": "V",
            "stop_id": "S",
            "status_text": "nearby",
            "status": "Live",
            "is_realtime": false,
        ]
        let result = try decoder.decode(BusArrival.self, from: jsonData(json))
        #expect(result.isRealtime == false)
    }
}

// MARK: - 8. BusVehicleResponse (BusVehicle)

@Suite("Contract: BusVehicleResponse")
struct BusVehicleContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "vehicle_id": "MTABC_5678",
            "route_id": "MTA NYCT_B63",
            "lat": 40.6844,
            "lon": -73.9775,
            "bearing": 90.0,
            "next_stop": "Atlantic Av / 4 Av",
            "status_text": "1 stop away",
            "direction_ref": 0,
            "expected_arrival": "2026-03-23T14:30:00Z",
            "onward_calls": [
                [
                    "route_id": "MTA NYCT_B63",
                    "vehicle_id": "MTABC_5678",
                    "stop_id": "MTA_300457",
                    "status_text": "3 stops away",
                    "status": "Live",
                ] as [String: Any],
            ],
            "is_realtime": true,
        ]
        let result = try decoder.decode(BusVehicleResponse.self, from: jsonData(json))
        #expect(result.vehicleId == "MTABC_5678")
        #expect(result.isRealtime == true)
        #expect(result.onwardCalls?.count == 1)
        #expect(result.directionRef == 0)
    }

    @Test func decodesMinimalPayload() throws {
        let json: [String: Any] = [
            "vehicle_id": "V",
            "route_id": "R",
            "lat": 40.0,
            "lon": -74.0,
        ]
        let result = try decoder.decode(BusVehicleResponse.self, from: jsonData(json))
        #expect(result.bearing == nil)
        #expect(result.nextStop == nil)
        #expect(result.isRealtime == true)  // default
    }

    @Test func decodesPositionRecordedAt() throws {
        /// iOS BusVehicleResponse now decodes position_recorded_at.
        let json: [String: Any] = [
            "vehicle_id": "V",
            "route_id": "R",
            "lat": 40.0,
            "lon": -74.0,
            "position_recorded_at": "2026-03-23T14:28:00Z",
        ]
        let result = try decoder.decode(BusVehicleResponse.self, from: jsonData(json))
        #expect(result.positionRecordedAt != nil)
    }

    @Test func toleratesExtraBackendFields() throws {
        /// Future unknown keys must not crash decoding.
        let json: [String: Any] = [
            "vehicle_id": "V",
            "route_id": "R",
            "lat": 40.0,
            "lon": -74.0,
            "some_future_field": "value",
        ]
        let result = try decoder.decode(BusVehicleResponse.self, from: jsonData(json))
        #expect(result.vehicleId == "V")
    }
}

// MARK: - 9. BusRoute

@Suite("Contract: BusRoute")
struct BusRouteContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "id": "MTA NYCT_B63",
            "short_name": "B63",
            "long_name": "Atlantic Av / Grand Army Plaza",
            "color": "0039A6",
            "description": "Brooklyn",
        ]
        let result = try decoder.decode(BusRoute.self, from: jsonData(json))
        #expect(result.id == "MTA NYCT_B63")
        #expect(result.shortName == "B63")
        #expect(result.longName == "Atlantic Av / Grand Army Plaza")
        #expect(result.color == "0039A6")
    }
}

// MARK: - 10. RouteShapeResponse (RouteShape)

@Suite("Contract: RouteShapeResponse")
struct RouteShapeContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "route_id": "L",
            "polylines": ["_p~iF~ps|U_ulLnnqC"],
            "stops": [
                ["id": "L01", "name": "8 Av", "lat": 40.74, "lon": -74.0] as [String: Any],
            ],
            "directions": [
                [
                    "direction_id": 0,
                    "headsign": "8 Av",
                    "polylines": ["_p~iF~ps|U_ulLnnqC"],
                    "stops": [
                        ["id": "L01", "name": "8 Av", "lat": 40.74, "lon": -74.0] as [String: Any],
                    ],
                    "service_type": "local",
                ] as [String: Any],
            ],
            "service_type": "local",
        ]
        let result = try decoder.decode(RouteShapeResponse.self, from: jsonData(json))
        #expect(result.routeId == "L")
        #expect(result.polylines.count == 1)
        #expect(result.stops.count == 1)
        #expect(result.directions.count == 1)
        #expect(result.directions[0].directionId == 0)
        #expect(result.serviceType == "local")
    }

    @Test func decodesMinimalPayload() throws {
        let json: [String: Any] = [
            "route_id": "X",
            "polylines": [] as [String],
            "stops": [] as [[String: Any]],
            "directions": [] as [[String: Any]],
        ]
        let result = try decoder.decode(RouteShapeResponse.self, from: jsonData(json))
        #expect(result.directions.isEmpty)
        #expect(result.serviceType == nil)
    }
}

// MARK: - 11. SubwayLineOverlay

@Suite("Contract: SubwayLineOverlay")
struct SubwayLineOverlayContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "route_id": "A",
            "color_hex": "#0039A6",
            "polylines": ["abc", "def"],
        ]
        let result = try decoder.decode(SubwayLineOverlay.self, from: jsonData(json))
        #expect(result.routeId == "A")
        #expect(result.colorHex == "#0039A6")
        #expect(result.polylines.count == 2)
    }
}

// MARK: - 12. TrunkGroupPolylines

@Suite("Contract: TrunkGroupPolylines")
struct TrunkGroupPolylinesContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "trunk_index": 0,
            "color_hex": "#0039A6",
            "route_ids": ["A", "C", "E"],
            "polylines": ["abc", "def"],
            "lane_offset": -12.0,
            "polyline_lane_offsets": [-12.0, 0.0],
        ]
        let result = try decoder.decode(TrunkGroupPolylines.self, from: jsonData(json))
        #expect(result.trunkIndex == 0)
        #expect(result.colorHex == "#0039A6")
        #expect(result.routeIds == ["A", "C", "E"])
        #expect(result.polylines.count == 2)
        #expect(result.laneOffset == -12.0)
        #expect(result.polylineLaneOffsets == [-12.0, 0.0])
    }

    @Test func decodesWithoutOptionalOffsets() throws {
        /// lane_offset and polyline_lane_offsets default to 0/[] when missing
        let json: [String: Any] = [
            "trunk_index": 0,
            "color_hex": "#C",
            "route_ids": ["A"],
            "polylines": ["abc"],
        ]
        let result = try decoder.decode(TrunkGroupPolylines.self, from: jsonData(json))
        #expect(result.laneOffset == 0.0)
        #expect(result.polylineLaneOffsets.isEmpty)
    }
}

// MARK: - 13. AllSubwayLinesResponse

@Suite("Contract: AllSubwayLinesResponse")
struct AllSubwayLinesResponseContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "lines": [
                ["route_id": "A", "color_hex": "#0039A6", "polylines": ["abc"]] as [String: Any],
                ["route_id": "L", "color_hex": "#A7A9AC", "polylines": ["def"]] as [String: Any],
            ],
            "trunk_polylines": [
                [
                    "trunk_index": 0,
                    "color_hex": "#0039A6",
                    "route_ids": ["A", "C", "E"],
                    "polylines": ["abc"],
                    "lane_offset": -12.0,
                    "polyline_lane_offsets": [-12.0],
                ] as [String: Any],
            ],
        ]
        let result = try decoder.decode(AllSubwayLinesResponse.self, from: jsonData(json))
        #expect(result.lines.count == 2)
        #expect(result.trunkPolylines?.count == 1)
    }

    @Test func decodesWithEmptyTrunkPolylines() throws {
        /// Backend sends [] by default — iOS decodes as .some([])
        let json: [String: Any] = [
            "lines": [] as [[String: Any]],
            "trunk_polylines": [] as [[String: Any]],
        ]
        let result = try decoder.decode(AllSubwayLinesResponse.self, from: jsonData(json))
        #expect(result.trunkPolylines?.isEmpty == true)
    }

    @Test func decodesWithMissingTrunkPolylines() throws {
        /// Backward compat: old responses might not have trunk_polylines
        let json: [String: Any] = [
            "lines": [] as [[String: Any]],
        ]
        let result = try decoder.decode(AllSubwayLinesResponse.self, from: jsonData(json))
        #expect(result.trunkPolylines == nil)
    }
}

// MARK: - 14. SubwayStation & AllSubwayStationsResponse

@Suite("Contract: SubwayStation")
struct SubwayStationContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "id": "A27",
            "name": "59 St-Columbus Circle",
            "lat": 40.768,
            "lon": -73.981,
            "routes": ["A", "C", "B", "D", "1"],
        ]
        let result = try decoder.decode(SubwayStation.self, from: jsonData(json))
        #expect(result.id == "A27")
        #expect(result.routes.count == 5)
    }

    @Test func decodesAllStationsResponse() throws {
        let json: [String: Any] = [
            "stations": [
                ["id": "A27", "name": "59 St", "lat": 40.768, "lon": -73.981, "routes": ["A"]] as [String: Any],
            ],
        ]
        let result = try decoder.decode(AllSubwayStationsResponse.self, from: jsonData(json))
        #expect(result.stations.count == 1)
    }
}

// MARK: - 15. ProcessedStation & ProcessedStationsResponse

@Suite("Contract: ProcessedStation")
struct ProcessedStationContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "stations": [
                [
                    "station_id": "A27",
                    "name": "59 St-Columbus Circle",
                    "is_transfer": true,
                    "positions": [
                        ["route_id": "A", "lat": 40.7681, "lon": -73.9813] as [String: Any],
                        ["route_id": "1", "lat": 40.7680, "lon": -73.9814] as [String: Any],
                    ],
                ] as [String: Any],
            ],
        ]
        let result = try decoder.decode(ProcessedStationsResponse.self, from: jsonData(json))
        #expect(result.stations.count == 1)
        #expect(result.stations[0].stationId == "A27")
        #expect(result.stations[0].isTransfer == true)
        #expect(result.stations[0].positions.count == 2)
        #expect(result.stations[0].positions[0].routeId == "A")
    }
}

// MARK: - 16. CommuterRailLineOverlay & AllCommuterRailLinesResponse

@Suite("Contract: CommuterRailLineOverlay")
struct CommuterRailContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "route_id": "LIRR_10",
            "name": "Babylon",
            "color_hex": "#00985F",
            "polylines": ["abc"],
            "mode": "lirr",
            "stops": [
                ["stop_id": "1", "name": "Jamaica", "lat": 40.699, "lon": -73.808] as [String: Any],
            ],
        ]
        let result = try decoder.decode(CommuterRailLineOverlay.self, from: jsonData(json))
        #expect(result.routeId == "LIRR_10")
        #expect(result.name == "Babylon")
        #expect(result.mode == "lirr")
        #expect(result.stops.count == 1)
    }

    @Test func decodesWithoutStops() throws {
        /// stops defaults to [] when missing (custom init(from:))
        let json: [String: Any] = [
            "route_id": "MNR_1",
            "name": "Hudson",
            "color_hex": "#009B3A",
            "polylines": ["abc"],
            "mode": "mnr",
        ]
        let result = try decoder.decode(CommuterRailLineOverlay.self, from: jsonData(json))
        #expect(result.stops.isEmpty)
    }

    @Test func decodesAllCommuterRailResponse() throws {
        let json: [String: Any] = [
            "lines": [
                [
                    "route_id": "LIRR_10", "name": "Babylon",
                    "color_hex": "#00985F", "polylines": ["abc"],
                    "mode": "lirr", "stops": [] as [[String: Any]],
                ] as [String: Any],
            ],
        ]
        let result = try decoder.decode(AllCommuterRailLinesResponse.self, from: jsonData(json))
        #expect(result.lines.count == 1)
    }
}

// MARK: - 17. BusScheduleResponse

@Suite("Contract: BusScheduleResponse")
struct BusScheduleContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "route_id": "MTA NYCT_B63",
            "directions": [
                [
                    "direction": "0",
                    "headsign": "Bay Ridge",
                    "departures": [
                        [
                            "stop_name": "Atlantic Av / 4 Av",
                            "stop_id": "MTA_300456",
                            "departure_time": 1711200600,
                            "headsign": "Bay Ridge",
                            "trip_id": "trip_001",
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ],
        ]
        let result = try decoder.decode(BusScheduleResponse.self, from: jsonData(json))
        #expect(result.routeId == "MTA NYCT_B63")
        #expect(result.directions.count == 1)
        #expect(result.directions[0].departures.count == 1)
        #expect(result.directions[0].departures[0].stopName == "Atlantic Av / 4 Av")
        #expect(result.directions[0].departures[0].departureTime == 1711200600)
    }
}

// MARK: - 18. DelayPrediction

@Suite("Contract: DelayPrediction")
struct DelayPredictionContractTests {

    @Test func decodesFullPayload() throws {
        let json: [String: Any] = [
            "adjusted_minutes": 7,
            "original_minutes": 5,
            "delay_factor": 1.4,
            "adjustment_reason": "Rain delay (+2m)",
            "model_source": "heuristic",
            "recency_error_seconds": 30.0,
        ]
        let result = try decoder.decode(DelayPrediction.self, from: jsonData(json))
        #expect(result.adjustedMinutes == 7)
        #expect(result.originalMinutes == 5)
        #expect(result.delayFactor == 1.4)
        #expect(result.adjustmentReason == "Rain delay (+2m)")
        #expect(result.modelSource == "heuristic")
        #expect(result.recencyErrorSeconds == 30.0)
    }

    @Test func decodesNullReason() throws {
        let json: [String: Any] = [
            "adjusted_minutes": 5,
            "original_minutes": 5,
            "delay_factor": 1.0,
            "adjustment_reason": NSNull(),
            "model_source": "disabled",
            "recency_error_seconds": 0.0,
        ]
        let result = try decoder.decode(DelayPrediction.self, from: jsonData(json))
        #expect(result.adjustmentReason == nil)
    }
}

// MARK: - 19. Forward Compatibility (extra fields)

@Suite("Contract: Forward Compatibility")
struct ForwardCompatibilityTests {

    @Test func allModelsTolerateFutureFields() throws {
        /// When the backend adds new fields, iOS must not crash.
        /// JSONDecoder ignores unknown keys by default, but custom
        /// init(from:) implementations could break this. Test all models.

        // GroupedNearbyTransitResponse with extra field
        let groupJSON: [String: Any] = [
            "route_id": "A", "display_name": "A", "mode": "subway",
            "color_hex": "#0039A6",
            "directions": [] as [[String: Any]],
            "sorting_key": "", "alerts": [] as [[String: Any]],
            "future_field": "hello",
        ]
        _ = try decoder.decode(GroupedNearbyTransitResponse.self, from: jsonData(groupJSON))

        // TransitAlert with extra field
        let alertJSON: [String: Any] = [
            "title": "T", "description": "D", "severity": "warning",
            "new_severity_level": 5,
        ]
        _ = try decoder.decode(TransitAlert.self, from: jsonData(alertJSON))

        // CommuterRailLineOverlay with extra field
        let crJSON: [String: Any] = [
            "route_id": "LIRR_10", "name": "Babylon",
            "color_hex": "#00985F", "polylines": ["abc"],
            "mode": "lirr", "branch_code": "BAB",
        ]
        _ = try decoder.decode(CommuterRailLineOverlay.self, from: jsonData(crJSON))

        // InlineAlertResponse with extra field
        let iaJSON: [String: Any] = [
            "title": "T", "severity": "warning",
            "resolution_eta": 1711300000,
        ]
        _ = try decoder.decode(InlineAlertResponse.self, from: jsonData(iaJSON))
    }
}
