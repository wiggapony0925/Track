// Sheet page for viewing and managing saved favorites.
// Supports search, mode filtering, and multi-select batch removal.

import SwiftUI
import CoreLocation

struct ManageFavoritesView: View {

    let sheetNavigator: SheetNavigator
    /// Passed from HomeView so rows show live countdowns matching the dashboard.
    var groupedTransit: [GroupedNearbyTransitResponse] = []
    /// User's current GPS location — used to sort rows by physical distance,
    /// matching the order in the Near You / Farther Away sections.
    var userLocation: CLLocation? = nil
    /// Called when a direction tab is tapped — triggers map polylines/markers,
    /// preferred-direction tracking, and analytics. Wired by the parent (HomeView)
    /// to match the identical callback in NearbyDashboard.
    var onSelect: ((GroupedNearbyTransitResponse, Int) -> Void)? = nil
    /// Called when the track button is tapped inside a row.
    var onTrack: ((GroupedNearbyTransitResponse, Int) -> Void)? = nil
    /// Called when an alert banner is tapped — triggers route selection
    /// (map polyline, banner, vehicles) without duplicating sheet navigation.
    var onAlertSelect: ((GroupedNearbyTransitResponse) -> Void)? = nil
    /// When true, route rows render desaturated and non-interactive during refresh.
    var isStale: Bool = false
    @ObservedObject private var favoritesManager = FavoritesManager.shared

    @State private var searchText = ""
    @State private var modeFilter = "all"
    @State private var isEditing = false
    /// Selected route IDs (one per unique route, not per direction).
    @State private var selectedIds: Set<String> = []
    @State private var isRemoving = false

    // MARK: - Mode Definitions

    private static let modes: [(id: String, label: String, icon: String)] = [
        ("all",    "All",          "line.3.horizontal.decrease"),
        ("subway", "Subway",       "tram.fill"),
        ("bus",    "Bus",          "bus.fill"),
        ("lirr",   "LIRR",         "train.side.front.car"),
        ("mnr",    "Metro-North",  "train.side.rear.car"),
    ]

    // MARK: - Computed

    private var filtered: [CloudFavorite] {
        favoritesManager.favorites.filter { fav in
            let modeOK = modeFilter == "all" || fav.mode == modeFilter
            let searchOK = searchText.isEmpty
                || fav.routeDisplayName
                    .localizedCaseInsensitiveContains(searchText)
                || (!fav.stopName.isEmpty
                    && fav.stopName
                        .localizedCaseInsensitiveContains(searchText))
                || (fav.destination?.localizedCaseInsensitiveContains(searchText) ?? false)
            return modeOK && searchOK
        }
    }

    /// All CloudFavorite rows whose routeId is in the selection set.
    private var selectedFavorites: [CloudFavorite] {
        favoritesManager.favorites.filter { selectedIds.contains($0.routeId) }
    }

