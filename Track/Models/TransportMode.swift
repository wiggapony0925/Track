//
//  TransportMode.swift
//  Track
//
//  Defines the transport modes supported by Track.
//  Used by HomeViewModel and TransportModeToggle.
//

import Foundation

/// The two transport modes supported by Track.
enum TransportMode: String, CaseIterable {
    case subway
    case bus

    var label: String {
        switch self {
        case .subway: return "Subway"
        case .bus: return "Bus"
        }
    }

    var icon: String {
        switch self {
        case .subway: return "tram.fill"
        case .bus: return "bus.fill"
        }
    }
}
