import CoreLocation
import MapKit
import SwiftUI

struct ManageSavedAddressesView: View {
    var sheetNavigator: SheetNavigator? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var supabase = SupabaseManager.shared

    @State private var places: [SavedLocation] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var draft: SavedAddressDraft?
    @State private var searchQuery = ""
    @State private var appleSearch = LocationSearchService()
    @State private var isResolvingSearch = false
    @State private var showMapPicker = false

    private var userID: String? {
        supabase.currentUser?.id.uuidString.lowercased()
            ?? supabase.storedUserIdString?.lowercased()
    }

    private var visiblePlacesCount: Int {
        places.filter(\.visibleOnMap).count
    }

    private var customCount: Int {
        places.filter { $0.resolvedCategory == .custom }.count
    }

    private var sortedPlaces: [SavedLocation] {
        places.sorted { lhs, rhs in
            if lhs.resolvedCategory.rawValue != rhs.resolvedCategory.rawValue {
                return lhs.resolvedCategory.rawValue < rhs.resolvedCategory.rawValue
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                AppTheme.Gradients.screenSheen.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        titleBlock
                        actionPanel

                        if let errorMessage {
                            errorBanner(errorMessage)
                        }

                        if isLoading && places.isEmpty {
                            loadingState
                        } else if places.isEmpty {
                            emptyState
                        } else {
                            placesSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Saved Addresses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .task(id: userID) {
            hydrateFromCacheIfNeeded()
            await loadPlaces()
        }
        .sheet(item: $draft, onDismiss: resetLocationSearch) { currentDraft in
            savedAddressEditor(currentDraft)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .fullScreenCover(isPresented: $showMapPicker) {
            SavedAddressMapPickerView { coordinate, name, address in
                applyPickedLocation(coordinate: coordinate, name: name, address: address)
                showMapPicker = false
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if sheetNavigator != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button { sheetNavigator?.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                }
                .accessibilityLabel("Back")
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button { startNewAddress() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AppTheme.Colors.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add saved address")
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.Colors.accentTint.opacity(0.55)))

                Text("Places")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }

            Text("Manage the saved locations Track uses in Trips, shortcuts, and map pins.")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var actionPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                statBlock(value: "\(places.count)", label: "Saved")
                statBlock(value: "\(visiblePlacesCount)", label: "On Map")
                statBlock(value: "\(customCount)", label: "Custom")
            }

            HStack(spacing: 10) {
                primaryActionButton(
                    title: "Add Place",
                    subtitle: "Apple search",
                    icon: "magnifyingglass",
                    action: startNewAddress
                )

                primaryActionButton(
                    title: "Pick on Map",
                    subtitle: "Drop a pin",
                    icon: "map.fill",
                    action: startNewAddressFromMap
                )
            }
        }
        .padding(14)
        .managementPanel()
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Colors.cardInset.opacity(0.86))
        )
    }

