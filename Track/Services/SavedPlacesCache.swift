// Lightweight singleton that caches the user's saved Home and Work
// places so any view in the app can read them without hitting the
// backend.  PlanViewModel populates this after each planner-data
// refresh; HomeView reads it to drive the FloatingSearchBar shortcut.
//
// Usage:
//   PlanViewModel  → SavedPlacesCache.shared.update(all: savedLocations)
//   FloatingSearchBar ← HomeView reads .homePlace / .workPlace

import Foundation
import Observation

@Observable
final class SavedPlacesCache {

    static let shared = SavedPlacesCache()
    private init() {}

    /// The user's saved Home location (nil if not set).
    private(set) var homePlace: SavedLocation? = nil
    /// The user's saved Work location (nil if not set).
    private(set) var workPlace: SavedLocation? = nil

    // MARK: - Update

    /// Called by PlanViewModel after it loads the user's saved places
    /// from the backend.  Thread-safe — must be called on the Main actor.
    @MainActor
    func update(all locations: [SavedLocation]) {
        homePlace = locations.first { $0.resolvedCategory == .home }
        workPlace = locations.first { $0.resolvedCategory == .work }
    }
}
