// Parses MTA alert text containing route tokens like [A], [7], [SBS]
// and renders them as inline RouteBadge icons within flowing text.
// Uses ImageRenderer to snapshot each badge so the result is a single
// concatenated Text view that wraps naturally.

import SwiftUI

/// A view that renders alert text with inline route-badge icons
/// wherever a bracketed route token like `[7]` or `[A]` appears.
struct AlertRichText: View {
    let text: String
    let font: Font
    let color: Color
    let alertMode: String
    var lineLimit: Int? = nil

    /// Inline badge diameter — tuned for 13-14pt body text.
    private let badgeDiameter: CGFloat = 18

    var body: some View {
        if let limit = lineLimit {
            buildSegments()
                .lineLimit(limit)
        } else {
            buildSegments()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Concatenated Text

    private func buildSegments() -> Text {
        let parts = Self.parse(text)
        var result = Text("")
        for part in parts {
            switch part {
            case .plain(let str):
                let segment = Text(str)
                    .font(font)
                    .foregroundColor(color)
                result = Text("\(result)\(segment)")
            case .route(let routeID):
                if let img = badgeImage(for: routeID) {
                    let badge = Text(Image(uiImage: img))
                        .baselineOffset(-3)
                    result = Text("\(result)\(badge)")
                } else {
                    let fallback = Text("[\(routeID)]")
                        .font(font)
                        .foregroundColor(color)
                    result = Text("\(result)\(fallback)")
                }
            }
        }
        return result
    }

    // MARK: - Badge → UIImage

    @MainActor
    private func badgeImage(for routeID: String) -> UIImage? {
        if let cached = Self.imageCache[routeID] {
            return cached
        }
        let badge = RouteBadge(
            routeID: routeID,
            size: .custom(badgeDiameter, badgeDiameter * 0.6),
            mode: resolvedMode(for: routeID)
        )
        let renderer = ImageRenderer(content: badge)
        renderer.scale = 3.0
        guard let img = renderer.uiImage else { return nil }
        Self.imageCache[routeID] = img
        return img
    }

    /// Simple cache so we don't re-render the same badge every layout pass.
    private static var imageCache: [String: UIImage] = [:]

    // MARK: - Mode Resolution

    /// Determine the badge mode for a route token extracted from text.
    /// Single letters / short numbers are subway; bus patterns get "bus".
    private func resolvedMode(for token: String) -> String {
        let upper = token.uppercased()

        // Known subway route IDs (single char or "SIR", shuttle variants).
        let subwayRoutes: Set<String> = [
            "1", "2", "3", "4", "5", "6", "6X", "7", "7X",
            "A", "B", "C", "D", "E", "F", "FX", "G",
            "J", "Z", "L", "M", "N", "Q", "R", "W",
            "S", "SF", "SR", "SIR", "T",
        ]
        if subwayRoutes.contains(upper) {
            return "subway"
        }

        // Bus pattern: starts with M, B, Bx, Q, S + digits
        let busPattern = /^(M|B|Bx|Q|S|X)\d/
        if upper.firstMatch(of: busPattern) != nil {
            return "bus"
        }

        // Fall back to the alert's own mode.
        return alertMode
    }

    // MARK: - Text Parsing

    enum Segment {
        case plain(String)
        case route(String)
    }

    /// Split text on `[X]` tokens. Only treats content inside brackets
    /// as a route reference when it looks like a valid MTA route ID.
    static func parse(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var i = text.startIndex

        while i < text.endIndex {
            if text[i] == "[" {
                // Look for closing bracket within a reasonable span.
                if let closingIdx = text[i...].firstIndex(of: "]"),
                   closingIdx > text.index(after: i) {
                    let token = String(
                        text[text.index(after: i)..<closingIdx]
                    ).trimmingCharacters(in: .whitespaces)
                    if isRouteToken(token) {
                        if !current.isEmpty {
                            segments.append(.plain(current))
                            current = ""
                        }
                        segments.append(.route(token.uppercased()))
                        i = text.index(after: closingIdx)
                        continue
                    }
                }
            }
            current.append(text[i])
            i = text.index(after: i)
        }

        if !current.isEmpty {
            segments.append(.plain(current))
        }
        return segments
    }

    /// Check whether a bracket-enclosed token looks like a transit route.
    private static func isRouteToken(_ token: String) -> Bool {
        let upper = token.uppercased()
            .trimmingCharacters(in: .whitespaces)

        // Subway: single letter, single/double digit, SIR, shuttle variants
        let subwayRoutes: Set<String> = [
            "1", "2", "3", "4", "5", "6", "6X", "7", "7X",
            "A", "B", "C", "D", "E", "F", "FX", "G",
            "J", "Z", "L", "M", "N", "Q", "R", "W",
            "S", "SF", "SR", "SIR", "T",
        ]
        if subwayRoutes.contains(upper) { return true }

        // Bus: M11, B46, Bx12, Q10, M34-SBS, M34A-SBS, etc.
        let busPattern = /^(M|B|Bx|Q|S|X)\d+[A-Z]?(-SBS)?$/
        if upper.firstMatch(of: busPattern) != nil { return true }

        return false
    }

    // MARK: - Plain Text

    /// Returns alert text with bracket tokens replaced by plain route IDs.
    /// Useful for contexts that don't support rich text (e.g., notifications).
    static func plainText(_ text: String) -> String {
        parse(text).map { segment in
            switch segment {
            case .plain(let str): return str
            case .route(let id): return id
            }
        }.joined()
    }
}
