// View model for the Plan tab.
// Connects the premium planner UI to the backend TrackEngine API.

import CoreLocation
import Foundation
import MapKit
import SwiftData

enum PlanErrorKind {
    /// Engine returned 200 but no trips matched the request.
    case noResults
    /// The routing engine is not reachable (503 / connection refused).
    case engineUnavailable
    /// A network or decoding error unrelated to the engine.
    case general
}

@Observable
@MainActor
final class PlanViewModel {

    // MARK: - Published State

    var origin: PlanLocation = .currentLocation
    var destination: PlanLocation?
    var departureOption: DepartureOption = .leaveNow
    var tripResults: [TripPlan] = []
    var recommendations: [PlannerRecommendation] = []
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    var errorKind: PlanErrorKind = .general
    var scheduleNote: String?
    var isUsingAppleFallback = false
    var showResults = false
    var showDestinationSearch = false
    var showOriginSearch = false
    var showTimePicker = false
    var showMapPicker = false
    var isOriginForMapPicker = false
    var searchText = ""
    var searchResults: [SearchResultItem] = []
    var savedLocations: [SavedLocation] = []
    var recentSearches: [RecentSearchLocation] = []
    var savedTrips: [SavedTrip] = []
    var calendarLocations: [SavedLocation] = []
    var pendingSavedPlaceCategory: SavedLocationCategory?
    var customPlaceLabel: String = ""
    var customPlaceIcon: String = "mappin"
    var showAddPlaceSheet = false
    let locationSearchService = LocationSearchService()
    var isResolvingLocation = false
    var isSavingPlace = false

    // MARK: - Private

    private var modelContext: ModelContext?
    private var locationManager: LocationManager?
    private var searchTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var didConfigure = false

    // MARK: - Setup

    func configure(modelContext: ModelContext, locationManager: LocationManager) {
        self.modelContext = modelContext
        self.locationManager = locationManager

        guard !didConfigure else { return }
        didConfigure = true

        bootstrapTask = Task {
            await refreshPlannerData()
        }
    }

    // MARK: - Actions

    func swapOriginDestination() {
        let oldOrigin = origin
        if let destination {
            origin = destination
        }
        self.destination = oldOrigin == .currentLocation ? nil : oldOrigin
    }

    func planTrip() async {
        guard let destination else { return }
        guard let originPayload = payload(for: origin) else {
            errorMessage = "Current location is still loading."
            showResults = true
            tripResults = []
            return
        }
        guard let destinationPayload = payload(for: destination) else {
            errorMessage = "Choose a destination with a valid location."
            showResults = true
            tripResults = []
            return
        }

        isLoading = true
        errorMessage = nil
        showResults = true

        let request = EngineGoRequestPayload(
            origin: originPayload,
            destination: destinationPayload,
            userID: currentUserID,
            departAtTS: departureOption.departureTimestamp,
            arriveByTS: departureOption.arrivalTimestamp,
            maxTransfers: 2,
            maxOriginWalkM: 1400,
            maxDestinationWalkM: 1200,
            maxTransferWalkM: 350,
            searchWindowMinutes: 180,
            numItineraries: 4,
            modes: ["subway", "bus", "lirr", "mnr"],
            recordRecent: currentUserID != nil,
            nowTS: Int(Date().timeIntervalSince1970)
        )

        do {
            let startTime = CFAbsoluteTimeGetCurrent()
            let response = try await TrackAPI.fetchEngineGo(request: request)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let ms = Int(elapsed * 1000)
            #if DEBUG
            print("[TrackEngine] \(ms)ms — \(response.tripPlans.count) trips")
            #endif
            tripResults = response.tripPlans
            scheduleNote = response.scheduleNote
            if tripResults.isEmpty {
                errorKind = .noResults
                errorMessage = emptyResultsMessage()
            } else {
                errorMessage = nil
            }
            await refreshPlannerData()
        } catch {
            let (kind, message) = friendlyError(for: error)
            if kind == .engineUnavailable {
                await fallbackToAppleDirections()
            } else {
                tripResults = []
                scheduleNote = nil
                errorKind = kind
                errorMessage = message
            }
        }

        isLoading = false
    }

