// Typed service-variant for transit arrivals.  Mirrors the backend
// `ServiceVariant` enum at app/services/transit/service_variant.py.
//
// Wire format: lowercase string token in JSON.  When the backend sends
// an unknown / future variant, we decode it as `.unknown` rather than
// failing the entire arrival decode.
//
// The enum is shared between the iOS app and the widget extension so
// both surfaces render identical pills.

import SwiftUI

enum ServiceVariant: String, Codable, CaseIterable, Equatable {
    case local
    case limited
    case express
    case sbs
    case superExpress = "super_express"
    case shuttle
    case unknown

    // MARK: - Decoding

    /// Tolerant decoder: any unrecognised raw value falls back to
    /// `.unknown` so a backend rollout that adds a new variant
    /// doesn't break old client builds.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ServiceVariant(rawValue: raw.lowercased()) ?? .unknown
    }

    // MARK: - Display

    /// Short label shown inside the pill.  Kept compact for arrival
    /// rows that already show route + destination + countdown.
    var displayLabel: String {
        switch self {
        case .local: return "Local"
        case .limited: return "Limited"
        case .express: return "Express"
        case .sbs: return "SBS"
        case .superExpress: return "Super Express"
        case .shuttle: return "Shuttle"
        case .unknown: return ""
        }
    }

    /// SF Symbol for the pill leading icon.  Empty string suppresses
    /// the icon (used for `.local` because every arrival is local by
    /// default and adding an icon to every row is visual noise).
    var iconName: String {
        switch self {
        case .local: return ""
        case .limited: return "forward.fill"
        case .express: return "bolt.fill"
        case .sbs: return "bus.fill"
        case .superExpress: return "bolt.horizontal.fill"
        case .shuttle: return "arrow.left.arrow.right"
        case .unknown: return ""
        }
    }

    /// True when this variant should render a visible pill in lists.
    /// Local arrivals don't render a pill (every line is local by
    /// default, so showing "Local" everywhere adds noise).  Same for
    /// `.unknown` which means the backend couldn't classify.
    var showsPill: Bool {
        switch self {
        case .local, .unknown: return false
        default: return true
        }
    }

    /// Tint for the pill background.  Subdued so the pill never
    /// competes with the main route badge.
    func tintColor(routeColor: Color) -> Color {
        switch self {
        case .express, .superExpress: return .orange
        case .limited: return .purple
        case .sbs: return Color(red: 0.0, green: 0.62, blue: 0.78)
        case .shuttle: return .gray
        case .local, .unknown: return routeColor
        }
    }

    /// Accessibility text spoken by VoiceOver.
    var accessibilityLabel: String {
        switch self {
        case .local: return "Local service"
        case .limited: return "Limited stops"
        case .express: return "Express service"
        case .sbs: return "Select Bus Service"
        case .superExpress: return "Super Express"
        case .shuttle: return "Shuttle"
        case .unknown: return ""
        }
    }
}
