import SwiftUI

/// Zoom-responsive subway station marker for the system map.
///
/// Matches the Apple Maps / MTA official map style:
/// - **Single color group** (e.g. L train only): tiny circle.
/// - **2 color groups**: oval (transfer station).
/// - **3 color groups**: wider oval (major transfer hub).
/// - **4+ color groups**: widest oval (complex like Times Sq, Atlantic Av).
///
/// Ovals denote major transfer complexes where historically separate
/// IRT / BMT / IND platforms were connected — the bigger the oval,
/// the more trunk-color lines converge there.
///
/// The marker scales with the camera distance:
/// - Zoomed in (< 2 km): markers are large and prominent.
/// - Medium zoom (2–8 km): default size.
/// - Zoomed out (> 8 km): markers shrink, keeping the map clean.
///
/// Keeping the view minimal is critical because hundreds of stations
/// can be visible simultaneously.
struct SubwayStationMarker: View, Equatable {
    let station: HomeViewModel.CachedSubwayStation

    /// Discrete zoom tier — only changes when crossing a zoom boundary,
    /// so MapKit skips diffing this view's body during continuous pan/zoom.
    var zoomTier: ZoomTier = .medium

    static func == (lhs: SubwayStationMarker, rhs: SubwayStationMarker) -> Bool {
        lhs.station == rhs.station && lhs.zoomTier == rhs.zoomTier
    }

    /// How many distinct MTA color groups serve this station.
    /// Used to stretch the marker into an oval for multi-group transfers.
    private var colorGroupCount: Int {
        var groups = Set<Int>()
        for route in station.routes {
            groups.insert(Self.trunkGroupIndex(for: route))
        }
        return max(groups.count, 1)
    }

    /// Scale factor derived from zoom tier.
    private var zoomScale: CGFloat { zoomTier.rawValue }

    var body: some View {
        let count = colorGroupCount
        let scale = zoomScale
        // Base sizing — Apple Maps uses small, elegant markers:
        //   1 group  → 5×5 circle  (tiny dot)
        //   2 groups → 8×5 oval    (e.g. Hoyt-Schermerhorn A/C + G)
        //   3 groups → 11×5 oval   (e.g. Atlantic Av, Forest Hills)
        //   4+ groups→ 13×5 oval   (e.g. Times Sq, Herald Sq)
        // Capped at 13 pt wide so even Times Sq (5 groups) stays clean.
        let baseWidth: CGFloat = count <= 1 ? 5 : min(5 + CGFloat(count) * 3, 13)
        let baseHeight: CGFloat = 5
        let width = baseWidth * scale
        let height = baseHeight * scale
        let strokeWidth = max(0.5, 0.75 * scale)
        Capsule()
            .fill(Color.white)
            .frame(width: width, height: height)
            .overlay(
                Capsule()
                    .stroke(Color(.darkGray), lineWidth: strokeWidth)
            )
            .accessibilityLabel("Station: \(station.name)")
    }

    // MARK: - Trunk Group Mapping

    /// Returns a stable group index for a route ID based on MTA trunk colors.
    /// Must match the `trunkGroups` array in `MapSystemViewModel`.
    private static func trunkGroupIndex(for routeId: String) -> Int {
        let r = routeId.uppercased()
        switch r {
        case "1", "2", "3":                return 0  // Red
        case "4", "5", "6", "6X":          return 1  // Green
        case "7", "7X":                    return 2  // Purple
        case "A", "C", "E":               return 3  // Blue
        case "B", "D", "F", "FX", "M":    return 4  // Orange
        case "G":                          return 5  // Lime
        case "J", "Z":                    return 6  // Brown
        case "L":                          return 7  // Gray
        case "N", "Q", "R", "W":          return 8  // Yellow
        case "S":                          return 9  // Shuttle
        case "SI":                         return 10 // SI
        default:                           return 99
        }
    }
}
