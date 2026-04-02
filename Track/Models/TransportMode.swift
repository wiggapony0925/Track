// Defines the transport modes supported by Track.
// Used by HomeViewModel and TransportModeToggle.

import Foundation

/// The transport modes supported by Track.
enum TransportMode: String, CaseIterable {
    case nearby
    case subway
    case bus
    case lirr
    case mnr

    var label: String {
        switch self {
        case .nearby: return "Nearby"
        case .subway: return "Subway"
        case .bus: return "Bus"
        case .lirr: return "LIRR"
        case .mnr: return "Metro-North"
        }
    }

    var icon: String {
        switch self {
        case .nearby: return "location.fill"
        case .subway: return "tram.fill"
        case .bus: return "bus.fill"
        case .lirr: return "train.side.front.car"
        case .mnr: return "train.side.rear.car"
        }
    }
}
