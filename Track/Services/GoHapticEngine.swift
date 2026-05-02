// Core Haptic Engine for "GO" mode navigation.
// Provides tactile feedback for stop-passing events and destination warnings.
// Designed to be "Better than Transit" by using specific haptic patterns
// that help users navigate eyes-free.

import UIKit

/// Tactical feedback engine for transit navigation.
final class GoHapticEngine {
    
    static let shared = GoHapticEngine()
    
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()
    
    private init() {
        // Pre-warm the generators to minimize latency during tracking.
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        notification.prepare()
    }
    
    /// Triggered when the user is within proximity of a stop.
    /// A subtle "click" that confirms tracking progress.
    func stopPassed() {
        impactLight.impactOccurred()
        // Re-prepare for next stop
        impactLight.prepare()
    }
    
    /// Triggered when the user is approaching their alight stop (400m).
    /// A distinct "thump" that alerts the user to check their surroundings.
    func approachingDestination() {
        impactMedium.impactOccurred()
        
        // Double-tap pattern for better detection in pockets
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.impactMedium.impactOccurred()
            self.impactMedium.prepare()
        }
    }
    
    /// Triggered when the user has arrived at their destination (150m).
    /// A heavy notification pattern to ensure they get off.
    func arrived() {
        notification.notificationOccurred(.success)
        
        // Persistent vibration for "Arrive Now"
        impactHeavy.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.impactHeavy.impactOccurred()
            self.impactHeavy.prepare()
        }
    }
    
    /// Triggered when GO mode is first activated.
    func goActivated() {
        notification.notificationOccurred(.success)
    }
}
