//
//  FavoritesSection.swift
//  Track
//
//  Displays the user's favorited routes/stops as compact cards
//  on the dashboard. Tapping a favorite navigates to the route detail.
//

import SwiftUI
import CoreLocation

// MARK: - FavoritesSection

/// Horizontal scrolling section showing the user's saved favorite routes.
/// Rendered by DashboardView after transit data has loaded.
/// Shows real cards when favorites exist, or an empty-state nudge otherwise.
struct FavoritesSection: View {
    @ObservedObject private var favoritesManager = FavoritesManager.shared
    let groupedTransit: [GroupedNearbyTransitResponse]
    let userLocation: CLLocation?
    let sheetNavigator: SheetNavigator
    let onSelect: (GroupedNearbyTransitResponse, Int) -> Void
    /// Shared ETA provider — when supplied, favorites use the same
    /// vehicle-position + delay-factor enriched ETA as home rows.
    var smartETAProvider: ((NearbyTransitResponse) -> SmartETA)? = nil

    /// Favorites sorted closest-first using the same distance function
    /// as the nearby list (`groupMinDistance`), so the order matches
    /// what the user sees in the Near You / Farther Away sections.
    ///
    /// Strategy:
    /// 1. Matched favorites (route has live data) — sorted by actual
    ///    meter distance from the user via `groupMinDistance`.
    /// 2. Unmatched favorites — sorted by saved stop coordinates, then
    ///    `displayOrder` as a final fallback.
    private var sortedFavorites: [CloudFavorite] {
        // Build a lookup: routeId → matched GroupedNearbyTransitResponse
        let groupLookup: [String: GroupedNearbyTransitResponse] = Dictionary(
            uniqueKeysWithValues: groupedTransit.map { ($0.routeId, $0) }
        )

        return favoritesManager.favorites.sorted { a, b in
            let aGroup = groupLookup[a.routeId]
            let bGroup = groupLookup[b.routeId]

            switch (aGroup, bGroup) {
            case let (ag?, bg?):
                // Both matched — sort purely by physical distance to nearest stop.
                // No soonestMinutes tiebreak: a far-away train arriving in 1 min
                // should not jump ahead of a closer stop arriving in 3 min.
                guard let loc = userLocation else {
                    // No GPS yet — stable alpha tiebreak
                    return ag.displayName.localizedCaseInsensitiveCompare(bg.displayName) == .orderedAscending
                }
                let aDist = groupMinDistance(for: ag, from: loc)
                let bDist = groupMinDistance(for: bg, from: loc)
                if abs(aDist - bDist) > 0.5 { return aDist < bDist }
                // Exact tie — stable alpha tiebreak
                return ag.displayName.localizedCaseInsensitiveCompare(bg.displayName) == .orderedAscending
            case (.some, .none):
                return true   // matched routes come before unmatched
            case (.none, .some):
                return false
            case (.none, .none):
                // Neither in radius — use saved stop coordinates
                let aDist = distanceToStop(a)
                let bDist = distanceToStop(b)
                if aDist != bDist { return aDist < bDist }
                return (a.displayOrder ?? 0) < (b.displayOrder ?? 0)
            }
        }
    }

