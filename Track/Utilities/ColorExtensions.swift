//
//  ColorExtensions.swift
//  Track
//
//  Color extensions used across the app. Extracted from RouteDetailSheet
//  so the hex initializer is available to any component that needs it.
//

import SwiftUI

extension Color {
    /// Creates a Color from a CSS hex string like ``"#FF6319"`` or ``"FF6319"``.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: Double
        switch cleaned.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b)
    }
}
