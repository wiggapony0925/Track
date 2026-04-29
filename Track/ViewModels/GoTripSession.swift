// Global "Go" session — when set to a non-nil trip, the entire app
// pivots into navigation mode and presents the immersive GoTripView
// full-screen cover.  The user cannot switch tabs while a trip is
// active; they must explicitly exit via the close button.

import CoreLocation
import Foundation
import SwiftUI
import AVFoundation
import WidgetKit
@preconcurrency import UserNotifications

@Observable
@MainActor
final class GoTripSession {
    /// The trip currently being navigated.  `nil` when not in Go mode.
    var activeTrip: TripPlan?

    /// Index of the leg the user is currently on (0 = first leg).
    /// Bumped manually for now; future work can advance based on GPS.
    var currentLegIndex: Int = 0

    /// Live, corrected ETA for the full Go trip. Falls back to the planned
    /// trip arrival when the engine did not attach realtime status.
    var liveArrivalTime: Date?

    /// Human-readable guidance synced with widgets / Live Activity.
    var guidanceStatusText: String = "Ready"

    private let speechSynthesizer = AVSpeechSynthesizer()
    private let goMode = GoModeViewModel()
    private var spokenGuidanceKeys: Set<String> = []
    private var guidanceTask: Task<Void, Never>?
    private var liveBoardingLegID: UUID?
    private var liveBoardingTimeOverride: Date?
    private var trackedAlightLegID: UUID?

    var isActive: Bool { activeTrip != nil }

    func start(_ trip: TripPlan) {
        guidanceTask?.cancel()
        spokenGuidanceKeys = []
        liveBoardingLegID = nil
        liveBoardingTimeOverride = nil
        currentLegIndex = 0
        activeTrip = trip
        liveArrivalTime = Self.resolvedTripArrivalTime(for: trip)
        guidanceStatusText = Self.statusText(for: trip, currentLegIndex: currentLegIndex)
        activateTripTracking(for: trip)
        saveTrackedTripForWidgets(from: trip)
        saveTrackedRouteForWidgets(from: trip)
        WidgetCenter.shared.reloadAllTimelines()

        guidanceTask = Task { [weak self] in
            await self?.startLiveGuidance(for: trip)
            await self?.runGuidanceLoop()
        }
    }

    func stop() {
        guidanceTask?.cancel()
        guidanceTask = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
        goMode.deactivateGoMode()
        LiveActivityManager.shared.endActivity()
        TrackedTripSnapshot.clear()
        TrackedRoute.clear()
        WidgetCenter.shared.reloadAllTimelines()
        activeTrip = nil
        currentLegIndex = 0
        liveArrivalTime = nil
        liveBoardingLegID = nil
        liveBoardingTimeOverride = nil
        trackedAlightLegID = nil
        guidanceStatusText = "Ready"
        spokenGuidanceKeys = []
    }

    func updateUserLocation(_ location: CLLocation?) {
        guard isActive else { return }
        goMode.updateUserLocation(location)
    }

    func refreshGuidance() {
        guard let trip = activeTrip else { return }
        currentLegIndex = Self.currentLegIndex(for: trip)
        liveArrivalTime = Self.resolvedTripArrivalTime(for: trip)
        guidanceStatusText = Self.statusText(for: trip, currentLegIndex: currentLegIndex)
        updateLiveActivity(for: trip)
        saveTrackedTripForWidgets(from: trip)
        saveTrackedRouteForWidgets(from: trip)
        WidgetCenter.shared.reloadAllTimelines()
        speakDueGuidance(for: trip)
    }

    func refreshLiveGuidance() async {
        guard let trip = activeTrip else { return }
        currentLegIndex = Self.currentLegIndex(for: trip)
        await refreshGetOffTrackingTarget(for: trip)
        await refreshLiveArrivalFromNearby(for: trip)
        refreshGuidance()
    }

