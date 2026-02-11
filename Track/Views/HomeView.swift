//
//  HomeView.swift
//  Track
//
//  Main dashboard view showing nearby transit arrivals.
//  Displays real-time subway and bus data based on the user's
//  current location. Presented as a map with a sliding bottom sheet.
//

import SwiftUI
import MapKit

struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @State private var locationManager = LocationManager()
    @State private var sheetDetent: PresentationDetent = .fraction(0.4)
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showSettings = false

    var body: some View {
        ZStack {
            // Map background centered on user location
            Map(position: $cameraPosition) {
                UserAnnotation()

                // Bus stop annotations when in bus mode
                if viewModel.selectedMode == .bus {
                    ForEach(viewModel.nearbyBusStops) { stop in
                        Annotation(stop.name, coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)) {
                            BusStopAnnotation(stopName: stop.name)
                                .onTapGesture {
                                    Task {
                                        await viewModel.fetchBusArrivals(for: stop)
                                    }
                                }
                        }
                    }
                }
            }
            .ignoresSafeArea()

            // Transport mode toggle floating at the bottom
            VStack {
                Spacer()
                TransportModeToggle(selectedMode: $viewModel.selectedMode)
                    .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: .constant(true)) {
            dashboardContent
                .presentationDetents([.fraction(0.4), .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
                .interactiveDismissDisabled()
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
        }
        .onAppear {
            locationManager.requestPermission()
            locationManager.startUpdating()
            Task {
                await viewModel.refresh(location: locationManager.currentLocation)
            }
        }
        .onChange(of: viewModel.selectedMode) {
            Task {
                await viewModel.refresh(location: locationManager.currentLocation)
            }
        }
    }

    // MARK: - Dashboard Content

    private var dashboardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header with settings gear
                HStack {
                    AppTheme.Typography.headerLarge("Track")
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer()

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .accessibilityLabel("Settings")
                }
                .padding(.horizontal, AppTheme.Layout.margin)

                // Mode-specific content
                Group {
                    switch viewModel.selectedMode {
                    case .nearby:
                        nearbyDashboard
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    case .subway:
                        subwayDashboard
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    case .bus:
                        busDashboard
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.selectedMode)

                // Network error banner
                if let error = viewModel.errorMessage {
                    NetworkErrorBanner(
                        message: error,
                        onDismiss: {
                            viewModel.errorMessage = nil
                        }
                    )
                }

                // Loading indicator
                if viewModel.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(AppTheme.Colors.mtaBlue)
                        Spacer()
                    }
                    .padding()
                }

                Spacer()
                    .frame(height: 20)
            }
            .padding(.top, AppTheme.Layout.margin)
        }
        .background(AppTheme.Colors.background)
        .refreshable {
            await viewModel.refresh(location: locationManager.currentLocation)
        }
    }

    // MARK: - Nearby Transit Dashboard (Unified)

    private var nearbyDashboard: some View {
        Group {
            if !viewModel.nearbyTransit.isEmpty {
                sectionHeader("Live Arrivals")

                ForEach(viewModel.nearbyTransit) { arrival in
                    NearbyTransitRow(
                        arrival: arrival,
                        isTracking: viewModel.trackingArrivalId == arrival.id,
                        onTrack: {
                            viewModel.trackNearbyArrival(arrival, location: locationManager.currentLocation)
                        }
                    )
                }
            } else if !viewModel.isLoading {
                emptyStateView(
                    icon: "location.fill",
                    message: "No transit nearby"
                )
            }
        }
    }

    // MARK: - Subway Dashboard

    private var subwayDashboard: some View {
        Group {
            // Upcoming Arrivals
            if !viewModel.upcomingArrivals.isEmpty {
                sectionHeader("Nearby Arrivals")

                ForEach(viewModel.upcomingArrivals) { arrival in
                    ArrivalRow(
                        arrival: arrival,
                        prediction: nil,
                        isTracking: viewModel.trackingArrivalId == arrival.id.uuidString,
                        reliabilityWarning: nil,
                        onTrack: {
                            viewModel.trackSubwayArrival(arrival, location: locationManager.currentLocation)
                        }
                    )
                }
            } else if !viewModel.isLoading {
                emptyStateView(
                    icon: "tram.fill",
                    message: "No subway arrivals nearby"
                )
            }

            // Nearby Stations
            if !viewModel.nearbyStations.isEmpty {
                sectionHeader("Nearby Stations")

                ForEach(viewModel.nearbyStations, id: \.stationID) { station in
                    NearbyStationRow(
                        name: station.name,
                        distance: station.distance,
                        routeIDs: station.routeIDs
                    )
                }
            }
        }
    }

    // MARK: - Bus Dashboard

    private var busDashboard: some View {
        Group {
            // Selected stop header
            if let stop = viewModel.selectedBusStop {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stop.name)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Live Bus Arrivals")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }

            // Bus arrivals
            if !viewModel.busArrivals.isEmpty {
                sectionHeader("Arriving")

                ForEach(viewModel.busArrivals) { arrival in
                    BusArrivalRow(
                        arrival: arrival,
                        isTracking: viewModel.trackingArrivalId == arrival.id,
                        reliabilityWarning: nil,
                        onTrack: {
                            viewModel.trackBusArrival(arrival, location: locationManager.currentLocation)
                        }
                    )
                }
            }

            // Nearby bus stops
            if !viewModel.nearbyBusStops.isEmpty {
                sectionHeader("Nearby Bus Stops")

                ForEach(viewModel.nearbyBusStops) { stop in
                    Button {
                        Task {
                            await viewModel.fetchBusArrivals(for: stop)
                        }
                    } label: {
                        NearbyBusStopRow(stop: stop)
                    }
                    .buttonStyle(.plain)
                }
            } else if !viewModel.isLoading {
                emptyStateView(
                    icon: "bus.fill",
                    message: "No bus stops nearby"
                )
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(AppTheme.Colors.textSecondary)
            .textCase(.uppercase)
            .lineLimit(1)
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 8)
    }

    private func emptyStateView(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text(message)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - Nearby Transit Row

/// Displays a single nearby transit arrival (bus or train) in the unified list.
private struct NearbyTransitRow: View {
    let arrival: NearbyTransitResponse
    var isTracking: Bool = false
    var onTrack: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Mode badge
            ZStack {
                Circle()
                    .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.Colors.subwayBlack)
                    .frame(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                if arrival.isBus {
                    Image(systemName: "bus.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textOnColor)
                } else {
                    Text(arrival.displayName)
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        .foregroundColor(AppTheme.Colors.textOnColor)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
            .accessibilityHidden(true)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(arrival.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if isTracking {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(AppTheme.Colors.textOnColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(AppTheme.Colors.alertRed)
                            .clipShape(Capsule())
                    }
                }
                Text(arrival.stopName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Countdown
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(arrival.minutesAway)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(countdownColor(arrival.minutesAway))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, AppTheme.Layout.margin)
        .contentShape(Rectangle())
        .onTapGesture {
            onTrack?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(arrival.isBus ? "Bus" : "Train") \(arrival.displayName), \(arrival.stopName), \(arrival.minutesAway) minutes away")
        .accessibilityHint(isTracking ? "Currently tracking" : "Tap to track this arrival")
    }

    private func countdownColor(_ minutes: Int) -> Color {
        if minutes <= 2 {
            return AppTheme.Colors.alertRed
        } else if minutes <= 5 {
            return AppTheme.Colors.successGreen
        }
        return AppTheme.Colors.textPrimary
    }
}

// MARK: - Nearby Bus Stop Row

/// Displays a nearby bus stop in the list. Tapping selects it.
private struct NearbyBusStopRow: View {
    let stop: BusStop

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.mtaBlue)
                    .frame(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                Image(systemName: "bus.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
            }
            .accessibilityHidden(true)

            Text(stop.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if let direction = stop.direction {
                Text(direction == "0" ? "→" : "←")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bus stop: \(stop.name)")
    }
}

#Preview {
    HomeView()
}
