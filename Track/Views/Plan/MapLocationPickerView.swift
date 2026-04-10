// Full-screen map picker — drag the map to select a location.
// Premium crosshair pin with layered glow, bounce on drag,
// glassmorphic bottom sheet with confirmed address, and
// gradient confirm button.

import MapKit
import SwiftUI

struct MapLocationPickerView: View {
    @Bindable var viewModel: PlanViewModel
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
    )
    @State private var resolvedName = ""
    @State private var resolvedAddress = ""
    @State private var centerCoordinate = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
    @State private var isGeocodingCenter = false
    @State private var isDragging = false
    @State private var pinBounce = false
    @State private var glowPulse = false
    @State private var appeared = false
    @State private var geocodeTask: Task<Void, Never>?

    // MARK: - Body

    var body: some View {
        ZStack {
            // Map
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {}
                .mapStyle(.standard(pointsOfInterest: .including([.publicTransport])))
                .ignoresSafeArea()
                .onMapCameraChange(frequency: .continuous) { context in
                    centerCoordinate = context.camera.centerCoordinate
                    if !isDragging {
                        isDragging = true
                        pinBounce = true
                    }
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    centerCoordinate = context.camera.centerCoordinate
                    isDragging = false
                    pinBounce = false
                    reverseGeocodeCenter()
                }

            // Center pin
            centerPinView

            // Top bar
            VStack {
                topBarView
                Spacer()
            }

            // Bottom card
            VStack {
                Spacer()
                bottomCardView
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 40)
            }
        }
        .onAppear {
            reverseGeocodeCenter()
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15)) {
                appeared = true
            }
        }
    }

    // MARK: - Center Pin

    private var centerPinView: some View {
        VStack(spacing: 0) {
            ZStack {
                // Outermost breathing glow
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.08))
                    .frame(width: 68, height: 68)
                    .scaleEffect(glowPulse ? 1.3 : 1.0)
                    .opacity(glowPulse ? 0.15 : 0.4)

                // Mid glow ring
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.12))
                    .frame(width: 44, height: 44)
                    .scaleEffect(glowPulse ? 1.15 : 1.0)

                // Outer ring
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 2.5
                    )
                    .frame(width: 28, height: 28)

                // Inner dot
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                            center: .center,
                            startRadius: 0,
                            endRadius: 8
                        )
                    )
                    .frame(width: 12, height: 12)
                    .shadow(color: AppTheme.Colors.accent.opacity(0.6), radius: 8)
            }
            .offset(y: pinBounce ? -12 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: pinBounce)

            // Ground shadow
            Ellipse()
                .fill(.black.opacity(isDragging ? 0.08 : 0.18))
                .frame(width: isDragging ? 6 : 14, height: isDragging ? 3 : 7)
                .blur(radius: isDragging ? 1 : 2)
                .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isDragging)
        }
    }

    // MARK: - Top Bar

    private var topBarView: some View {
        HStack {
            // Close
            Button { dismiss() } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                        }
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                }
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(MapPickerPressStyle())

            Spacer()

            // Title pill
            HStack(spacing: 6) {
                Image(systemName: viewModel.isOriginForMapPicker ? "location.fill" : "mappin")
                    .font(.system(size: 11, weight: .bold))
                Text(viewModel.isOriginForMapPicker ? "Choose Origin" : "Choose Destination")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundColor(AppTheme.Colors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
            )
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)

            Spacer()

            // Invisible balance
            Circle().fill(.clear).frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Bottom Card

    private var bottomCardView: some View {
        VStack(spacing: 16) {
            // Handle
            Capsule()
                .fill(.white.opacity(0.15))
                .frame(width: 36, height: 4)

            // Location info row
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppTheme.Colors.accent.opacity(0.15),
                                    AppTheme.Colors.accentDeep.opacity(0.08),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(AppTheme.Colors.accent.opacity(0.12), lineWidth: 0.5)
                        )
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if isGeocodingCenter {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(AppTheme.Colors.accent)
                            Text("Finding address...")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(AppTheme.Colors.textTertiary)
                        }
                    } else if resolvedName.isEmpty {
                        Text("Drag map to select location")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    } else {
                        Text(resolvedName)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .lineLimit(1)

                        if !resolvedAddress.isEmpty {
                            Text(resolvedAddress)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            // Confirm button
            Button {
                viewModel.selectMapCoordinate(centerCoordinate)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Confirm Location")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                        // Glass top-edge highlight
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.18), location: 0),
                                        .init(color: .clear, location: 0.5),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                )
                .shadow(color: AppTheme.Colors.accent.opacity(0.35), radius: 16, x: 0, y: 6)
            }
            .buttonStyle(MapPickerPressStyle())
            .disabled(isGeocodingCenter || isDragging)
            .opacity((isGeocodingCenter || isDragging) ? 0.45 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isGeocodingCenter || isDragging)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground.opacity(0.55))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 30, x: 0, y: -6)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Reverse Geocode

    private func reverseGeocodeCenter() {
        geocodeTask?.cancel()
        isGeocodingCenter = true

        geocodeTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            do {
                let mapItem = try await viewModel.locationSearchService.reverseGeocode(centerCoordinate)
                guard !Task.isCancelled else { return }
                resolvedName = mapItem.name ?? "Unknown location"
                resolvedAddress = mapItem.formattedAddress
            } catch {
                guard !Task.isCancelled else { return }
                resolvedName = String(format: "%.4f, %.4f", centerCoordinate.latitude, centerCoordinate.longitude)
                resolvedAddress = ""
            }
            isGeocodingCenter = false
        }
    }
}

// MARK: - Button Style

private struct MapPickerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

#Preview {
    MapLocationPickerView(viewModel: PlanViewModel())
        .preferredColorScheme(.dark)
}
