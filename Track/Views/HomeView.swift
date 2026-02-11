//
//  HomeView.swift
//  Track
//
//  Main dashboard view with the "Magic Card" smart suggestion,
//  upcoming arrivals, and nearby stations. Presented as a map-based
//  view with a sliding bottom sheet. Supports Subway and Bus modes.
//

import SwiftUI
import SwiftData
import MapKit

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = HomeViewModel()
    @State private var locationManager = LocationManager()
    @State private var sheetDetent: PresentationDetent = .fraction(0.4)
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)

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

            // Transport mode toggle floating at the bottom of the map
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
        }
        .onAppear {
            locationManager.requestPermission()
            locationManager.startUpdating()
            Task {
                await viewModel.refresh(
                    context: modelContext,
                    location: locationManager.currentLocation
                )
            }
        }
        .onChange(of: viewModel.selectedMode) {
            Task {
                await viewModel.refresh(
                    context: modelContext,
                    location: locationManager.currentLocation
                )
            }
        }
    }

    // MARK: - Dashboard Content

    private var dashboardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                AppTheme.Typography.headerLarge("Track")
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, AppTheme.Layout.margin)

                // Mode-specific content
                switch viewModel.selectedMode {
                case .subway:
                    subwayDashboard
                case .bus:
                    busDashboard
                }

                // Error message
                if let error = viewModel.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 14))
                        Text(error)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(AppTheme.Colors.alertRed)
                    .padding(.horizontal, AppTheme.Layout.margin)
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

                // Bottom padding
                Spacer()
                    .frame(height: 20)
            }
            .padding(.top, AppTheme.Layout.margin)
        }
        .background(AppTheme.Colors.background)
    }

    // MARK: - Subway Dashboard

    private var subwayDashboard: some View {
        Group {
            // Smart Suggestion Card
            SmartSuggestionCard(
                suggestion: viewModel.suggestion,
                minutesAway: viewModel.upcomingArrivals.first?.minutesAway ?? 0,
                onStartTrip: {
                    // Trip start action placeholder
                }
            )
            .padding(.horizontal, AppTheme.Layout.margin)

            // Upcoming Arrivals
            if !viewModel.upcomingArrivals.isEmpty {
                sectionHeader("Upcoming Arrivals")

                ForEach(viewModel.upcomingArrivals) { arrival in
                    ArrivalRow(arrival: arrival, prediction: nil)
                }
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
                    BusArrivalRow(arrival: arrival)
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
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(AppTheme.Colors.textSecondary)
            .textCase(.uppercase)
            .lineLimit(1)
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 8)
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
                    .foregroundColor(.white)
            }
            .accessibilityHidden(true)

            Text(stop.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if let direction = stop.direction {
                // OBA direction: "0" = first direction of travel, "1" = reverse
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
        .modelContainer(for: [
            Station.self,
            Route.self,
            TripLog.self,
            CommutePattern.self,
        ], inMemory: true)
}
