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
    let selectedMode: TransportMode
    /// Shared ETA provider — when supplied, favorites use the same
    /// vehicle-position + delay-factor enriched ETA as home rows.
    var smartETAProvider: ((NearbyTransitResponse) -> SmartETA)? = nil
    /// When true, favorite cards render desaturated and non-interactive
    /// while fresh backend data is being fetched.
    var isStale: Bool = false

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

        let allFavorites = favoritesManager.favorites
        let filteredFavorites = selectedMode == .nearby 
            ? allFavorites 
            : allFavorites.filter { $0.mode == selectedMode.rawValue }

        return filteredFavorites.sorted { a, b in
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
        VStack(alignment: .leading, spacing: 12) {
            // Custom header row: FAVORITES title + Manage button
            HStack {
                Text("Favorites")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .lineLimit(1)
                Spacer()
                if !sortedFavorites.isEmpty || selectedMode != .nearby {
                    Button("Manage") {
                        sheetNavigator.navigate(to: .manageFavorites)
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(AppTheme.Colors.accentTint)
                            .overlay {
                                Capsule()
                                    .stroke(AppTheme.Colors.borderSubtle, lineWidth: 0.5)
                            }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if sortedFavorites.isEmpty {
                        FavoritesEmptyCard(mode: selectedMode)
                    } else {
                        ForEach(sortedFavorites) { favorite in
                            FavoriteCard(
                                favorite: favorite,
                                matchedGroup: groupedTransit.first { $0.routeId == favorite.routeId },
                                onTap: onSelect,
                                userLocation: userLocation,
                                smartETAProvider: smartETAProvider,
                                isStale: isStale
                            )
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
    }
}

// MARK: - Empty Favorites Nudge

/// A friendly floating nudge shown when the user has no favorites for
/// the active transport mode. Uses mode-specific iconography, color
/// tinting, and playful copy ("Why not favorite…?") to encourage the
/// user to try the feature.
private struct FavoritesEmptyCard: View {
    let mode: TransportMode

    @State private var pulse = false

    private var modeIcon: String { mode.icon }

    private var accentColor: Color {
        switch mode {
        case .nearby:  return .red.opacity(0.75)
        case .subway:  return AppTheme.Colors.mtaBlue
        case .lirr:    return AppTheme.CommuterRailColors.lirrBlue
        case .mnr:     return AppTheme.CommuterRailColors.mnrBlue
        case .bus:     return AppTheme.Colors.mtaBlue
        }
    }

    private var nudgeText: String {
        switch mode {
        case .nearby:  return "Why not favorite a route?"
        case .subway:  return "Why not favorite a subway line?"
        case .lirr:    return "Why not favorite an LIRR train?"
        case .mnr:     return "Why not favorite a Metro-North train?"
        case .bus:     return "Why not favorite a bus route?"
        }
    }

    private var hint: String {
        switch mode {
        case .nearby:  return "Tap the heart on any route to pin it here"
        case .subway:  return "Your favorited trains will show up right here"
        case .lirr:    return "Save your commute for a quick glance"
        case .mnr:     return "Save your commute for a quick glance"
        case .bus:     return "Your favorited buses will show up right here"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Mode icon with a pulsing heart badge
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: modeIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(accentColor)
                    .frame(width: 36, height: 36)

                Image(systemName: "heart.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.red)
                    .scaleEffect(pulse ? 1.2 : 1.0)
                    .offset(x: 4, y: 4)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(nudgeText)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(hint)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous)
                .fill(AppTheme.Gradients.floating)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: accentColor.opacity(0.10), radius: 12, x: 0, y: 6)
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.0)
                .repeatForever(autoreverses: true)
            ) {
                pulse = true
            }
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
    /// User's current location — used to pick the nearest stop for the
    /// countdown, matching the same stop-selection logic as GroupedRouteRow
    /// and RouteDetailSheet (via `ArrivalHelpers.countdownArrival`).
    var userLocation: CLLocation? = nil
    /// Shared ETA provider — matches home row + route detail chip ETAs.
    var smartETAProvider: ((NearbyTransitResponse) -> SmartETA)? = nil
    /// When true, card renders desaturated and non-interactive during refresh.
    var isStale: Bool = false

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

    /// Next live arrival for the matched direction, picking the soonest
    /// bus at the user's **nearest stop** — same algorithm as the nearby
    /// row and detail sheet so all three always show the same number.
    private var nextArrival: NearbyTransitResponse? {
        guard let group = matchedGroup else { return nil }
        let dir = group.directions.first {
            $0.direction.lowercased() == (favorite.direction ?? "").lowercased()
        } ?? group.directions.first
        guard let dir else { return nil }
        return ArrivalHelpers.countdownArrival(
            for: dir,
            userLocation: userLocation,
            provider: smartETAProvider
        )
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
                guard !isStale else { return }
                if let group = matchedGroup {
                    onTap(group, directionIndex)
                }
            } label: {
                cardContent
            }
            .buttonStyle(.plain)
            .staleOverlay(isStale, normalOpacity: matchedGroup != nil ? 1.0 : 0.5)
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
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(favorite.stopName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                if let dest = favorite.destination ?? favorite.direction {
                    Text("→ \(dest)")
                        .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
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
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundColor(
                        eta.minutesRemaining <= 2
                            ? AppTheme.Colors.alertRed
                            : AppTheme.Colors.textPrimary
                    )
            }
        } else {
            Text("—")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
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
        let shape = RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous)
        return ZStack {
            shape
                .fill(AppTheme.Colors.cardBackground)
            shape
                .fill(
                    AppTheme.Gradients.tintWash(routeColor, intensity: 0.06)
                )
            shape
                .fill(
                    LinearGradient(
                        colors: [AppTheme.Colors.glassHighlight.opacity(0.08), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
            shape
                .stroke(AppTheme.Colors.borderSubtle, lineWidth: 0.5)
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.08), radius: 12, x: 0, y: 5)
        .shadow(color: routeColor.opacity(0.04), radius: 16, x: 0, y: 6)
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
