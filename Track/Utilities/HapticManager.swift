//
//  HapticManager.swift
//  Track
//
//  Provides tactile feedback for key interactions.
//  Makes the app feel mechanical and responsive, like a turnstile.
//

import UIKit

enum HapticManager {

    // MARK: - Prepared Generators (reused to reduce latency)

    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyImpactGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    /// Light tap for tab switching and list scrolling.
    static func selection() {
        selectionGenerator.selectionChanged()
    }

    /// Solid thud for significant actions like "Start Tracking."
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        switch style {
        case .light:
            lightImpactGenerator.impactOccurred()
        case .heavy:
            heavyImpactGenerator.impactOccurred()
        default:
            mediumImpactGenerator.impactOccurred()
        }
    }

    /// Distinct buzz for completion events like "Trip Completed" or "Settings Saved."
    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notificationGenerator.notificationOccurred(type)
    }
}