    private func distanceToStop(_ fav: CloudFavorite) -> CLLocationDistance {
        guard let loc = userLocation,
              let lat = fav.stopLat, let lon = fav.stopLon else { return .greatestFiniteMagnitude }
        return loc.distance(from: CLLocation(latitude: lat, longitude: lon))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Custom header row: FAVORITES title + Manage button
            HStack {
                Text("Favorites")
                    .font(AppTheme.Typography.sectionHeader)
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Spacer()
                if !favoritesManager.favorites.isEmpty {
                    Button("Manage") {
                        sheetNavigator.navigate(to: .manageFavorites)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppTheme.Gradients.controlSurface)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(AppTheme.Colors.borderSubtle, lineWidth: 1)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if favoritesManager.favorites.isEmpty {
                        FavoritesEmptyCard()
                    } else {
                        ForEach(sortedFavorites) { favorite in
                            FavoriteCard(
                                favorite: favorite,
                                matchedGroup: groupedTransit.first { $0.routeId == favorite.routeId },
                                onTap: onSelect,
                                smartETAProvider: smartETAProvider
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
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous)
                .fill(AppTheme.Gradients.floating)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: AppTheme.Colors.shadow.opacity(0.15), radius: 10, x: 0, y: 6)
        }
    }
}

// MARK: - Favorite Card

/// A single compact card (or full-width list row) showing a favorited route with live countdown.
///
/// Use `isListRow = false` (default) for the horizontal scroll strip on the dashboard.
/// Use `isListRow = true` in ManageFavoritesView for a full-width list layout —
/// in that mode the view renders plain content with no Button wrapper; the caller
/// is responsible for tap handling.
struct FavoriteCard: View {
    let favorite: CloudFavorite
    let matchedGroup: GroupedNearbyTransitResponse?
    let onTap: (GroupedNearbyTransitResponse, Int) -> Void
    var isListRow: Bool = false
    /// Shared ETA provider — matches home row + route detail chip ETAs.
    var smartETAProvider: ((NearbyTransitResponse) -> SmartETA)? = nil

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
        if isListRow {
            // Plain content — no Button wrapper. Caller owns tap + selection handling.
            listRowContent
        } else {
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
    }

    // MARK: - List Row Layout (used in ManageFavoritesView)

    /// Full-width horizontal row: badge | text column | Spacer | countdown | chevron
    var listRowContent: some View {
        HStack(spacing: 12) {
            RouteBadge(
                routeID: favorite.routeDisplayName,
                size: .medium,
                hexColor: matchedGroup?.colorHex,
                mode: favorite.mode
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(favorite.routeDisplayName)
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(favorite.stopName)
                    .font(.custom("Helvetica", size: 12))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                if let dest = favorite.destination ?? favorite.direction {
                    Text("→ \(dest)")
                        .font(.custom("Helvetica", size: 11))
                        .foregroundColor(routeColor.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Live countdown pill — same logic as the dashboard card
            countdownPill

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.3))
        }
        .padding(.vertical, 13)
        .opacity(matchedGroup != nil ? 1.0 : 0.55)
    }

    /// Pill-style countdown used in list rows (more prominent than the inline label in cards).
    @ViewBuilder
    private var countdownPill: some View {
        if let arrival = nextArrival {
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                let eta = resolvedETA(for: arrival)
                let isNow = eta.isAtStop || eta.secondsRemaining <= 30
                Text(isNow ? "Now" : "\(eta.minutesRemaining) min")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(eta.minutesRemaining <= 2 ? .white : AppTheme.Colors.mtaBlue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background {
                        Capsule()
                            .fill(
                                eta.minutesRemaining <= 2
                                    ? AnyShapeStyle(AppTheme.Colors.alertRed)
                                    : AnyShapeStyle(AppTheme.Gradients.accentSurface)
                            )
                    }
                    .clipShape(Capsule())
            }
        } else {
            Text("—")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(AppTheme.Gradients.controlSurface)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading) {
            // Top row: Badge + Countdown
            HStack(alignment: .top) {
                RouteBadge(
                    routeID: favorite.routeDisplayName,
                    size: .medium,
                    hexColor: matchedGroup?.colorHex,
                    mode: favorite.mode
                )
                Spacer(minLength: 2)
                countdownChip
            }

            Spacer()

            // Bottom row: Text Info
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.stopName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                if let direction = favorite.direction {
                    Text("→ \(favorite.destination ?? direction)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 135, height: 135, alignment: .leading)
        .background { cardChrome }
    }

    /// Resolve ETA using the shared provider (same computation as home rows)
    /// or fall back to a basic arrivalTs countdown.
    private func resolvedETA(for arrival: NearbyTransitResponse) -> SmartETA {
        ArrivalHelpers.resolvedETA(for: arrival, provider: smartETAProvider)
    }

    @ViewBuilder
    private var countdownLabel: some View {
        if let arrival = nextArrival {
            // Per-second countdown — consistent with all other countdown views
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                let eta = resolvedETA(for: arrival)
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

    @ViewBuilder
    private var countdownChip: some View {
        if let arrival = nextArrival {
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                let eta = resolvedETA(for: arrival)
                let isNow = eta.isAtStop || eta.secondsRemaining <= 30
                VStack(alignment: .trailing, spacing: -2) {
                    if isNow {
                        Text("Now")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundColor(AppTheme.Colors.alertRed)
                    } else {
                        Text("\(eta.minutesRemaining)")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundColor(AppTheme.Colors.countdown(eta.minutesRemaining))
                            .contentTransition(.numericText())
                        Text("MIN")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.8))
                    }
                }
            }
        } else {
            Text("—")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.3))
        }
    }

    private var cardChrome: some View {
        RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous)
            .fill(AppTheme.Gradients.floating)
            .shadow(color: AppTheme.Colors.shadow.opacity(0.08), radius: 12, x: 0, y: 4)
    }

    private var favoriteModeIcon: String {
        switch favorite.mode {
        case "bus":
            return "bus.fill"
        case "lirr":
            return "train.side.front.car"
        case "mnr":
            return "train.side.rear.car"
        default:
            return "tram.fill"
        }
    }
}
