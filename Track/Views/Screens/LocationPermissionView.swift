//
//  LocationPermissionView.swift
//  Track
//
//  Premium location-permission gate. Shown when the user hasn't granted
//  location access yet. Supports both not-determined (first ask) and
//  denied (redirect to Settings) states.
//

import SwiftUI
import CoreLocation

struct LocationPermissionView: View {
    @Binding var authorizationStatus: CLAuthorizationStatus
    let onRequestPermission: () -> Void

    @State private var iconScale: CGFloat = 0.7
    @State private var contentOpacity: Double = 0
    @State private var iconPulse = false

    private var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    var body: some View {
        ZStack {
            // MARK: - Animated gradient background
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.06, blue: 0.16),
                    Color(red: 0.06, green: 0.11, blue: 0.28),
                    Color(red: 0.02, green: 0.08, blue: 0.20),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Subtle radial glow behind the icon
            RadialGradient(
                colors: [
                    AppTheme.Colors.mtaBlue.opacity(0.35),
                    Color.clear
                ],
                center: .init(x: 0.5, y: 0.32),
                startRadius: 10,
                endRadius: 280
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // MARK: - Hero icon
                ZStack {
                    // Outer glow ring (pulsing)
                    Circle()
                        .fill(AppTheme.Colors.mtaBlue.opacity(0.18))
                        .frame(width: iconPulse ? 180 : 160, height: iconPulse ? 180 : 160)
                        .animation(
                            .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                            value: iconPulse
                        )

                    // Inner circle
                    Circle()
                        .fill(AppTheme.Colors.mtaBlue.opacity(0.25))
                        .frame(width: 120, height: 120)

                    Image(systemName: isDenied ? "location.slash.fill" : "location.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: !isDenied)
                }
                .scaleEffect(iconScale)
                .padding(.bottom, 36)

                // MARK: - Headline
                Text(isDenied ? "Location Access Needed" : "Track Needs Your Location")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Text(
                    isDenied
                        ? "You've denied location access. Open Settings and enable \"While Using the App\" to see nearby transit."
                        : "To show real-time arrivals and your nearest stops, Track needs to know where you are. Your location never leaves your device."
                )
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.top, 14)
                .lineSpacing(3)

                // MARK: - Feature pills (only on first-ask)
                if !isDenied {
                    HStack(spacing: 10) {
                        featurePill(icon: "tram.fill", label: "Subway")
                        featurePill(icon: "bus.fill", label: "Bus")
                        featurePill(icon: "train.side.front.car", label: "LIRR / MNR")
                    }
                    .padding(.top, 28)
                }

                Spacer()

                // MARK: - CTA
                VStack(spacing: 12) {
                    if isDenied {
                        Button(action: openSettings) {
                            Label("Open Settings", systemImage: "gear")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(AppTheme.Colors.mtaBlue)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .shadow(color: AppTheme.Colors.mtaBlue.opacity(0.5), radius: 12, y: 6)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: onRequestPermission) {
                            Label("Share My Location", systemImage: "location.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(AppTheme.Colors.mtaBlue)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .shadow(color: AppTheme.Colors.mtaBlue.opacity(0.5), radius: 12, y: 6)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("Only used while the app is open")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 52)
            }
            .opacity(contentOpacity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.7)) {
                iconScale = 1.0
                contentOpacity = 1.0
            }
            iconPulse = true
        }
    }

    // MARK: - Helpers

    private func featurePill(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
