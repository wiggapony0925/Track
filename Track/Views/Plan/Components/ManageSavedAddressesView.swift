import CoreLocation
import SwiftUI

struct ManageSavedAddressesView: View {
    var sheetNavigator: SheetNavigator? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var places: [SavedLocation] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var draft: SavedAddressDraft?
    @State private var searchQuery = ""
    @State private var searchResults: [PlannerSearchResult] = []
    @State private var isSearching = false

    private var userID: String? {
        SupabaseManager.shared.currentUser?.id.uuidString.lowercased()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if let errorMessage {
                        Text(errorMessage)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Colors.alertRed)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .savedAddressCard()
                    }

                    if isLoading {
                        ProgressView()
                            .tint(AppTheme.Colors.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    } else if places.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 10) {
                            ForEach(places) { place in
                                savedAddressRow(place)
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 24)
            }
            .background(AppTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Saved Addresses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sheetNavigator != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            sheetNavigator?.goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                }
                if sheetNavigator == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startNewAddress()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .accessibilityLabel("Add saved address")
                }
            }
        }
        .task { await loadPlaces() }
        .sheet(item: $draft) { currentDraft in
            savedAddressEditor(currentDraft)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 42, height: 42)
                .background(Circle().fill(AppTheme.Colors.accent.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text("Manage Saved Addresses")
                    .font(AppTheme.Typography.cardTitle)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Home, work, and the places you visit most.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textTertiary)
            Text("No saved addresses yet")
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Button {
                startNewAddress()
            } label: {
                Label("Add Address", systemImage: "plus")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(AppTheme.Colors.accent))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .savedAddressCard()
    }

    private func savedAddressRow(_ place: SavedLocation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: place.iconName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 38, height: 38)
                .background(Circle().fill(AppTheme.Colors.accent.opacity(0.14)))

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(AppTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(place.address.isEmpty ? place.resolvedCategory.label : place.address)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                Task { await toggleVisibility(place) }
            } label: {
                Image(systemName: place.visibleOnMap ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(place.visibleOnMap ? AppTheme.Colors.successGreen : AppTheme.Colors.textTertiary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(place.visibleOnMap ? "Hide on map" : "Show on map")

            Button {
                draft = SavedAddressDraft(place: place)
                searchQuery = ""
                searchResults = []
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit saved address")
        }
        .padding(14)
        .savedAddressCard()
    }

    private func savedAddressEditor(_ currentDraft: SavedAddressDraft) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    editorFields(currentDraft)
                    locationSearchSection
                    iconPicker
                    visibilityToggle
                    if currentDraft.placeID != nil {
                        deleteButton
                    }
                }
                .padding(20)
            }
            .background(AppTheme.Colors.background.ignoresSafeArea())
            .navigationTitle(currentDraft.placeID == nil ? "Add Address" : "Edit Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { draft = nil }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "Saving" : "Save") {
                        Task { await saveDraft() }
                    }
                    .disabled(isSaving || draft?.hasCoordinate != true)
                }
            }
        }
    }

    private func editorFields(_ currentDraft: SavedAddressDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: Binding(
                get: { draft?.label ?? currentDraft.label },
                set: { draft?.label = $0 }
            ))
            .textInputAutocapitalization(.words)

            Picker("Type", selection: Binding(
                get: { draft?.category ?? currentDraft.category },
                set: { newValue in
                    draft?.category = newValue
                    if draft?.icon == currentDraft.category.defaultIcon {
                        draft?.icon = newValue.defaultIcon
                    }
                }
            )) {
                ForEach(SavedAddressDraft.categories, id: \.self) { category in
                    Text(category.label).tag(category)
                }
            }
            .pickerStyle(.segmented)

            TextField("Address", text: Binding(
                get: { draft?.address ?? currentDraft.address },
                set: { draft?.address = $0 }
            ))
            .textInputAutocapitalization(.words)
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .savedAddressCard()
    }

    private var locationSearchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Search for an address", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await searchAddresses() }
                } label: {
                    Image(systemName: isSearching ? "hourglass" : "magnifyingglass")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(AppTheme.Colors.accent))
                }
                .buttonStyle(.plain)
                .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ForEach(searchResults) { result in
                Button {
                    draft?.label = draft?.label.isEmpty == true ? result.label : (draft?.label ?? result.label)
                    draft?.address = result.subtitle
                    draft?.latitude = result.lat
                    draft?.longitude = result.lon
                    searchResults = []
                    searchQuery = ""
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: result.iconName)
                            .foregroundStyle(AppTheme.Colors.accent)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.label)
                                .font(AppTheme.Typography.body.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text(result.subtitle)
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .savedAddressCard()
    }

    private var iconPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
            ForEach(PlanViewModel.customPlaceIcons, id: \.icon) { option in
                Button {
                    draft?.icon = option.icon
                } label: {
                    Image(systemName: option.icon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(draft?.icon == option.icon ? .white : AppTheme.Colors.textSecondary)
                        .frame(height: 40)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(draft?.icon == option.icon ? AppTheme.Colors.accent : AppTheme.Colors.cardInset)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .savedAddressCard()
    }

    private var visibilityToggle: some View {
        Toggle(isOn: Binding(
            get: { draft?.visibleOnMap ?? true },
            set: { draft?.visibleOnMap = $0 }
        )) {
            Label("Show on map", systemImage: "eye.fill")
                .font(AppTheme.Typography.body.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .padding(14)
        .savedAddressCard()
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            Task { await deleteDraft() }
        } label: {
            Label("Delete Address", systemImage: "trash")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.Colors.alertRed)
    }

    private func startNewAddress() {
        draft = SavedAddressDraft()
        searchQuery = ""
        searchResults = []
    }

    @MainActor
    private func loadPlaces() async {
        guard let userID else {
            errorMessage = "Sign in to manage saved addresses."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let records = try await TrackAPI.fetchEngineSavedPlaces(userID: userID)
            places = Self.locations(from: records)
            SavedPlacesCache.shared.update(all: places)
        } catch {
            errorMessage = "Saved addresses could not be loaded."
        }
    }

    @MainActor
    private func saveDraft() async {
        guard let userID, var draft else { return }
        draft.normalize()
        guard draft.hasCoordinate else {
            errorMessage = "Search and select an address before saving."
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
    private func searchAddresses() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await TrackAPI.fetchEngineSearch(
                query: query,
                userID: userID,
                limit: 8
            )
        } catch {
            searchResults = []
            errorMessage = "Address search failed."
        }
    }

    @MainActor
    private func upsertLocal(_ record: PlannerSavedPlaceRecord) {
        let location = Self.locations(from: [record])[0]
        places.removeAll { $0.enginePlaceID == record.placeID }
        places.insert(location, at: 0)
        places.sort { lhs, rhs in
            lhs.resolvedCategory.rawValue == rhs.resolvedCategory.rawValue
                ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                : lhs.resolvedCategory.rawValue < rhs.resolvedCategory.rawValue
        }
        SavedPlacesCache.shared.update(all: places)
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

#Preview {
    ManageSavedAddressesView()
        .preferredColorScheme(.dark)
}

private struct SavedAddressCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: AppTheme.Colors.shadow.opacity(0.18), radius: 12, y: 5)
    }
}

private extension View {
    func savedAddressCard() -> some View { modifier(SavedAddressCardModifier()) }
}