    /// Load additional trips starting after the last displayed trip.
    /// Appends unique results — no duplicates.
    func loadMoreTrips() async {
        guard !isUsingAppleFallback else { return }
        guard let destination else { return }
        guard let originPayload = payload(for: origin),
              let destinationPayload = payload(for: destination) else { return }
        guard !isLoadingMore else { return }

        // Cursor: start searching 60s after the last trip's departure
        let cursor: Int? = if let lastDeparture = tripResults.last?.departureTime {
            Int(lastDeparture.timeIntervalSince1970) + 60
        } else {
            departureOption.departureTimestamp
        }

        isLoadingMore = true

        let request = EngineGoRequestPayload(
            origin: originPayload,
            destination: destinationPayload,
            userID: nil,
            departAtTS: cursor,
            arriveByTS: nil,
            maxTransfers: 2,
            maxOriginWalkM: 1400,
            maxDestinationWalkM: 1200,
            maxTransferWalkM: 350,
            searchWindowMinutes: 180,
            numItineraries: 4,
            modes: ["subway", "bus", "lirr", "mnr"],
            recordRecent: false,
            nowTS: Int(Date().timeIntervalSince1970)
        )

        do {
            let response = try await TrackAPI.fetchEngineGo(request: request)
            let existingIDs = Set(tripResults.map(\.itineraryID))
            let newTrips = response.tripPlans.filter { !existingIDs.contains($0.itineraryID) }

            // Also deduplicate by route pattern + departure time
            var existingKeys = Set(tripResults.map { tripDedupeKey($0) })
            var uniqueNew: [TripPlan] = []
            for trip in newTrips {
                let key = tripDedupeKey(trip)
                if !existingKeys.contains(key) {
                    existingKeys.insert(key)
                    uniqueNew.append(trip)
                }
            }

            if !uniqueNew.isEmpty {
                tripResults.append(contentsOf: uniqueNew)
            }
        } catch {
            // Silently fail — user still sees existing results
        }

        isLoadingMore = false
    }

    /// Creates a dedup key from route pattern + departure timestamp.
    private func tripDedupeKey(_ trip: TripPlan) -> String {
        let routes = trip.legs.map { leg in
            leg.isTransit ? (leg.routeId ?? leg.mode.rawValue) : "walk"
        }.joined(separator: "|")
        return "\(routes)@\(Int(trip.departureTime.timeIntervalSince1970))"
    }

    func selectDestination(_ location: PlanLocation) {
        destination = location
        showDestinationSearch = false
    }

    func selectOrigin(_ location: PlanLocation) {
        origin = location
        showOriginSearch = false
    }

    @discardableResult
    func selectLocation(_ location: PlanLocation, isOrigin: Bool) async -> Bool {
        if let category = pendingSavedPlaceCategory {
            return await persistSavedPlace(location, category: category)
        }

        if isOrigin {
            selectOrigin(location)
        } else {
            selectDestination(location)
        }
        return true
    }

    func selectRecommendation(_ recommendation: PlannerRecommendation) {
        destination = .custom(
            name: recommendation.label,
            address: recommendation.subtitle,
            lat: recommendation.lat,
            lon: recommendation.lon
        )
    }

    func clearResults() {
        showResults = false
        tripResults = []
        errorMessage = nil
        isUsingAppleFallback = false
    }

    func dismissError() {
        errorMessage = nil
    }

    func refreshPlannerData() async {
        guard let userID = currentUserID else {
            savedLocations = []
            recentSearches = []
            savedTrips = []
            calendarLocations = []
            recommendations = []
            return
        }

        do {
            async let savedPlacesTask = TrackAPI.fetchEngineSavedPlaces(userID: userID)
            async let recentTripsTask = TrackAPI.fetchEngineRecentTrips(userID: userID, limit: 12)
            async let recommendationsTask = TrackAPI.fetchEngineRecommendations(
                userID: userID,
                latitude: effectiveOriginCoordinate?.latitude,
                longitude: effectiveOriginCoordinate?.longitude,
                originLabel: origin.displayName,
                limit: 6
            )

            let (savedPlaces, recentTrips, recommendations) = try await (
                savedPlacesTask,
                recentTripsTask,
                recommendationsTask
            )
            applyPlannerSnapshot(
                savedPlaces: savedPlaces,
                recentTrips: recentTrips,
                recommendations: recommendations
            )
        } catch {
            // Keep the current UI state if the background refresh fails.
        }
    }

