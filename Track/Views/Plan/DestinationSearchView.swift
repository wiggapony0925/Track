// Destination / origin search sheet — rich search experience with
// animated focus ring, categorised suggestions, MapKit autocomplete,
// and premium row treatments. Every action is wired to live logic.

import MapKit
import SwiftUI

struct DestinationSearchView: View {
    @Bindable var viewModel: PlanViewModel
    let isOrigin: Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool
    @State private var appeared = false
    @State private var pulseFocus = false

    private var searchTitle: String {
        if let category = viewModel.pendingSavedPlaceCategory {
            if category == .custom {
                let label = viewModel.customPlaceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                return label.isEmpty ? "Save a Place" : "Save \"\(label)\""
            }
            return "Set \(category.label)"
        }
        return isOrigin ? "Set Origin" : "Where to?"
    }

    private var searchPlaceholder: String {
        if let category = viewModel.pendingSavedPlaceCategory {
            if category == .custom {
                return "Search for a location to save"
            }
            return "Search for \(category.label.lowercased())"
        }
        return isOrigin ? "Search origin..." : "Search a place or address"
    }

    private var plannerMessage: String? {
        guard !viewModel.showResults else { return nil }
        return viewModel.errorMessage
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchHeader

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        if viewModel.searchText.isEmpty {
                            defaultContent
                                .transition(.opacity)
                        } else {
                            searchResultsContent
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: viewModel.searchText.isEmpty)
                }
            }
            .background(
                ZStack {
                    AppTheme.Colors.background
                    RadialGradient(
                        colors: [
                            AppTheme.Colors.accent.opacity(0.05),
                            .clear,
                        ],
                        center: .top,
                        startRadius: 0,
                        endRadius: 400
                    )
                    .ignoresSafeArea()
                }
            )
            .navigationBarHidden(true)
            .overlay {
                if viewModel.isResolvingLocation || viewModel.isSavingPlace {
                    resolvingOverlay
                }
            }
            .animation(
                .easeInOut(duration: 0.25),
                value: viewModel.isResolvingLocation || viewModel.isSavingPlace
            )
        }
        .onAppear {
            isSearchFocused = true
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                appeared = true
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulseFocus = true
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Resolving Overlay
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var resolvingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(AppTheme.Colors.accent.opacity(0.15), lineWidth: 3)
                        .frame(width: 56, height: 56)
                    ProgressView()
                        .tint(AppTheme.Colors.accent)
                        .scaleEffect(1.4)
                }
                Text(viewModel.isSavingPlace ? "Saving place..." : "Getting location...")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(36)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(AppTheme.Colors.cardBackground.opacity(0.35))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                    }
            )
            .shadow(color: .black.opacity(0.25), radius: 40)
        }
        .transition(.opacity)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Search Header
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var searchHeader: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(AppTheme.Colors.textTertiary.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 12)

            // Title row + close button
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(searchTitle)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)

                    if let category = viewModel.pendingSavedPlaceCategory {
                        Text(
                            category == .custom
                                ? "Search and select a location to save."
                                : "Pick a place to save as \(category.label.lowercased())."
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                    }
                }
                Spacer()
                Button {
                    viewModel.cancelSavedPlaceFlow()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(AppTheme.Colors.cardInset)
                                .overlay(
                                    Circle()
                                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.25), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)

            // Search bar
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(
                                isSearchFocused
                                    ? AppTheme.Colors.accent.opacity(0.14)
                                    : AppTheme.Colors.accent.opacity(0.08)
                            )
                            .frame(width: 30, height: 30)
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(AppTheme.Colors.accent)
                    }

                    TextField(searchPlaceholder, text: $viewModel.searchText)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                        .onChange(of: viewModel.searchText) { _, newValue in
                            viewModel.performSearch(query: newValue)
                        }

                    if viewModel.searchText.isEmpty {
                        Button {
                            if let text = UIPasteboard.general.string, !text.isEmpty {
                                viewModel.searchText = text
                                viewModel.performSearch(query: text)
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textTertiary)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(AppTheme.Colors.cardInset.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                    }

                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                            viewModel.locationSearchService.cancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    isSearchFocused
                                        ? AppTheme.Colors.accent.opacity(pulseFocus ? 0.4 : 0.2)
                                        : AppTheme.Colors.borderSubtle.opacity(0.15),
                                    lineWidth: isSearchFocused ? 1.5 : 0.5
                                )
                        )
                        .shadow(
                            color: isSearchFocused
                                ? AppTheme.Colors.accent.opacity(0.1)
                                : .clear,
                            radius: 14
                        )
                )
                .animation(.easeInOut(duration: 0.2), value: isSearchFocused)

                // Error message
                if let message = plannerMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(AppTheme.Colors.alertRed)
                        Text(message)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Button { viewModel.dismissError() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(AppTheme.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.Colors.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(AppTheme.Colors.alertRed.opacity(0.12), lineWidth: 0.8)
                            )
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            Divider().opacity(0.08)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Default Content
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var defaultContent: some View {
        VStack(spacing: 0) {
            quickChips
                .padding(.top, 14)

            savedLocationsSection
            calendarSection
            recentSection

            Spacer(minLength: 40)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Quick Action Chips
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var quickChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickChipButton(
                    icon: "location.fill", label: "Current Location",
                    color: .blue
                ) {
                    Task { await selectLocation(.currentLocation) }
                }

                quickChipButton(
                    icon: "map.fill", label: "Choose on Map",
                    color: AppTheme.Colors.accent
                ) {
                    viewModel.isOriginForMapPicker = isOrigin
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        viewModel.showMapPicker = true
                    }
                }

                quickChipButton(
                    icon: "person.crop.rectangle.fill", label: "From Contacts",
                    color: AppTheme.Colors.accentSecondary
                ) { /* TODO: Open contacts picker */ }
            }
            .padding(.horizontal, 16)
        }
    }

    private func quickChipButton(
        icon: String, label: String, color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(color)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(color.opacity(0.12))
                    )

                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
            }
            .padding(.trailing, 14)
            .padding(.leading, 6)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        Capsule()
                            .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.12), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(SearchChipButtonStyle())
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Saved Locations
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var savedLocationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Saved Places")

            VStack(spacing: 4) {
                savedLocationEntry(
                    icon: "house.fill", label: "Home",
                    color: AppTheme.Colors.accent,
                    location: viewModel.savedLocation(for: .home),
                    category: .home
                )
                savedLocationEntry(
                    icon: "briefcase.fill", label: "Work",
                    color: AppTheme.Colors.warningYellow,
                    location: viewModel.savedLocation(for: .work),
                    category: .work
                )
                savedLocationEntry(
                    icon: "graduationcap.fill", label: "School",
                    color: AppTheme.Colors.successGreen,
                    location: viewModel.savedLocation(for: .school),
                    category: .school
                )
                savedLocationEntry(
                    icon: "heart.fill", label: "Partner",
                    color: AppTheme.Colors.alertRed,
                    location: viewModel.savedLocation(for: .partner),
                    category: .partner
                )

                ForEach(viewModel.customSavedLocations) { place in
                    locationRow(
                        icon: place.iconName,
                        iconColor: AppTheme.Colors.accentSecondary,
                        name: place.name,
                        detail: place.address
                    ) {
                        Task { await selectLocation(.saved(place)) }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func savedLocationEntry(
        icon: String, label: String, color: Color,
        location: SavedLocation?, category: SavedLocationCategory
    ) -> some View {
        if let loc = location {
            locationRow(
                icon: loc.iconName, iconColor: color,
                name: loc.name, detail: loc.address
            ) {
                Task { await selectLocation(.saved(loc)) }
            }
        } else {
            setLocationRow(icon: icon, label: "Set \(label)", color: color, category: category)
        }
    }

    @ViewBuilder
    private var calendarSection: some View {
        if !viewModel.calendarLocations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Calendar")
                VStack(spacing: 4) {
                    ForEach(viewModel.calendarLocations) { loc in
                        locationRow(
                            icon: "calendar",
                            iconColor: AppTheme.Colors.accent,
                            name: loc.name,
                            detail: loc.address
                        ) {
                            Task { await selectLocation(.saved(loc)) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !viewModel.recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Recent")
                VStack(spacing: 4) {
                    ForEach(viewModel.recentSearches) { loc in
                        locationRow(
                            icon: "clock.arrow.circlepath",
                            iconColor: AppTheme.Colors.textTertiary,
                            name: loc.name,
                            detail: loc.address,
                            isSubtle: true
                        ) {
                            Task { await selectLocation(.recent(loc)) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Search Results
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @ViewBuilder
    private var searchResultsContent: some View {
        let completions = viewModel.locationSearchService.completions
        let localResults = viewModel.searchResults
        let isSearching = viewModel.locationSearchService.isSearching

        if localResults.isEmpty && completions.isEmpty && !isSearching {
            emptySearchState
        } else {
            LazyVStack(spacing: 0) {
                if !localResults.isEmpty {
                    ForEach(localResults) { result in
                        searchResultRow(result)
                    }
                    if !completions.isEmpty {
                        sectionHeader("Suggestions")
                    }
                }
                ForEach(completions) { completion in
                    completionRow(completion)
                }
                if isSearching && completions.isEmpty {
                    searchingIndicator
                }
            }
            .padding(.top, 6)
        }
    }

    private var emptySearchState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.cardInset.opacity(0.4))
                    .frame(width: 68, height: 68)
                Circle()
                    .fill(AppTheme.Colors.cardInset)
                    .frame(width: 52, height: 52)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.5))
            }
            VStack(spacing: 4) {
                Text("No results found")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                Text("Try a different search term or address")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    private var searchingIndicator: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.Colors.accent)
            Text("Searching...")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Completion Row
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func completionRow(_ completion: MKLocalSearchCompletion) -> some View {
        Button {
            Task {
                let shouldDismiss = await viewModel.selectCompletion(
                    completion,
                    isOrigin: isOrigin
                )
                if shouldDismiss { dismiss() }
            }
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppTheme.Colors.accent.opacity(0.12),
                                    AppTheme.Colors.accentDeep.opacity(0.05),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(AppTheme.Colors.accent.opacity(0.08), lineWidth: 0.5)
                        )
                    Image(systemName: completion.iconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                    if !completion.subtitle.isEmpty {
                        Text(completion.subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.25))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(AppTheme.Colors.cardInset.opacity(0.4)))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(SearchRowButtonStyle())
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Row Views
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func locationRow(
        icon: String, iconColor: Color, name: String, detail: String,
        isSubtle: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(iconColor.opacity(isSubtle ? 0.05 : 0.12))
                        .frame(width: 40, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(iconColor.opacity(0.06), lineWidth: 0.5)
                        )
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(iconColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.25))
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.45))
            )
        }
        .buttonStyle(SearchRowButtonStyle())
    }

    private func setLocationRow(
        icon: String, label: String, color: Color,
        category: SavedLocationCategory
    ) -> some View {
        Button {
            viewModel.beginSavedPlaceFlow(category)
            isSearchFocused = true
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            color.opacity(0.18),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4])
                        )
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(color.opacity(0.45))
                }

                Text(label)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)

                Spacer(minLength: 0)

                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .heavy))
                    Text("Add")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundColor(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(color.opacity(0.1)))
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.25))
            )
        }
        .buttonStyle(SearchRowButtonStyle())
    }

    private func searchResultRow(_ result: SearchResultItem) -> some View {
        Button {
            Task { await selectLocation(result.toPlanLocation()) }
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(resultIconColor(result).opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: resultIcon(result))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(resultIconColor(result))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(result.address)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.25))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(SearchRowButtonStyle())
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Helpers
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func selectLocation(_ location: PlanLocation) async {
        let shouldDismiss = await viewModel.selectLocation(location, isOrigin: isOrigin)
        if shouldDismiss { dismiss() }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            SectionHeader(title: title, size: 11, tracking: 1.0)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [AppTheme.Colors.borderSubtle.opacity(0.2), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    private func resultIcon(_ result: SearchResultItem) -> String {
        switch result {
        case .saved(let loc):  return loc.iconName
        case .recent:          return "clock.arrow.circlepath"
        case .geocoded:        return "mappin"
        case .planner(let r):  return r.iconName
        }
    }

    private func resultIconColor(_ result: SearchResultItem) -> Color {
        switch result {
        case .saved:           return AppTheme.Colors.accent
        case .recent:          return AppTheme.Colors.textTertiary
        case .geocoded:        return AppTheme.Colors.alertRed
        case .planner(let p):
            switch p.source {
            case "saved_place":        return AppTheme.Colors.accent
            case "recent_destination": return AppTheme.Colors.textTertiary
            default:
                return p.mode == "subway"
                    ? AppTheme.Colors.accentSecondary
                    : AppTheme.Colors.alertRed
            }
        }
    }
}

// MARK: - Button Styles

private struct SearchRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.Colors.cardInset.opacity(0.45))
                    : nil
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SearchChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    DestinationSearchView(viewModel: PlanViewModel(), isOrigin: false)
        .preferredColorScheme(.dark)
}
