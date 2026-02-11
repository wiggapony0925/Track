//
//  HomeView.swift
//  Track
//
//  Main dashboard view with the "Magic Card" smart suggestion,
//  upcoming arrivals, and nearby stations. Presented as a map-based
//  view with a sliding bottom sheet.
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
            }
            .ignoresSafeArea()

            // Bottom sheet overlay
            VStack {
                Spacer()
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

                // Smart Suggestion Card
                SmartSuggestionCard(
                    suggestion: viewModel.suggestion,
                    minutesAway: viewModel.upcomingArrivals.first?.minutesAway ?? 0,
                    onStartTrip: {
                        // Trip start action placeholder
                    }
                )
                .padding(.horizontal, AppTheme.Layout.margin)

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

                // Bottom padding so content is not hidden behind home indicator
                Spacer()
                    .frame(height: 20)
            }
            .padding(.top, AppTheme.Layout.margin)
        }
        .background(AppTheme.Colors.background)
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

#Preview {
    HomeView()
        .modelContainer(for: [
            Station.self,
            Route.self,
            TripLog.self,
            CommutePattern.self,
        ], inMemory: true)
}