    private func startLiveGuidance(for trip: TripPlan) async {
        guard let leg = Self.primaryTransitLeg(in: trip) else { return }
        await refreshGetOffTrackingTarget(for: trip)
        await refreshLiveArrivalFromNearby(for: trip)
        let arrivalTime = resolvedBoardingTime(for: leg)
        let minutesAway = TrackingTimeSync.remainingMinutes(until: arrivalTime)
        let walkMinutes = Self.firstWalkMinutes(in: trip)

        await LiveActivityManager.shared.startActivity(
            lineId: Self.displayLineID(for: leg),
            destination: leg.headsign ?? leg.alightStopName,
            arrivalTime: arrivalTime,
            isBus: leg.mode == .bus,
            stationId: leg.boardStopId ?? "",
            minutesAway: minutesAway,
            nextArrivals: [],
            walkMinutes: walkMinutes,
            isHurryUp: Self.shouldHurry(to: leg)
        )
        updateLiveActivity(for: trip)
        speakDueGuidance(for: trip)
    }

    private func runGuidanceLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: LiveTrackingClock.vehiclePollSleepNanoseconds)
            guard !Task.isCancelled else { return }
            if let activeTrip {
                await refreshLiveArrivalFromNearby(for: activeTrip)
            }
            refreshGuidance()
        }
    }

    private func updateLiveActivity(for trip: TripPlan) {
        guard let leg = Self.currentTransitLeg(in: trip, currentLegIndex: currentLegIndex) else {
            let arrival = Self.resolvedTripArrivalTime(for: trip)
            LiveActivityManager.shared.updateActivity(
                statusText: TrackingTimeSync.statusText(until: arrival),
                arrivalTime: arrival,
                progress: TrackingTimeSync.progress(until: arrival),
                minutesAway: TrackingTimeSync.remainingMinutes(until: arrival),
                nextArrivals: [],
                walkMinutes: nil,
                isHurryUp: false
            )
            return
        }

        let boardingTime = resolvedBoardingTime(for: leg)
        let minutesAway = TrackingTimeSync.remainingMinutes(until: boardingTime)
        let walkMinutes = Self.firstWalkMinutes(in: trip)
        LiveActivityManager.shared.updateActivity(
            statusText: Self.statusText(for: trip, currentLegIndex: currentLegIndex),
            arrivalTime: boardingTime,
            progress: TrackingTimeSync.progress(until: boardingTime),
            minutesAway: minutesAway,
            nextArrivals: [],
            walkMinutes: walkMinutes,
            isHurryUp: Self.shouldHurry(to: leg)
        )
    }

    private func speakDueGuidance(for trip: TripPlan, now: Date = .now) {
        guard let leg = Self.currentTransitLeg(in: trip, currentLegIndex: currentLegIndex) else { return }
        let boardingTime = resolvedBoardingTime(for: leg)
        let secondsUntilBoarding = boardingTime.timeIntervalSince(now)

        if secondsUntilBoarding <= 75 {
            speakOnce(
                key: "board-now-\(leg.id)",
                text: "Go now to \(Self.displayLineID(for: leg)) toward \(leg.headsign ?? leg.alightStopName). Board at \(leg.boardStopName)."
            )
        } else if secondsUntilBoarding <= 180 {
            let minutes = max(1, Int(ceil(secondsUntilBoarding / 60.0)))
            speakOnce(
                key: "board-soon-\(leg.id)",
                text: "Your \(Self.displayLineID(for: leg)) arrives in \(minutes) minutes at \(leg.boardStopName)."
            )
        }
    }

    private func speakOnce(key: String, text: String) {
        guard !spokenGuidanceKeys.contains(key) else { return }
        spokenGuidanceKeys.insert(key)

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            AppLogger.shared.logError("GO guidance audio session", error: error)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    private func refreshLiveArrivalFromNearby(for trip: TripPlan) async {
        guard let leg = Self.currentTransitLeg(in: trip, currentLegIndex: currentLegIndex),
              let location = Self.lastWidgetLocation()
        else { return }

        do {
            let arrivals = try await TrackAPI.fetchNearbyTransit(
                lat: location.latitude,
                lon: location.longitude,
                radius: 1_600
            )
            guard let match = Self.bestArrivalMatch(for: leg, arrivals: arrivals) else { return }

            let refreshedBoardingTime = Self.arrivalDate(for: match)
            liveBoardingLegID = leg.id
            liveBoardingTimeOverride = refreshedBoardingTime

            let delta = refreshedBoardingTime.timeIntervalSince(Self.resolvedBoardingTime(for: leg))
            liveArrivalTime = Self.resolvedTripArrivalTime(for: trip).addingTimeInterval(delta)
            guidanceStatusText = Self.statusText(
                for: trip,
                currentLegIndex: currentLegIndex,
                boardingOverride: refreshedBoardingTime
            )
        } catch {
            AppLogger.shared.logError("GO live arrival refresh", error: error)
        }
    }

    private func resolvedBoardingTime(for leg: TripLeg) -> Date {
        if liveBoardingLegID == leg.id, let liveBoardingTimeOverride {
            return liveBoardingTimeOverride
        }
        return Self.resolvedBoardingTime(for: leg)
    }

    private func saveTrackedRouteForWidgets(from trip: TripPlan) {
        guard let leg = Self.currentTransitLeg(in: trip, currentLegIndex: currentLegIndex)
            ?? Self.primaryTransitLeg(in: trip)
        else { return }
        let routeId = leg.routeId ?? leg.routeName ?? Self.displayLineID(for: leg)
        let trackedRoute = TrackedRoute(
            routeId: routeId,
            displayName: Self.displayLineID(for: leg),
            stopName: leg.boardStopName,
            direction: leg.headsign ?? leg.alightStopName,
            destination: leg.headsign ?? leg.alightStopName,
            mode: Self.widgetMode(for: leg),
            trackedAt: Date()
        )
        trackedRoute.save()
    }

    private func saveTrackedTripForWidgets(from trip: TripPlan) {
        let snapshot = TrackedTripSnapshot(
            destinationName: trip.legs.last?.alightStopName ?? "Destination",
            departureTime: trip.departureTime,
            arrivalTime: liveArrivalTime ?? Self.resolvedTripArrivalTime(for: trip),
            totalDurationMinutes: trip.totalDurationMinutes,
            currentLegIndex: currentLegIndex,
            legs: trip.legs.map { leg in
                TrackedTripLeg(
                    id: leg.id.uuidString,
                    mode: Self.widgetModeName(for: leg),
                    routeId: leg.routeId,
                    routeName: leg.routeName,
                    routeColorHex: leg.routeColor,
                    textColorHex: leg.textColorHex,
                    boardStopName: leg.boardStopName,
                    alightStopName: leg.alightStopName,
                    departureTime: Self.resolvedBoardingTime(for: leg),
                    arrivalTime: Self.resolvedLegArrivalTime(for: leg),
                    durationMinutes: leg.durationMinutes
                )
            },
            updatedAt: Date()
        )
        snapshot.save()
    }

    private func activateTripTracking(for trip: TripPlan) {
        guard let leg = Self.currentTransitLeg(in: trip, currentLegIndex: currentLegIndex)
            ?? Self.primaryTransitLeg(in: trip)
        else { return }
        goMode.activateGoMode(
            routeName: Self.displayLineID(for: leg),
            routeColor: Self.color(for: leg)
        )
        requestTripNotificationPermissionIfNeeded()
    }

    private func refreshGetOffTrackingTarget(for trip: TripPlan) async {
        guard let leg = Self.currentTransitLeg(in: trip, currentLegIndex: currentLegIndex),
              trackedAlightLegID != leg.id
        else { return }

        trackedAlightLegID = leg.id
        do {
            let shape = try await Self.fetchShape(for: leg)
            guard let stop = Self.alightStop(for: leg, shape: shape) else { return }
            goMode.setAlightStop(
                id: stop.id,
                name: stop.name,
                lat: stop.lat,
                lon: stop.lon
            )
        } catch {
            AppLogger.shared.logError("GO get-off tracking target", error: error)
        }
    }

    private func requestTripNotificationPermissionIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    private static func primaryTransitLeg(in trip: TripPlan) -> TripLeg? {
        trip.legs.first(where: \.isTransit)
    }

    private static func fetchShape(for leg: TripLeg) async throws -> RouteShapeResponse {
        guard let routeId = leg.routeId else { throw URLError(.badURL) }
        switch leg.mode {
        case .subway:
            return try await TrackAPI.fetchSubwayShape(routeID: routeId)
        case .bus:
            return try await TrackAPI.fetchRouteShape(routeID: routeId)
        case .lirr:
            return try await TrackAPI.fetchLIRRShape(routeID: routeId)
        case .mnr:
            return try await TrackAPI.fetchMNRShape(routeID: routeId)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private static func alightStop(for leg: TripLeg, shape: RouteShapeResponse) -> BusStop? {
        if let direction = bestDirection(for: leg, shape: shape),
           let stop = TripRouteClipping.findStop(
                in: direction.stops,
                id: leg.alightStopId,
                name: leg.alightStopName
           ) {
            return stop
        }

        return TripRouteClipping.findStop(
            in: shape.stops,
            id: leg.alightStopId,
            name: leg.alightStopName
        )
    }

    private static func bestDirection(
        for leg: TripLeg,
        shape: RouteShapeResponse
    ) -> DirectionShapeResponse? {
        guard !shape.directions.isEmpty else { return nil }
        let headsign = leg.headsign.map(normalizedMatchToken)

        struct Candidate {
            let direction: DirectionShapeResponse
            let forward: Bool
            let nameMatches: Bool
            let span: Int
        }

        let candidates: [Candidate] = shape.directions.compactMap { direction in
            guard let boardStop = TripRouteClipping.findStop(
                in: direction.stops,
                id: leg.boardStopId,
                name: leg.boardStopName
            ),
                  let alightStop = TripRouteClipping.findStop(
                    in: direction.stops,
                    id: leg.alightStopId,
                    name: leg.alightStopName
                  ),
                  let boardIndex = direction.stops.firstIndex(where: { $0.id == boardStop.id }),
                  let alightIndex = direction.stops.firstIndex(where: { $0.id == alightStop.id }),
                  boardIndex != alightIndex
            else { return nil }

            let directionHeadsign = normalizedMatchToken(direction.headsign)
            let nameMatches = headsign.map {
                $0 == directionHeadsign || $0.contains(directionHeadsign) || directionHeadsign.contains($0)
            } ?? false
            return Candidate(
                direction: direction,
                forward: boardIndex < alightIndex,
                nameMatches: nameMatches,
                span: abs(alightIndex - boardIndex)
            )
        }

        return candidates.min { lhs, rhs in
            if lhs.forward != rhs.forward { return lhs.forward && !rhs.forward }
            if lhs.nameMatches != rhs.nameMatches { return lhs.nameMatches && !rhs.nameMatches }
            return lhs.span < rhs.span
        }?.direction
    }

    private static func currentLegIndex(for trip: TripPlan, now: Date = .now) -> Int {
        guard !trip.legs.isEmpty else { return 0 }
        if now < trip.legs[0].departureTime { return 0 }
        for (index, leg) in trip.legs.enumerated() {
            if now >= leg.departureTime && now < leg.arrivalTime {
                return index
            }
        }
        return max(0, trip.legs.count - 1)
    }

    private static func currentTransitLeg(in trip: TripPlan, currentLegIndex: Int) -> TripLeg? {
        if trip.legs.indices.contains(currentLegIndex), trip.legs[currentLegIndex].isTransit {
            return trip.legs[currentLegIndex]
        }
        return trip.legs.dropFirst(max(0, currentLegIndex)).first(where: \.isTransit)
            ?? primaryTransitLeg(in: trip)
    }

    private static func resolvedBoardingTime(for leg: TripLeg) -> Date {
        leg.liveStatus?.predictedDepartureTime ?? leg.departureTime
    }

    private static func resolvedLegArrivalTime(for leg: TripLeg) -> Date {
        leg.liveStatus?.predictedArrivalTime ?? leg.arrivalTime
    }

    private static func resolvedTripArrivalTime(for trip: TripPlan) -> Date {
        guard let finalTransitLeg = trip.legs.last(where: \.isTransit) else {
            return trip.arrivalTime
        }
        let correctedFinalTransitArrival = resolvedLegArrivalTime(for: finalTransitLeg)
        let plannedRemainder = max(0, trip.arrivalTime.timeIntervalSince(finalTransitLeg.arrivalTime))
        return correctedFinalTransitArrival.addingTimeInterval(plannedRemainder)
    }

    private static func firstWalkMinutes(in trip: TripPlan) -> Int? {
        guard let first = trip.legs.first, first.mode == .walk || first.mode == .transfer else {
            return nil
        }
        return max(1, first.durationMinutes)
    }

    private static func shouldHurry(to leg: TripLeg, now: Date = .now) -> Bool {
        resolvedBoardingTime(for: leg).timeIntervalSince(now) <= 180
    }

    private static func statusText(for trip: TripPlan, currentLegIndex: Int) -> String {
        guard let leg = currentTransitLeg(in: trip, currentLegIndex: currentLegIndex) else {
            return TrackingTimeSync.statusText(until: resolvedTripArrivalTime(for: trip))
        }
        return statusText(
            for: trip,
            currentLegIndex: currentLegIndex,
            boardingOverride: resolvedBoardingTime(for: leg)
        )
    }

    private static func statusText(
        for trip: TripPlan,
        currentLegIndex: Int,
        boardingOverride: Date
    ) -> String {
        guard let leg = currentTransitLeg(in: trip, currentLegIndex: currentLegIndex) else {
            return TrackingTimeSync.statusText(until: resolvedTripArrivalTime(for: trip))
        }
        let boardingTime = boardingOverride
        let seconds = boardingTime.timeIntervalSinceNow
        let line = displayLineID(for: leg)
        if seconds <= 75 {
            return "Go now to \(line)"
        }
        let minutes = max(1, Int(ceil(seconds / 60.0)))
        return "\(line) in \(minutes) min"
    }

    private static func displayLineID(for leg: TripLeg) -> String {
        let raw = leg.routeId ?? leg.routeName ?? leg.modeName ?? "Transit"
        return raw.replacingOccurrences(of: "MTA NYCT_", with: "")
    }

    private static func widgetMode(for leg: TripLeg) -> String {
        switch leg.mode {
        case .bus: return "bus"
        case .lirr: return "lirr"
        case .mnr: return "mnr"
        default: return "subway"
        }
    }

    private static func widgetModeName(for leg: TripLeg) -> String {
        switch leg.mode {
        case .walk: return "walk"
        case .transfer: return "transfer"
        case .bus: return "bus"
        case .lirr: return "lirr"
        case .mnr: return "mnr"
        case .subway: return "subway"
        }
    }

    private static func color(for leg: TripLeg) -> Color {
        if let hex = leg.routeColor, !hex.isEmpty { return Color(hex: hex) }
        if let routeId = leg.routeId {
            return AppTheme.SubwayColors.color(for: stripMTAAgencyPrefix(routeId))
        }
        return AppTheme.Colors.accent
    }

    private static func lastWidgetLocation() -> CLLocationCoordinate2D? {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        guard defaults.bool(forKey: "hasLastLocation") else { return nil }
        let lat = defaults.double(forKey: "lastLatitude")
        let lon = defaults.double(forKey: "lastLongitude")
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func bestArrivalMatch(
        for leg: TripLeg,
        arrivals: [NearbyTransitResponse]
    ) -> NearbyTransitResponse? {
        let plannedBoarding = resolvedBoardingTime(for: leg)
        let legRoute = normalizedMatchToken(leg.routeId ?? leg.routeName ?? "")
        let legMode = widgetMode(for: leg)
        let boardStopID = leg.boardStopId?.uppercased()
        let boardStopName = normalizedMatchToken(leg.boardStopName)

        return arrivals
            .filter { arrival in
                guard !arrival.isPlaceholder,
                      widgetMode(for: arrival.mode) == legMode,
                      normalizedMatchToken(arrival.routeId) == legRoute
                else { return false }

                if let boardStopID,
                   let stopID = arrival.stopId?.uppercased(),
                   stopID == boardStopID {
                    return true
                }

                let arrivalStopName = normalizedMatchToken(arrival.stopName)
                return arrivalStopName == boardStopName
                    || arrivalStopName.contains(boardStopName)
                    || boardStopName.contains(arrivalStopName)
            }
            .min { lhs, rhs in
                abs(arrivalDate(for: lhs).timeIntervalSince(plannedBoarding))
                    < abs(arrivalDate(for: rhs).timeIntervalSince(plannedBoarding))
            }
    }

    private static func arrivalDate(for arrival: NearbyTransitResponse) -> Date {
        if let ts = arrival.arrivalTs, ts > 0 {
            return Date(timeIntervalSince1970: TimeInterval(ts))
        }
        return Date().addingTimeInterval(TimeInterval(max(0, arrival.minutesAway)) * 60)
    }

    private static func widgetMode(for mode: String) -> String {
        switch mode.lowercased() {
        case "bus": return "bus"
        case "lirr": return "lirr"
        case "mnr", "metro_north": return "mnr"
        default: return "subway"
        }
    }

    private static func normalizedMatchToken(_ value: String) -> String {
        value.uppercased()
            .replacingOccurrences(of: "MTA NYCT_", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
