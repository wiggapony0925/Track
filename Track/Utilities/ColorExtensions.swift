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
        let cleaned: String = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let a: Double
        let r: Double
        let g: Double
        let b: Double
        let count: Int = cleaned.count
        switch count {
        case 3: // RGB (12-bit)
            let ri: UInt64 = (int >> 8) * 17
            let gi: UInt64 = (int >> 4 & 0xF) * 17
            let bi: UInt64 = (int & 0xF) * 17
            r = Double(ri) / 255.0
            g = Double(gi) / 255.0
            b = Double(bi) / 255.0
            a = 1.0
        case 6: // RGB (24-bit)
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
            a = 1.0
        case 8: // ARGB (32-bit)
            a = Double((int >> 24) & 0xFF) / 255.0
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 0.0
            g = 0.0
            b = 0.0
            a = 1.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
