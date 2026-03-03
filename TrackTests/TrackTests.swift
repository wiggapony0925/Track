//
//  TrackTests.swift
//  TrackTests
//
//  Created by Jeffrey Fernandez on 2/10/26.
//

import CoreLocation
import Testing
@testable import Track

@MainActor
struct TrackTests {

    // MARK: - DelayCalculator Tests (disabled — DelayCalculator was removed)
    #if false

    @Test func delayCalculatorReturnsOriginalTimeInClearWeatherOffPeak() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 5,
            routeID: "L",
            timeOfDay: 14, // 2 PM, off-peak
            dayOfWeek: 4,  // Wednesday
            weather: .clear
        )
        #expect(prediction.adjustedMinutes == 5)
        #expect(prediction.adjustmentReason == nil)
    }

    @Test func delayCalculatorAppliesRushHourAdjustment() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 10,
            routeID: "4",
            timeOfDay: 8,  // 8 AM morning rush
            dayOfWeek: 3,  // Tuesday (weekday)
            weather: .clear
        )
        // Rush hour adds 10%, so 10 * 1.1 = 11
        #expect(prediction.adjustedMinutes == 11)
        #expect(prediction.adjustmentReason != nil)
        #expect(prediction.adjustmentReason!.contains("rush hour"))
    }

    @Test func delayCalculatorAppliesRainAdjustment() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 10,
            routeID: "L",
            timeOfDay: 14,
            dayOfWeek: 1,  // Sunday (not a weekday)
            weather: .rain
        )
        // Rain adds 10%, so 10 * 1.1 = 11
        #expect(prediction.adjustedMinutes == 11)
        #expect(prediction.adjustmentReason!.contains("rain"))
    }

    @Test func delayCalculatorAppliesSnowAdjustment() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 10,
            routeID: "L",
            timeOfDay: 14,
            dayOfWeek: 1,
            weather: .snow
        )
        // Snow adds 20%, so 10 * 1.2 = 12
        #expect(prediction.adjustedMinutes == 12)
        #expect(prediction.adjustmentReason!.contains("snow"))
    }

    @Test func delayCalculatorCombinesRushHourAndWeather() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 10,
            routeID: "A",
            timeOfDay: 17, // 5 PM evening rush
            dayOfWeek: 2,  // Monday (weekday)
            weather: .rain
        )
        // Rush hour 10% + Rain 10% = 1.2, so 10 * 1.2 = 12
        #expect(prediction.adjustedMinutes == 12)
        #expect(prediction.adjustmentReason!.contains("rush hour"))
        #expect(prediction.adjustmentReason!.contains("rain"))
    }

    @Test func delayCalculatorNoRushOnWeekend() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 10,
            routeID: "L",
            timeOfDay: 8,  // 8 AM but Saturday
            dayOfWeek: 7,  // Saturday
            weather: .clear
        )
        #expect(prediction.adjustedMinutes == 10)
        #expect(prediction.adjustmentReason == nil)
    }
    #endif

    // MARK: - WeatherCondition Tests

    @Test func weatherConditionCodable() async throws {
        let conditions: [WeatherCondition] = [.clear, .rain, .snow]
        for condition in conditions {
            let data = try JSONEncoder().encode(condition)
            let decoded = try JSONDecoder().decode(WeatherCondition.self, from: data)
            #expect(decoded == condition)
        }
    }

    // MARK: - DelayPrediction Tests

    @Test func delayPredictionProperties() async throws {
        let prediction = DelayPrediction(
            adjustedMinutes: 6,
            originalMinutes: 5,
            delayFactor: 1.2,
            adjustmentReason: "Adjusted for rain (+1m)",
            modelSource: "model",
            recencyErrorSeconds: 12.5
        )
        #expect(prediction.adjustedMinutes == 6)
        #expect(prediction.originalMinutes == 5)
        #expect(prediction.delayFactor == 1.2)
        #expect(prediction.adjustmentReason == "Adjusted for rain (+1m)")
        #expect(prediction.modelSource == "model")
        #expect(prediction.recencyErrorSeconds == 12.5)
    }

    // MARK: - RouteSuggestion Tests

    @Test func routeSuggestionProperties() async throws {
        let suggestion = RouteSuggestion(
            routeID: "2",
            direction: "Uptown",
            destinationName: "Work",
            score: 5.0
        )
        #expect(suggestion.routeID == "2")
        #expect(suggestion.direction == "Uptown")
        #expect(suggestion.destinationName == "Work")
        #expect(suggestion.score == 5.0)
    }

    // MARK: - TransitError Tests

    @Test func transitErrorDescriptions() async throws {
        #expect(TransitError.networkUnavailable.description == "No network connection available")
        #expect(TransitError.feedParsingFailed.description == "Unable to read transit data")
        #expect(TransitError.signalLost.description == "Signal Lost in Tunnel")
    }

    // MARK: - Polyline Simplification Tests

    @Test func simplifyPolylinePreservesEndpoints() async throws {
        let coords: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            CLLocationCoordinate2D(latitude: 40.7130, longitude: -74.0058),
            CLLocationCoordinate2D(latitude: 40.7132, longitude: -74.0056),
            CLLocationCoordinate2D(latitude: 40.7135, longitude: -74.0050),
        ]
        let simplified = simplifyPolyline(coords, tolerance: 0.001)
        #expect(simplified.first!.latitude == coords.first!.latitude)
        #expect(simplified.first!.longitude == coords.first!.longitude)
        #expect(simplified.last!.latitude == coords.last!.latitude)
        #expect(simplified.last!.longitude == coords.last!.longitude)
    }

    @Test func simplifyPolylineReducesCollinearPoints() async throws {
        // Three collinear points — the middle one should be removed
        let coords: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 40.7000, longitude: -74.0000),
            CLLocationCoordinate2D(latitude: 40.7500, longitude: -74.0000),
            CLLocationCoordinate2D(latitude: 40.8000, longitude: -74.0000),
        ]
        let simplified = simplifyPolyline(coords, tolerance: 0.0001)
        #expect(simplified.count == 2)
    }

    @Test func simplifyPolylineKeepsSharpTurns() async throws {
        // L-shaped path — the corner point must be preserved
        let coords: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 40.7000, longitude: -74.0000),
            CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9000),
            CLLocationCoordinate2D(latitude: 40.8000, longitude: -73.9000),
        ]
        let simplified = simplifyPolyline(coords, tolerance: 0.0001)
        #expect(simplified.count == 3)
    }

    @Test func simplifyPolylineHandlesShortArrays() async throws {
        // Empty array
        let empty: [CLLocationCoordinate2D] = []
        #expect(simplifyPolyline(empty, tolerance: 0.001).isEmpty)

        // Single point
        let single = [CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0)]
        #expect(simplifyPolyline(single, tolerance: 0.001).count == 1)

        // Two points — returned as-is
        let two = [
            CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0),
            CLLocationCoordinate2D(latitude: 40.8, longitude: -74.0),
        ]
        #expect(simplifyPolyline(two, tolerance: 0.001).count == 2)
    }

    @Test func simplifyPolylineWithZeroToleranceKeepsAll() async throws {
        let coords: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 40.7000, longitude: -74.0000),
            CLLocationCoordinate2D(latitude: 40.7001, longitude: -74.0001),
            CLLocationCoordinate2D(latitude: 40.7003, longitude: -74.0000),
            CLLocationCoordinate2D(latitude: 40.7005, longitude: -74.0002),
        ]
        let simplified = simplifyPolyline(coords, tolerance: 0)
        #expect(simplified.count == coords.count)
    }

    // MARK: - ArrivalETAEngine Tests

    /// Vehicle coord + stop coord provided → source should be vehiclePosition.
    @Test func etaEngineUsesVehiclePositionWhenProvided() async throws {
        // Vehicle is ~500 m north of the stop along the same longitude
        let vehicleCoord = CLLocationCoordinate2D(latitude: 40.7050, longitude: -74.0060)
        let stopCoord    = CLLocationCoordinate2D(latitude: 40.7005, longitude: -74.0060)
        let futureTs = Int(Date.now.timeIntervalSince1970) + 300  // 5 min from now

        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: vehicleCoord,
            vehicleKey: "test-v1",
            stopCoord: stopCoord,
            polyline: nil,
            arrivalTs: futureTs,
            staticMinutes: 10,
            mode: "subway"
        )
        #expect(eta.source == .vehiclePosition)
        #expect(!eta.isPastArrival)
    }

    /// No vehicle coord → engine should count down from the feed's arrivalTs.
    @Test func etaEngineFallsBackToFeedTimestamp() async throws {
        let futureTs = Int(Date.now.timeIntervalSince1970) + 240  // 4 min from now
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: nil,
            vehicleKey: nil,
            stopCoord: nil,
            polyline: nil,
            arrivalTs: futureTs,
            staticMinutes: 99,
            mode: "bus"
        )
        #expect(eta.source == .feedTimestamp)
        // secondsRemaining should be close to 240 (±5 s for execution time)
        #expect(eta.secondsRemaining >= 230)
        #expect(eta.secondsRemaining <= 245)
    }

    /// Vehicle within 50 m of stop → isAtStop must be true.
    @Test func etaEngineReturnsNowWhenVehicleAtStop() async throws {
        // Close enough: ~10 m offset
        let stopCoord    = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let vehicleCoord = CLLocationCoordinate2D(latitude: 40.71281, longitude: -74.0060)

        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: vehicleCoord,
            vehicleKey: "test-v2",
            stopCoord: stopCoord,
            polyline: nil,
            arrivalTs: nil,
            staticMinutes: 1,
            mode: "subway"
        )
        #expect(eta.isAtStop)
        #expect(eta.secondsRemaining == 0)
    }

    /// Stopped vehicle within 150 m of destination stop → treated as "Now"
    /// (dwell detection: speed ≈ 0 && routeDistance < 150 m).
    @Test func etaEngineStoppedVehicleNearStopIsNow() async throws {
        // Place vehicle ~80 m south of the stop — well within 150 m
        let stopCoord    = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let vehicleCoord = CLLocationCoordinate2D(latitude: 40.7121, longitude: -74.0060)

        // Record the same position twice with 20 s gap → speed = 0
        let key = "test-dwell"
        ArrivalETAEngine.recordPosition(
            vehicleKey: key,
            coordinate: vehicleCoord,
            at: Date.now.addingTimeInterval(-20))
        ArrivalETAEngine.recordPosition(
            vehicleKey: key,
            coordinate: vehicleCoord,
            at: Date.now)

        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: vehicleCoord,
            vehicleKey: key,
            stopCoord: stopCoord,
            polyline: nil,
            arrivalTs: nil,
            staticMinutes: 2,
            mode: "subway"
        )
        // With speed=0 and routeDistance < 150 m, engine returns isAtStop=true
        #expect(eta.isAtStop)
        ArrivalETAEngine.clearHistory(for: key)
    }

    /// When routeDistance > 2 km and no position history, the feed timestamp
    /// is weighted more heavily (positionWeight ≈ 0.3).
    @Test func etaEngineBlendedETAFavorsFeedWhenFar() async throws {
        // Vehicle is ~3 km north of stop
        let vehicleCoord = CLLocationCoordinate2D(latitude: 40.7400, longitude: -74.0060)
        let stopCoord    = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        // Feed says 5 min; position-speed would estimate ~3000/9 = 333 s ≈ 5.5 min
        let futureTs = Int(Date.now.timeIntervalSince1970) + 300

        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: vehicleCoord,
            vehicleKey: "test-far",
            stopCoord: stopCoord,
            polyline: nil,
            arrivalTs: futureTs,
            staticMinutes: 5,
            mode: "subway"
        )
        #expect(eta.source == .vehiclePosition)
        // Blended result should be close to the feed (5 min = 300 s) —
        // with 0.3 position weight and similar estimates, expect ~300–360 s
        #expect(eta.secondsRemaining >= 200)
        #expect(eta.secondsRemaining <= 400)
    }
}

