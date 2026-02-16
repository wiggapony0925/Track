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
    
    /// Whether the drag-to-search is actively loading new results.
    var isDragSearching: Bool = false
    
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
                selectedMode: Binding(
                    get: { viewModel.selectedMode },
                    set: { viewModel.selectedMode = $0 }
                ),
                lastUpdated: lastUpdated
            )
            
            // MARK: - Drag-Search Loading Banner
            Group {
                if isDragSearching {
                    DragSearchLoadingBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDragSearching)
            
            // MARK: - Scrollable Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Favorites section (shows only when user has favorites)
                    FavoritesSection(
                        groupedTransit: viewModel.groupedTransit,
                        onSelect: { group, directionIndex in
                            viewModel.selectedDirectionIndex = directionIndex
                            Task {
                                await viewModel.selectGroupedRoute(group, userLocation: locationManager.currentLocation)
                            }
                            sheetNavigator.navigate(to: .routeDetail(group: group, directionIndex: directionIndex))
                        }
                    )
                    
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
                                sheetNavigator: sheetNavigator,
                                lastUpdated: lastUpdated
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .bus:
                            BusDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                sheetNavigator: sheetNavigator,
                                lastUpdated: lastUpdated
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .lirr:
                            LIRRDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                sheetNavigator: sheetNavigator,
                                lastUpdated: lastUpdated
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .mnr:
                            MNRDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                sheetNavigator: sheetNavigator,
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
            // Use effectiveLocation so pull-to-refresh during drag-to-search
            // fetches from the explored area, not the user's GPS.
            let loc = viewModel.effectiveLocation(userLocation: locationManager.currentLocation)
            await viewModel.refresh(location: loc)
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
