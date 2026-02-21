//
//  WidgetURLHelper.swift
//  Track
//
//  Shared URL construction for widget timeline providers.
//  Centralizes the localhost / custom-IP logic
//  so TrackWidget, SingleRouteWidget, and LiveNearMeWidget
//  don't duplicate the same block.
//

import Foundation

enum WidgetURLHelper {
    /// Resolves the backend base URL using the same developer-settings
    /// logic that was previously inlined in each widget provider.
    /// Reads from the App Group defaults so it works inside a widget extension.
    static func resolvedBaseURL() -> String {
        let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? .standard
        let useLocalhost = defaults.bool(forKey: "dev_use_localhost")
        let storedIP = defaults.string(forKey: "dev_custom_ip") ?? "192.168.12.101"

        #if targetEnvironment(simulator)
        if useLocalhost {
            return "http://127.0.0.1:8000"
        } else {
            return "http://\(storedIP):8000"
        }
        #else
        // Physical device — localhost would point to the phone itself,
        // so always use the stored IP regardless of the toggle.
        return "http://\(storedIP):8000"
        #endif
    }
}
