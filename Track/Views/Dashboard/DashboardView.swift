//
//  DashboardView.swift
//  Track
//
//  Main dashboard content displayed in the bottom sheet.
//  Contains the modal navbar, transport mode-specific content,
//  service alerts, and other dashboard sections.
//

import SwiftUI
import CoreLocation
import MapKit

/// Main dashboard content showing transit arrivals based on selected mode.
struct DashboardView: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    @Binding var lastUpdated: Date?
    @Binding var cameraPosition: MapCameraPosition
    @Binding var is3DMode: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Navbar (Fixed Header)
            ModalNavbar(
                searchText: Binding(
                    get: { viewModel.searchText },
                    set: { viewModel.searchText = $0 }
                ),
                showSettings: Binding(
                    get: { false },
                    set: { _ in sheetNavigator.navigate(to: .settings) }
                ),
                lastUpdated: lastUpdated,
                onDropPin: {
                    let center = locationManager.currentLocation?.coordinate
                        ?? AppTheme.MapConfig.nycCenter
                    let offset = CLLocationCoordinate2D(
                        latitude: center.latitude + 0.002,
                        longitude: center.longitude + 0.002
                    )
                    Task {
                        await viewModel.setSearchPin(offset, userLocation: locationManager.currentLocation)
                    }
                }
            )
            
            // MARK: - Scrollable Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Mode-specific content
                    Group {
                        switch viewModel.selectedMode {
                        case .nearby:
                            NearbyDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                sheetNavigator: sheetNavigator,
                                lastUpdated: lastUpdated,
                                cameraPosition: $cameraPosition,
                                is3DMode: $is3DMode
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .subway:
                            SubwayDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                lastUpdated: lastUpdated
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .bus:
                            BusDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                lastUpdated: lastUpdated
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .lirr:
                            LIRRDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                lastUpdated: lastUpdated
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .mnr:
                            MNRDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                lastUpdated: lastUpdated
                            )
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
                    
                    // Service alerts section
                    ServiceAlertsSection(alerts: viewModel.serviceAlerts)
                    
                    // Elevator outages section
                    ElevatorOutagesSection(outages: viewModel.elevatorOutages)
                    
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
                .padding(.top, 4)
            }
        }
        .background(AppTheme.Colors.background)
        .refreshable {
            await viewModel.refresh(location: locationManager.currentLocation)
            lastUpdated = Date()
        }
    }
}

#Preview {
    @Previewable @State var lastUpdated: Date? = Date()
    @Previewable @State var cameraPosition: MapCameraPosition = .automatic
    @Previewable @State var is3DMode: Bool = false
    
    DashboardView(
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        sheetNavigator: SheetNavigator(),
        lastUpdated: $lastUpdated,
        cameraPosition: $cameraPosition,
        is3DMode: $is3DMode
    )
}
