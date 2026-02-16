//
//  GroupedRouteRow.swift
//  Track
//
//  A compact row for a grouped route card. Shows the route badge,
//  display name, direction count, and soonest arrival countdown.
//  Tapping opens the RouteDetailSheet.
//  Extracted from HomeView for reusability.
//

import SwiftUI

struct GroupedRouteRow: View {
    let group: GroupedNearbyTransitResponse
    var onSelect: ((Int) -> Void)? = nil

    @State private var currentDirectionIndex = 0

    var body: some View {
        HStack(spacing: 12) {
            // Unified route badge — shows route name with mode-specific styling
            RouteBadge(
                routeID: group.displayName,
                size: .medium,
                isBus: group.isBus,
                hexColor: group.colorHex,
                mode: group.mode
            )
            .accessibilityHidden(true)

            // Swipeable content area
            if group.directions.isEmpty {
                Text("No active service")
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    TabView(selection: $currentDirectionIndex) {
                        ForEach(Array(group.directions.enumerated()), id: \.element.id) { index, direction in
                            // Destination Label + Station subtitle
                            let label = direction.arrivals.first?.destination
                                ?? direction.directionLabel
                                ?? directionLabel(direction.direction)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(label)
                                    .font(.custom("Helvetica-Bold", size: 15))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.9)
                                
                                // Show station name for commuter rail & subway
                                if let stopName = direction.arrivals.first?.stopName,
                                   !stopName.isEmpty,
                                   stopName != direction.arrivals.first?.destination {
                                    Text("at \(stopName)")
                                        .font(.custom("Helvetica", size: 12))
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .tag(index)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 36) // Taller to fit subtitle
                    
                    // Custom Pagination Dots
                    if group.directions.count > 1 {
                        HStack(spacing: 4) {
                            ForEach(0..<group.directions.count, id: \.self) { index in
                                Circle()
                                    .fill(index == currentDirectionIndex 
                                          ? AppTheme.Colors.textPrimary 
                                          : AppTheme.Colors.textSecondary.opacity(0.3))
                                    .frame(width: 5, height: 5)
                            }
                        }
                    }
                }
                .frame(height: 48)
            }

            Spacer(minLength: 8)

            // Big Countdown for the CURRENT direction
            if !group.directions.isEmpty {
                let currentDir = group.directions[min(currentDirectionIndex, group.directions.count - 1)]
                if let first = currentDir.arrivals.first {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(first.minutesAway)")
                            .font(.custom("Helvetica-Bold", size: 24))
                            .foregroundColor(AppTheme.Colors.countdown(first.minutesAway))
                        Text("min")
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary)

                        if first.status == "Scheduled" {
                            Image(systemName: "clock")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .offset(y: -5)
                        }
                    }
                } else {
                    Text("--")
                        .font(.custom("Helvetica-Bold", size: 20))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }

            // Chevron (outside the swipe area so it's always visible)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .padding(.vertical, 14) // Increased padding for better touch target
        .padding(.horizontal, AppTheme.Layout.margin)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?(currentDirectionIndex)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(group.isLIRR ? "LIRR" : group.isMNR ? "Metro-North" : group.isBus ? "Bus" : "Train") \(group.displayName), swipe for directions"
        )
        .accessibilityHint("Double tap to see details for current direction")
    }
}
