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
        let a, r, g, b: Double
        switch cleaned.count {
        case 3: // RGB (12-bit)
            r = Double((int >> 8) * 17) / 255
            g = Double((int >> 4 & 0xF) * 17) / 255
            b = Double((int & 0xF) * 17) / 255
            a = 1.0
        case 6: // RGB (24-bit)
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
            a = 1.0
        case 8: // ARGB (32-bit)
            a = Double((int >> 24) & 0xFF) / 255
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            (r, g, b, a) = (0, 0, 0, 1)
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
