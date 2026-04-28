import Foundation

struct TrackedTripSnapshot: Codable, Equatable {
    let destinationName: String
    let departureTime: Date
    let arrivalTime: Date
    let totalDurationMinutes: Int
    let currentLegIndex: Int
    let legs: [TrackedTripLeg]
    let updatedAt: Date

    var durationString: String {
        let hours = totalDurationMinutes / 60
        let minutes = totalDurationMinutes % 60
        if hours > 0 { return "\(hours) h \(String(format: "%02d", minutes)) min" }
        return "\(minutes) min"
    }

    var progress: Double {
        let total = max(1, arrivalTime.timeIntervalSince(departureTime))
        let elapsed = Date().timeIntervalSince(departureTime)
        return min(1, max(0, elapsed / total))
    }

    private nonisolated(unsafe) static let defaults =
        UserDefaults(suiteName: "group.JFMCAPITALGROUP.Track") ?? .standard

    private enum Keys {
        static let snapshot = "tracked_trip_snapshot_v1"
    }

    static func load() -> TrackedTripSnapshot? {
        guard let data = defaults.data(forKey: Keys.snapshot) else { return nil }
        return try? JSONDecoder().decode(TrackedTripSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults.set(data, forKey: Keys.snapshot)
    }

    static func clear() {
        defaults.removeObject(forKey: Keys.snapshot)
    }
}

struct TrackedTripLeg: Codable, Equatable, Identifiable {
    let id: String
    let mode: String
    let routeId: String?
    let routeName: String?
    let routeColorHex: String?
    let textColorHex: String?
    let boardStopName: String
    let alightStopName: String
    let departureTime: Date
    let arrivalTime: Date
    let durationMinutes: Int

    var isTransit: Bool {
        mode != "walk" && mode != "transfer"
    }

    var isBus: Bool { mode == "bus" }
    var isLIRR: Bool { mode == "lirr" }
    var isMNR: Bool { mode == "mnr" }
    var isCommuterRail: Bool { isLIRR || isMNR }

    var displayRoute: String {
        stripMTAAgencyPrefix(routeId ?? routeName ?? modeDisplayName)
    }

    var modeDisplayName: String {
        switch mode {
        case "walk", "transfer": return "Walk"
        case "bus": return "Bus"
        case "lirr": return "LIRR"
        case "mnr": return "Metro-North"
        default: return "Train"
        }
    }
}
