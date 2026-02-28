//
//  ManageFavoritesView.swift
//  Track
//
//  Sheet page for viewing and managing saved favorites.
//  Supports search, mode filtering, and multi-select batch removal.
//

import SwiftUI

struct ManageFavoritesView: View {

    let sheetNavigator: SheetNavigator
    /// Passed from HomeView so rows show live countdowns matching the dashboard.
    var groupedTransit: [GroupedNearbyTransitResponse] = []
    @ObservedObject private var favoritesManager = FavoritesManager.shared

    @State private var searchText = ""
    @State private var modeFilter = "all"
    @State private var isEditing = false
    @State private var selectedIds: Set<Int64> = []
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
                || fav.routeDisplayName.localizedCaseInsensitiveContains(searchText)
                || fav.stopName.localizedCaseInsensitiveContains(searchText)
                || (fav.destination?.localizedCaseInsensitiveContains(searchText) ?? false)
            return modeOK && searchOK
        }
    }

    private var selectedFavorites: [CloudFavorite] {
        favoritesManager.favorites.filter { fav in
            guard let id = fav.id else { return false }
            return selectedIds.contains(id)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            searchAndFilters

            Divider()

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
        .background(AppTheme.Colors.background)
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

            Text("My Favorites")
                .font(.custom("Helvetica-Bold", size: 17))
                .foregroundColor(AppTheme.Colors.textPrimary)

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
            .background(AppTheme.Colors.cardBackground)
            .cornerRadius(AppTheme.Layout.cornerRadius)
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
            .foregroundColor(isSelected ? .white : AppTheme.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? AppTheme.Colors.mtaBlue : AppTheme.Colors.cardBackground)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Skeleton List

    private static let skeletonWidths: [(CGFloat, CGFloat)] = [
        (160, 110), (140, 90), (175, 125), (130, 85), (155, 105), (170, 120)
    ]

    private var skeletonList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { i in
                    let widths = Self.skeletonWidths[i]
                    VStack(spacing: 0) {
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
                        .padding(.vertical, 13)
                        .padding(.horizontal, 4)
                        if i < 5 { Divider().padding(.leading, AppTheme.Layout.margin) }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
        }
        .shimmer()
        .disabled(true)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "heart.slash" : "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text(
                searchText.isEmpty
                    ? (modeFilter == "all"
                        ? "No favorites yet"
                        : "No \(Self.modes.first { $0.id == modeFilter }?.label ?? modeFilter) favorites")
                    : "No results for \"\(searchText)\""
            )
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(AppTheme.Colors.textSecondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Favorites List

    private var favoritesList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, fav in
                    VStack(spacing: 0) {
                        favoriteRow(fav)
                        if index < filtered.count - 1 {
                            Divider()
                                .padding(.leading, isEditing ? 58 : AppTheme.Layout.margin)
                        }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isEditing)
        }
    }

    private func matchedGroup(for fav: CloudFavorite) -> GroupedNearbyTransitResponse? {
        groupedTransit.first { $0.routeId == fav.routeId }
    }

    private func directionIndex(for fav: CloudFavorite, in group: GroupedNearbyTransitResponse) -> Int {
        group.directions.firstIndex {
            $0.direction.lowercased() == (fav.direction ?? "").lowercased()
        } ?? 0
    }

    @ViewBuilder
    private func favoriteRow(_ fav: CloudFavorite) -> some View {
        let isSelected = fav.id.map { selectedIds.contains($0) } ?? false
        let group = matchedGroup(for: fav)

        HStack(spacing: 12) {
            // Edit-mode selection circle
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? AppTheme.Colors.alertRed : AppTheme.Colors.textSecondary.opacity(0.3))
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
                    .frame(width: 26)
            }

            // Reuse the exact same FavoriteCard component from the dashboard strip,
            // rendered in list-row mode (full-width, medium badge, live countdown pill).
            FavoriteCard(
                favorite: fav,
                matchedGroup: group,
                onTap: { _, _ in },  // tap handled below via contentShape
                isListRow: true
            )
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(
            isEditing && isSelected
                ? AppTheme.Colors.alertRed.opacity(0.06)
                : Color.clear
        )
        .onTapGesture {
            HapticManager.impact(.light)
            if isEditing {
                guard let id = fav.id else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    if selectedIds.contains(id) { selectedIds.remove(id) }
                    else { selectedIds.insert(id) }
                }
            } else if let group {
                sheetNavigator.navigate(
                    to: .routeDetail(group: group, directionIndex: directionIndex(for: fav, in: group))
                )
            }
        }
    }

    // MARK: - Remove Bar

    private var removeBar: some View {
        VStack(spacing: 0) {
            Divider()
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
                            : "Remove \(selectedIds.count) Favorite\(selectedIds.count == 1 ? "" : "s")"
                    )
                    .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(AppTheme.Colors.alertRed)
            }
            .disabled(isRemoving)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
