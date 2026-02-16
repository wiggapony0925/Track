//
//  LIRRDashboard.swift
//  Track
//
//  Dashboard content for the "LIRR" transport mode.
//  Shows Long Island Rail Road departures grouped by timing.
//

import SwiftUI
import CoreLocation

/// LIRR-specific dashboard showing rail departures.
struct LIRRDashboard: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    let lastUpdated: Date?
    
    /// Get filtered arrivals based on search
    private var displayArrivals: [TrainArrival] {
        viewModel.filteredLIRRArrivals
    }
    
    /// Arrivals within 15 minutes (soon)
    private var soonArrivals: [TrainArrival] {
        displayArrivals.filter { $0.minutesAway <= 15 }
    }
    
    /// Arrivals more than 15 minutes away
    private var laterArrivals: [TrainArrival] {
        displayArrivals.filter { $0.minutesAway > 15 }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !displayArrivals.isEmpty {
                // MARK: - Arriving Soon Section
                if !soonArrivals.isEmpty {
                    LIRRSectionHeader(title: "Arriving Soon", iconName: "train.side.front.car", color: AppTheme.CommuterRailColors.lirrBlue, updated: lastUpdated)
                    
                    VStack(spacing: 0) {
                        ForEach(Array(soonArrivals.prefix(AppSettings.shared.maxLirrArrivals).enumerated()), id: \.element.id) { index, arrival in
                            LIRRArrivalRow(
                                arrival: arrival,
                                isTracking: viewModel.isTracking(arrival),
                                onTrack: {
                                    viewModel.trackLIRRArrival(arrival, location: locationManager.currentLocation)
                                }
                            )
                            if index < min(soonArrivals.count, AppSettings.shared.maxLirrArrivals) - 1 {
                                Divider()
                                    .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                            }
                        }
                    }
                    .background(AppTheme.Colors.cardBackground)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
                    .padding(.horizontal, AppTheme.Layout.margin)
                }
                
                // MARK: - Later Section
                if !laterArrivals.isEmpty {
                    LIRRSectionHeader(title: "Later", iconName: "clock", color: AppTheme.Colors.textSecondary, updated: soonArrivals.isEmpty ? lastUpdated : nil)
                    
                    VStack(spacing: 0) {
                        ForEach(Array(laterArrivals.prefix(AppSettings.shared.maxLirrArrivals).enumerated()), id: \.element.id) { index, arrival in
                            LIRRArrivalRow(
                                arrival: arrival,
                                isTracking: viewModel.isTracking(arrival),
                                onTrack: {
                                    viewModel.trackLIRRArrival(arrival, location: locationManager.currentLocation)
                                }
                            )
                            if index < min(laterArrivals.count, AppSettings.shared.maxLirrArrivals) - 1 {
                                Divider()
                                    .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                            }
                        }
                    }
                    .background(AppTheme.Colors.cardBackground)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
                    .padding(.horizontal, AppTheme.Layout.margin)
                }
            } else if !viewModel.isLoading {
                if !viewModel.searchText.isEmpty && !viewModel.lirrArrivals.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No LIRR results for \"\(viewModel.searchText)\""
                    )
                } else {
                    EmptyStateView(
                        icon: "train.side.front.car",
                        message: "No LIRR departures available"
                    )
                }
            }
        }
    }
}

// MARK: - LIRR Section Header

struct LIRRSectionHeader: View {
    let title: String
    let iconName: String
    let color: Color
    let updated: Date?
    
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color)
            )
            
            Spacer()
            
            if let updated = updated {
                Text(updated, style: .time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

// MARK: - LIRR Arrival Row

struct LIRRArrivalRow: View {
    let arrival: TrainArrival
    let isTracking: Bool
    let onTrack: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Route badge
            Text(arrival.routeID)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 50, height: 28)
                .background(AppTheme.CommuterRailColors.lirrBlue)
                .cornerRadius(6)
            
            // Station and destination info
            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.destination ?? arrival.direction)
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                
                Text(arrival.stationID)
                    .font(.custom("Helvetica", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Time info
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(arrival.minutesAway)")
                        .font(.custom("Helvetica-Bold", size: 24))
                        .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    Text("min")
                        .font(.custom("Helvetica-Bold", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                
                Text(arrival.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(arrival.status.lowercased().contains("on time") ? AppTheme.Colors.successGreen : AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, AppTheme.Layout.margin)
        .contentShape(Rectangle())
        .onTapGesture {
            onTrack()
        }
    }
}

#Preview {
    LIRRDashboard(
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        sheetNavigator: SheetNavigator(),
        lastUpdated: Date()
    )
}
