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
    /// True once the initial planner data (saved places, recent trips, etc.) is loaded.
    var isPlanDataLoaded = false
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
    var savedTripTemplates: [PlannerSavedTripRecord] = []
    var calendarLocations: [SavedLocation] = []
    var pendingSavedPlaceCategory: SavedLocationCategory?
    var customPlaceLabel: String = ""
    var customPlaceIcon: String = "mappin"
    var showAddPlaceSheet = false
    let locationSearchService = LocationSearchService()
    var isResolvingLocation = false
    var isSavingPlace = false
    /// Whether the user has already loaded additional trips for the current search.
    var didLoadMore = false

    /// Shown briefly when the user picks the same origin + destination.
    var sameLocationMessage: String?

    /// Trip settings (modes, walking, accessibility, priority).
    /// Loaded from Supabase on configure; mutated by TripSettingsSheet.
    var tripConfiguration: CloudTripConfiguration = CloudTripConfiguration.makeDefault(userId: UUID())

    private static let sameLocationQuips: [String] = [
        "C'mon, you should know how to get there! 😄",
        "You're already there! 📍",
        "That's… right here 🤔",
        "Zero steps. New record! 🏆",
        "Shortest trip ever — 0 min 🎉",
    ]

    // MARK: - Private

    private var modelContext: ModelContext?
    private var locationManager: LocationManager?
    private var searchTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var configSaveTask: Task<Void, Never>?
    /// Active trip-planning task — cancelled on re-tap to avoid stale overwrites.
    private var planTask: Task<Void, Never>?
    private var didConfigure = false

    // MARK: - Trip Result Cache

    /// In-memory cache entry for a single trip search result.
    private struct TripCacheEntry {
        let plans: [TripPlan]
        let scheduleNote: String?
        let timestamp: Date
        /// Cache is valid for 2 minutes — transit data is real-time.
        var isValid: Bool { Date().timeIntervalSince(timestamp) < 120 }
    }

    /// Recent trip results keyed by an O/D + settings hash.
    /// Keeps up to 6 entries (most recent unique searches).
    private var tripCache: [String: TripCacheEntry] = [:]
    private let maxCacheEntries = 6

    /// Build a deterministic cache key from the current search parameters.
    private func tripCacheKey(
        origin: EngineLocationPayloadRequest,
        destination: EngineLocationPayloadRequest
    ) -> String {
        let tc = tripConfiguration

        // For "Leave now", bucket time into 2-minute windows so the same
        // search within ~2 min hits cache instead of calling the engine.
        let timePart: String
        switch departureOption {
        case .leaveNow:
            let bucket = Int(Date().timeIntervalSince1970) / 120
            timePart = "now_\(bucket)"
        case .departAt(let d):
            timePart = "dep_\(Int(d.timeIntervalSince1970))"
        case .arriveBy(let d):
            timePart = "arr_\(Int(d.timeIntervalSince1970))"
        }

        let parts: [String] = [
            String(format: "%.5f,%.5f", origin.lat ?? 0, origin.lon ?? 0),
            String(format: "%.5f,%.5f", destination.lat ?? 0, destination.lon ?? 0),
            timePart,
            tc.priority,
            tc.enabledModes.sorted().joined(separator: ","),
            "w\(Int(tc.walkPreference * 100))",
            tc.accessibilityPriority ? "ada" : "std",
        ]
        return parts.joined(separator: "|")
    }

    /// Prune oldest entries if cache exceeds max size.
    private func pruneTripCache() {
        guard tripCache.count > maxCacheEntries else { return }
        let sorted = tripCache.sorted { $0.value.timestamp < $1.value.timestamp }
        let excess = tripCache.count - maxCacheEntries
        for (key, _) in sorted.prefix(excess) {
            tripCache.removeValue(forKey: key)
        }
    }

    // MARK: - Setup

    func configure(modelContext: ModelContext, locationManager: LocationManager) {
        self.modelContext = modelContext
        self.locationManager = locationManager

        guard !didConfigure else { return }
        didConfigure = true

        // Seed the user ID for the default config
        if let uid = currentUserID, let uuid = UUID(uuidString: uid) {
            tripConfiguration = .makeDefault(userId: uuid)
        }

        bootstrapTask = Task {
            async let plannerData: Void = refreshPlannerData()
            async let tripConfig: Void = loadTripConfiguration()
            _ = await (plannerData, tripConfig)
            isPlanDataLoaded = true
        }
    }

    // MARK: - Actions

    /// Guards against rapid-fire taps on the swap button.
    private var isSwapping = false

    /// Atomically swaps origin ↔ destination.
    /// - `.currentLocation` is always preserved — it moves to the other field,
    ///   never dropped.
    /// - Ignores re-entrant calls so the user can spam the button safely.
    /// - Returns `true` when a meaningful swap was performed.
    @discardableResult
    func swapOriginDestination() -> Bool {
        guard !isSwapping else { return false }
        isSwapping = true
        defer { isSwapping = false }

        let oldOrigin = origin
        let oldDestination = destination

        // Nothing to swap if destination hasn't been set yet.
        guard let dest = oldDestination else { return false }

        origin = dest
        destination = oldOrigin
        return true
    }

    func planTrip(forceRefresh: Bool = false) async {
        // Cancel any in-flight plan request so a rapid re-tap doesn't
        // overwrite fresh results with a stale response.
        planTask?.cancel()

        let task = Task { @MainActor in
            await self._planTripImpl(forceRefresh: forceRefresh)
        }
        planTask = task
        await task.value
    }

    private func _planTripImpl(forceRefresh: Bool) async {
        // Reset same-location flag so onChange fires fresh each time.
        sameLocationMessage = nil

        guard let destination else { return }
        guard let originPayload = payload(for: origin) else {
            errorMessage = "Current location is still loading."
            return
        }
        guard let destinationPayload = payload(for: destination) else {
            errorMessage = "Choose a destination with a valid location."
            return
        }

        // ── Same-location / walking-distance check ──────────────
        if let oLat = originPayload.lat, let oLon = originPayload.lon,
           let dLat = destinationPayload.lat, let dLon = destinationPayload.lon {
            let originCL  = CLLocation(latitude: oLat, longitude: oLon)
            let destCL    = CLLocation(latitude: dLat, longitude: dLon)
            let distanceM = originCL.distance(from: destCL)

            // Exact same spot (< 50 m) — haptic + witty message, no trip
            if distanceM < 50 {
                sameLocationMessage = Self.sameLocationQuips.randomElement()
                HapticManager.notification(.error)
                return
            }

            // Walking distance (< 1.2 km ≈ ~15 min walk) — synthesize a walk-only result
            let walkSpeedMPS: Double = 1.35 // average walking speed
            let walkSeconds = distanceM / walkSpeedMPS
            let walkMinutes = Int(ceil(walkSeconds / 60))

            if distanceM < 1200 {
                let now = Date()
                let walkTrip = TripPlan(
                    departureTime: now,
                    arrivalTime: now.addingTimeInterval(walkSeconds),
                    totalDurationMinutes: walkMinutes,
                    legs: [
                        TripLeg(
                            mode: .walk,
                            routeId: nil,
                            routeName: nil,
                            routeColor: nil,
                            headsign: nil,
                            boardStopName: originPayload.label,
                            alightStopName: destinationPayload.label,
                            departureTime: now,
                            arrivalTime: now.addingTimeInterval(walkSeconds),
                            numStops: 0,
                            durationMinutes: walkMinutes,
                            walkMeters: distanceM
                        )
                    ],
                    totalWalkMeters: distanceM,
                    numTransfers: 0,
                    routeChips: [
                        TripRouteChip(
                            kind: "walk",
                            label: "Walk",
                            routeId: nil,
                            colorHex: nil,
                            textColorHex: nil,
                            mode: "walk",
                            modeName: "Walk",
                            durationSeconds: Int(walkSeconds),
                            walkMeters: distanceM
                        )
                    ]
                )
                tripResults = [walkTrip]
                scheduleNote = "It's close enough to walk — \(walkMinutes) min on foot."
                errorMessage = nil
                showResults = true
                return
            }
        }

        // Check cache first (skip for explicit refresh)
        let cacheKey = tripCacheKey(origin: originPayload, destination: destinationPayload)
        if !forceRefresh, let cached = tripCache[cacheKey], cached.isValid {
            tripResults = cached.plans
            scheduleNote = cached.scheduleNote
            errorMessage = cached.plans.isEmpty ? emptyResultsMessage() : nil
            if cached.plans.isEmpty { errorKind = .noResults }
            didLoadMore = false
            showResults = true
            #if DEBUG
            print("[TripCache] HIT — \(cached.plans.count) trips (age: \(Int(Date().timeIntervalSince(cached.timestamp)))s)")
            #endif
            return
        }

        isLoading = true
        errorMessage = nil
        showResults = true
        didLoadMore = false
        defer { isLoading = false }

        let tc = tripConfiguration
        let modes = tc.enabledModes.isEmpty ? ["subway", "bus", "lirr", "mnr"] : tc.enabledModes
        let request = EngineGoRequestPayload(
            origin: originPayload,
            destination: destinationPayload,
            userID: currentUserID,
            departAtTS: departureOption.departureTimestamp,
            arriveByTS: departureOption.arrivalTimestamp,
            maxTransfers: tc.maxTransfers,
            maxOriginWalkM: tc.maxOriginWalkMeters,
            maxDestinationWalkM: tc.maxDestinationWalkMeters,
            maxTransferWalkM: tc.maxTransferWalkMeters,
            searchWindowMinutes: 180,
            numItineraries: 4,
            modes: modes,
            recordRecent: currentUserID != nil,
            nowTS: Int(Date().timeIntervalSince1970),
            priority: tc.priority,
            accessibilityPriority: tc.accessibilityPriority
        )

        do {
            let startTime = CFAbsoluteTimeGetCurrent()
            let response = try await TrackAPI.fetchEngineGo(request: request)
            // If this task was cancelled while awaiting, bail out so we
            // don't overwrite results from a newer request.
            guard !Task.isCancelled else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let ms = Int(elapsed * 1000)
            #if DEBUG
            print("[TrackEngine] \(ms)ms — \(response.tripPlans.count) trips")
            #endif
            tripResults = response.tripPlans
            scheduleNote = response.scheduleNote

            // ── Future-day fallback ──
            // When the engine has no service right now and returns only
            // future-day trips (schedule_note = "Next trips available …"),
            // try Apple Maps for immediate transit options first.
            if !tripResults.isEmpty,
               scheduleNote != nil,
               allTripsAreFutureDay(tripResults)
            {
                let futurePlans = tripResults
                let futureNote = scheduleNote
                #if DEBUG
                print("[PlanVM] All \(futurePlans.count) trips are future-day — trying Apple fallback")
                #endif
                await fallbackToAppleDirections()
                if tripResults.isEmpty || isUsingAppleFallback == false {
                    // Apple returned nothing — restore the future trips
                    tripResults = futurePlans
                    scheduleNote = futureNote
                }
                // If Apple succeeded, tripResults + isUsingAppleFallback are
                // already set by fallbackToAppleDirections().
            }

            if tripResults.isEmpty {
                errorKind = .noResults
                errorMessage = scheduleNote ?? emptyResultsMessage()
            } else {
                errorMessage = nil
                // Cache trip plans for offline access (generic last-viewed)
                OfflineCacheManager.shared.cacheTripPlans(tripResults)
                // Also cache by O/D pair for smart offline matching
                let commuteKey = OfflineCacheManager.commuteKey(
                    originLat: originPayload.lat ?? 0,
                    originLon: originPayload.lon ?? 0,
                    destLat: destinationPayload.lat ?? 0,
                    destLon: destinationPayload.lon ?? 0
                )
                OfflineCacheManager.shared.cacheCommutePlans(
                    key: commuteKey,
                    originLabel: originPayload.label,
                    originLat: originPayload.lat ?? 0,
                    originLon: originPayload.lon ?? 0,
                    destinationLabel: destinationPayload.label,
                    destLat: destinationPayload.lat ?? 0,
                    destLon: destinationPayload.lon ?? 0,
                    plans: tripResults
                )
            }
            // Store in session cache
            tripCache[cacheKey] = TripCacheEntry(
                plans: response.tripPlans,
                scheduleNote: response.scheduleNote,
                timestamp: Date()
            )
            pruneTripCache()
            await refreshPlannerData()
        } catch {
            let (kind, message) = friendlyError(for: error)
            if kind == .engineUnavailable {
                await fallbackToAppleDirections()
            } else if !OfflineCacheManager.shared.isOnline {
                // Smart offline fallback — try O/D-matched plans first, then generic
                let oLat = originPayload.lat ?? 0
                let oLon = originPayload.lon ?? 0
                let dLat = destinationPayload.lat ?? 0
                let dLon = destinationPayload.lon ?? 0
                if let match = OfflineCacheManager.shared.findCachedCommutePlans(
                    originLat: oLat, originLon: oLon,
                    destLat: dLat, destLon: dLon
                ) {
                    tripResults = match.plans
                    scheduleNote = nil
                    errorMessage = "You're offline. Showing cached plans from \(match.age)."
                } else if let cached = OfflineCacheManager.shared.getCachedTripPlans(),
                          !cached.isEmpty {
                    tripResults = cached
                    scheduleNote = nil
                    let age = OfflineCacheManager.shared.getTripPlanCacheAge() ?? "recently"
                    errorMessage = "You're offline. Showing cached plans from \(age)."
                } else {
                    tripResults = []
                    scheduleNote = nil
                    errorKind = kind
                    errorMessage = "You're offline with no cached trips."
                }
            } else {
                tripResults = []
                scheduleNote = nil
                errorKind = kind
                errorMessage = message
            }
        }
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

        let tc = tripConfiguration
        let modes = tc.enabledModes.isEmpty ? ["subway", "bus", "lirr", "mnr"] : tc.enabledModes
        let request = EngineGoRequestPayload(
            origin: originPayload,
            destination: destinationPayload,
            userID: nil,
            departAtTS: cursor,
            arriveByTS: nil,
            maxTransfers: tc.maxTransfers,
            maxOriginWalkM: tc.maxOriginWalkMeters,
            maxDestinationWalkM: tc.maxDestinationWalkMeters,
            maxTransferWalkM: tc.maxTransferWalkMeters,
            searchWindowMinutes: 180,
            numItineraries: 3,
            modes: modes,
            recordRecent: false,
            nowTS: Int(Date().timeIntervalSince1970),
            priority: tc.priority,
            accessibilityPriority: tc.accessibilityPriority
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

                // Update session cache so dismissing + reopening preserves "load more" results.
                if let originPayload = payload(for: origin),
                   let destinationPayload = payload(for: destination) {
                    let cacheKey = tripCacheKey(origin: originPayload, destination: destinationPayload)
                    tripCache[cacheKey] = TripCacheEntry(
                        plans: tripResults,
                        scheduleNote: scheduleNote,
                        timestamp: Date()
                    )
                }
            }
        } catch {
            // Silently fail — user still sees existing results
        }

        didLoadMore = true
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
            savedTripTemplates = []
            calendarLocations = []
            recommendations = []
            return
        }

        do {
            async let savedPlacesTask = TrackAPI.fetchEngineSavedPlaces(userID: userID)
            async let recentTripsTask = TrackAPI.fetchEngineRecentTrips(userID: userID, limit: 12)
            async let savedTripTemplatesTask = TrackAPI.fetchEngineSavedTrips(userID: userID)
            async let recommendationsTask = TrackAPI.fetchEngineRecommendations(
                userID: userID,
                latitude: effectiveOriginCoordinate?.latitude,
                longitude: effectiveOriginCoordinate?.longitude,
                originLabel: origin.displayName,
                limit: 6
            )

            let (savedPlaces, recentTrips, templates, recommendations) = try await (
                savedPlacesTask,
                recentTripsTask,
                savedTripTemplatesTask,
                recommendationsTask
            )
            savedTripTemplates = templates
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

    /// Confirms a map-picked coordinate. Synchronous — all state
    /// mutations happen in one run-loop tick to avoid mid-dismiss races.
    func confirmMapCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        name: String,
        address: String
    ) {
        let displayName = name.isEmpty
            ? String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
            : name
        let location = PlanLocation.custom(
            name: displayName,
            address: address,
            lat: coordinate.latitude,
            lon: coordinate.longitude
        )

        if let category = pendingSavedPlaceCategory {
            // Saved-place flow — fire-and-forget the async persist.
            Task { await persistSavedPlace(location, category: category) }
        } else if isOriginForMapPicker {
            selectOrigin(location)
        } else {
            selectDestination(location)
        }

        // Dismiss last — no further state changes after this.
        showMapPicker = false
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

    // MARK: - Saved Trip Templates

    /// Save the current origin/destination as a reusable trip template.
    func saveTripTemplate(name: String) async {
        guard let userID = currentUserID,
              let dest = destination else { return }

        let originPayload = EngineLocationPayloadRequest(
            label: origin.displayName,
            lat: resolvedCoordinate(for: origin)?.latitude,
            lon: resolvedCoordinate(for: origin)?.longitude,
            stopID: nil,
            address: origin.displayAddress
        )
        let destPayload = EngineLocationPayloadRequest(
            label: dest.displayName,
            lat: resolvedCoordinate(for: dest)?.latitude,
            lon: resolvedCoordinate(for: dest)?.longitude,
            stopID: nil,
            address: dest.displayAddress
        )

        let modes = tripConfiguration.enabledModes

        let request = EngineSavedTripUpsertRequest(
            userID: userID,
            name: name,
            origin: originPayload,
            destination: destPayload,
            preferredDepartureHour: nil,
            preferredArrivalHour: nil,
            preferredModes: modes,
            tripID: nil
        )

        do {
            let saved = try await TrackAPI.upsertEngineSavedTrip(request: request)
            savedTripTemplates.insert(saved, at: 0)
        } catch {
            let (kind, message) = friendlyError(for: error)
            errorKind = kind
            errorMessage = message
        }
    }

    /// Delete a saved trip template.
    func deleteSavedTripTemplate(_ template: PlannerSavedTripRecord) async {
        guard let userID = currentUserID else { return }

        do {
            try await TrackAPI.deleteEngineSavedTrip(tripID: template.tripID, userID: userID)
            savedTripTemplates.removeAll { $0.tripID == template.tripID }
        } catch {
            let (kind, message) = friendlyError(for: error)
            errorKind = kind
            errorMessage = message
        }
    }

    /// Launch a trip plan from a saved trip template.
    func planFromTemplate(_ template: PlannerSavedTripRecord) {
        origin = .custom(
            name: template.originLabel,
            address: "",
            lat: template.originLat,
            lon: template.originLon
        )
        destination = .custom(
            name: template.destinationLabel,
            address: "",
            lat: template.destinationLat,
            lon: template.destinationLon
        )
        Task { await planTrip() }
    }

    // MARK: - Calendar Sync

    /// Sync upcoming calendar events to the backend for smarter recommendations.
    func syncCalendarEvents(_ events: [CalendarEventPayload]) async {
        guard let userID = currentUserID else { return }
        do {
            try await TrackAPI.replaceCalendarEvents(userID: userID, events: events)
            await refreshPlannerData()
        } catch {
            #if DEBUG
            print("[CalendarSync] Failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Trip Configuration

    /// Load trip configuration from Supabase (or use defaults).
    func loadTripConfiguration() async {
        guard let uid = currentUserID, let uuid = UUID(uuidString: uid) else { return }
        do {
            if let saved = try await SupabaseManager.shared.fetchTripConfiguration() {
                tripConfiguration = saved
            } else {
                tripConfiguration = .makeDefault(userId: uuid)
            }
        } catch {
            #if DEBUG
            print("[TripConfig] Failed to load: \(error.localizedDescription)")
            #endif
            tripConfiguration = .makeDefault(userId: uuid)
        }
    }

    /// Save trip configuration to Supabase.
    func saveTripConfiguration() async {
        guard currentUserID != nil else { return }
        do {
            try await SupabaseManager.shared.saveTripConfiguration(tripConfiguration)
            #if DEBUG
            print("[TripConfig] Saved to cloud")
            #endif
        } catch {
            #if DEBUG
            print("[TripConfig] Save failed: \(error.localizedDescription)")
            #endif
        }
    }

    /// Debounced save — waits 600ms after the last change before persisting.
    func saveTripConfigurationDebounced() {
        configSaveTask?.cancel()
        configSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await saveTripConfiguration()
        }
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
    /// directions via AppleRoutingService.
    private func fallbackToAppleDirections() async {
        guard let destination else { return }
        guard let originCoord = resolvedCoordinate(for: origin),
              let destCoord = resolvedCoordinate(for: destination) else {
            errorKind = .engineUnavailable
            errorMessage = "The routing engine is temporarily offline."
            tripResults = []
            return
        }

        do {
            let plans = try await AppleRoutingService.fetchTransitRoutes(
                from: originCoord,
                to: destCoord,
                departureOption: departureOption,
                originName: origin.displayName,
                destinationName: destination.displayName
            )
            if !plans.isEmpty {
                tripResults = plans
                scheduleNote = nil
                isUsingAppleFallback = true
                errorMessage = nil
                return
            }
        } catch {
            #if DEBUG
            print("[Fallback] Apple Maps transit failed: \(error.localizedDescription)")
            #endif
        }

        tripResults = []
        scheduleNote = nil
        isUsingAppleFallback = false
        errorKind = .engineUnavailable
        errorMessage = "The routing engine is temporarily offline. Please try again shortly."
    }

    /// Returns `true` when every trip departs on a different calendar day
    /// (Eastern time) than right now — i.e. the engine found nothing for
    /// today and fell back to the next service day.
    private func allTripsAreFutureDay(_ trips: [TripPlan]) -> Bool {
        guard !trips.isEmpty else { return false }
        let cal = Calendar.current
        let todayComponents = cal.dateComponents([.year, .month, .day], from: Date())
        return trips.allSatisfy { trip in
            let depComponents = cal.dateComponents([.year, .month, .day], from: trip.departureTime)
            return depComponents != todayComponents
        }
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

    // MARK: - Smart Commute Pre-Fetch

    /// Background pre-fetch trip plans for the user's frequent O/D pairs.
    /// Uses saved places (home/work) + recent trips to build pairs,
    /// then fetches plans for any that aren't already cached.
    /// Call this after the initial data load, on a low-priority task.
    func prefetchCommutePlans() async {
        guard let userID = currentUserID else { return }
        guard OfflineCacheManager.shared.isOnline else { return }

        // Build candidate O/D pairs from saved places + recent trips
        var pairs: [(originLabel: String, oLat: Double, oLon: Double,
                      destLabel: String, dLat: Double, dLon: Double)] = []

        // 1) Current location → each saved place (home, work, etc.)
        if let coord = currentLocationCoordinate {
            for place in savedLocations {
                pairs.append((
                    originLabel: "Current location",
                    oLat: coord.latitude, oLon: coord.longitude,
                    destLabel: place.name,
                    dLat: place.latitude, dLon: place.longitude
                ))
                // Also reverse: saved place → current location
                pairs.append((
                    originLabel: place.name,
                    oLat: place.latitude, oLon: place.longitude,
                    destLabel: "Current location",
                    dLat: coord.latitude, dLon: coord.longitude
                ))
            }
        }

        // 2) Between saved places (home ↔ work)
        let keyPlaces = savedLocations.filter {
            let cat = SavedLocationCategory(rawValue: $0.category)
            return cat == .home || cat == .work || cat == .school
        }
        for i in 0..<keyPlaces.count {
            for j in 0..<keyPlaces.count where i != j {
                pairs.append((
                    originLabel: keyPlaces[i].name,
                    oLat: keyPlaces[i].latitude, oLon: keyPlaces[i].longitude,
                    destLabel: keyPlaces[j].name,
                    dLat: keyPlaces[j].latitude, dLon: keyPlaces[j].longitude
                ))
            }
        }

        // 3) Top recent trips (up to 4 most recent unique O/D pairs)
        let recentPairs = savedTrips.prefix(4)
        for trip in recentPairs {
            pairs.append((
                originLabel: trip.originName,
                oLat: trip.originLat, oLon: trip.originLon,
                destLabel: trip.destinationName,
                dLat: trip.destinationLat, dLon: trip.destinationLon
            ))
        }

        // Deduplicate by commute key
        var seen = Set<String>()
        let alreadyCached = Set(
            OfflineCacheManager.shared.cachedCommuteKeys().map(\.key)
        )
        var uniquePairs = pairs.filter { pair in
            let key = OfflineCacheManager.commuteKey(
                originLat: pair.oLat, originLon: pair.oLon,
                destLat: pair.dLat, destLon: pair.dLon
            )
            guard !alreadyCached.contains(key) else { return false }
            return seen.insert(key).inserted
        }

        // Cap at 3 pre-fetches to avoid competing with active user requests
        uniquePairs = Array(uniquePairs.prefix(3))

        guard !uniquePairs.isEmpty else {
            #if DEBUG
            print("[Prefetch] All commute pairs already cached — skipping")
            #endif
            return
        }

        #if DEBUG
        print("[Prefetch] Pre-fetching \(uniquePairs.count) commute plans...")
        #endif

        let tc = tripConfiguration
        let modes = tc.enabledModes.isEmpty
            ? ["subway", "bus", "lirr", "mnr"]
            : tc.enabledModes

        for (index, pair) in uniquePairs.enumerated() {
            // Stagger fetches to avoid competing with active user requests
            if index > 0 {
                try? await Task.sleep(for: .milliseconds(800))
            }
            guard !Task.isCancelled else { break }
            guard OfflineCacheManager.shared.isOnline else { break }

            let request = EngineGoRequestPayload(
                origin: EngineLocationPayloadRequest(
                    label: pair.originLabel,
                    lat: pair.oLat, lon: pair.oLon,
                    stopID: nil, address: nil
                ),
                destination: EngineLocationPayloadRequest(
                    label: pair.destLabel,
                    lat: pair.dLat, lon: pair.dLon,
                    stopID: nil, address: nil
                ),
                userID: userID,
                departAtTS: Int(Date().timeIntervalSince1970),
                arriveByTS: nil,
                maxTransfers: tc.maxTransfers,
                maxOriginWalkM: tc.maxOriginWalkMeters,
                maxDestinationWalkM: tc.maxDestinationWalkMeters,
                maxTransferWalkM: tc.maxTransferWalkMeters,
                searchWindowMinutes: 180,
                numItineraries: 3,
                modes: modes,
                recordRecent: false,
                nowTS: Int(Date().timeIntervalSince1970),
                priority: tc.priority,
                accessibilityPriority: tc.accessibilityPriority
            )

            do {
                let response = try await TrackAPI.fetchEngineGo(request: request)
                let plans = response.tripPlans
                guard !plans.isEmpty else { continue }

                let key = OfflineCacheManager.commuteKey(
                    originLat: pair.oLat, originLon: pair.oLon,
                    destLat: pair.dLat, destLon: pair.dLon
                )
                OfflineCacheManager.shared.cacheCommutePlans(
                    key: key,
                    originLabel: pair.originLabel,
                    originLat: pair.oLat, originLon: pair.oLon,
                    destinationLabel: pair.destLabel,
                    destLat: pair.dLat, destLon: pair.dLon,
                    plans: plans
                )
                #if DEBUG
                print("[Prefetch] Cached \(plans.count) plans: \(pair.originLabel) → \(pair.destLabel)")
                #endif
            } catch {
                #if DEBUG
                print("[Prefetch] Failed \(pair.originLabel) → \(pair.destLabel): \(error.localizedDescription)")
                #endif
                // Non-fatal — continue with next pair
            }
        }

        #if DEBUG
        let total = OfflineCacheManager.shared.cachedCommuteKeys().count
        print("[Prefetch] Done. \(total) commute pairs cached for offline use.")
        #endif
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