    // MARK: - Departure Time

    func setLeaveNow() {
        departureOption = .leaveNow
        showTimePicker = false
    }

    func setDepartAt(_ date: Date) {
        departureOption = .departAt(date)
        showTimePicker = false
    }

    func setArriveBy(_ date: Date) {
        departureOption = .arriveBy(date)
        showTimePicker = false
    }

    func clearDepartureOption() {
        departureOption = .leaveNow
    }

    var departureTimeLabel: String {
        departureOption.label
    }

    var timeIntervalStep: TimeInterval { 15 * 60 }

    func stepTime(forward: Bool) {
        let delta = forward ? timeIntervalStep : -timeIntervalStep
        switch departureOption {
        case .leaveNow:
            departureOption = .departAt(Date().addingTimeInterval(delta))
        case .departAt(let date):
            departureOption = .departAt(date.addingTimeInterval(delta))
        case .arriveBy(let date):
            departureOption = .arriveBy(date.addingTimeInterval(delta))
        }
    }

    // MARK: - Search

    func performSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            searchResults = []
            locationSearchService.updateQuery("")
            return
        }

        locationSearchService.updateQuery(trimmed)

        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }

            do {
                let results = try await TrackAPI.fetchEngineSearch(
                    query: trimmed,
                    userID: currentUserID,
                    latitude: effectiveOriginCoordinate?.latitude,
                    longitude: effectiveOriginCoordinate?.longitude,
                    limit: 12
                )
                guard !Task.isCancelled else { return }
                searchResults = results.map(SearchResultItem.planner)
            } catch {
                guard !Task.isCancelled else { return }
                searchResults = []
            }
        }
    }

    func selectCompletion(_ completion: MKLocalSearchCompletion, isOrigin: Bool) async -> Bool {
        isResolvingLocation = true
        defer { isResolvingLocation = false }
        do {
            let mapItem = try await locationSearchService.resolve(completion)
            let coordinate = mapItem.location.coordinate
            let location = PlanLocation.custom(
                name: mapItem.name ?? completion.title,
                address: mapItem.formattedAddress,
                lat: coordinate.latitude,
                lon: coordinate.longitude
            )
            return await selectLocation(location, isOrigin: isOrigin)
        } catch {
            errorMessage = "Couldn't resolve that location."
            return false
        }
    }

    func selectMapCoordinate(_ coordinate: CLLocationCoordinate2D) async -> Bool {
        isResolvingLocation = true
        defer { isResolvingLocation = false }
        do {
            let mapItem = try await locationSearchService.reverseGeocode(coordinate)
            let location = PlanLocation.custom(
                name: mapItem.name ?? mapItem.formattedAddress,
                address: mapItem.formattedAddress,
                lat: coordinate.latitude,
                lon: coordinate.longitude
            )
            let didApply = await selectLocation(location, isOrigin: isOriginForMapPicker)
            if didApply {
                showMapPicker = false
            }
            return didApply
        } catch {
            let fallback = PlanLocation.custom(
                name: String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude),
                address: "",
                lat: coordinate.latitude,
                lon: coordinate.longitude
            )
            let didApply = await selectLocation(fallback, isOrigin: isOriginForMapPicker)
            if didApply {
                showMapPicker = false
            }
            return didApply
        }
    }

    // MARK: - Saved Place Helpers

    func beginSavedPlaceFlow(_ category: SavedLocationCategory) {
        errorMessage = nil
        pendingSavedPlaceCategory = category
        customPlaceLabel = ""
        customPlaceIcon = category == .custom ? "mappin" : category.defaultIcon
        searchText = ""
        searchResults = []
        showDestinationSearch = true
    }

    func beginCustomPlaceFlow() {
        errorMessage = nil
        pendingSavedPlaceCategory = .custom
        customPlaceLabel = ""
        customPlaceIcon = "mappin"
        showAddPlaceSheet = true
    }

    func cancelSavedPlaceFlow() {
        pendingSavedPlaceCategory = nil
        customPlaceLabel = ""
        customPlaceIcon = "mappin"
    }

    /// All custom (non-preset) saved places
    var customSavedLocations: [SavedLocation] {
        savedLocations.filter { $0.resolvedCategory == .custom }
    }

    /// Available icon options for custom places
    static let customPlaceIcons: [(icon: String, label: String)] = [
        ("mappin", "Pin"),
        ("star.fill", "Star"),
        ("fork.knife", "Food"),
        ("cart.fill", "Shop"),
        ("dumbbell.fill", "Gym"),
        ("cross.fill", "Health"),
        ("book.fill", "Library"),
        ("music.note", "Music"),
        ("theatermasks.fill", "Arts"),
        ("figure.walk", "Park"),
        ("building.2.fill", "Building"),
        ("airplane", "Airport"),
    ]

    func deleteSavedLocation(_ location: SavedLocation) async {
        guard let userID = currentUserID else {
            savedLocations.removeAll { $0.id == location.id }
            return
        }
        guard let placeID = location.enginePlaceID else {
            savedLocations.removeAll { $0.id == location.id }
            return
        }

        do {
            try await TrackAPI.deleteEngineSavedPlace(placeID: placeID, userID: userID)
            savedLocations.removeAll { $0.id == location.id }
            pendingSavedPlaceCategory = nil
            await refreshPlannerData()
        } catch {
            let (kind, message) = friendlyError(for: error)
            errorKind = kind
            errorMessage = message
        }
    }

    func savedLocation(for category: SavedLocationCategory) -> SavedLocation? {
        savedLocations.first { $0.resolvedCategory == category }
    }

    // MARK: - Private

    private var currentUserID: String? {
        SupabaseManager.shared.currentUser?.id.uuidString.lowercased()
    }

    private var effectiveOriginCoordinate: CLLocationCoordinate2D? {
        switch origin {
        case .currentLocation:
            return currentLocationCoordinate
        default:
            return origin.coordinate
        }
    }

    private var currentLocationCoordinate: CLLocationCoordinate2D? {
        if let coordinate = locationManager?.currentLocation?.coordinate {
            return coordinate
        }
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        guard defaults.bool(forKey: "hasLastLocation") else {
            return nil
        }
        let lat = defaults.double(forKey: "lastLatitude")
        let lon = defaults.double(forKey: "lastLongitude")
        guard lat != 0 || lon != 0 else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func payload(for location: PlanLocation) -> EngineLocationPayloadRequest? {
        switch location {
        case .currentLocation:
            guard let coordinate = currentLocationCoordinate else {
                return nil
            }
            return EngineLocationPayloadRequest(
                label: "Current location",
                lat: coordinate.latitude,
                lon: coordinate.longitude,
                stopID: nil,
                address: nil
            )
        case .saved(let saved):
            return EngineLocationPayloadRequest(
                label: saved.name,
                lat: saved.latitude,
                lon: saved.longitude,
                stopID: nil,
                address: saved.address
            )
        case .recent(let recent):
            return EngineLocationPayloadRequest(
                label: recent.name,
                lat: recent.latitude,
                lon: recent.longitude,
                stopID: nil,
                address: recent.address
            )
        case .custom(let name, let address, let lat, let lon):
            return EngineLocationPayloadRequest(
                label: name,
                lat: lat,
                lon: lon,
                stopID: nil,
                address: address
            )
        }
    }

    private func persistSavedPlace(
        _ location: PlanLocation,
        category: SavedLocationCategory
    ) async -> Bool {
        defer {
            pendingSavedPlaceCategory = nil
            customPlaceLabel = ""
            customPlaceIcon = "mappin"
        }
        guard let userID = currentUserID else {
            errorMessage = "Sign in to save places."
            return false
        }
        guard let coordinate = resolvedCoordinate(for: location) else {
            errorMessage = "That place does not have a usable location yet."
            return false
        }

        let effectiveLabel: String
        let effectiveIcon: String
        let effectiveKind: String

        if category == .custom {
            effectiveLabel = customPlaceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (location.displayName)
                : customPlaceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            effectiveIcon = customPlaceIcon
            effectiveKind = "custom"
        } else {
            effectiveLabel = category.label
            effectiveIcon = category.defaultIcon
            effectiveKind = category.rawValue
        }

        isSavingPlace = true
        defer { isSavingPlace = false }

        do {
            let savedRecord = try await TrackAPI.upsertEngineSavedPlace(
                request: EngineSavedPlaceUpsertRequest(
                    userID: userID,
                    label: effectiveLabel,
                    kind: effectiveKind,
                    lat: coordinate.latitude,
                    lon: coordinate.longitude,
                    address: location.displayAddress,
                    icon: effectiveIcon,
                    placeID: category == .custom ? nil : savedLocation(for: category)?.enginePlaceID
                )
            )

            if category != .custom {
                savedLocations.removeAll {
                    $0.resolvedCategory == category || $0.enginePlaceID == savedRecord.placeID
                }
            } else {
                savedLocations.removeAll { $0.enginePlaceID == savedRecord.placeID }
            }
            savedLocations.insert(
                SavedLocation(
                    enginePlaceID: savedRecord.placeID,
                    name: savedRecord.label,
                    address: savedRecord.address ?? location.displayAddress ?? "",
                    latitude: savedRecord.lat,
                    longitude: savedRecord.lon,
                    category: category,
                    iconName: savedRecord.icon ?? category.defaultIcon,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(savedRecord.createdAt)),
                    lastUsedAt: savedRecord.lastUsedAt.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    }
                ),
                at: 0
            )
            errorMessage = nil
            await refreshPlannerData()
            return true
        } catch {
            let (kind, message) = friendlyError(for: error)
            errorKind = kind
            errorMessage = message
            return false
        }
    }

    private func resolvedCoordinate(for location: PlanLocation) -> CLLocationCoordinate2D? {
        switch location {
        case .currentLocation:
            return currentLocationCoordinate
        default:
            return location.coordinate
        }
    }

    private func applyPlannerSnapshot(
        savedPlaces: [PlannerSavedPlaceRecord],
        recentTrips: [PlannerRecentTripRecord],
        recommendations: [PlannerRecommendation]
    ) {
        savedLocations = savedPlaces.map { place in
            let category = SavedLocationCategory(engineKind: place.kind)
            return SavedLocation(
                enginePlaceID: place.placeID,
                name: place.label,
                address: place.address ?? "",
                latitude: place.lat,
                longitude: place.lon,
                category: category,
                iconName: place.icon ?? category.defaultIcon,
                createdAt: Date(timeIntervalSince1970: TimeInterval(place.createdAt)),
                lastUsedAt: place.lastUsedAt.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
            )
        }

        self.recommendations = recommendations
        calendarLocations = recommendations
            .filter { $0.source == "calendar" }
            .map { recommendation in
                SavedLocation(
                    enginePlaceID: recommendation.placeID,
                    name: recommendation.label,
                    address: recommendation.subtitle,
                    latitude: recommendation.lat,
                    longitude: recommendation.lon,
                    category: .calendar,
                    iconName: "calendar",
                    createdAt: recommendation.upcomingDate ?? .now,
                    lastUsedAt: recommendation.upcomingDate
                )
            }

        savedTrips = recentTrips.map { trip in
            SavedTrip(
                originName: trip.originLabel,
                originAddress: "",
                originLat: trip.originLat,
                originLon: trip.originLon,
                destinationName: trip.destinationLabel,
                destinationAddress: "",
                destinationLat: trip.destinationLat,
                destinationLon: trip.destinationLon,
                legSummary: trip.routeTokens,
                legModes: trip.routeTokens.map(Self.modeToken),
                savedAt: Date(timeIntervalSince1970: TimeInterval(trip.requestedAt)),
                lastUsedAt: Date(timeIntervalSince1970: TimeInterval(trip.requestedAt)),
                usageCount: 1
            )
        }

        var seenDestinations = Set<String>()
        recentSearches = recentTrips.compactMap { trip in
            let key = "\(trip.destinationLabel)|\(trip.destinationLat)|\(trip.destinationLon)"
            guard seenDestinations.insert(key).inserted else {
                return nil
            }
            return RecentSearchLocation(
                name: trip.destinationLabel,
                address: trip.summary,
                latitude: trip.destinationLat,
                longitude: trip.destinationLon,
                searchedAt: Date(timeIntervalSince1970: TimeInterval(trip.requestedAt))
            )
        }
    }

    // MARK: - Apple Maps Fallback

    /// When TrackEngine is unreachable, fall back to Apple Maps transit
    /// directions via MKDirections. Results are converted into TripPlan
    /// models so the existing results UI can display them seamlessly.
    private func fallbackToAppleDirections() async {
        guard let destination else { return }
        guard let originCoord = resolvedCoordinate(for: origin),
              let destCoord = resolvedCoordinate(for: destination) else {
            errorKind = .engineUnavailable
            errorMessage = "The routing engine is temporarily offline."
            tripResults = []
            return
        }

        #if DEBUG
        print("[Fallback] Attempting Apple Maps transit directions")
        #endif

        // MKPlacemark is deprecated in iOS 26.0
        let sourceItem = MKMapItem(
            location: CLLocation(latitude: originCoord.latitude, longitude: originCoord.longitude),
            address: nil)
        let destItem = MKMapItem(
            location: CLLocation(latitude: destCoord.latitude, longitude: destCoord.longitude),
            address: nil)

        // Try transit first, then automobile as last resort
        let transportTypes: [MKDirectionsTransportType] = [.transit, .automobile]
        for transportType in transportTypes {
            let request = MKDirections.Request()
            request.source = sourceItem
            request.destination = destItem
            request.transportType = transportType
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
            do {
                let response = try await directions.calculate()
                let plans = response.routes.prefix(4).map { route in
                    appleRouteToTripPlan(route, isDriving: transportType == .automobile)
                }
                if !plans.isEmpty {
                    tripResults = plans
                    scheduleNote = nil
                    isUsingAppleFallback = true
                    errorMessage = nil
                    #if DEBUG
                    print("[Fallback] Apple Maps returned \(plans.count) routes via \(transportType == .transit ? "transit" : "driving")")
                    #endif
                    return
                }
            } catch {
                #if DEBUG
                print("[Fallback] Apple Maps \(transportType == .transit ? "transit" : "driving") failed: \(error.localizedDescription)")
                #endif
                continue
            }
        }

        // Both transit and automobile failed
        tripResults = []
        scheduleNote = nil
        isUsingAppleFallback = false
        errorKind = .engineUnavailable
        errorMessage = "The routing engine is temporarily offline. Please try again shortly."
    }

    /// Convert an Apple Maps MKRoute into a TripPlan for the results UI.
    private func appleRouteToTripPlan(_ route: MKRoute, isDriving: Bool = false) -> TripPlan {
        let departDate: Date = switch departureOption {
        case .leaveNow: Date()
        case .departAt(let d): d
        case .arriveBy: Date()
        }
        let arriveDate = departDate.addingTimeInterval(route.expectedTravelTime)
        let durationMin = max(1, Int(route.expectedTravelTime / 60))

        // Driving fallback: single leg, no steps parsing
        if isDriving {
            let leg = TripLeg(
                mode: .bus,
                routeId: "Drive",
                routeName: "Drive",
                routeColor: "4A90D9",
                headsign: route.name.isEmpty ? "Via car" : route.name,
                boardStopName: origin.displayName,
                alightStopName: destination?.displayName ?? "Destination",
                departureTime: departDate, arrivalTime: arriveDate,
                numStops: 0, durationMinutes: durationMin
            )
            return TripPlan(
                departureTime: departDate,
                arrivalTime: arriveDate,
                totalDurationMinutes: durationMin,
                legs: [leg],
                totalWalkMeters: 0,
                numTransfers: 0
            )
        }

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
                boardStopName: origin.displayName,
                alightStopName: destination?.displayName ?? "Destination",
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

    private func friendlyError(for error: Error) -> (PlanErrorKind, String) {
        if let apiError = error as? TrackAPIError {
            switch apiError {
            case .serverError(let statusCode) where statusCode == 503:
                return (.engineUnavailable, "The routing engine is starting up — it usually takes a few seconds.")
            case .networkError:
                return (.general, "Check your connection and try again.")
            default:
                return (.general, apiError.localizedDescription)
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return (.general, "Check your connection and try again.")
        }
        return (.general, error.localizedDescription)
    }

    /// Build a contextual message when the engine returned zero trips.
    private func emptyResultsMessage() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 1 && hour < 5 {
            return "Transit service is very limited at this hour. Try a later departure time."
        }
        return "No trip options found. Try adjusting your origin or destination."
    }

    private static func modeToken(for token: String) -> String {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = normalized.uppercased()
        if upper.hasPrefix("WALK") {
            return "walk"
        }
        if upper.contains("BRANCH") || upper.contains("LIRR") {
            return "lirr"
        }
        if upper.contains("MNR") || upper.contains("METRO-NORTH") {
            return "mnr"
        }
        if upper.hasPrefix("SIM")
            || upper.hasPrefix("BX")
            || upper.hasPrefix("BM")
            || upper.hasPrefix("QM")
            || upper.hasPrefix("X")
        {
            return "bus"
        }
        if let first = upper.first, first.isLetter {
            if ["A", "B", "C", "D", "E", "F", "G", "J", "L", "M", "N", "Q", "R", "S", "W", "Z"].contains(String(first))
                && upper.count <= 3
            {
                return "subway"
            }
            if upper.hasPrefix("Q") || upper.hasPrefix("B") || upper.hasPrefix("M") || upper.hasPrefix("S") {
                return "bus"
            }
        }
        if let first = upper.first, first.isNumber {
            return "subway"
        }
        return "bus"
    }
}

