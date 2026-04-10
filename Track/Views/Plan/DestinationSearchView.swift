// Premium destination / origin search sheet.
// Prominent search bar with animated focus ring, categorised suggestions,
// Apple MapKit autocomplete results, and polished row treatments.

import MapKit
import SwiftUI

struct DestinationSearchView: View {
    @Bindable var viewModel: PlanViewModel
    let isOrigin: Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool
    @State private var appeared = false

    private var searchTitle: String {
        if let category = viewModel.pendingSavedPlaceCategory {
            return "Set \(category.label)"
        }
        return isOrigin ? "Set Origin" : "Where to?"
    }

    private var searchPlaceholder: String {
        if let category = viewModel.pendingSavedPlaceCategory {
            return "Search for \(category.label.lowercased())"
        }
        return isOrigin ? "Search origin..." : "Search a place or address"
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
                            AppTheme.Colors.accent.opacity(0.04),
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
        }
    }

    // MARK: - Resolving Overlay

    private var resolvingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(AppTheme.Colors.accent.opacity(0.2), lineWidth: 3)
                        .frame(width: 54, height: 54)
                    ProgressView()
                        .tint(AppTheme.Colors.accent)
                        .scaleEffect(1.4)
                }
                Text(viewModel.isSavingPlace ? "Saving place..." : "Getting location...")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(AppTheme.Colors.cardBackground.opacity(0.4))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                    }
            )
            .shadow(color: .black.opacity(0.2), radius: 30)
        }
        .transition(.opacity)
    }

    // MARK: - Search Header

    private var searchHeader: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(AppTheme.Colors.textTertiary.opacity(0.25))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(searchTitle)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    if let category = viewModel.pendingSavedPlaceCategory {
                        Text("Pick a place to save as \(category.label.lowercased()).")
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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(AppTheme.Colors.cardInset)
                                .overlay(
                                    Circle()
                                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.3), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            // Search field
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.accent.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .bold))
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                            .frame(width: 32, height: 32)
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
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isSearchFocused
                                    ? AppTheme.Colors.accent.opacity(0.35)
                                    : AppTheme.Colors.borderSubtle.opacity(0.2),
                                lineWidth: isSearchFocused ? 1.5 : 0.5
                            )
                    )
                    .shadow(
                        color: isSearchFocused ? AppTheme.Colors.accent.opacity(0.08) : .clear,
                        radius: 12
                    )
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .animation(.easeInOut(duration: 0.2), value: isSearchFocused)

            Rectangle()
                .fill(AppTheme.Colors.borderSubtle.opacity(0.1))
                .frame(height: 1)
        }
    }

    // MARK: - Default Content

    private var defaultContent: some View {
        VStack(spacing: 0) {
            quickActionsGrid
                .padding(.top, 14)

            savedLocationsSection
            calendarSection
            recentSection

            Spacer(minLength: 40)
        }
    }

    // MARK: - Quick Actions Grid

    private var quickActionsGrid: some View {
        HStack(spacing: 10) {
            quickActionTile(
                icon: "location.fill", label: "Current\nLocation", color: .blue
            ) {
                Task { await selectLocation(.currentLocation) }
            }

            quickActionTile(
                icon: "map.fill", label: "Choose\non Map", color: AppTheme.Colors.accent
            ) {
                viewModel.isOriginForMapPicker = isOrigin
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    viewModel.showMapPicker = true
                }
            }

            quickActionTile(
                icon: "person.crop.rectangle.fill", label: "From\nContacts", color: AppTheme.Colors.accentSecondary
            ) { /* TODO: Open contacts picker */ }
        }
        .padding(.horizontal, 16)
    }

    private func quickActionTile(
        icon: String, label: String, color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.15), color.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(color.opacity(0.15), lineWidth: 1)
                        )
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(color)
                }
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.15), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(SearchTileButtonStyle())
    }

    // MARK: - Saved Locations

    private var savedLocationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Saved Places")
            VStack(spacing: 2) {
                if let home = viewModel.savedLocation(for: .home) {
                    premiumLocationRow(icon: home.iconName, iconColor: AppTheme.Colors.accent, name: home.name, detail: home.address) {
                        Task { await selectLocation(.saved(home)) }
                    }
                } else {
                    setLocationRow(
                        icon: "house.fill",
                        label: "Set Home",
                        color: AppTheme.Colors.accent,
                        category: .home
                    )
                }
                if let work = viewModel.savedLocation(for: .work) {
                    premiumLocationRow(icon: work.iconName, iconColor: AppTheme.Colors.warningYellow, name: work.name, detail: work.address) {
                        Task { await selectLocation(.saved(work)) }
                    }
                } else {
                    setLocationRow(
                        icon: "briefcase.fill",
                        label: "Set Work",
                        color: AppTheme.Colors.warningYellow,
                        category: .work
                    )
                }
                if let school = viewModel.savedLocation(for: .school) {
                    premiumLocationRow(icon: school.iconName, iconColor: AppTheme.Colors.successGreen, name: school.name, detail: school.address) {
                        Task { await selectLocation(.saved(school)) }
                    }
                } else {
                    setLocationRow(
                        icon: "graduationcap.fill",
                        label: "Set School",
                        color: AppTheme.Colors.successGreen,
                        category: .school
                    )
                }
                if let partner = viewModel.savedLocation(for: .partner) {
                    premiumLocationRow(icon: partner.iconName, iconColor: AppTheme.Colors.alertRed, name: partner.name, detail: partner.address) {
                        Task { await selectLocation(.saved(partner)) }
                    }
                } else {
                    setLocationRow(
                        icon: "heart.fill",
                        label: "Set Partner",
                        color: AppTheme.Colors.alertRed,
                        category: .partner
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var calendarSection: some View {
        if !viewModel.calendarLocations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Calendar")
                VStack(spacing: 2) {
                    ForEach(viewModel.calendarLocations) { loc in
                        premiumLocationRow(icon: "calendar", iconColor: AppTheme.Colors.accent, name: loc.name, detail: loc.address) {
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
                VStack(spacing: 2) {
                    ForEach(viewModel.recentSearches) { loc in
                        premiumLocationRow(icon: "clock.arrow.circlepath", iconColor: AppTheme.Colors.textTertiary, name: loc.name, detail: loc.address, isSubtle: true) {
                            Task { await selectLocation(.recent(loc)) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Search Results

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
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.cardInset.opacity(0.5))
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(AppTheme.Colors.cardInset)
                    .frame(width: 56, height: 56)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.6))
            }
            VStack(spacing: 5) {
                Text("No results found")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                Text("Try a different search term or address")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
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

    // MARK: - Completion Row

    private func completionRow(_ completion: MKLocalSearchCompletion) -> some View {
        Button {
            viewModel.selectCompletion(completion, isOrigin: isOrigin)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.Colors.accent.opacity(0.12), AppTheme.Colors.accentDeep.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(AppTheme.Colors.accent.opacity(0.1), lineWidth: 0.5)
                        )
                    Image(systemName: completion.iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.3))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(AppTheme.Colors.cardInset.opacity(0.5)))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .buttonStyle(SearchRowButtonStyle())
    }

    // MARK: - Row Views

    private func premiumLocationRow(
        icon: String, iconColor: Color, name: String, detail: String,
        isSubtle: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(iconColor.opacity(isSubtle ? 0.06 : 0.12))
                        .frame(width: 42, height: 42)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(iconColor.opacity(0.08), lineWidth: 0.5)
                        )
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(iconColor)
                }
                VStack(alignment: .leading, spacing: 3) {
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.3))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.5))
            )
        }
        .buttonStyle(SearchRowButtonStyle())
    }

    private func setLocationRow(icon: String, label: String, color: Color) -> some View {
        setLocationRow(icon: icon, label: label, color: color, category: .custom)
    }

    private func setLocationRow(
        icon: String,
        label: String,
        color: Color,
        category: SavedLocationCategory
    ) -> some View {
        Button {
            viewModel.beginSavedPlaceFlow(category)
            isSearchFocused = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(color.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(color.opacity(0.5))
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
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.3))
            )
        }
        .buttonStyle(SearchRowButtonStyle())
    }

    private func searchResultRow(_ result: SearchResultItem) -> some View {
        Button {
            Task { await selectLocation(result.toPlanLocation()) }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(resultIconColor(result).opacity(0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: resultIcon(result))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(resultIconColor(result))
                }
                VStack(alignment: .leading, spacing: 3) {
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .buttonStyle(SearchRowButtonStyle())
    }

    // MARK: - Helpers

    private func selectLocation(_ location: PlanLocation) async {
        await viewModel.selectLocation(location, isOrigin: isOrigin)
        dismiss()
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textTertiary)
                .textCase(.uppercase)
                .tracking(1.0)
            Rectangle()
                .fill(AppTheme.Colors.borderSubtle.opacity(0.15))
                .frame(height: 0.5)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 10)
    }

    private func resultIcon(_ result: SearchResultItem) -> String {
        switch result {
        case .saved(let loc):
            return loc.iconName
        case .recent:
            return "clock.arrow.circlepath"
        case .geocoded:
            return "mappin"
        case .planner(let result):
            return result.iconName
        }
    }

    private func resultIconColor(_ result: SearchResultItem) -> Color {
        switch result {
        case .saved:
            return AppTheme.Colors.accent
        case .recent:
            return AppTheme.Colors.textTertiary
        case .geocoded:
            return AppTheme.Colors.alertRed
        case .planner(let planner):
            switch planner.source {
            case "saved_place":
                return AppTheme.Colors.accent
            case "recent_destination":
                return AppTheme.Colors.textTertiary
            default:
                return planner.mode == "subway"
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
                        .fill(AppTheme.Colors.cardInset.opacity(0.5))
                    : nil
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct SearchTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    DestinationSearchView(viewModel: PlanViewModel(), isOrigin: false)
        .preferredColorScheme(.dark)
}