    private func primaryActionButton(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AppTheme.Colors.accent))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.Colors.cardElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(ManagementPressStyle())
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.Colors.alertRed)
                .frame(width: 30, height: 30)
                .background(Circle().fill(AppTheme.Colors.alertRed.opacity(0.12)))

            Text(message)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button { errorMessage = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.Colors.alertRed.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.Colors.alertRed.opacity(0.16), lineWidth: 1)
        )
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.Colors.accent)
            Text("Loading saved places")
                .font(AppTheme.Typography.captionBold)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .managementPanel()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "mappin.slash")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(AppTheme.Colors.accentTint.opacity(0.55)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("No saved places yet")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("Add home, work, school, or any custom stop once and reuse it everywhere.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                primaryActionButton(
                    title: "Search",
                    subtitle: "Apple places",
                    icon: "magnifyingglass",
                    action: startNewAddress
                )
                primaryActionButton(
                    title: "Map",
                    subtitle: "Pick pin",
                    icon: "map.fill",
                    action: startNewAddressFromMap
                )
            }
        }
        .padding(16)
        .managementPanel()
    }

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved Locations")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                Spacer()
                Text("Tap a row to edit")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 10) {
                ForEach(sortedPlaces) { place in
                    savedAddressRow(place)
                }
            }
        }
    }

    private func savedAddressRow(_ place: SavedLocation) -> some View {
        Button {
            edit(place)
        } label: {
            HStack(spacing: 12) {
                placeBadge(place)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(place.name)
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)

                        categoryTag(place.resolvedCategory.label)
                    }

                    Text(place.address.isEmpty ? coordinateText(place) : place.address)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    Task { await toggleVisibility(place) }
                } label: {
                    Image(systemName: place.visibleOnMap ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(place.visibleOnMap ? AppTheme.Colors.accent : AppTheme.Colors.textTertiary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(AppTheme.Colors.cardInset))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(place.visibleOnMap ? "Hide on map" : "Show on map")

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.7))
            }
            .padding(12)
            .managementPanel(cornerRadius: 18, shadowRadius: 10, shadowY: 4)
        }
        .buttonStyle(ManagementPressStyle())
    }

    private func placeBadge(_ place: SavedLocation) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.Colors.accentTint.opacity(0.62))
                .frame(width: 50, height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(AppTheme.Colors.accent.opacity(0.18), lineWidth: 1)
                )

            Image(systemName: place.iconName)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.Colors.accent)

            Circle()
                .fill(place.visibleOnMap ? AppTheme.Colors.successGreen : AppTheme.Colors.textTertiary)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(AppTheme.Colors.cardBackground, lineWidth: 2))
                .offset(x: 3, y: 3)
        }
        .frame(width: 52, height: 52)
    }

    private func categoryTag(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(AppTheme.Colors.textTertiary)
            .lineLimit(1)
    }

    private func coordinateText(_ place: SavedLocation) -> String {
        String(format: "%.4f, %.4f", place.latitude, place.longitude)
    }

    private func savedAddressEditor(_ currentDraft: SavedAddressDraft) -> some View {
        NavigationStack {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                AppTheme.Gradients.screenSheen.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        editorSummary(currentDraft)
                        editorFields(currentDraft)
                        locationPickerSection(currentDraft)
                        iconPicker
                        visibilityToggle
                        if currentDraft.placeID != nil {
                            deleteButton
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(currentDraft.placeID == nil ? "Add Place" : "Edit Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { draft = nil }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "Saving" : "Save") {
                        Task { await saveDraft() }
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .disabled(isSaving || draft?.hasCoordinate != true)
                }
            }
        }
    }

    private func editorSummary(_ currentDraft: SavedAddressDraft) -> some View {
        HStack(spacing: 12) {
            Image(systemName: draft?.icon ?? currentDraft.icon)
                .font(.system(size: 21, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.Colors.accentTint.opacity(0.65))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text((draft?.label ?? currentDraft.label).isEmpty ? "New saved place" : (draft?.label ?? currentDraft.label))
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text((draft?.address ?? currentDraft.address).isEmpty ? "Choose a location with Apple search or the map." : (draft?.address ?? currentDraft.address))
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .managementPanel()
    }

    private func editorFields(_ currentDraft: SavedAddressDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeader(title: "Details", icon: "slider.horizontal.3")

            VStack(spacing: 10) {
                managementTextField(
                    title: "Name",
                    placeholder: "Home, Work, Gym...",
                    text: Binding(
                        get: { draft?.label ?? currentDraft.label },
                        set: { draft?.label = $0 }
                    )
                )

                Picker("Type", selection: Binding(
                    get: { draft?.category ?? currentDraft.category },
                    set: { newValue in
                        let oldCategory = draft?.category ?? currentDraft.category
                        draft?.category = newValue
                        if draft?.icon == oldCategory.defaultIcon || draft?.icon.isEmpty == true {
                            draft?.icon = newValue.defaultIcon
                        }
                    }
                )) {
                    ForEach(SavedAddressDraft.categories, id: \.self) { category in
                        Text(category.label).tag(category)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(14)
        .managementPanel()
    }

    private func managementTextField(
        title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .textCase(.uppercase)
            TextField(placeholder, text: text)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.Colors.cardInset)
                )
        }
    }

    private func locationPickerSection(_ currentDraft: SavedAddressDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                panelHeader(title: "Location", icon: "location.magnifyingglass")
                Spacer()
                if isResolvingSearch || appleSearch.isSearching {
                    ProgressView()
                        .tint(AppTheme.Colors.accent)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                TextField("Search Apple Maps", text: $searchQuery)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .textInputAutocapitalization(.words)
                    .onChange(of: searchQuery) { _, value in
                        appleSearch.updateQuery(value)
                    }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        appleSearch.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.Colors.cardInset)
            )

            if !appleSearch.completions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(appleSearch.completions.prefix(5)) { completion in
                        Button {
                            Task { await selectAppleCompletion(completion) }
                        } label: {
                            appleCompletionRow(completion)
                        }
                        .buttonStyle(ManagementPressStyle())
                    }
                }
            }

            Button {
                showMapPicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Choose with Map")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(AppTheme.Colors.accent)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.Colors.accentTint.opacity(0.42))
                )
            }
            .buttonStyle(ManagementPressStyle())

            if (draft ?? currentDraft).hasCoordinate {
                selectedLocationSummary(currentDraft)
            }
        }
        .padding(14)
        .managementPanel()
    }

    private func appleCompletionRow(_ completion: MKLocalSearchCompletion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: completion.iconName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(AppTheme.Colors.accentTint.opacity(0.45)))

            VStack(alignment: .leading, spacing: 2) {
                Text(completion.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Colors.cardInset.opacity(0.75))
        )
    }

    private func selectedLocationSummary(_ currentDraft: SavedAddressDraft) -> some View {
        let activeDraft = draft ?? currentDraft
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.Colors.successGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text(activeDraft.address.isEmpty ? "Location selected" : activeDraft.address)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(2)
                Text(String(format: "%.4f, %.4f", activeDraft.latitude, activeDraft.longitude))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Colors.successGreen.opacity(0.08))
        )
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeader(title: "Icon", icon: "square.grid.2x2.fill")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(PlanViewModel.customPlaceIcons, id: \.icon) { option in
                    let isSelected = draft?.icon == option.icon
                    Button { draft?.icon = option.icon } label: {
                        Image(systemName: option.icon)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(isSelected ? .white : AppTheme.Colors.textSecondary)
                            .frame(height: 40)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.cardInset)
                            )
                    }
                    .buttonStyle(ManagementPressStyle())
                }
            }
        }
        .padding(14)
        .managementPanel()
    }

    private var visibilityToggle: some View {
        Toggle(isOn: Binding(
            get: { draft?.visibleOnMap ?? true },
            set: { draft?.visibleOnMap = $0 }
        )) {
            Label("Show as a map pin", systemImage: "eye.fill")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .padding(14)
        .managementPanel()
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            Task { await deleteDraft() }
        } label: {
            Label("Delete Place", systemImage: "trash")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.alertRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.Colors.alertRed.opacity(0.08))
                )
        }
        .buttonStyle(ManagementPressStyle())
    }

    private func panelHeader(title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppTheme.Colors.accent)
            Text(title)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .textCase(.uppercase)
        }
    }

    private func startNewAddress() {
        draft = SavedAddressDraft()
        resetLocationSearch()
    }

    private func startNewAddressFromMap() {
        draft = SavedAddressDraft()
        resetLocationSearch()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            showMapPicker = true
        }
    }

    private func edit(_ place: SavedLocation) {
        draft = SavedAddressDraft(place: place)
        resetLocationSearch()
    }

    private func resetLocationSearch() {
        searchQuery = ""
        appleSearch.cancel()
        isResolvingSearch = false
    }

    @MainActor
    private func selectAppleCompletion(_ completion: MKLocalSearchCompletion) async {
        isResolvingSearch = true
        defer { isResolvingSearch = false }
        do {
            let item = try await appleSearch.resolve(completion)
            applyPickedLocation(
                coordinate: item.location.coordinate,
                name: item.name ?? completion.title,
                address: item.formattedAddress
            )
            resetLocationSearch()
        } catch {
            errorMessage = "That Apple Maps result could not be resolved."
        }
    }

    private func applyPickedLocation(
        coordinate: CLLocationCoordinate2D,
        name: String,
        address: String
    ) {
        if draft == nil {
            draft = SavedAddressDraft()
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft?.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            draft?.label = trimmedName.isEmpty ? draft?.category.label ?? "Place" : trimmedName
        }
        draft?.address = trimmedAddress
        draft?.latitude = coordinate.latitude
        draft?.longitude = coordinate.longitude
    }

    @MainActor
    private func hydrateFromCacheIfNeeded() {
        guard places.isEmpty else { return }
        let cachedPlaces = SavedPlacesCache.shared.allPlaces
        if !cachedPlaces.isEmpty {
            places = cachedPlaces
            errorMessage = nil
            return
        }
        guard let userID else { return }
        let cachedRecords = PlannerDataCache.shared.snapshot(for: userID).savedPlaces
        guard !cachedRecords.isEmpty else { return }
        places = Self.locations(from: cachedRecords)
        SavedPlacesCache.shared.update(all: places)
        errorMessage = nil
    }

    @MainActor
    private func loadPlaces() async {
        guard let userID else {
            hydrateFromCacheIfNeeded()
            if places.isEmpty {
                errorMessage = "Sign in to manage saved addresses."
            }
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let records = try await TrackAPI.fetchEngineSavedPlaces(userID: userID)
            places = Self.locations(from: records)
            SavedPlacesCache.shared.update(all: places)
            PlannerDataCache.shared.updateSavedPlaces(records, for: userID)
            errorMessage = nil
        } catch {
            hydrateFromCacheIfNeeded()
            if places.isEmpty {
                errorMessage = "Saved addresses could not be loaded."
            } else {
                errorMessage = nil
            }
        }
    }

    @MainActor
    private func saveDraft() async {
        guard let userID, var draft else { return }
        draft.normalize()
        guard draft.hasCoordinate else {
            errorMessage = "Choose a location before saving."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let record = try await TrackAPI.upsertEngineSavedPlace(
                request: EngineSavedPlaceUpsertRequest(
                    userID: userID,
                    label: draft.label,
                    kind: draft.category.rawValue,
                    lat: draft.latitude,
                    lon: draft.longitude,
                    address: draft.address,
                    icon: draft.icon,
                    visibleOnMap: draft.visibleOnMap,
                    placeID: draft.placeID
                )
            )
            upsertLocal(record)
            self.draft = nil
            errorMessage = nil
            notifyChanged()
        } catch {
            errorMessage = "Saved address could not be saved."
        }
    }

    @MainActor
    private func deleteDraft() async {
        guard let userID, let placeID = draft?.placeID else { return }
        do {
            try await TrackAPI.deleteEngineSavedPlace(placeID: placeID, userID: userID)
            places.removeAll { $0.enginePlaceID == placeID }
            SavedPlacesCache.shared.update(all: places)
            persistCurrentPlaces(for: userID)
            draft = nil
            notifyChanged()
        } catch {
            errorMessage = "Saved address could not be deleted."
        }
    }

    @MainActor
    private func toggleVisibility(_ place: SavedLocation) async {
        guard let userID else { return }
        do {
            let record = try await TrackAPI.upsertEngineSavedPlace(
                request: EngineSavedPlaceUpsertRequest(
                    userID: userID,
                    label: place.name,
                    kind: place.resolvedCategory.rawValue,
                    lat: place.latitude,
                    lon: place.longitude,
                    address: place.address.isEmpty ? nil : place.address,
                    icon: place.iconName,
                    visibleOnMap: !place.visibleOnMap,
                    placeID: place.enginePlaceID
                )
            )
            upsertLocal(record)
            notifyChanged()
        } catch {
            errorMessage = "Map visibility could not be updated."
        }
    }

    @MainActor
    private func upsertLocal(_ record: PlannerSavedPlaceRecord) {
        let location = Self.locations(from: [record])[0]
        places.removeAll { $0.enginePlaceID == record.placeID }
        places.insert(location, at: 0)
        places = sortedPlaces
        SavedPlacesCache.shared.update(all: places)
        if let userID {
            persistCurrentPlaces(for: userID)
        }
    }

    @MainActor
    private func persistCurrentPlaces(for userID: String) {
        PlannerDataCache.shared.updateSavedPlaces(Self.records(from: places, userID: userID), for: userID)
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .savedPlacesDidChange, object: nil)
    }

    private static func locations(from records: [PlannerSavedPlaceRecord]) -> [SavedLocation] {
        records.map { record in
            let category = SavedLocationCategory(engineKind: record.kind)
            return SavedLocation(
                enginePlaceID: record.placeID,
                name: record.label,
                address: record.address ?? "",
                latitude: record.lat,
                longitude: record.lon,
                category: category,
                iconName: record.icon ?? category.defaultIcon,
                visibleOnMap: record.visibleOnMap,
                createdAt: Date(timeIntervalSince1970: TimeInterval(record.createdAt)),
                lastUsedAt: record.lastUsedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }

    private static func records(from locations: [SavedLocation], userID: String) -> [PlannerSavedPlaceRecord] {
        let updatedAt = Int(Date().timeIntervalSince1970)
        return locations.compactMap { location in
            guard let placeID = location.enginePlaceID else { return nil }
            return PlannerSavedPlaceRecord(
                placeID: placeID,
                userID: userID,
                label: location.name,
                kind: location.resolvedCategory.rawValue,
                lat: location.latitude,
                lon: location.longitude,
                address: location.address.isEmpty ? nil : location.address,
                icon: location.iconName,
                visibleOnMap: location.visibleOnMap,
                createdAt: Int(location.createdAt.timeIntervalSince1970),
                updatedAt: updatedAt,
                lastUsedAt: location.lastUsedAt.map { Int($0.timeIntervalSince1970) }
            )
        }
    }
}

private struct SavedAddressMapPickerView: View {
    let onConfirm: (CLLocationCoordinate2D, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var locationSearch = LocationSearchService()
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
    )
    @State private var centerCoordinate = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
    @State private var resolvedName = ""
    @State private var resolvedAddress = ""
    @State private var isGeocoding = false
    @State private var isDragging = false
    @State private var geocodeTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {}
                .mapStyle(.standard(pointsOfInterest: .including([.publicTransport])))
                .ignoresSafeArea()
                .onMapCameraChange(frequency: .continuous) { context in
                    centerCoordinate = context.camera.centerCoordinate
                    isDragging = true
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    centerCoordinate = context.camera.centerCoordinate
                    isDragging = false
                    reverseGeocodeCenter()
                }

            centerPin

            VStack {
                pickerTopBar
                Spacer()
                pickerBottomCard
            }
        }
        .onAppear { reverseGeocodeCenter() }
        .onDisappear { geocodeTask?.cancel() }
    }

    private var pickerTopBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .buttonStyle(ManagementPressStyle())

            Spacer()

            Text("Choose Location")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(.ultraThinMaterial))

            Spacer()
            Color.clear.frame(width: 42, height: 42)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var centerPin: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.15))
                    .frame(width: 50, height: 50)
                Circle()
                    .strokeBorder(AppTheme.Colors.accent, lineWidth: 2.5)
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(AppTheme.Colors.accent)
                    .frame(width: 12, height: 12)
            }
            .offset(y: isDragging ? -10 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: isDragging)

            Ellipse()
                .fill(.black.opacity(isDragging ? 0.08 : 0.18))
                .frame(width: isDragging ? 8 : 16, height: isDragging ? 4 : 7)
                .blur(radius: 2)
        }
    }

    private var pickerBottomCard: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(AppTheme.Colors.textTertiary.opacity(0.35))
                .frame(width: 38, height: 4)

            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.Colors.accentTint.opacity(0.55))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    if isGeocoding {
                        Text("Finding address")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } else {
                        Text(resolvedName.isEmpty ? "Selected pin" : resolvedName)
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Text(resolvedAddress.isEmpty ? String(format: "%.4f, %.4f", centerCoordinate.latitude, centerCoordinate.longitude) : resolvedAddress)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            Button {
                onConfirm(centerCoordinate, resolvedName, resolvedAddress)
            } label: {
                Label("Use This Location", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.Gradients.accent)
                    )
            }
            .buttonStyle(ManagementPressStyle())
            .disabled(isDragging || isGeocoding)
            .opacity((isDragging || isGeocoding) ? 0.55 : 1)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground.opacity(0.62))
                )
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func reverseGeocodeCenter() {
        geocodeTask?.cancel()
        isGeocoding = true
        geocodeTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let item = try await locationSearch.reverseGeocode(centerCoordinate)
                guard !Task.isCancelled else { return }
                resolvedName = item.name ?? "Selected location"
                resolvedAddress = item.formattedAddress
            } catch {
                guard !Task.isCancelled else { return }
                resolvedName = String(format: "%.4f, %.4f", centerCoordinate.latitude, centerCoordinate.longitude)
                resolvedAddress = ""
            }
            isGeocoding = false
        }
    }
}