// MARK: - Search Result

enum SearchResultItem: Identifiable {
    case saved(SavedLocation)
    case recent(RecentSearchLocation)
    case geocoded(name: String, address: String, lat: Double, lon: Double)
    case planner(PlannerSearchResult)

    var id: String {
        switch self {
        case .saved(let location):
            return "saved-\(location.id)"
        case .recent(let location):
            return "recent-\(location.id)"
        case .geocoded(let name, _, let lat, _):
            return "geo-\(name)-\(lat)"
        case .planner(let result):
            return "planner-\(result.id)"
        }
    }

    var name: String {
        switch self {
        case .saved(let location):
            return location.name
        case .recent(let location):
            return location.name
        case .geocoded(let name, _, _, _):
            return name
        case .planner(let result):
            return result.label
        }
    }

    var address: String {
        switch self {
        case .saved(let location):
            return location.address
        case .recent(let location):
            return location.address
        case .geocoded(_, let address, _, _):
            return address
        case .planner(let result):
            return result.subtitle
        }
    }

    var iconName: String {
        switch self {
        case .saved(let location):
            return location.iconName
        case .recent:
            return "clock.arrow.circlepath"
        case .geocoded:
            return "mappin"
        case .planner(let result):
            return result.iconName
        }
    }

    func toPlanLocation() -> PlanLocation {
        switch self {
        case .saved(let location):
            return .saved(location)
        case .recent(let location):
            return .recent(location)
        case .geocoded(let name, let address, let lat, let lon):
            return .custom(name: name, address: address, lat: lat, lon: lon)
        case .planner(let result):
            return .custom(
                name: result.label,
                address: result.subtitle,
                lat: result.lat,
                lon: result.lon
            )
        }
    }
}
