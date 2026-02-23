//
//  FavoritesSection.swift
//  Track
//
//  Displays the user's favorited routes/stops as compact cards
//  on the dashboard. Tapping a favorite navigates to the route detail.
//

import SwiftUI

// MARK: - FavoritesSection

/// Horizontal scrolling section showing the user's saved favorite routes.
/// Rendered by DashboardView after transit data has loaded.
/// Shows real cards when favorites exist, or an empty-state nudge otherwise.
struct FavoritesSection: View {
    @ObservedObject private var favoritesManager = FavoritesManager.shared
    let groupedTransit: [GroupedNearbyTransitResponse]
    let onSelect: (GroupedNearbyTransitResponse, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader(title: "Favorites")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if favoritesManager.favorites.isEmpty {
                        FavoritesEmptyCard()
                    } else {
                        ForEach(favoritesManager.favorites) { favorite in
                            FavoriteCard(
                                favorite: favorite,
                                matchedGroup: groupedTransit.first { $0.routeId == favorite.routeId },
                                onTap: onSelect
                            )
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
    }
}

// MARK: - Empty Card

/// Shown when the user hasn't favorited anything yet.
private struct FavoritesEmptyCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.red.opacity(0.7))

            VStack(alignment: .leading, spacing: 3) {
                Text("No favorites yet")
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text("Try favoriting a route! ♥")
                    .font(.custom("Helvetica", size: 12))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                .strokeBorder(Color.red.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Favorite Card

/// A single compact card showing a favorited route with live countdown.
private struct FavoriteCard: View {
    let favorite: CloudFavorite
    let matchedGroup: GroupedNearbyTransitResponse?
    let onTap: (GroupedNearbyTransitResponse, Int) -> Void

    // MARK: Helpers

    private var routeColor: Color {
        if let hex = matchedGroup?.colorHex { return Color(hex: hex) }
        switch favorite.mode {
        case "lirr": return AppTheme.CommuterRailColors.lirrBlue
        case "mnr":  return AppTheme.CommuterRailColors.mnrBlue
        case "bus":  return AppTheme.Colors.mtaBlue
        default:     return AppTheme.SubwayColors.color(for: favorite.routeDisplayName)
        }
    }

    /// First live arrival for the matched direction.
    private var nextArrival: NearbyTransitResponse? {
        guard let group = matchedGroup else { return nil }
        let dir = group.directions.first {
            $0.direction.lowercased() == (favorite.direction ?? "").lowercased()
        } ?? group.directions.first
        return dir?.liveArrivals.first
    }

    private var directionIndex: Int {
        matchedGroup?.directions.firstIndex {
            $0.direction.lowercased() == (favorite.direction ?? "").lowercased()
        } ?? 0
    }

    // MARK: Body

    var body: some View {
        Button {
            if let group = matchedGroup {
                onTap(group, directionIndex)
            }
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .opacity(matchedGroup != nil ? 1.0 : 0.5)
        .disabled(matchedGroup == nil)
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Route badge + countdown row
            HStack(spacing: 8) {
                RouteBadge(
                    routeID: favorite.routeDisplayName,
                    size: .small,
                    hexColor: matchedGroup?.colorHex,
                    mode: favorite.mode
                )
                countdownLabel
            }

            // Stop name
            Text(favorite.stopName)
                .font(.custom("Helvetica", size: 12))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .lineLimit(1)

            // Direction / destination
            if let direction = favorite.direction {
                Text("→ \(favorite.destination ?? direction)")
                    .font(.custom("Helvetica", size: 11))
                    .foregroundColor(routeColor.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(minWidth: 130)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                .strokeBorder(routeColor.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    @ViewBuilder
    private var countdownLabel: some View {
        if let arrival = nextArrival {
            // Per-second countdown — consistent with all other countdown views
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                let eta = ArrivalETAEngine.computeETA(
                    vehicleCoord: nil,
                    vehicleKey: nil,
                    stopCoord: nil,
                    arrivalTs: arrival.arrivalTs,
                    staticMinutes: arrival.minutesAway,
                    mode: arrival.mode
                )
                let isNow = eta.isAtStop || eta.secondsRemaining <= 30
                Text(isNow ? "Now" : "\(eta.minutesRemaining) min")
                    .font(.custom("Helvetica-Bold", size: 14))
                    .foregroundColor(
                        eta.minutesRemaining <= 2
                            ? AppTheme.Colors.alertRed
                            : AppTheme.Colors.textPrimary
                    )
            }
        } else {
            Text("—")
                .font(.custom("Helvetica-Bold", size: 14))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
    }
}