private struct SavedAddressDraft: Identifiable, Equatable {
    static let categories: [SavedLocationCategory] = [.home, .work, .school, .partner, .custom]

    let id = UUID()
    var placeID: Int?
    var label: String = ""
    var category: SavedLocationCategory = .custom
    var address: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var icon: String = "mappin"
    var visibleOnMap: Bool = true

    init() {}

    init(place: SavedLocation) {
        placeID = place.enginePlaceID
        label = place.name
        category = place.resolvedCategory
        address = place.address
        latitude = place.latitude
        longitude = place.longitude
        icon = place.iconName
        visibleOnMap = place.visibleOnMap
    }

    var hasCoordinate: Bool {
        latitude != 0 || longitude != 0
    }

    mutating func normalize() {
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty {
            label = category.label
        }
        if icon.isEmpty {
            icon = category.defaultIcon
        }
    }
}

private struct ManagementPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 18
    var shadowRadius: CGFloat = 12
    var shadowY: CGFloat = 5

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: AppTheme.Colors.shadow.opacity(0.14), radius: shadowRadius, y: shadowY)
    }
}

private extension View {
    func managementPanel(
        cornerRadius: CGFloat = 18,
        shadowRadius: CGFloat = 12,
        shadowY: CGFloat = 5
    ) -> some View {
        modifier(ManagementPanelModifier(cornerRadius: cornerRadius, shadowRadius: shadowRadius, shadowY: shadowY))
    }
}

private struct ManagementPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

#Preview {
    ManageSavedAddressesView()
        .preferredColorScheme(.dark)
}
