//
//  LiveTrackingOverlay.swift
//  Track
//
//  The "GO" mode overlay that appears when a user is actively tracking
//  a transit vehicle. Inspired by the Transit app's hands-free cockpit view.
//
//  Features:
//  - Pulsing countdown with the largest text element
//  - Auto-scrolling stop checklist that dims passed stops
//  - "Get Off" button to end tracking instantly
//  - Progressive disclosure: shows relevant info per tracking phase
//
//  References:
//  - MKMapItem: https://developer.apple.com/documentation/mapkit/mkmapitem/init(placemark:)
//  - MKDirections: https://developer.apple.com/documentation/mapkit/mkdirections
//

import SwiftUI
import MapKit

/// The live tracking overlay shown during GO mode.
/// Floats above the map as a compact bottom card that progressively
/// discloses more information as the user moves along the route.
struct LiveTrackingOverlay: View {
    let routeName: String
    let routeColor: Color
    let etaMinutes: Int?
    let stops: [BusStop]
    let passedStopIds: Set<String>
    var onGetOff: (() -> Void)?

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            // Route header
            HStack(spacing: 12) {
                // Pulsing route badge
                ZStack {
                    Circle()
                        .fill(routeColor.opacity(0.3))
                        .frame(width: 48, height: 48)
                        .scaleEffect(pulseScale)
                    Circle()
                        .fill(routeColor)
                        .frame(width: AppTheme.Layout.badgeSizeLarge,
                               height: AppTheme.Layout.badgeSizeLarge)
                    Text(routeName)
                        .font(.system(size: AppTheme.Layout.badgeFontLarge,
                                      weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("In Transit")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .textCase(.uppercase)

                    // Large countdown — pulses when GPS updates arrive
                    if let eta = etaMinutes {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(eta)")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundColor(AppTheme.Colors.countdown(eta))
                                .scaleEffect(pulseScale)
                            Text("min remaining")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                    } else {
                        Text("Tracking…")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                    }
                }

                Spacer()

                // Live indicator pulse
                Circle()
                    .fill(AppTheme.Colors.goGreen)
                    .frame(width: 10, height: 10)
                    .scaleEffect(pulseScale)
                    .shadow(color: AppTheme.Colors.goGreen.opacity(0.6), radius: 4)
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 12)

            // Stop checklist (auto-scrolls with progressive dimming)
            if !stops.isEmpty {
                Divider()
                    .padding(.top, 10)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(stops) { stop in
                                StopChecklistItem(
                                    stopName: stop.name,
                                    isPassed: passedStopIds.contains(stop.id),
                                    routeColor: routeColor
                                )
                                .id(stop.id)
                            }
                        }
                        .padding(.horizontal, AppTheme.Layout.margin)
                    }
                    .frame(height: 60)
                    .onChange(of: passedStopIds) {
                        // Auto-scroll to next unpassed stop
                        if let nextStop = stops.first(where: { !passedStopIds.contains($0.id) }) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(nextStop.id, anchor: .leading)
                            }
                        }
                    }
                }
            }

            // "Get Off" button — always visible at bottom
            Button {
                onGetOff?()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text("Get Off")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.Colors.alertRed)
                .cornerRadius(AppTheme.Layout.cornerRadius)
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 10, y: -4)
        )
        .onAppear {
            // Continuous pulse animation for the radar ping effect
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulseScale = 1.15
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live tracking \(routeName), \(etaMinutes ?? 0) minutes remaining")
    }
}

// MARK: - Stop Checklist Item

/// A single stop in the horizontal checklist. Passed stops dim out;
/// the next stop is bright. As the user passes each stop, it fades
/// like a visual tick — no interaction needed.
private struct StopChecklistItem: View {
    let stopName: String
    let isPassed: Bool
    let routeColor: Color

    var body: some View {
        VStack(spacing: 4) {
            // Stop dot on the line
            ZStack {
                // Connecting line segment
                Rectangle()
                    .fill(isPassed ? routeColor.opacity(0.3) : routeColor)
                    .frame(width: 60, height: 3)

                Circle()
                    .fill(isPassed ? Color.gray.opacity(0.4) : .white)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(isPassed ? Color.gray.opacity(0.3) : routeColor, lineWidth: 2)
                    )
            }

            Text(stopName)
                .font(.system(size: 10, weight: isPassed ? .regular : .semibold))
                .foregroundColor(isPassed ? AppTheme.Colors.textSecondary.opacity(0.5) : AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .frame(width: 60)
        }
        .opacity(isPassed ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.3), value: isPassed)
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.2).ignoresSafeArea()

        VStack {
            Spacer()
            LiveTrackingOverlay(
                routeName: "B63",
                routeColor: AppTheme.Colors.mtaBlue,
                etaMinutes: 7,
                stops: [
                    BusStop(id: "1", name: "5 Av", lat: 40.67, lon: -73.99, direction: nil),
                    BusStop(id: "2", name: "Union St", lat: 40.68, lon: -73.98, direction: nil),
                    BusStop(id: "3", name: "Carroll St", lat: 40.68, lon: -73.97, direction: nil),
                    BusStop(id: "4", name: "9 St", lat: 40.67, lon: -73.97, direction: nil),
                ],
                passedStopIds: ["1", "2"],
                onGetOff: {}
            )
        }
    }
}
