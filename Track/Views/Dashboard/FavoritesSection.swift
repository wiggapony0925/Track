//
//  FavoritesSection.swift
//  Track
//
//  Displays the user's favorited routes/stops as compact cards
//  on the dashboard. Tapping a favorite navigates to the route detail.
//

import SwiftUI

/// A horizontal scrolling section showing the user's saved favorite routes.
struct FavoritesSection: View {
    @ObservedObject var favoritesManager = FavoritesManager.shared
    let groupedTransit: [GroupedNearbyTransitResponse]
    let onSelect: (GroupedNearbyTransitResponse, Int) -> Void
    
    var body: some View {
        if !favoritesManager.favorites.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // Section header
                HStack {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 14))
                    Text("Favorites")
                        .font(AppTheme.Typography.sectionHeader)
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                
                // Horizontal scroll of favorite cards
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(favoritesManager.favorites) { favorite in
                            FavoriteCard(
                                favorite: favorite,
                                matchedGroup: groupedTransit.first(where: { $0.routeId == favorite.routeId }),
                                onTap: { group, dirIdx in
                                    onSelect(group, dirIdx)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, AppTheme.Layout.margin)
                }
            }
        }
    }
}

/// A single compact favorite card
private struct FavoriteCard: View {
    let favorite: CloudFavorite
    let matchedGroup: GroupedNearbyTransitResponse?
    let onTap: (GroupedNearbyTransitResponse, Int) -> Void
    
    private var routeColor: Color {
        if let group = matchedGroup, let hex = group.colorHex {
            return Color(hex: hex)
        }
        switch favorite.mode {
        case "lirr": return AppTheme.CommuterRailColors.lirrBlue
        case "mnr": return AppTheme.CommuterRailColors.mnrBlue
        case "bus": return AppTheme.Colors.mtaBlue
        default: return AppTheme.SubwayColors.color(for: favorite.routeDisplayName)
        }
    }
    
    /// Minutes until next arrival for this favorite, if live data is available.
    private var nextMinutes: Int? {
        guard let group = matchedGroup else { return nil }
        // Find the direction matching this favorite
        let dir = group.directions.first(where: {
            $0.direction.lowercased() == (favorite.direction ?? "").lowercased()
        }) ?? group.directions.first
        return dir?.arrivals.first?.minutesAway
    }
    
    var body: some View {
        Button {
            if let group = matchedGroup {
                // Find direction index matching favorite
                let dirIdx = group.directions.firstIndex(where: {
                    $0.direction.lowercased() == (favorite.direction ?? "").lowercased()
                }) ?? 0
                onTap(group, dirIdx)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    RouteBadge(
                        routeID: favorite.routeDisplayName,
                        size: .small,
                        hexColor: matchedGroup?.colorHex,
                        mode: favorite.mode
                    )
                    
                    if let mins = nextMinutes {
                        Text("\(mins) min")
                            .font(.custom("Helvetica-Bold", size: 14))
                            .foregroundColor(mins <= 2 ? AppTheme.Colors.alertRed : AppTheme.Colors.textPrimary)
                    } else {
                        Text("—")
                            .font(.custom("Helvetica-Bold", size: 14))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                }
                
                Text(favorite.stopName)
                    .font(.custom("Helvetica", size: 12))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                
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
        .buttonStyle(.plain)
        .opacity(matchedGroup != nil ? 1.0 : 0.5)
        .disabled(matchedGroup == nil)
    }
}