    /// Deduplicated route IDs from `filtered`, sorted by actual meter distance
    /// (same `groupMinDistance` function as the nearby list).
    private var uniqueFilteredRouteIds: [String] {
        let groupLookup: [String: GroupedNearbyTransitResponse] = Dictionary(
            uniqueKeysWithValues: groupedTransit.map { ($0.routeId, $0) }
        )
        let sorted = filtered.sorted { a, b in
            let ag = groupLookup[a.routeId]
            let bg = groupLookup[b.routeId]
            switch (ag, bg) {
            case let (ag?, bg?):
                // Sort purely by distance — same logic as FavoritesSection.
                guard let loc = userLocation else {
                    return ag.displayName
                        .localizedCaseInsensitiveCompare(
                            bg.displayName
                        ) == .orderedAscending
                }
                let aDist = groupMinDistance(for: ag, from: loc)
                let bDist = groupMinDistance(for: bg, from: loc)
                if abs(aDist - bDist) > 0.5 { return aDist < bDist }
                return ag.displayName
                    .localizedCaseInsensitiveCompare(
                        bg.displayName
                    ) == .orderedAscending
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return (a.displayOrder ?? 0) < (b.displayOrder ?? 0)
            }
        }
        var seen = Set<String>()
        return sorted.compactMap { seen.insert($0.routeId).inserted ? $0.routeId : nil }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            searchAndFilters

            Rectangle()
                .fill(AppTheme.Colors.borderSubtle)
                .frame(height: 1)
                .padding(.horizontal, AppTheme.Layout.margin)

            if favoritesManager.isLoading && favoritesManager.favorites.isEmpty {
                skeletonList
            } else if filtered.isEmpty {
                emptyState
            } else {
                favoritesList
            }

            if isEditing && !selectedIds.isEmpty {
                removeBar
            }
        }
        .trackScreenBackground()
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                sheetNavigator.goBack()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Back")
                        .font(AppTheme.Typography.navButton)
                }
                .foregroundColor(AppTheme.Colors.mtaBlue)
            }

            Spacer()

            VStack(spacing: 2) {
                Text("My Favorites")
                    .font(.custom("Helvetica-Bold", size: 17))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text("\(filtered.count) saved route\(filtered.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }

            Spacer()

            Button(isEditing ? "Done" : "Edit") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isEditing.toggle()
                    if !isEditing { selectedIds.removeAll() }
                }
            }
            .font(AppTheme.Typography.navButton)
            .foregroundColor(AppTheme.Colors.mtaBlue)
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Search + Mode Filters

    private var searchAndFilters: some View {
        VStack(spacing: 10) {
            // Inline search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)

                TextField("Search favorites…", text: $searchText)
                    .font(AppTheme.Typography.searchInput)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .autocorrectionDisabled()

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .trackFloatingChrome(cornerRadius: AppTheme.Layout.cornerRadius)
            .padding(.horizontal, AppTheme.Layout.margin)

            // Mode filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.modes, id: \.id) { mode in
                        filterChip(mode)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
        .padding(.bottom, 10)
    }

    private func filterChip(_ mode: (id: String, label: String, icon: String)) -> some View {
        let isSelected = modeFilter == mode.id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                modeFilter = mode.id
            }
            HapticManager.impact(.light)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(mode.label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : AppTheme.Colors.mtaBlue)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule()
                    .fill(
                        isSelected
                            ? AnyShapeStyle(AppTheme.Gradients.accent)
                            : AnyShapeStyle(AppTheme.Gradients.accentSurface)
                    )
            }
            .overlay {
                Capsule()
                    .stroke(
                        isSelected
                            ? AppTheme.Colors.textOnColor.opacity(0.18)
                            : AppTheme.Colors.borderAccent.opacity(0.56),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Skeleton List

    private static let skeletonWidths: [(CGFloat, CGFloat)] = [
        (160, 110), (140, 90), (175, 125), (130, 85), (155, 105), (170, 120)
    ]

    private var skeletonList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { i in
                    let widths = Self.skeletonWidths[i]
                    HStack(spacing: 12) {
                        SkeletonBar(
                            width: AppTheme.Layout.badgeSizeMedium,
                            height: AppTheme.Layout.badgeSizeMedium
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBar(width: widths.0, height: 13, opacity: 0.09)
                            SkeletonBar(width: widths.1, height: 11, opacity: 0.07)
                        }
                        Spacer()
                        SkeletonBar(width: 48, height: 26, opacity: 0.07)
                            .clipShape(Capsule())
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 16)
                    .trackFloatingChrome(cornerRadius: 24)
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.vertical, 8)
        }
        .shimmer()
        .disabled(true)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "heart.slash" : "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(AppTheme.Colors.mtaBlue)
            let modeLabel = Self.modes
                .first { $0.id == modeFilter }?
                .label ?? modeFilter
            Text(
                searchText.isEmpty
                    ? (modeFilter == "all"
                        ? "No favorites yet"
                        : "No \(modeLabel) favorites")
                    : "No results for \"\(searchText)\""
            )
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(AppTheme.Colors.textSecondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.vertical, 48)
        .trackCardBackground(cornerRadius: 24)
    }

    // MARK: - Favorites List

    private var favoritesList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(uniqueFilteredRouteIds, id: \.self) { routeId in
                    routeRow(routeId: routeId)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isEditing)
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.vertical, 8)
        }
    }

    /// One row per unique route. In edit mode a selection circle slides in
    /// beside the content and the whole row becomes tappable for toggling.
    @ViewBuilder
    private func routeRow(routeId: String) -> some View {
        let isSelected = selectedIds.contains(routeId)
        let matchedGroup = groupedTransit.first { $0.routeId == routeId }
        let repFav = filtered.first { $0.routeId == routeId }

        HStack(spacing: 0) {
            // ── Edit-mode selection circle ──
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(
                        isSelected
                            ? AppTheme.Colors.alertRed
                            : AppTheme.Colors.textSecondary.opacity(0.35)
                    )
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
                    .padding(.leading, AppTheme.Layout.margin)
                    .padding(.trailing, 8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // ── Real row content ──
            Group {
                if let group = matchedGroup {
                    GroupedRouteRow(
                        group: group,
                        hasAlert: !group.alerts.isEmpty,
                        userLocation: userLocation,
                        onSelect: isEditing ? nil : { directionIndex in
                            onSelect?(group, directionIndex)
                        },
                        onTrack: { directionIndex in
                            onTrack?(group, directionIndex)
                        },
                        onAlertTapped: isEditing ? nil : {
                            // Navigate to route detail, then trigger route
                            // selection so the map banner + polyline appear.
                            sheetNavigator.navigate(
                                to: .routeDetail(
                                    group: group,
                                    directionIndex: 0,
                                    initialTab: .stops
                                )
                            )
                            onAlertSelect?(group)
                        },
                        presentation: .favorite,
                        isStale: isStale
                    )
                } else if let fav = repFav {
                    offlineFavoriteRow(fav: fav)
                }
            }
            .allowsHitTesting(!isEditing)
        }
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    isEditing && isSelected
                        ? AppTheme.Colors.alertRed.opacity(0.08)
                        : Color.clear
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(
                    isEditing && isSelected
                        ? AppTheme.Colors.alertRed.opacity(0.45)
                        : Color.clear,
                    lineWidth: 1.5
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEditing else { return }
            HapticManager.impact(.light)
            withAnimation(.easeInOut(duration: 0.15)) {
                if selectedIds.contains(routeId) { selectedIds.remove(routeId) }
                else { selectedIds.insert(routeId) }
            }
        }
    }

    /// Compact row for a favorite that isn't currently in the nearby radius.
    private func offlineFavoriteRow(fav: CloudFavorite) -> some View {
        let routeColor = favoriteRouteColor(for: fav)
        let routeDisplayName = canonicalFavoriteRouteDisplayName(
            routeId: fav.routeId,
            savedDisplayName: fav.routeDisplayName,
            mode: fav.mode
        )

        return HStack(spacing: 12) {
            RouteBadge(
                routeID: routeDisplayName,
                size: .medium,
                isBus: fav.mode == "bus",
                hexColor: nil,
                mode: fav.mode
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(routeDisplayName)
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(fav.stopName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                if let destination = fav.destination ?? fav.direction {
                    Text(destination)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(routeColor.opacity(0.82))
                        .lineLimit(1)
                }
            }
            Spacer()
            Text("Not nearby")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(routeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(routeColor.opacity(0.12))
                .clipShape(Capsule())
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.35))
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AppTheme.Gradients.floating)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(routeColor.opacity(0.18), lineWidth: 1)
                }
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(routeColor)
                        .frame(width: 5)
                        .padding(.vertical, 16)
                        .padding(.leading, 10)
                }
                .shadow(color: AppTheme.Colors.shadow.opacity(0.18), radius: 14, x: 0, y: 8)
        }
    }

    // MARK: - Remove Bar

    private var removeBar: some View {
        VStack(spacing: 0) {
            Button(action: removeSelected) {
                HStack(spacing: 8) {
                    if isRemoving {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: "trash.fill")
                    }
                    Text(
                        isRemoving
                            ? "Removing…"
                            : "Remove \(selectedIds.count)"
                                + " Route\(selectedIds.count == 1 ? "" : "s")"
                    )
                    .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(AppTheme.Colors.alertRed)
                        .shadow(
                            color: AppTheme.Colors.alertRed
                                .opacity(0.28),
                            radius: 12, x: 0, y: 6
                        )
                )
            }
            .disabled(isRemoving)
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(AppTheme.Gradients.screen)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func favoriteRouteColor(for favorite: CloudFavorite) -> Color {
        switch favorite.mode {
        case "lirr":
            return AppTheme.CommuterRailColors.lirrBlue
        case "mnr":
            return AppTheme.CommuterRailColors.mnrBlue
        case "bus":
            return AppTheme.BusColors.localBlue
        default:
            return AppTheme.SubwayColors.color(for: canonicalFavoriteRouteDisplayName(
                routeId: favorite.routeId,
                savedDisplayName: favorite.routeDisplayName,
                mode: favorite.mode
            ))
        }
    }

    // MARK: - Actions

    private func removeSelected() {
        let toRemove = selectedFavorites
        guard !toRemove.isEmpty else { return }
        isRemoving = true
        Task {
            await favoritesManager.removeFavorites(toRemove)
            await MainActor.run {
                withAnimation {
                    selectedIds.removeAll()
                    isRemoving = false
                    if favoritesManager.favorites.isEmpty {
                        isEditing = false
                    }
                }
            }
            HapticManager.notification(.success)
        }
    }
}

#Preview {
    ManageFavoritesView(sheetNavigator: SheetNavigator(), groupedTransit: [])
        .background(AppTheme.Colors.background)
}
