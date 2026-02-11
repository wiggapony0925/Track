//
//  LocationPermissionView.swift
//  Track
//
//  A blocking overlay that requires the user to share their location
//  before using the app. Displayed when location permission is not granted.
//

import SwiftUI
import CoreLocation

struct LocationPermissionView: View {
    @Binding var authorizationStatus: CLAuthorizationStatus
    let onRequestPermission: () -> Void

    var body: some View {
        ZStack {
            AppTheme.Colors.background
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "location.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                    .accessibilityHidden(true)

                Text("Track Needs Your Location")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text("To show nearby stations and real-time arrivals, Track needs access to your location. Your location data stays on your device.")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .lineLimit(4)

                if authorizationStatus == .denied || authorizationStatus == .restricted {
                    // User has explicitly denied — direct them to Settings
                    VStack(spacing: 12) {
                        Text("Location access was denied. Please enable it in Settings to use Track.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppTheme.Colors.alertRed)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .lineLimit(3)

                        Button(action: openSettings) {
                            Text("Open Settings")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(AppTheme.Colors.mtaBlue)
                                .cornerRadius(AppTheme.Layout.cornerRadius)
                        }
                        .padding(.horizontal, 40)
                        .accessibilityHint("Opens device Settings to enable location access")
                    }
                } else {
                    // First time — ask for permission
                    Button(action: onRequestPermission) {
                        Text("Share My Location")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(AppTheme.Colors.mtaBlue)
                            .cornerRadius(AppTheme.Layout.cornerRadius)
                    }
                    .padding(.horizontal, 40)
                    .accessibilityHint("Requests location permission for Track")
                }

                Spacer()
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
