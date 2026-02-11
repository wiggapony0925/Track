//
//  ContentView.swift
//  Track
//
//  Created by Jeffrey Fernandez on 2/10/26.
//
//  Root view of the Track NYC Transit app.
//  Hosts onboarding, location gate, and the main dashboard.
//

import SwiftUI
import CoreLocation

struct ContentView: View {
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
            if !hasCompletedOnboarding {
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
            if hasCompletedOnboarding && locationManager.authorizationStatus == .notDetermined {
                locationManager.requestPermission()
            }
        }
    }
}

#Preview {
    ContentView()
}
