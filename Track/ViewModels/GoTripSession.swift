// Global "Go" session — when set to a non-nil trip, the entire app
// pivots into navigation mode and presents the immersive GoTripView
// full-screen cover.  The user cannot switch tabs while a trip is
// active; they must explicitly exit via the close button.

import Foundation
import SwiftUI

@Observable
@MainActor
final class GoTripSession {
    /// The trip currently being navigated.  `nil` when not in Go mode.
    var activeTrip: TripPlan?

    /// Index of the leg the user is currently on (0 = first leg).
    /// Bumped manually for now; future work can advance based on GPS.
    var currentLegIndex: Int = 0

    var isActive: Bool { activeTrip != nil }

    func start(_ trip: TripPlan) {
        currentLegIndex = 0
        activeTrip = trip
    }

    func stop() {
        activeTrip = nil
        currentLegIndex = 0
    }
}
