// Per-user onboarding completion flag.
//
// The legacy `@AppStorage("hasCompletedOnboarding")` lived in
// UserDefaults under a single device-wide key, which meant a stale
// `true` from one account would skip onboarding for every account
// signed in on the device after it. This observable wraps the
// flag with a key derived from the currently-authenticated
// Supabase user ID, so each account independently completes (or
// re-completes) onboarding exactly once.

import Foundation
import Combine

@MainActor
final class OnboardingTracker: ObservableObject {
    static let shared = OnboardingTracker()

    /// Public state ContentView and OnboardingView observe.
    @Published private(set) var hasCompletedOnboarding: Bool = false

    /// Legacy device-wide key, retained for one-time migration.
    private let legacyKey = "hasCompletedOnboarding"
    private let perUserKeyPrefix = "hasCompletedOnboarding."

    private var cancellable: AnyCancellable?
    private var currentUserId: String?

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    private init() {
        // Re-derive the flag whenever the signed-in user changes.
        cancellable = SupabaseManager.shared.$currentUser
            .receive(on: DispatchQueue.main)
            .sink { [weak self] user in
                self?.refresh(for: user?.id.uuidString)
            }
        // Initial read covers the cold-start case before Combine fires.
        refresh(for: SupabaseManager.shared.currentUser?.id.uuidString)
    }

    /// Mark onboarding complete for the current user.
    func markComplete() {
        guard let key = currentKey() else {
            // No user yet — fall back to the legacy device-wide key
            // so we never silently lose a completion.
            defaults.set(true, forKey: legacyKey)
            hasCompletedOnboarding = true
            return
        }
        defaults.set(true, forKey: key)
        hasCompletedOnboarding = true
    }

    /// Force-reset the flag for the current user. Used by
    /// "Restart onboarding" debug affordances if we add one.
    func reset() {
        if let key = currentKey() { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: legacyKey)
        hasCompletedOnboarding = false
    }

    // MARK: - Private

    private func currentKey() -> String? {
        guard let id = currentUserId, !id.isEmpty else { return nil }
        return perUserKeyPrefix + id
    }

    private func refresh(for userId: String?) {
        currentUserId = userId

        // Signed out — surface false so ContentView routes to LoginView.
        guard let userId, !userId.isEmpty else {
            hasCompletedOnboarding = false
            return
        }

        let perUserKey = perUserKeyPrefix + userId

        // One-time migration: if the legacy device-wide flag was set
        // AND the per-user flag has never been written for *this* user,
        // copy the legacy value forward so the original account that
        // completed onboarding doesn't get re-prompted.
        if defaults.object(forKey: perUserKey) == nil,
           defaults.bool(forKey: legacyKey) == true,
           isLegacyOwner(userId: userId) {
            defaults.set(true, forKey: perUserKey)
        }

        hasCompletedOnboarding = defaults.bool(forKey: perUserKey)
    }

    /// Heuristic for the migration above: we only forward the legacy
    /// flag to the *first* user we ever see post-migration. The id of
    /// that user is stamped into UserDefaults so subsequent accounts
    /// (including freshly-created ones) start fresh.
    private func isLegacyOwner(userId: String) -> Bool {
        let stampKey = "hasCompletedOnboarding.legacyOwner"
        if let stamped = defaults.string(forKey: stampKey) {
            return stamped == userId
        }
        defaults.set(userId, forKey: stampKey)
        return true
    }
}
