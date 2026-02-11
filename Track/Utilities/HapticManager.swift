//
//  HapticManager.swift
//  Track
//
//  Provides tactile feedback for key interactions.
//  Makes the app feel mechanical and responsive, like a turnstile.
//

import UIKit

enum HapticManager {

    /// Light tap for tab switching and list scrolling.
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }

    /// Solid thud for significant actions like "Start Tracking."
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }

    /// Distinct buzz for completion events like "Trip Completed" or "Settings Saved."
    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }
}
