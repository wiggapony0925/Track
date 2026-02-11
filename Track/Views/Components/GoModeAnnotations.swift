//
//  GoModeAnnotations.swift
//  Track
//
//  Map annotations used during "GO" mode live tracking.
//
//  - ``GoModeUserAnnotation``: Replaces the standard blue dot with a
//    pulsing vehicle icon that visually "snaps" to the route line.
//    Emits an expanding radar-like pulse to indicate the user is
//    broadcasting live position data (crowdsourcing visual).
//
//  - ``GoModeStopAnnotation``: A stop dot that dims when the user
//    passes it, creating a live checklist effect on the map.
//
//  Inspired by Transit app's "GO" mode cockpit animations.
//

import SwiftUI

// MARK: - Pulsing User Annotation (GO Mode)

/// Replaces the standard ``UserAnnotation`` during GO mode.
///
/// The icon pulses rhythmically (like a radar ping) to confirm
/// that the app is actively tracking. The outer ring expands and
/// fades — the signature "broadcasting" animation.
struct GoModeUserAnnotation: View {
    let routeColor: Color

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    var body: some View {
        ZStack {
            // Outer radar pulse (expanding ring)
            Circle()
                .stroke(routeColor, lineWidth: 2)
                .frame(width: 50, height: 50)
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)

            // Inner glow
            Circle()
                .fill(routeColor.opacity(0.25))
                .frame(width: 36, height: 36)

            // Solid vehicle icon
            Circle()
                .fill(routeColor)
                .frame(width: 24, height: 24)
                .shadow(color: routeColor.opacity(0.6), radius: 6)

            Image(systemName: "location.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
        .onAppear {
            // Continuous expanding pulse — the "broadcasting" radar effect
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                pulseScale = 2.0
                pulseOpacity = 0.0
            }
        }
        .accessibilityLabel("Your position — tracking active")
    }
}

// MARK: - Stop Annotation (GO Mode)

/// A map stop dot that dims when the user passes it during GO mode.
/// Creates the live "checklist" effect on the map — passed stops
/// fade to gray while upcoming stops remain bright.
struct GoModeStopAnnotation: View {
    let stopName: String
    let isPassed: Bool
    let routeColor: Color

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(isPassed ? Color.gray.opacity(0.3) : .white)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(isPassed ? Color.gray.opacity(0.4) : routeColor, lineWidth: 2)
                    )
            }
            .shadow(color: isPassed ? .clear : routeColor.opacity(0.3), radius: 3)

            Text(stopName)
                .font(.system(size: 9, weight: isPassed ? .regular : .semibold))
                .foregroundColor(isPassed ? AppTheme.Colors.textSecondary.opacity(0.4) : AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: 60)
        }
        .opacity(isPassed ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.4), value: isPassed)
        .accessibilityLabel("\(stopName) — \(isPassed ? "passed" : "upcoming")")
    }
}

#Preview {
    VStack(spacing: 40) {
        GoModeUserAnnotation(routeColor: AppTheme.Colors.mtaBlue)

        HStack(spacing: 20) {
            GoModeStopAnnotation(
                stopName: "5 Av",
                isPassed: true,
                routeColor: AppTheme.Colors.mtaBlue
            )
            GoModeStopAnnotation(
                stopName: "Union St",
                isPassed: false,
                routeColor: AppTheme.Colors.mtaBlue
            )
        }
    }
    .padding()
}
