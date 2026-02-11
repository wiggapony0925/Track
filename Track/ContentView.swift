//
//  ContentView.swift
//  Track
//
//  Root view of the Track NYC Transit app.
//  Hosts login, onboarding, location gate, and the main dashboard.
//

import SwiftUI
import CoreLocation

struct ContentView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appTheme") private var appTheme = "system"
    @State private var locationManager = LocationManager()

    /// True when the user has granted location access.
    private var locationGranted: Bool {
        locationManager.authorizationStatus == .authorizedWhenInUse ||
        locationManager.authorizationStatus == .authorizedAlways
    }

    /// Maps the appTheme string to a ColorScheme.
    private var colorScheme: ColorScheme? {
        switch appTheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var body: some View {
        Group {
            if !isLoggedIn {
                LoginView()
            } else if !hasCompletedOnboarding {
                OnboardingView()
            } else if locationGranted {
                HomeView()
            } else {
                LocationPermissionView(
                    authorizationStatus: $locationManager.authorizationStatus,
                    onRequestPermission: {
                        locationManager.requestPermission()
                    }
                )
            }
        }
        .preferredColorScheme(colorScheme)
        .onAppear {
            if isLoggedIn && hasCompletedOnboarding && locationManager.authorizationStatus == .notDetermined {
                locationManager.requestPermission()
            }
        }
    }
}

#Preview {
    ContentView()
}
