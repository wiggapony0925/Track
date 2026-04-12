// Apple Maps transit routing fallback.
// Used when the TrackEngine backend is unreachable (503 / timeout).
// Converts MKDirections transit results into TripPlan models so the
// existing results UI can display them seamlessly.

import CoreLocation
import MapKit

/// Lightweight service that wraps MKDirections for transit-only routing.
enum AppleRoutingService {

    /// Request up to 4 transit routes between two coordinates.
    /// - Returns: An array of `TripPlan` ready for the results UI.
    /// - Throws: If Apple Maps transit directions are unavailable.
    static func fetchTransitRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departureOption: DepartureOption,
        originName: String,
        destinationName: String
    ) async throws -> [TripPlan] {
        let sourceItem = MKMapItem(
            location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
            address: nil)
        let destItem = MKMapItem(
            location: CLLocation(latitude: destination.latitude, longitude: destination.longitude),
            address: nil)

        let request = MKDirections.Request()
        request.source = sourceItem
        request.destination = destItem
        request.transportType = .transit
        request.requestsAlternateRoutes = true

        switch departureOption {
        case .leaveNow:
            request.departureDate = Date()
        case .departAt(let date):
            request.departureDate = date
        case .arriveBy(let date):
            request.arrivalDate = date
        }

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()

        let plans = response.routes.prefix(4).map { route in
            tripPlan(
                from: route,
                departureOption: departureOption,
                originName: originName,
                destinationName: destinationName
            )
        }

        #if DEBUG
        print("[AppleRoutingService] Returned \(plans.count) transit routes")
        #endif

        return plans
    }

    // MARK: - Route → TripPlan Conversion

    private static func tripPlan(
        from route: MKRoute,
        departureOption: DepartureOption,
        originName: String,
        destinationName: String
    ) -> TripPlan {
        let departDate: Date = switch departureOption {
        case .leaveNow: Date()
        case .departAt(let d): d
        case .arriveBy: Date()
        }
        let arriveDate = departDate.addingTimeInterval(route.expectedTravelTime)
        let durationMin = max(1, Int(route.expectedTravelTime / 60))

        var legs: [TripLeg] = []
        var totalWalkM: Double = 0
        var transitLegCount = 0

        let steps = route.steps.filter { !$0.instructions.isEmpty }
        let totalDist = max(route.distance, 1.0)

        if steps.count > 1 {
            var cursor = departDate
            for step in steps {
                let frac = step.distance / totalDist
                let dur = route.expectedTravelTime * frac
                let end = cursor.addingTimeInterval(dur)
                let durMin = max(1, Int(dur / 60))

                let isWalk = step.transportType == .walking
                    || step.instructions.localizedCaseInsensitiveContains("walk")

                if isWalk {
                    totalWalkM += step.distance
                    legs.append(TripLeg(
                        mode: .walk,
                        routeId: nil, routeName: nil, routeColor: nil,
                        headsign: nil,
                        boardStopName: step.instructions,
                        alightStopName: "",
                        departureTime: cursor, arrivalTime: end,
                        numStops: 0, durationMinutes: durMin,
                        walkMeters: step.distance
                    ))
                } else {
                    transitLegCount += 1
                    let label = route.name.isEmpty ? "Transit" : route.name
                    legs.append(TripLeg(
                        mode: .subway,
                        routeId: label,
                        routeName: label,
                        routeColor: "4A90D9",
                        headsign: step.instructions,
                        boardStopName: step.instructions,
                        alightStopName: "",
                        departureTime: cursor, arrivalTime: end,
                        numStops: 0, durationMinutes: durMin
                    ))
                }
                cursor = end
            }
        }

        // Fallback: single transit leg when steps are unavailable
        if legs.isEmpty {
            let label = route.name.isEmpty ? "Transit" : route.name
            legs.append(TripLeg(
                mode: .bus,
                routeId: label,
                routeName: label,
                routeColor: "4A90D9",
                headsign: route.name,
                boardStopName: originName,
                alightStopName: destinationName,
                departureTime: departDate, arrivalTime: arriveDate,
                numStops: 0, durationMinutes: durationMin
            ))
        }

        return TripPlan(
            departureTime: departDate,
            arrivalTime: arriveDate,
            totalDurationMinutes: durationMin,
            legs: legs,
            totalWalkMeters: totalWalkM,
            numTransfers: max(0, transitLegCount - 1)
        )
    }
}