@MainActor
@Suite(.serialized)
struct DistanceBucketUtilsTests {
    private let nearKey = "near_you_radius_meters"
    private let fartherKey = "farther_away_radius_meters"
    private let muchFartherKey = "much_farther_away_radius_meters"

    @Test func groupedBucketsCoverEverySliderStepWithoutDroppingRoutes() async throws {
        let origin = CLLocation(latitude: 40.7128, longitude: -74.0060)
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: nearKey)
            defaults.removeObject(forKey: fartherKey)
            defaults.removeObject(forKey: muchFartherKey)
        }

        var sliderValues = Array(stride(from: 1600.0, through: 16000.0, by: 200.0))
        sliderValues.append(16093.0)

        for slider in sliderValues {
            let near = derivedNearRadius(from: slider)
            let farther = derivedFartherRadius(from: slider, near: near)
            defaults.set(near, forKey: nearKey)
            defaults.set(farther, forKey: fartherKey)
            defaults.set(slider, forKey: muchFartherKey)

            let distances: [Double] = [
                max(10, near * 0.25),
                near,
                near + 1,
                (near + farther) / 2,
                farther,
                farther + 1,
                slider,
            ]

            let groups = distances.enumerated().map { index, meters in
                makeGroup(routeId: "R\(index)", distanceMeters: meters, origin: origin)
            }

            let buckets = separateGroupsByDistance(groups: groups, from: origin)
            let allAssigned = buckets.nearYou + buckets.fartherAway + buckets.muchFarther

            #expect(allAssigned.count == groups.count)
            #expect(Set(allAssigned.map(\.routeId)) == Set(groups.map(\.routeId)))

            let nearIds = Set(buckets.nearYou.map(\.routeId))
            let fartherIds = Set(buckets.fartherAway.map(\.routeId))
            let muchFartherIds = Set(buckets.muchFarther.map(\.routeId))
            #expect(nearIds.isDisjoint(with: fartherIds))
            #expect(nearIds.isDisjoint(with: muchFartherIds))
            #expect(fartherIds.isDisjoint(with: muchFartherIds))

            for group in buckets.nearYou {
                #expect(groupMinDistance(for: group, from: origin) <= near)
            }
            for group in buckets.fartherAway {
                let distance = groupMinDistance(for: group, from: origin)
                #expect(distance > near)
                #expect(distance <= farther)
            }
            for group in buckets.muchFarther {
                let distance = groupMinDistance(for: group, from: origin)
                #expect(distance > farther)
                #expect(distance <= slider)
            }

            assertAscendingDistance(buckets.nearYou, from: origin)
            assertAscendingDistance(buckets.fartherAway, from: origin)
            assertAscendingDistance(buckets.muchFarther, from: origin)
        }
    }

    @Test func flatArrivalBucketsCoverEverySliderStepWithoutDroppingArrivals() async throws {
        let origin = CLLocation(latitude: 40.7128, longitude: -74.0060)
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: nearKey)
            defaults.removeObject(forKey: fartherKey)
            defaults.removeObject(forKey: muchFartherKey)
        }

        var sliderValues = Array(stride(from: 1600.0, through: 16000.0, by: 200.0))
        sliderValues.append(16093.0)

        for slider in sliderValues {
            let near = derivedNearRadius(from: slider)
            let farther = derivedFartherRadius(from: slider, near: near)
            defaults.set(near, forKey: nearKey)
            defaults.set(farther, forKey: fartherKey)
            defaults.set(slider, forKey: muchFartherKey)

            let distances: [Double] = [
                max(10, near * 0.25),
                near,
                near + 1,
                (near + farther) / 2,
                farther,
                farther + 1,
                slider,
            ]

            let arrivals = distances.enumerated().map { index, meters in
                makeArrival(routeId: "F\(index)", distanceMeters: meters, origin: origin)
            }

            let buckets = separateFlatArrivalsByDistance(arrivals: arrivals, from: origin)
            let allAssigned = buckets.nearYou + buckets.fartherAway

            #expect(allAssigned.count == arrivals.count)
            #expect(Set(allAssigned.map(\.id)) == Set(arrivals.map(\.id)))

            let nearIds = Set(buckets.nearYou.map(\.id))
            let fartherIds = Set(buckets.fartherAway.map(\.id))
            #expect(nearIds.isDisjoint(with: fartherIds))

            for arrival in buckets.nearYou {
                #expect(arrivalDistance(for: arrival, from: origin) <= near)
            }
            for arrival in buckets.fartherAway {
                #expect(arrivalDistance(for: arrival, from: origin) > near)
            }

            assertAscendingFlatDistance(buckets.nearYou, from: origin)
            assertAscendingFlatDistance(buckets.fartherAway, from: origin)
        }
    }

    @Test func groupedBucketsExcludeRoutesOutsideLargestRadius() async throws {
        let origin = CLLocation(latitude: 40.7128, longitude: -74.0060)
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: nearKey)
            defaults.removeObject(forKey: fartherKey)
            defaults.removeObject(forKey: muchFartherKey)
        }

        let slider = 8047.0
        let near = derivedNearRadius(from: slider)
        let farther = derivedFartherRadius(from: slider, near: near)
        defaults.set(near, forKey: nearKey)
        defaults.set(farther, forKey: fartherKey)
        defaults.set(slider, forKey: muchFartherKey)

        let inside = makeGroup(routeId: "IN", distanceMeters: slider - 50, origin: origin)
        let outside = makeGroup(routeId: "OUT", distanceMeters: slider + 500, origin: origin)

        let buckets = separateGroupsByDistance(groups: [inside, outside], from: origin)
        let allAssigned = buckets.nearYou + buckets.fartherAway + buckets.muchFarther
        let assignedIds = Set(allAssigned.map(\.routeId))

        #expect(assignedIds.contains("IN"))
        #expect(!assignedIds.contains("OUT"))
    }

    @Test func groupedBucketsKeepRoutesWithMissingCoordinates() async throws {
        let origin = CLLocation(latitude: 40.7128, longitude: -74.0060)
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: nearKey)
            defaults.removeObject(forKey: fartherKey)
            defaults.removeObject(forKey: muchFartherKey)
        }

        let slider = 8047.0
        let near = derivedNearRadius(from: slider)
        let farther = derivedFartherRadius(from: slider, near: near)
        defaults.set(near, forKey: nearKey)
        defaults.set(farther, forKey: fartherKey)
        defaults.set(slider, forKey: muchFartherKey)

        let missingCoords = GroupedNearbyTransitResponse(
            routeId: "NOC",
            displayName: "No Coords",
            mode: "bus",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Northbound",
                    directionLabel: "Northbound",
                    arrivals: [
                        NearbyTransitResponse(
                            routeId: "NOC",
                            stopName: "Unknown",
                            direction: "Northbound",
                            destination: "Terminal",
                            minutesAway: 5,
                            status: "OK",
                            mode: "bus",
                            stopLat: nil,
                            stopLon: nil,
                            arrivalTs: Int(Date.now.timeIntervalSince1970) + 300,
                            vehicleId: "V-NOC",
                            tripId: "T-NOC",
                            stopId: "S-NOC"
                        )
                    ]
                )
            ]
        )

        let buckets = separateGroupsByDistance(groups: [missingCoords], from: origin)
        #expect(buckets.nearYou.isEmpty)
        #expect(buckets.fartherAway.isEmpty)
        #expect(buckets.muchFarther.map(\.routeId) == ["NOC"])
    }

    @Test func busDisplayDistanceUsesArrivalCoords() async throws {
        let origin = CLLocation(latitude: 40.7128, longitude: -74.0060)
        let viewModel = HomeViewModel()

        // nearbyBusStops matching Q10 exist but are FARTHER than the arrival.
        // displayDistanceMeters takes min(nearby, arrival) → arrival wins.
        viewModel.nearbyBusStops = [
            BusStop(
                id: "FAR",
                name: "Far Stop",
                lat: origin.coordinate.latitude + (1200.0 / 111_111.0),
                lon: origin.coordinate.longitude,
                direction: nil,
                routeIds: ["MTA NYCT_Q10"]
            ),
        ]

        let group = GroupedNearbyTransitResponse(
            routeId: "MTA NYCT_Q10",
            displayName: "Q10",
            mode: "bus",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Northbound",
                    directionLabel: "Northbound",
                    arrivals: [
                        makeArrival(routeId: "Q10", distanceMeters: 800, origin: origin)
                    ]
                )
            ]
        )

        let result = viewModel.displayDistanceMeters(for: group, from: origin)
        #expect(result != nil)
        // min(nearbyStop ~1200 m, arrival ~800 m) → uses arrival coords.
        #expect((result ?? 0) > 700)
        #expect((result ?? 0) < 900)
    }

    @Test func busDisplayDistanceFallsBackToGroupedStopsWhenNearbyStopMetadataMissing() async throws {
        let origin = CLLocation(latitude: 40.7128, longitude: -74.0060)
        let viewModel = HomeViewModel()
        viewModel.nearbyBusStops = []

        let group = GroupedNearbyTransitResponse(
            routeId: "MTA NYCT_B63",
            displayName: "B63",
            mode: "bus",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Southbound",
                    directionLabel: "Southbound",
                    arrivals: [
                        makeArrival(routeId: "B63", distanceMeters: 430, origin: origin)
                    ]
                )
            ]
        )

        let anchored = viewModel.displayDistanceMeters(for: group, from: origin)
        #expect(anchored != nil)
        #expect((anchored ?? 0) > 300)
        #expect((anchored ?? 0) < 560)
    }

    // MARK: - Unified displayDistanceMeters (groupMinDistance only)

    @Test func subwayDisplayDistanceUsesArrivalCoords() async throws {
        let origin = CLLocation(latitude: 40.7128, longitude: -74.0060)
        let viewModel = HomeViewModel()

        // nearbyStations serves A/C/E but is FARTHER than the arrival.
        // displayDistanceMeters takes min(station, arrival) → arrival wins.
        viewModel.nearbyStations = [
            (stationID: "A27", name: "Chambers St",
             lat: origin.coordinate.latitude + (500.0 / 111_111.0),
             lon: origin.coordinate.longitude,
             routeIDs: ["A", "C", "E"])
        ]

        let group = GroupedNearbyTransitResponse(
            routeId: "A",
            displayName: "A",
            mode: "subway",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Northbound",
                    directionLabel: "Uptown",
                    arrivals: [
                        makeArrivalSubway(routeId: "A", distanceMeters: 350, origin: origin)
                    ]
                )
            ]
        )

        let result = viewModel.displayDistanceMeters(for: group, from: origin)
        #expect(result != nil)
        // min(station ~500 m, arrival ~350 m) → uses arrival coords.
        #expect((result ?? 0) > 300)
        #expect((result ?? 0) < 400)
    }

    @Test func subwayDisplayDistanceFallsBackToArrivalWhenNoStationMatch() async throws {
        let origin = CLLocation(latitude: 40.7128, longitude: -74.0060)
        let viewModel = HomeViewModel()

        // nearbyStations has no station serving the G train.
        viewModel.nearbyStations = [
            (stationID: "A27", name: "Chambers St", lat: 40.7128, lon: -74.0060, routeIDs: ["A", "C", "E"])
        ]

        let group = GroupedNearbyTransitResponse(
            routeId: "G",
            displayName: "G",
            mode: "subway",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Northbound",
                    directionLabel: "Court Sq",
                    arrivals: [
                        makeArrivalSubway(routeId: "G", distanceMeters: 500, origin: origin)
                    ]
                )
            ]
        )

        let result = viewModel.displayDistanceMeters(for: group, from: origin)
        #expect(result != nil)
        // Falls back to grouped arrival stop distance (~500 m).
        #expect((result ?? 0) > 400)
        #expect((result ?? 0) < 600)
    }

    @Test func subwayDisplayDistanceUsesArrivalCoordsRegardlessOfStations() async throws {
        let origin = CLLocation(latitude: 40.7128, longitude: -74.0060)
        let viewModel = HomeViewModel()

        // nearbyStations present but irrelevant — only arrival coords matter.
        viewModel.nearbyStations = [
            (stationID: "L01", name: "1 Av", lat: 40.7128, lon: -74.0060, routeIDs: ["L"])
        ]

        let group = GroupedNearbyTransitResponse(
            routeId: "L",
            displayName: "L",
            mode: "subway",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Westbound",
                    directionLabel: "8 Av",
                    arrivals: [
                        makeArrivalSubway(routeId: "L", distanceMeters: 150, origin: origin)
                    ]
                )
            ]
        )

        let result = viewModel.displayDistanceMeters(for: group, from: origin)
        #expect(result != nil)
        // Uses arrival stop coords (~150 m).
        #expect((result ?? .greatestFiniteMagnitude) < 180)
    }

    @Test func subwayDisplayDistanceWithEmptyStations() async throws {
        let origin = CLLocation(latitude: 40.7128, longitude: -74.0060)
        let viewModel = HomeViewModel()
        viewModel.nearbyStations = []

        let group = GroupedNearbyTransitResponse(
            routeId: "7",
            displayName: "7",
            mode: "subway",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Eastbound",
                    directionLabel: "Flushing",
                    arrivals: [
                        makeArrivalSubway(routeId: "7", distanceMeters: 300, origin: origin)
                    ]
                )
            ]
        )

        let result = viewModel.displayDistanceMeters(for: group, from: origin)
        #expect(result != nil)
        // Falls back to grouped arrival distance (~300 m).
        #expect((result ?? 0) > 250)
        #expect((result ?? 0) < 400)
    }

    private func makeArrivalSubway(routeId: String, distanceMeters: Double, origin: CLLocation) -> NearbyTransitResponse {
        let stopCoordinate = CLLocationCoordinate2D(
            latitude: origin.coordinate.latitude + (distanceMeters / 111_111.0),
            longitude: origin.coordinate.longitude
        )
        return NearbyTransitResponse(
            routeId: routeId,
            stopName: "Stop \(routeId)",
            direction: "Northbound",
            destination: "Terminal",
            minutesAway: 5,
            status: "OK",
            mode: "subway",
            stopLat: stopCoordinate.latitude,
            stopLon: stopCoordinate.longitude,
            arrivalTs: Int(Date.now.timeIntervalSince1970) + 300,
            vehicleId: "V-\(routeId)",
            tripId: "T-\(routeId)",
            stopId: "S-\(routeId)"
        )
    }

    // MARK: - Distance assertion helpers

    private func assertAscendingDistance(_ groups: [GroupedNearbyTransitResponse], from origin: CLLocation) {
        guard groups.count > 1 else { return }
        let distances = groups.map { groupMinDistance(for: $0, from: origin) }
        for index in 1..<distances.count {
            #expect(distances[index - 1] <= distances[index])
        }
    }

    private func derivedNearRadius(from slider: Double) -> Double {
        let derived = (slider * 0.40 / 100).rounded() * 100
        return max(400, derived)
    }

    private func derivedFartherRadius(from slider: Double, near: Double) -> Double {
        let derived = (slider * 0.65 / 100).rounded() * 100
        return max(near + 400, derived)
    }

    private func assertAscendingFlatDistance(_ arrivals: [NearbyTransitResponse], from origin: CLLocation) {
        guard arrivals.count > 1 else { return }
        let distances = arrivals.map { arrivalDistance(for: $0, from: origin) }
        for index in 1..<distances.count {
            #expect(distances[index - 1] <= distances[index])
        }
    }

    private func makeGroup(routeId: String, distanceMeters: Double, origin: CLLocation) -> GroupedNearbyTransitResponse {
        let stopCoordinate = CLLocationCoordinate2D(
            latitude: origin.coordinate.latitude + (distanceMeters / 111_111.0),
            longitude: origin.coordinate.longitude
        )

        let arrival = NearbyTransitResponse(
            routeId: routeId,
            stopName: "Stop \(routeId)",
            direction: "Northbound",
            destination: "Terminal",
            minutesAway: 5,
            status: "OK",
            mode: "subway",
            stopLat: stopCoordinate.latitude,
            stopLon: stopCoordinate.longitude,
            arrivalTs: Int(Date.now.timeIntervalSince1970) + 300,
            vehicleId: "V-\(routeId)",
            tripId: "T-\(routeId)",
            stopId: "S-\(routeId)"
        )

        return GroupedNearbyTransitResponse(
            routeId: routeId,
            displayName: "Route \(routeId)",
            mode: "subway",
            colorHex: nil,
            directions: [
                DirectionArrivalsResponse(
                    direction: "Northbound",
                    directionLabel: "Northbound",
                    arrivals: [arrival]
                )
            ]
        )
    }

    private func makeArrival(routeId: String, distanceMeters: Double, origin: CLLocation) -> NearbyTransitResponse {
        let stopCoordinate = CLLocationCoordinate2D(
            latitude: origin.coordinate.latitude + (distanceMeters / 111_111.0),
            longitude: origin.coordinate.longitude
        )

        return NearbyTransitResponse(
            routeId: routeId,
            stopName: "Stop \(routeId)",
            direction: "Northbound",
            destination: "Terminal",
            minutesAway: 7,
            status: "OK",
            mode: "bus",
            stopLat: stopCoordinate.latitude,
            stopLon: stopCoordinate.longitude,
            arrivalTs: Int(Date.now.timeIntervalSince1970) + 420,
            vehicleId: "V-\(routeId)",
            tripId: "T-\(routeId)",
            stopId: "S-\(routeId)"
        )
    }
}
